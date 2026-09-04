// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation

public struct GenerationThroughputSnapshot: Sendable {
    public let prefillTokens: Int
    public let prefillSeconds: Double
    public let decodeTokens: Int
    public let decodeSeconds: Double
    public let timeToFirstTokenSeconds: Double
    public let initialPrefillSeconds: Double
    public let continuationPrefillSeconds: Double
    public let toolCallGenerationSeconds: Double
}

public actor GenerationThroughput {
    private var prefillTokens = 0
    private var prefillSeconds = 0.0
    private var decodeTokens = 0
    private var decodeSeconds = 0.0
    private var timeToFirstTokenSeconds = 0.0
    private var initialPrefillSeconds = 0.0
    private var continuationPrefillSeconds = 0.0
    private var toolCallGenerationSeconds = 0.0
    private var generationCount = 0

    public init() {}

    public func snapshot() -> GenerationThroughputSnapshot {
        GenerationThroughputSnapshot(
            prefillTokens: prefillTokens, prefillSeconds: prefillSeconds,
            decodeTokens: decodeTokens, decodeSeconds: decodeSeconds,
            timeToFirstTokenSeconds: timeToFirstTokenSeconds,
            initialPrefillSeconds: initialPrefillSeconds,
            continuationPrefillSeconds: continuationPrefillSeconds,
            toolCallGenerationSeconds: toolCallGenerationSeconds
        )
    }

    public func beginResponse() {
        prefillTokens = 0
        prefillSeconds = 0
        decodeTokens = 0
        decodeSeconds = 0
        timeToFirstTokenSeconds = 0
        initialPrefillSeconds = 0
        continuationPrefillSeconds = 0
        toolCallGenerationSeconds = 0
        generationCount = 0
    }

    func recordFirstToken(after duration: Duration) {
        guard generationCount == 0, timeToFirstTokenSeconds == 0 else { return }
        timeToFirstTokenSeconds = duration.seconds
    }

    func record(promptTokens: Int, prefillDuration: Duration, generatedTokens: Int,
                decodeDuration: Duration, timeToFirstToken: Duration,
                generationDuration: Duration, excludedFromDecode: Bool) {
        prefillTokens += promptTokens
        prefillSeconds += prefillDuration.seconds
        if generationCount == 0 {
            if timeToFirstTokenSeconds == 0 { timeToFirstTokenSeconds = timeToFirstToken.seconds }
            initialPrefillSeconds = prefillDuration.seconds
        } else {
            continuationPrefillSeconds += prefillDuration.seconds
        }
        generationCount += 1
        guard !excludedFromDecode else {
            toolCallGenerationSeconds += max(0, generationDuration.seconds - prefillDuration.seconds)
            return
        }
        decodeTokens += max(0, generatedTokens - 1)
        decodeSeconds += decodeDuration.seconds
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
