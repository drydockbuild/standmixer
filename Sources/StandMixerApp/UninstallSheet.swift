import SwiftUI
import StandMixerCore

struct UninstallSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let preview: UninstallPreview
    @State private var showingFiles = false
    @State private var selectedPath: String?

    private var changes: [FileChange] { preview.changes.filter(\.isChanged) }
    private var selectedFile: FileChange? { changes.first { $0.path == selectedPath } ?? changes.first }
    private var hasRemoval: Bool { !changes.isEmpty || (preview.hasInstallation && preview.conflicts.isEmpty) }
    private var canRemove: Bool { hasRemoval && !store.isUninstalling }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Uninstall StandMixer")
                        .font(.system(size: 23, weight: .semibold, design: .rounded)).tracking(-0.5)
                    Text("Review what will be restored or removed.")
                        .font(.system(size: 11)).foregroundStyle(StandMixerTheme.muted)
                }
                Spacer(minLength: 0)
                if !changes.isEmpty {
                    Picker("Review uninstall", selection: $showingFiles) {
                        Text("Overview").tag(false)
                        Text("Files (\(changes.count))").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
            }
            .padding(22)
            Rectangle().fill(StandMixerTheme.line).frame(height: 1)

            Group {
                if showingFiles { fileReview }
                else { overview }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(StandMixerTheme.line).frame(height: 1)
            HStack(spacing: 12) {
                Text("The app stays on your Mac.")
                    .font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
                Spacer(minLength: 8)
                Button(hasRemoval ? "Cancel" : "Done") { dismiss() }
                    .buttonStyle(StandMixerSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    .disabled(store.isUninstalling)
                if hasRemoval {
                    Button { store.uninstall() } label: {
                        Text(store.isUninstalling ? "Removing…" : "Remove StandMixer")
                    }
                    .buttonStyle(StandMixerPrimaryButtonStyle())
                    .disabled(!canRemove).opacity(canRemove ? 1 : 0.45)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
        }
        .frame(width: 760, height: 520)
        .background(StandMixerTheme.background).foregroundStyle(StandMixerTheme.ink)
        .interactiveDismissDisabled(store.isUninstalling)
        .onAppear { showingFiles = !changes.isEmpty && ProcessInfo.processInfo.arguments.contains("--files") }
        .alert("StandMixer couldn’t finish uninstalling", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !preview.hasInstallation && changes.isEmpty && preview.conflicts.isEmpty {
                    Label("StandMixer isn’t applied on this Mac.", systemImage: "checkmark.circle")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(StandMixerTheme.green)
                        .padding(.vertical, 16)
                } else if !changes.isEmpty {
                    VStack(alignment: .leading, spacing: 19) {
                        if changes.contains(where: { ["config.toml", "settings.json"].contains(URL(fileURLWithPath: $0.path).lastPathComponent) }) {
                            summaryRow("Restore your previous defaults", detail: "Return managed settings to their values before the first apply.", symbol: "clock.arrow.circlepath")
                        }
                        summaryRow("Remove StandMixer integrations", detail: "Remove its managed routing instructions, workers, and commands.", symbol: "minus.circle")
                    }
                    Text("\(changes.count) \(changes.count == 1 ? "file" : "files") will change. Your later edits will be preserved.")
                        .font(.system(size: 11)).foregroundStyle(StandMixerTheme.muted)
                } else if preview.hasInstallation && preview.conflicts.isEmpty {
                    summaryRow("Finish removing StandMixer", detail: "The integration files are already gone. Remove the remaining installation record.", symbol: "minus.circle")
                }

                if !preview.conflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Some settings or files will be kept", systemImage: "exclamationmark.circle")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(StandMixerTheme.amber)
                        ForEach(Array(preview.conflicts.enumerated()), id: \.offset) { _, conflict in
                            Text(conflict).font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(StandMixerTheme.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
    }

    private func summaryRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(StandMixerTheme.accent)
                .frame(width: 24).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(StandMixerTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fileReview: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(changes) { file in
                        Button { selectedPath = file.path } label: {
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: file.isDeletion ? "minus.circle" : "arrow.uturn.backward")
                                    .font(.system(size: 10)).padding(.top, 1)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                        .font(.system(size: 10, weight: .medium)).lineLimit(2)
                                    Text(shortParent(file.path)).font(.system(size: 9))
                                        .foregroundStyle(StandMixerTheme.muted).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(selectedFile?.path == file.path ? StandMixerTheme.accent : StandMixerTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(selectedFile?.path == file.path ? StandMixerTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain).help(file.path)
                        .accessibilityAddTraits(selectedFile?.path == file.path ? .isSelected : [])
                    }
                }
                .padding(8)
            }
            .frame(width: 215).background(StandMixerTheme.sidebar.opacity(0.5))
            Rectangle().fill(StandMixerTheme.line).frame(width: 1)
            if let file = selectedFile {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(file.isDeletion ? "Remove file" : "Restore settings").font(.system(size: 11, weight: .semibold))
                            Spacer()
                        }
                        Text(file.path).font(.system(size: 9, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle).help(file.path)
                        Text(file.reason).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(StandMixerTheme.muted).padding(14)
                    Rectangle().fill(StandMixerTheme.line).frame(height: 1)
                    FileDiffView(diff: TextDiff(before: file.before, after: file.isDeletion ? nil : file.after, contextLines: 3))
                        .id(file.path).background(StandMixerTheme.surface)
                }
            }
        }
    }

    private func shortParent(_ path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return parent.hasPrefix(home + "/") ? "~" + parent.dropFirst(home.count) : parent
    }
}
