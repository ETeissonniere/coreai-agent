import SwiftUI

struct ContextUsageView: View {
    let context: ContextStatus
    let cache: KVCacheSnapshot?

    private var composition: ContextTokenComposition? { context.composition }
    private var inputSlices: [ContextTokenSlice] {
        composition?.slices.filter { $0.category.isRetainedInput } ?? []
    }
    private var activitySlices: [ContextTokenSlice] {
        composition?.slices.filter { !$0.category.isRetainedInput } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            retainedContext
            Divider()
            generationActivity
            Divider()
            turnActivity
            Divider()
            cacheView
        }
    }

    private var retainedContext: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("Retained context", badge: "Runtime total")
            Text("Tokens currently supplied to the model as input.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let composition {
                TokenStackedBar(slices: inputSlices, usedTokens: composition.inputTokens, capacity: context.inputLimit)
                    .frame(height: 10)
                    .accessibilityLabel("Retained input context")
                    .accessibilityValue("\(composition.inputTokens) of \(context.inputLimit) tokens")

                HStack {
                    Text("\(composition.inputTokens.formatted()) retained")
                    Spacer()
                    Text("\(max(context.inputLimit - composition.inputTokens, 0).formatted()) available")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                categoryGrid(slices: inputSlices, includeAvailable: true)
                Text("The total is exact. Category splits marked ≈ are proportional estimates because Core AI does not report token spans for individual messages.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                legacyContextSummary
            }

            if context.outputReserve > 0 {
                Label("\(context.outputReserve.formatted()) tokens reserved for generation", systemImage: "arrow.down.to.line.compact")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var generationActivity: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("Current generation", badge: "Runtime")
            Text("Output activity for the current response; it is not retained input composition.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let composition, composition.generatedTokens > 0 {
                TokenStackedBar(
                    slices: activitySlices,
                    usedTokens: composition.generatedTokens,
                    capacity: max(composition.outputReserve, 1)
                )
                .frame(height: 8)
                categoryGrid(slices: activitySlices, includeAvailable: false)
                HStack {
                    Text("\(composition.generatedTokens.formatted()) generated")
                    Spacer()
                    Text("\(composition.remainingTokens.formatted()) reserved")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text("Generation activity appears while a response is running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var turnActivity: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("Turn activity", badge: "Mixed")
            Text("Input and output attributed to each recorded turn. Reasoning is activity, not retained conversation text.")
                .font(.caption)
                .foregroundStyle(.secondary)
            let turns = turnRows
            if turns.isEmpty {
                Text("Turn details appear after the first response.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        TurnActivityRow(index: index + 1, turn: turn, largest: turns.map(\.total).max() ?? 1)
                    }
                }
            }
        }
    }

    @ViewBuilder private var cacheView: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("KV cache", badge: "Runtime")
            if let cache {
                Gauge(value: Double(cache.usedTokens), in: 0...Double(max(cache.maximumTokens, 1))) {
                    Text("KV cache")
                } currentValueLabel: {
                    Text(cache.usedTokens.formatted()).monospacedDigit()
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(contextTint)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityValue("\(cache.usedTokens) of \(cache.maximumTokens) tokens")

                LabeledContent("Used", value: "\(cache.usedTokens.formatted()) tokens")
                LabeledContent("Allocated", value: "\(cache.allocatedTokens.formatted()) tokens")
                LabeledContent("Prefix reused", value: "\(cache.reusedPrefixTokens.formatted()) tokens")
                LabeledContent("Maximum", value: "\(cache.maximumTokens.formatted()) tokens")
            } else {
                Text("Cache statistics appear while the model is generating.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var legacyContextSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressView(value: context.utilization).tint(contextTint)
            HStack {
                Text("\(context.usedTokens.formatted()) used")
                Spacer()
                Text("\(max(context.inputLimit - context.usedTokens, 0).formatted()) available")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Text("Detailed composition was not recorded for this response.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func sectionHeader(_ title: String, badge: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Text(badge)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }

    private func categoryGrid(slices: [ContextTokenSlice], includeAvailable: Bool) -> some View {
        let grouped = Dictionary(grouping: slices, by: \.category)
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 7) {
            ForEach(ContextTokenCategory.allCases.filter { grouped[$0] != nil }) { category in
                let categorySlices = grouped[category] ?? []
                let tokens = categorySlices.reduce(0) { $0 + $1.tokens }
                let estimated = categorySlices.contains { $0.basis == .proportionalEstimate }
                tokenLegend(category.label, color: category.color, value: "\(estimated ? "≈" : "")\(tokens.formatted())")
            }
            if includeAvailable, let composition {
                tokenLegend(
                    "Available",
                    color: Color.secondary.opacity(0.25),
                    value: max(context.inputLimit - composition.inputTokens, 0).formatted()
                )
            }
        }
    }

    private func tokenLegend(_ label: String, color: Color, value: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).lineLimit(1)
            Spacer(minLength: 2)
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private var turnRows: [TurnActivity] {
        composition?.turns.map { TurnActivity(id: $0.id, slices: $0.slices) } ?? []
    }

    private var contextTint: Color {
        switch context.state {
        case .normal: .accentColor
        case .elevated: .yellow
        case .high: .orange
        case .compacting: .purple
        }
    }
}

private struct TurnActivity: Identifiable {
    let id: UUID
    let slices: [ContextTokenSlice]
    var total: Int { slices.reduce(0) { $0 + $1.tokens } }
}

private struct TurnActivityRow: View {
    let index: Int
    let turn: TurnActivity
    let largest: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(turn.slices) { slice in
                        Rectangle()
                            .fill(slice.category.color)
                            .frame(width: geometry.size.width * CGFloat(slice.tokens) / CGFloat(max(largest, 1)))
                    }
                }
                .clipShape(Capsule())
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 7)
            Text("\(turn.slices.contains { $0.basis == .proportionalEstimate } ? "≈" : "")\(turn.total.formatted())")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .help("Turn \(index): \(turn.total) attributed tokens")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Turn \(index)")
        .accessibilityValue("\(turn.total) attributed tokens")
    }
}

private struct TokenStackedBar: View {
    let slices: [ContextTokenSlice]
    let usedTokens: Int
    let capacity: Int

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let represented = max(slices.reduce(0) { $0 + $1.tokens }, 1)
            let usedWidth = width * min(CGFloat(usedTokens) / CGFloat(max(capacity, 1)), 1)
            HStack(spacing: 1) {
                ForEach(slices) { slice in
                    Rectangle()
                        .fill(slice.category.color)
                        .frame(width: usedWidth * CGFloat(slice.tokens) / CGFloat(represented))
                }
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
            .clipShape(Capsule())
        }
    }
}

private extension ContextTokenCategory {
    var isRetainedInput: Bool {
        switch self {
        case .systemAndMemory, .user, .attachments, .assistant, .toolCalls, .toolResults: true
        case .reasoning, .unclassified: false
        }
    }

    var label: String {
        switch self {
        case .systemAndMemory: "System + memory"
        case .user: "User"
        case .attachments: "Attachments"
        case .reasoning: "Reasoning"
        case .assistant: "Responses"
        case .toolCalls: "Tool calls"
        case .toolResults: "Tool results"
        case .unclassified: "Other output"
        }
    }

    var color: Color {
        switch self {
        case .systemAndMemory: .pink
        case .user: .blue
        case .attachments: .indigo
        case .reasoning: .purple
        case .assistant: .cyan
        case .toolCalls: .orange
        case .toolResults: .green
        case .unclassified: .teal
        }
    }
}

extension ContextTokenCategory: Identifiable {
    var id: Self { self }
}
