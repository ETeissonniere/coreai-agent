// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation

public struct DecodeMetricsSnapshot: Sendable {
    public let tokens: Int
    public let seconds: Double
}

public actor DecodeMetrics {
    private var tokens = 0
    private var seconds = 0.0

    public func snapshot() -> DecodeMetricsSnapshot {
        DecodeMetricsSnapshot(tokens: tokens, seconds: seconds)
    }

    func record(tokens: Int, duration: Duration) {
        self.tokens += tokens
        let parts = duration.components
        seconds += Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
