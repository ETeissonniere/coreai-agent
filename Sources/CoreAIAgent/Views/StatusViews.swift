import SwiftUI

struct ModelStatusPill: View {
    let phase: ModelPhase

    var body: some View {
        HStack(spacing: 6) {
            if phase == .loading || phase == .generating || phase == .compacting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon)
            }
            Text(phase.label)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch phase {
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .missing: "arrow.down.circle"
        default: "circle"
        }
    }
}

struct PerformanceInspectorView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Runtime") {
                LabeledContent("Backend", value: "Core AI")
                LabeledContent("Mode", value: model.selectedModelProfile.label)
                LabeledContent("Model", value: model.selectedModelProfile.modelName)
                LabeledContent("Quantization", value: model.selectedModelProfile.quantization)
                LabeledContent("Reasoning", value: model.selectedReasoningEnabled ? "On" : "Off")
                LabeledContent("State", value: model.modelPhase.label)
            }
            Section("Latest Response") {
                if let metrics = model.lastMetrics {
                    LabeledContent("Prompt tokens", value: "\(metrics.promptTokens)")
                    LabeledContent("Cached tokens", value: "\(metrics.cachedTokens)")
                    LabeledContent("Prefill", value: "\(metrics.prefillTokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s")
                    LabeledContent("Time to first token", value: metrics.timeToFirstToken.formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1))))
                    LabeledContent("Generated tokens", value: "\(metrics.generatedTokens)")
                    LabeledContent("Reasoning tokens", value: "\(metrics.reasoningTokens)")
                    LabeledContent("Decode", value: "\(metrics.tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s")
                } else {
                    Text("Performance measurements appear after a response.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Context Management") {
                if let context = model.selectedContext {
                    LabeledContent("State", value: contextLabel(context.state))
                    LabeledContent("Used", value: "\(context.usedTokens.formatted()) tokens")
                    LabeledContent("Active budget", value: "\(context.activeBudget.formatted()) tokens")
                    LabeledContent("Usable input", value: "\(context.inputLimit.formatted()) tokens")
                    LabeledContent("Output reserve", value: "\(context.outputReserve.formatted()) tokens")
                    LabeledContent("Model limit", value: "\(context.modelLimit.formatted()) tokens")
                    LabeledContent("Compactions", value: "\(context.compactionCount)")
                    ProgressView(value: context.utilization)
                        .tint(contextColor(context.state))
                } else {
                    Text("Context usage appears after the first message.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("KV Cache") {
                if let cache = model.selectedKVCache {
                    KVCacheCard(cache: cache)
                } else {
                    Text("KV-cache telemetry appears during generation.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Performance")
    }

    private func contextLabel(_ state: ContextState) -> String {
        switch state {
        case .normal: "Normal"
        case .elevated: "70% warning"
        case .high: "85% warning"
        case .compacting: "Compacting"
        }
    }

    private func contextColor(_ state: ContextState) -> Color {
        switch state {
        case .normal: .accentColor
        case .elevated: .orange
        case .high, .compacting: .red
        }
    }
}

private struct KVCacheCard: View {
    let cache: KVCacheSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 22) {
                cacheGauge(
                    title: "In use",
                    value: cache.allocationUtilization,
                    label: cache.usedTokens.formatted()
                )
                cacheGauge(
                    title: "Allocated",
                    value: allocatedFraction,
                    label: cache.allocatedTokens.formatted()
                )
            }
            .frame(maxWidth: .infinity)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.secondary.opacity(0.28))
                        .frame(width: geometry.size.width * allocatedFraction)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * cache.maximumUtilization)
                }
            }
            .frame(height: 10)
            .accessibilityLabel("KV cache usage")
            .accessibilityValue("\(cache.usedTokens) of \(cache.maximumTokens) tokens")

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                metricRow("Used", "\(cache.usedTokens.formatted()) tokens")
                metricRow("Allocated", "\(cache.allocatedTokens.formatted()) tokens")
                metricRow("Maximum", "\(cache.maximumTokens.formatted()) tokens")
                metricRow("Prefix reused", "\(cache.reusedPrefixTokens.formatted()) tokens")
                metricRow("Headroom", "\(max(0, cache.maximumTokens - cache.usedTokens).formatted()) tokens")
            }
            .font(.caption.monospacedDigit())
        }
        .padding(.vertical, 6)
    }

    private var allocatedFraction: Double {
        guard cache.maximumTokens > 0 else { return 0 }
        return min(Double(cache.allocatedTokens) / Double(cache.maximumTokens), 1)
    }

    private func cacheGauge(title: String, value: Double, label: String) -> some View {
        Gauge(value: value) {
            Text(title)
        } currentValueLabel: {
            Text(label).font(.caption2.monospacedDigit())
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(value > 0.85 ? .orange : .accentColor)
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
