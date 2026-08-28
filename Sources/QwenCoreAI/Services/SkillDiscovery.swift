import Foundation
import CryptoKit

struct SkillSearchRoot: Sendable {
    let url: URL
    let scope: SkillScope
}

struct SkillDiscovery: Sendable {
    static let maximumSkillCount = 256
    static let maximumSkillBytes = 256_000
    static let reservedBuiltInNames: Set<String> = ["web-research", "document-authoring"]

    /// Discovers portable SKILL.md packages without loading their full instructions into model
    /// context. A skill with the same name in a narrower scope shadows broader scopes.
    func discover(in roots: [SkillSearchRoot]) throws -> [AgentSkillMetadata] {
        var selectedByName = [String: AgentSkillMetadata]()

        for root in roots {
            guard FileManager.default.fileExists(atPath: root.url.path) else { continue }
            let canonicalRoot = root.url.standardizedFileURL.resolvingSymlinksInPath()
            guard let enumerator = FileManager.default.enumerator(
                at: canonicalRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "SKILL.md" {
                let canonicalFile = fileURL.standardizedFileURL.resolvingSymlinksInPath()
                guard canonicalFile.path.hasPrefix(canonicalRoot.path + "/") else { continue }
                let values = try canonicalFile.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                guard let metadata = try parse(fileURL: canonicalFile, scope: root.scope) else { continue }
                let collisionKey = metadata.name.lowercased()
                if let existing = selectedByName[collisionKey] {
                    throw SkillDiscoveryError.duplicateName(
                        name: metadata.name,
                        firstPath: existing.path,
                        secondPath: metadata.path
                    )
                }
                guard selectedByName.count < Self.maximumSkillCount else {
                    throw SkillDiscoveryError.tooManySkills(maximum: Self.maximumSkillCount)
                }
                selectedByName[collisionKey] = metadata
            }
        }

        return selectedByName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func parse(fileURL: URL, scope: SkillScope) throws -> AgentSkillMetadata? {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= Self.maximumSkillBytes else {
            throw SkillDiscoveryError.skillTooLarge(path: fileURL.path, maximumBytes: Self.maximumSkillBytes)
        }
        guard let source = String(data: data, encoding: .utf8) else { return nil }
        let lines = source.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closingIndex = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else { return nil }

        var fields = [String: String]()
        var listFields = [String: [String]]()
        var activeListKey: String?
        for rawLine in lines[1..<closingIndex] {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- "), let activeListKey {
                listFields[activeListKey, default: []].append(clean(String(trimmed.dropFirst(2))))
                continue
            }
            guard let separator = rawLine.firstIndex(of: ":") else { continue }
            let key = rawLine[..<separator].trimmingCharacters(in: .whitespaces)
            let value = rawLine[rawLine.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                activeListKey = key
            } else {
                fields[key] = clean(value)
                activeListKey = nil
            }
        }

        guard let name = fields["name"], !name.isEmpty,
              let description = fields["description"], !description.isEmpty else { return nil }
        let normalizedName = name.lowercased()
        guard normalizedName.range(of: #"^[a-z0-9][a-z0-9._-]{0,79}$"#, options: .regularExpression) != nil else {
            throw SkillDiscoveryError.invalidName(name)
        }
        if scope != .bundled, Self.reservedBuiltInNames.contains(normalizedName) {
            throw SkillDiscoveryError.reservedBuiltInName(name)
        }
        let inlineTools = fields["allowed-tools"].map(parseInlineList) ?? []
        let allowedTools = listFields["allowed-tools", default: []] + inlineTools
        let disabled = fields["disable-model-invocation"]?.lowercased() == "true"

        let contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AgentSkillMetadata(
            name: name,
            description: description,
            version: fields["version"],
            path: fileURL.deletingLastPathComponent().path,
            scope: scope,
            allowedTools: allowedTools,
            modelInvocable: !disabled,
            identity: "skill:\(scope.rawValue):\(normalizedName):sha256:\(contentHash)",
            contentHash: contentHash,
            provenance: fileURL.path,
            trust: scope == .bundled ? .bundled : .local
        )
    }

    private func parseInlineList(_ value: String) -> [String] {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .map { clean(String($0)) }
            .filter { !$0.isEmpty }
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
    }
}

enum SkillDiscoveryError: LocalizedError, Equatable {
    case duplicateName(name: String, firstPath: String, secondPath: String)
    case invalidName(String)
    case reservedBuiltInName(String)
    case tooManySkills(maximum: Int)
    case skillTooLarge(path: String, maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .duplicateName(let name, let firstPath, let secondPath):
            "Skill name collision for \(name): \(firstPath) and \(secondPath)."
        case .invalidName(let name): "Invalid skill name: \(name)."
        case .reservedBuiltInName(let name): "Skill name is reserved for a built-in skill: \(name)."
        case .tooManySkills(let maximum): "Skill registry exceeds its limit of \(maximum) entries."
        case .skillTooLarge(let path, let maximumBytes):
            "Skill at \(path) exceeds the \(maximumBytes)-byte metadata limit."
        }
    }
}
