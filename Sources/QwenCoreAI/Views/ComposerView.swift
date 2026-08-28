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
                                || model.modelPhase != .ready || model.isAttachingFiles
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
