import Foundation
import QwenAgentRuntime

struct SkillRoutingResult: Equatable {
    let prompt: String
    let selectedSkillIDs: Set<String>
    let explicitlyRequestedSkillIDs: Set<String>

    var explicitlyRequestedSkillID: String? { explicitlyRequestedSkillIDs.first }
}

/// Selects model-invocable skills from a request. Explicit `/skill-name` commands win;
/// otherwise the request is matched against skill names and descriptions.
struct SkillRouter {
    func route(
        _ input: String,
        availableSkills: [AgentSkillMetadata],
        pinnedSkillIDs: Set<String> = []
    ) -> SkillRoutingResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = explicitInvocations(in: trimmed, skills: availableSkills)
        let prompt = removingExplicitInvocations(explicit, from: trimmed)
        var selected = pinnedSkillIDs

        if !explicit.isEmpty {
            selected.formUnion(explicit.map(\.skill.id))
        } else {
            selected.formUnion(automaticallyMatchedSkills(for: prompt, in: availableSkills).map(\.id))
        }

        return SkillRoutingResult(
            prompt: prompt,
            selectedSkillIDs: selected,
            explicitlyRequestedSkillIDs: Set(explicit.map(\.skill.id))
        )
    }

    func suggestions(for input: String, in skills: [AgentSkillMetadata]) -> [AgentSkillMetadata] {
        guard let invocation = incompleteInvocation(in: input) else { return [] }
        let query = normalize(invocation.command)
        return skills.filter(\.modelInvocable).filter { skill in
            query.isEmpty || commandName(for: skill).hasPrefix(query)
        }.sorted { commandName(for: $0) < commandName(for: $1) }
    }

    func inserting(_ skill: AgentSkillMetadata, into input: String) -> String {
        let command = "/\(commandName(for: skill))"
        guard let invocation = incompleteInvocation(in: input) else {
            return input.isEmpty ? "\(command) " : "\(input) \(command) "
        }
        var result = input
        result.replaceSubrange(invocation.range, with: command)
        if result.last?.isWhitespace != true { result.append(" ") }
        return result
    }

    func commandName(for skill: AgentSkillMetadata) -> String {
        let name = skill.name.hasPrefix("builtin.") ? String(skill.name.dropFirst("builtin.".count)) : skill.name
        return normalize(name)
    }

    private struct Invocation {
        let skill: AgentSkillMetadata
        let range: Range<String.Index>
    }

    private struct IncompleteInvocation {
        let command: String
        let range: Range<String.Index>
    }

    private func explicitInvocations(
        in input: String,
        skills: [AgentSkillMetadata]
    ) -> [Invocation] {
        var invocations: [Invocation] = []
        var index = input.startIndex
        while index < input.endIndex {
            guard input[index] == "/", isSafeBoundary(before: index, in: input) else {
                index = input.index(after: index)
                continue
            }
            let end = input[index...].firstIndex(where: { $0.isWhitespace }) ?? input.endIndex
            let token = input[input.index(after: index)..<end]
            let command = normalize(String(token))
            if isCommandToken(token),
               let skill = skills.first(where: { commandName(for: $0) == command && $0.modelInvocable }) {
                invocations.append(Invocation(skill: skill, range: index..<end))
            }
            index = end
        }
        return invocations
    }

    private func incompleteInvocation(in input: String) -> IncompleteInvocation? {
        guard let slash = input.lastIndex(of: "/"),
              isSafeBoundary(before: slash, in: input) else { return nil }
        let commandStart = input.index(after: slash)
        let token = input[commandStart...]
        guard !token.contains(where: { $0.isWhitespace }), isCommandToken(token) else { return nil }
        return IncompleteInvocation(command: String(token), range: slash..<input.endIndex)
    }

    private func isSafeBoundary(before index: String.Index, in input: String) -> Bool {
        index == input.startIndex || input[input.index(before: index)].isWhitespace
    }

    private func isCommandToken(_ token: Substring) -> Bool {
        token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private func removingExplicitInvocations(_ invocations: [Invocation], from input: String) -> String {
        guard !invocations.isEmpty else { return input }
        var prompt = input
        for invocation in invocations.reversed() { prompt.removeSubrange(invocation.range) }
        prompt = prompt.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        prompt = prompt.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func automaticallyMatchedSkills(
        for prompt: String,
        in skills: [AgentSkillMetadata]
    ) -> [AgentSkillMetadata] {
        let requestTerms = meaningfulTerms(in: prompt)
        guard !requestTerms.isEmpty else { return [] }
        return skills.filter(\.modelInvocable).filter { skill in
            if requestsCurrentInformation(requestTerms), skill.allowedTools.contains("searchWeb") {
                return true
            }
            let nameTerms = meaningfulTerms(in: skill.name.replacingOccurrences(of: ".", with: " "))
            let descriptionTerms = meaningfulTerms(in: skill.description)
            let overlap = requestTerms.intersection(nameTerms.union(descriptionTerms))
            if !overlap.isEmpty && !requestTerms.intersection(nameTerms).isEmpty { return true }
            return overlap.count >= 2
        }
    }

    private func requestsCurrentInformation(_ terms: Set<String>) -> Bool {
        if !terms.isDisjoint(with: ["current", "latest", "recent", "recently", "announced", "today", "news"]) {
            return true
        }

        // A dated release, availability, or price comparison depends on externally
        // verifiable product facts even when the user does not say “latest”. Keep the
        // year requirement so generic prose about implementation or operating cost
        // does not automatically enable network access.
        let containsYear = terms.contains { term in
            guard term.count == 4, let year = Int(term) else { return false }
            return (1900...2099).contains(year)
        }
        let dateSensitiveProductTerms: Set<String> = [
            "release", "released", "launch", "launched", "availability",
            "price", "pricing", "cost", "specs", "specifications",
        ]
        return containsYear && !terms.isDisjoint(with: dateSensitiveProductTerms)
    }

    private func meaningfulTerms(in text: String) -> Set<String> {
        let stopWords: Set<String> = ["a", "an", "and", "for", "from", "in", "of", "on", "or", "the", "to", "with"]
        return Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) })
    }

    private func normalize(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "_", with: "-")
    }
}
