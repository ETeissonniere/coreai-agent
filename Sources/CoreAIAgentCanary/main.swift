import CoreAILanguageModels
import Foundation
import FoundationModels
import CoreAIAgentRuntime

if ProcessInfo.processInfo.environment["COREAI_VERBOSE"] == "1" {
    CLILogger.setLevel(to: 2)
}

let mode = CommandLine.arguments.dropFirst().first
let agentToolMode = mode == "--agent-tool" || mode == "--agent-web-tool"
let webToolMode = mode == "--agent-web-tool"
let positionalArguments = agentToolMode
    ? Array(CommandLine.arguments.dropFirst(2))
    : Array(CommandLine.arguments.dropFirst())

guard let bundlePath = positionalArguments.first else {
    FileHandle.standardError.write(Data(
        "usage: coreai-agent-canary [--agent-tool] /path/to/model-bundle [prompt]\n".utf8
    ))
    exit(2)
}

let bundleURL = URL(filePath: bundlePath, directoryHint: .isDirectory)
let prompt = positionalArguments.dropFirst().first ?? (webToolMode
    ? "Use searchWeb for 'Apple Core AI' with exactly 3 results, then summarize the result."
    : agentToolMode
        ? "Use countCharacters to count the characters in the exact text 'CoreAI', then report the result."
        : "Reply with exactly: Core AI is running.")

do {
    let clock = ContinuousClock()
    let loadStart = clock.now
    let model = try await CoreAILanguageModel(resourcesAt: bundleURL)
    let loadTime = loadStart.duration(to: clock.now)
    let journal = AgentEventJournal()
    let tools: [any Tool] = webToolMode
        ? [WebSearchTool(provider: CanarySearchProvider())]
        : [CharacterCountTool()]
    let session = agentToolMode
        ? LocalAgentSession.make(
            model: model,
            instructions: "Use the available tool to answer the request.",
            tools: tools,
            journal: journal,
            toolCallingMode: .required
        )
        : LanguageModelSession(model: model)
    let start = clock.now
    let stream = session.streamResponse(
        to: prompt,
        options: GenerationOptions(
            temperature: nil,
            maximumResponseTokens: agentToolMode ? 256 : 64
        )
    )
    var firstTokenAt: ContinuousClock.Instant?
    var content = ""
    var input = 0
    var output = 0
    for try await snapshot in stream {
        content = snapshot.content
        input = snapshot.usage.input.totalTokenCount
        output = snapshot.usage.output.totalTokenCount
        if firstTokenAt == nil, !content.isEmpty { firstTokenAt = clock.now }
    }
    let elapsed = start.duration(to: clock.now)
    let ttft = start.duration(to: firstTokenAt ?? clock.now)
    print(content)
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let ttftSeconds = Double(ttft.components.seconds) + Double(ttft.components.attoseconds) / 1e18
    let decodeSeconds = seconds - ttftSeconds
    let prefillRate = ttftSeconds > 0 ? Double(input) / ttftSeconds : 0
    let decodeRate = decodeSeconds > 0 ? Double(output) / decodeSeconds : 0
    let report = "load: \(loadTime) · input: \(input) · output: \(output) · TTFT: \(ttft) · prefill: \(prefillRate.formatted(.number.precision(.fractionLength(1)))) tok/s · decode: \(decodeRate.formatted(.number.precision(.fractionLength(1)))) tok/s\n"
    FileHandle.standardError.write(Data(report.utf8))
    if agentToolMode {
        let events = await journal.snapshot()
        for event in events {
            FileHandle.standardError.write(Data("agent-event: \(event)\n".utf8))
        }
        let expectedTool = webToolMode ? "searchWeb" : "countCharacters"
        let usedTool = events.contains {
            if case .toolOutput(_, expectedTool, _) = $0 { return true }
            return false
        }
        guard usedTool else {
            FileHandle.standardError.write(Data("error: model did not complete the deterministic tool call\n".utf8))
            exit(3)
        }
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

private struct CanarySearchProvider: WebSearching {
    func search(query: String, maximumResults: Int) async throws -> [WebSource] {
        [WebSource(
            title: "Canary result \(maximumResults)",
            url: URL(string: "https://example.com/core-ai")!,
            snippet: "Static result for \(query)"
        )]
    }
}
