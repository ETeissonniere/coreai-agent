// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can be
// found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import FoundationModels
import Testing
import Tokenizers

@testable import CoreAILanguageModels

@Suite("Per-turn reasoning mode")
struct ReasoningModeTests {
    private func prompt(_ text: String) -> Transcript.Entry {
        .prompt(.init(segments: [.text(.init(content: text))]))
    }

    @Test("Tool turns retain bounded reasoning")
    func toolTurnUsesLowReasoning() {
        let mode = CoreAILanguageModel.CoreAIExecutor.reasoningMode(
            for: [prompt("Find current information")],
            hasTools: true
        )
        #expect(mode == .low)
    }

    @Test("Ordinary chat retains standard reasoning")
    func chatUsesStandardReasoning() {
        let mode = CoreAILanguageModel.CoreAIExecutor.reasoningMode(
            for: [prompt("Explain this idea")],
            hasTools: false
        )
        #expect(mode == .standard)
    }

    @Test("No-think overrides the tool default for a recovery turn")
    func noThinkDisablesReasoning() {
        let mode = CoreAILanguageModel.CoreAIExecutor.reasoningMode(
            for: [prompt("Retry the complete tool call. /no_think")],
            hasTools: true
        )
        #expect(mode == .disabled)
    }

    @Test("Tool transcript preserves generated reasoning on its assistant entry")
    func toolTranscriptPreservesReasoningPrefix() throws {
        let arguments = try GeneratedContent(json: #"{"query":"weather"}"#)
        let messages = CoreAILanguageModel.CoreAIExecutor.makeMessages(from: [
            .prompt(.init(segments: [.text(.init(content: "Check the weather"))])),
            .reasoning(.init(segments: [.text(.init(content: "I should "))])),
            .reasoning(.init(segments: [.text(.init(content: "search."))])),
            .toolCalls(.init([
                .init(id: "call-1", toolName: "search", arguments: arguments)
            ])),
            .toolOutput(.init(
                id: "call-1",
                toolName: "search",
                segments: [.text(.init(content: "Sunny"))]
            )),
        ])

        #expect(messages.count == 3)
        #expect(messages[1]["role"] as? String == "assistant")
        #expect(messages[1]["reasoning_content"] as? String == "I should search.")
        #expect(messages[1]["tool_calls"] != nil)
        #expect(messages[2]["role"] as? String == "tool")
    }

    @Test("Tool transcript reuses the model's exact generated call text")
    func toolTranscriptPreservesRawCallText() throws {
        let rawText = "<tool_call>\n{  \"arguments\": {\"z\":1,\"a\":2}, \"name\":\"search\" }\n</tool_call>"
        let arguments = try GeneratedContent(json: #"{"query":"weather"}"#)
        let messages = CoreAILanguageModel.CoreAIExecutor.makeMessages(from: [
            prompt("Question"),
            .reasoning(.init(segments: [.text(.init(content: "Think"))])),
            .toolCalls(.init([.init(id: "call-1", toolName: "search", arguments: arguments)])),
            .toolOutput(.init(
                id: "call-1",
                toolName: "search",
                segments: [.text(.init(content: "Sunny"))]
            )),
        ]) { _ in rawText }

        #expect(messages[1]["content"] as? String == rawText)
        #expect(messages[1]["tool_calls"] == nil)
        #expect(messages[2]["role"] as? String == "tool")
    }

    @Test("Qwen tool continuation retains the rendered token prefix")
    func qwenToolContinuationRetainsTokenPrefix() async throws {
        let source = URL(fileURLWithPath: #filePath)
        let repository = source.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let tokenizerURL = repository.appending(path: "Models/TitleModel/qwen3_0_6b_4bit_dynamic/tokenizer")
        let tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerURL)
        let template = try #require(CoreAIRunner.prefixStableChatTemplate(in: tokenizerURL))
        let rawCall = "\n\n<tool_call>\n{  \"arguments\": {\"z\":1}, \"name\":\"search\" }\n</tool_call>"
        let arguments = try GeneratedContent(json: #"{"query":"weather"}"#)
        let assistantEntries: [Transcript.Entry] = [
            prompt("Question"),
            .toolCalls(.init([.init(id: "call-1", toolName: "search", arguments: arguments)])),
        ]
        let initialMessages = CoreAILanguageModel.CoreAIExecutor.makeMessages(
            from: [prompt("Question")])
        let assistantMessages = CoreAILanguageModel.CoreAIExecutor.makeMessages(
            from: assistantEntries) { _ in rawCall }
        let continuationMessages = CoreAILanguageModel.CoreAIExecutor.makeMessages(
            from: assistantEntries + [
                .toolOutput(.init(
                    id: "call-1", toolName: "search",
                    segments: [.text(.init(content: "Sunny"))]))
            ]) { _ in rawCall }

        func render(_ messages: [Message], generationPrompt: Bool) throws -> [Int] {
            try tokenizer.applyChatTemplate(
                messages: messages,
                chatTemplate: .literal(template),
                addGenerationPrompt: generationPrompt,
                truncation: false,
                maxLength: nil,
                tools: nil,
                additionalContext: nil)
        }

        let initial = try render(initialMessages, generationPrompt: true)
        let completedAssistant = try render(assistantMessages, generationPrompt: false)
        let continuation = try render(continuationMessages, generationPrompt: true)
        #expect(completedAssistant.starts(with: initial))
        #expect(continuation.starts(with: completedAssistant))
    }
}
