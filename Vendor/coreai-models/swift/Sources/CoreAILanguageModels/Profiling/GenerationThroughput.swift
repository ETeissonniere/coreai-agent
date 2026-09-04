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
}

public actor GenerationThroughput {
    private var prefillTokens = 0
    private var prefillSeconds = 0.0
    private var decodeTokens = 0
    private var decodeSeconds = 0.0

    public init() {}

    public func snapshot() -> GenerationThroughputSnapshot {
        GenerationThroughputSnapshot(
            prefillTokens: prefillTokens, prefillSeconds: prefillSeconds,
            decodeTokens: decodeTokens, decodeSeconds: decodeSeconds
        )
    }

    func record(promptTokens: Int, prefillDuration: Duration, generatedTokens: Int,
                decodeDuration: Duration, excludedFromDecode: Bool) {
        prefillTokens += promptTokens
        prefillSeconds += prefillDuration.seconds
        guard !excludedFromDecode else { return }
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
