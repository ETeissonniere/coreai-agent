// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can be
// found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import FoundationModels
import Testing

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
}
