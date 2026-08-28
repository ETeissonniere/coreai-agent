import Testing
@testable import QwenCoreAI
import QwenAgentRuntime

private let routingSkills = [
    AgentSkillMetadata(
        name: "builtin.web-research",
        description: "Search current web sources and return citations.",
        version: "1",
        path: "builtin://web-research",
        scope: .bundled,
        allowedTools: ["searchWeb"],
        modelInvocable: true
    ),
    AgentSkillMetadata(
        name: "builtin.document-authoring",
        description: "Create and revise local documents.",
        version: "1",
        path: "builtin://document-authoring",
        scope: .bundled,
        allowedTools: ["createDocumentDraft"],
        modelInvocable: true
    ),
]

@Test func skillRouterAutomaticallySelectsRelevantSkill() {
    let result = SkillRouter().route(
        "Search the web for current Apple documentation and cite sources",
        availableSkills: routingSkills
    )

    #expect(result.selectedSkillIDs == [routingSkills[0].id])
    #expect(result.prompt == "Search the web for current Apple documentation and cite sources")
}

@Test func recentAnnouncementRequestAutomaticallySelectsWebResearch() {
    let result = SkillRouter().route(
        "Please analyze the relevance of Apple's recent WWDC CoreAI announcements and Mac Ultras announced last week to local AI workflows",
        availableSkills: routingSkills
    )

    #expect(result.selectedSkillIDs == [routingSkills[0].id])
}

@Test func datedProductReleaseAndCostRequestAutomaticallySelectsWebResearch() {
    let result = SkillRouter().route(
        "Can you analyze the relevance of the 2026 Mac Ultra release for local AI tasks vs $$ cost",
        availableSkills: routingSkills
    )

    #expect(result.selectedSkillIDs == [routingSkills[0].id])
}

@Test func genericCostAnalysisDoesNotAutomaticallySelectWebResearch() {
    let result = SkillRouter().route(
        "Analyze the relevance of quantization for local AI tasks versus compute cost",
        availableSkills: routingSkills
    )

    #expect(result.selectedSkillIDs.isEmpty)
}

@Test func genericReleaseProcessDoesNotAutomaticallySelectWebResearch() {
    let result = SkillRouter().route(
        "Explain how a software release process affects engineering cost",
        availableSkills: routingSkills
    )

    #expect(result.selectedSkillIDs.isEmpty)
}

@Test func slashCommandExplicitlySelectsSkillAndIsRemovedFromPrompt() {
    let result = SkillRouter().route(
        "/document-authoring Create a launch brief",
        availableSkills: routingSkills
    )

    #expect(result.selectedSkillIDs == [routingSkills[1].id])
    #expect(result.explicitlyRequestedSkillID == routingSkills[1].id)
    #expect(result.prompt == "Create a launch brief")
}

@Test func unknownSlashCommandRemainsOrdinaryPrompt() {
    let result = SkillRouter().route("/unknown explain this", availableSkills: routingSkills)

    #expect(result.selectedSkillIDs.isEmpty)
    #expect(result.prompt == "/unknown explain this")
}

@Test func skillSuggestionsFilterByCommandPrefix() {
    let suggestions = SkillRouter().suggestions(for: "/web", in: routingSkills)

    #expect(suggestions.map(\.name) == ["builtin.web-research"])
}

@Test func skillSuggestionsFindCommandAtEndOfExistingDraft() {
    let suggestions = SkillRouter().suggestions(for: "Please research this with /web", in: routingSkills)

    #expect(suggestions.map(\.name) == ["builtin.web-research"])
}

@Test func selectingSuggestionReplacesOnlyInlineCommandFragment() {
    let result = SkillRouter().inserting(routingSkills[0], into: "Please research this with /we")

    #expect(result == "Please research this with /web-research ")
}

@Test func inlineSlashCommandsSelectMultipleSkillsAndAreRemovedFromPrompt() {
    let result = SkillRouter().route(
        "Research this /web-research and then /document-authoring create a brief",
        availableSkills: routingSkills
    )

    #expect(result.selectedSkillIDs == Set(routingSkills.map(\.id)))
    #expect(result.explicitlyRequestedSkillIDs == Set(routingSkills.map(\.id)))
    #expect(result.prompt == "Research this and then create a brief")
}

@Test func slashLikeURLsPathsAndEscapesAreNotCommands() {
    let input = #"Compare https://example.com/web-research, /tmp/web-research, and \/web-research"#
    let result = SkillRouter().route(input, availableSkills: routingSkills)

    #expect(result.explicitlyRequestedSkillIDs.isEmpty)
    #expect(result.prompt == input)
    #expect(SkillRouter().suggestions(for: "Open https://example.com/we", in: routingSkills).isEmpty)
    #expect(SkillRouter().suggestions(for: "Open /tmp/we", in: routingSkills).isEmpty)
}

@Test func unknownInlineSlashCommandRemainsOrdinaryPrompt() {
    let input = "Explain this with /unknown please"
    let result = SkillRouter().route(input, availableSkills: routingSkills)

    #expect(result.explicitlyRequestedSkillIDs.isEmpty)
    #expect(result.prompt == input)
}

@Test func pinnedSkillsRemainSelectedAlongsideAutomaticRouting() {
    let result = SkillRouter().route(
        "Search current web sources",
        availableSkills: routingSkills,
        pinnedSkillIDs: [routingSkills[1].id]
    )

    #expect(result.selectedSkillIDs == Set(routingSkills.map(\.id)))
}
