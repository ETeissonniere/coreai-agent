import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var model: AppModel
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.draftAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(model.draftAttachments) { attachment in
                            HStack(spacing: 5) {
                                Image(systemName: "doc.text")
                                Text(attachment.name).lineLimit(1)
                                Button { model.removeAttachment(attachment.id) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(attachment.name)")
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if let notice = model.attachmentNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if model.isAttachingFiles {
                Label("Adding files…", systemImage: "paperclip")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if modelProfilePresentation.hasWarning,
               let notice = model.modelSelectionNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .accessibilityLabel("Model warning: \(notice)")
            }
            if !model.skillCommandSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invoke a skill").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.skillCommandSuggestions.prefix(6)) { skill in
                        Button { model.invokeSkillCommand(skill) } label: {
                            HStack {
                                Image(systemName: skill.systemImage).frame(width: 18)
                                Text("/\(SkillRouter().commandName(for: skill))")
                                Spacer()
                                Text(skill.description).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                    }
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button("Attach Files or Folders", systemImage: "plus", action: model.chooseAttachments)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 44)
                    .help("Attach files or folders")

                TextField("Describe a task…", text: $model.draft, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 44)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                .onSubmit { model.send() }

                modelProfileMenu

                if model.modelPhase == .loading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Loading model")
                } else if model.modelPhase == .generating || model.modelPhase == .compacting {
                    composerButton("Stop", systemImage: "stop.fill", action: model.stop)
                } else {
                    composerButton("Start Task", systemImage: "arrow.up", action: model.send)
                        .disabled(
                            model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || !model.isSelectedModelReady || model.isAttachingFiles
                        )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addAttachments(from: urls)
            return !urls.isEmpty
        } isTargeted: { isDropTarget = $0 }
    }

    private var modelProfileMenu: some View {
        let presentation = modelProfilePresentation

        return Menu {
            Section("Response model") {
                ForEach(ModelProfile.allCases, id: \.self) { profile in
                    Button {
                        model.selectModelProfile(profile)
                    } label: {
                        Label {
                            Text(profile.label)
                            Text("\(profile.modelName) · \(profile.quantization)")
                        } icon: {
                            Image(systemName: profile == model.selectedModelProfile ? "checkmark.circle.fill" : profile.systemImage)
                        }
                    }
                    .disabled(!model.isModelAvailable(profile) || profile == model.selectedModelProfile)
                }
            }
            if model.selectedModelProfile == .fast {
                Section("Fast model") {
                    Toggle("Reasoning", isOn: Binding(
                        get: { model.selectedReasoningEnabled },
                        set: model.setFastReasoningEnabled
                    ))
                }
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                modelProfileLabel(presentation, showsText: true)
                modelProfileLabel(presentation, showsText: false)
            }
            .frame(height: 44, alignment: .center)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(height: 44, alignment: .center)
        .disabled(model.modelPhase != .ready)
        .help(presentation.help)
        .accessibilityLabel("Response model")
        .accessibilityValue(presentation.accessibilityValue)
    }

    private var modelProfilePresentation: ModelProfileControlPresentation {
        ModelProfileControlPresentation(
            profile: model.selectedModelProfile,
            loadingProfile: model.loadingModelProfile,
            phase: model.modelPhase,
            isSelectedModelReady: model.isSelectedModelReady,
            reasoningEnabled: model.selectedReasoningEnabled,
            notice: model.modelSelectionNotice
        )
    }

    private func modelProfileLabel(
        _ presentation: ModelProfileControlPresentation,
        showsText: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: presentation.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 20, height: 20, alignment: .center)
                .foregroundStyle(presentation.statusColor)
            if showsText {
                Text(presentation.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: showsText ? 96 : 44, height: 44, alignment: .center)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func composerButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
        }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
            .accessibilityLabel(title)
    }
}

private extension ModelProfile {
    var systemImage: String {
        self == .fast ? "bolt.fill" : "sparkles"
    }
}

struct ModelProfileControlPresentation {
    let profile: ModelProfile
    let loadingProfile: ModelProfile?
    let phase: ModelPhase
    let isSelectedModelReady: Bool
    let reasoningEnabled: Bool
    let notice: String?

    var displayedProfile: ModelProfile { loadingProfile ?? profile }
    var label: String {
        if hasWarning { return "\(displayedProfile.label) !" }
        if isLoading { return "\(displayedProfile.label)…" }
        if displayedProfile == .fast, reasoningEnabled { return "Fast · Think" }
        return displayedProfile.label
    }
    var isLoading: Bool { phase == .loading }
    var hasWarning: Bool {
        if phase == .missing || isFailed { return true }
        guard let notice else { return false }
        return notice.contains("Could not load")
            || notice.contains("not bundled")
            || notice.contains("No bundled model")
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var systemImage: String {
        switch phase {
        case .failed, .missing: "exclamationmark.triangle.fill"
        case .loading: "hourglass"
        case .ready, .generating, .compacting:
            hasWarning ? "exclamationmark.triangle.fill" : profile.systemImage
        }
    }

    var statusColor: Color {
        switch phase {
        case .failed, .missing: .orange
        case .loading: .secondary
        case .ready: hasWarning ? .orange : (isSelectedModelReady ? .green : .secondary)
        case .generating, .compacting: .green
        }
    }

    var help: String {
        notice ?? "\(displayedProfile.modelName) · \(displayedProfile.quantization)"
    }

    var accessibilityValue: String {
        var components = [displayedProfile.label, displayedProfile.modelName, displayedProfile.quantization]
        if isLoading {
            components.append("loading")
        } else if phase == .generating || phase == .compacting || isSelectedModelReady {
            components.append("in use")
        } else {
            components.append(phase.label)
        }
        if profile == .fast {
            components.append(reasoningEnabled ? "reasoning on" : "reasoning off")
        }
        return components.joined(separator: ", ")
    }
}
