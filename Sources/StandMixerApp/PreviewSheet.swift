import SwiftUI
import StandMixerCore

struct PreviewSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let preview: IntegrationPreview
    var initiallyShowingFiles = false
    @State private var selectedPath: String?
    @State private var showingFiles = false
    @State private var expandedAgentTools: Set<AgentPlatform> = []

    private var changedFiles: [FileChange] { preview.changes.filter(\.isChanged) }
    private var selectedFile: FileChange? { changedFiles.first { $0.path == selectedPath } ?? changedFiles.first }
    private var canApply: Bool { !store.previewPlatforms.isEmpty && store.previewPlatforms.isSubset(of: store.enabledPlatforms) && !changedFiles.isEmpty && !store.isApplying }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Review changes")
                        .font(.system(size: 25, weight: .semibold, design: .rounded)).tracking(-0.5)
                    Text(store.presetName + " · " + AgentPlatform.allCases.filter { store.previewPlatforms.contains($0) }.map(\.displayName).joined(separator: " + "))
                        .font(.system(size: 12)).foregroundStyle(StandMixerTheme.muted)
                }
                Spacer()
                Picker("Review", selection: $showingFiles) {
                    Text("Changes").tag(false)
                    Text("Files (\(changedFiles.count))").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 210).padding(.trailing, 12)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StandMixerTheme.muted).frame(width: 28, height: 28)
                        .background(StandMixerTheme.sidebar, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close preview")
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            Group {
                if showingFiles { fileReview }
                else { changeReview }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { Rectangle().fill(StandMixerTheme.line).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(StandMixerTheme.line).frame(height: 1) }

            if !preview.preservedConflicts.isEmpty {
                DisclosureGroup("Kept files (\(preview.preservedConflicts.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(preview.preservedConflicts.enumerated()), id: \.offset) { _, conflict in
                                Text(conflict).font(.system(size: 10)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 130)
                }.font(.system(size: 11)).foregroundStyle(StandMixerTheme.amber)
                    .padding(.horizontal, 26).padding(.top, 12)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 14)).foregroundStyle(StandMixerTheme.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(changedFiles.isEmpty ? (preview.preservedConflicts.isEmpty ? "Everything is already up to date." : "Modified files were kept.") : "Your previous setup will be backed up.")
                            .font(.system(size: 11, weight: .medium))
                        Text("Changes take effect in new agent sessions.")
                            .font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(StandMixerSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    Button { store.applyPreview() } label: {
                        Text(store.isApplying ? "Applying…" : "Apply")
                    }
                    .buttonStyle(StandMixerPrimaryButtonStyle())
                    .disabled(!canApply).opacity(canApply ? 1 : 0.45)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 26).padding(.vertical, 20)
        }
        .frame(width: 970, height: 690)
        .background(StandMixerTheme.background)
        .foregroundStyle(StandMixerTheme.ink)
        .onAppear {
            selectedPath = changedFiles.first?.path
            if initiallyShowingFiles || ProcessInfo.processInfo.arguments.contains("--files") { showingFiles = true }
        }
        .alert("StandMixer couldn’t apply the changes", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var changeReview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if changedFiles.isEmpty {
                    Label(preview.preservedConflicts.isEmpty ? "This setup is already applied." : "Modified files were kept.", systemImage: preview.preservedConflicts.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(StandMixerTheme.green)
                } else {
                    nativeSettingsChanges
                    PresetChangesView(controller: store.currentSettings, platforms: store.previewPlatforms, showEffort: true)
                    let removed = changedFiles.filter { $0.isDeletion && isWorker($0) }
                    if !removed.isEmpty {
                        Text("Remove \(removed.count) obsolete agent \(removed.count == 1 ? "definition" : "definitions").")
                            .font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var nativeSettingsChanges: some View {
        let files = changedFiles.filter { ["config.toml", "settings.json"].contains(URL(fileURLWithPath: $0.path).lastPathComponent) }
        return VStack(alignment: .leading, spacing: 5) {
            if !files.isEmpty {
                Text("Saved defaults").font(.system(size: 11, weight: .semibold))
                HStack(alignment: .top, spacing: 8) {
                    ForEach(files) { file in
                        let diff = TextDiff(before: file.before, after: file.after, contextLines: 0)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(platform(for: file).displayName).font(.system(size: 9, weight: .semibold))
                            ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                    HStack(alignment: .top, spacing: 5) {
                                        Text(line.kind == .removal ? "−" : "+").frame(width: 8)
                                        Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(line.kind == .removal ? FileDiffPalette.removal : FileDiffPalette.addition)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(line.kind == .removal ? FileDiffPalette.removalBackground : FileDiffPalette.additionBackground, in: RoundedRectangle(cornerRadius: 3))
                                }
                            }
                            if diff.hasFinalNewlineChange {
                                Text(diff.afterEndsWithNewline ? "Final newline added" : "Final newline removed")
                                    .font(.system(size: 9)).foregroundStyle(StandMixerTheme.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(7).background(StandMixerTheme.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StandMixerTheme.line, lineWidth: 1))
                    }
                }
            }
        }
    }

    private var fileReview: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AgentPlatform.allCases.filter { store.previewPlatforms.contains($0) }) { tool in
                        let files = changedFiles.filter { platform(for: $0) == tool }
                        if !files.isEmpty {
                            SectionEyebrow(text: tool.displayName).padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 5)
                            ForEach(files.filter { !isWorker($0) }) { fileButton($0) }
                            let agents = files.filter(isWorker)
                            if !agents.isEmpty {
                                agentGroupButton(tool, files: agents)
                                if expandedAgentTools.contains(tool) {
                                    ForEach(agents) { fileButton($0).padding(.leading, 15) }
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
            .frame(width: 224)
            .background(StandMixerTheme.sidebar.opacity(0.55))
            Rectangle().fill(StandMixerTheme.line).frame(width: 1)
            fileContents
        }
    }

    private func agentGroupButton(_ tool: AgentPlatform, files: [FileChange]) -> some View {
        let expanded = expandedAgentTools.contains(tool)
        let containsSelection = !expanded && files.contains { $0.path == selectedFile?.path }
        return Button {
            if expanded { expandedAgentTools.remove(tool) }
            else { expandedAgentTools.insert(tool) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).frame(width: 10)
                Text("Agents").font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
                Text(String(files.count)).font(.system(size: 9, weight: .medium)).monospacedDigit()
                    .foregroundStyle(StandMixerTheme.muted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(StandMixerTheme.surface.opacity(0.8), in: Capsule())
            }
            .foregroundStyle(containsSelection ? StandMixerTheme.accent : StandMixerTheme.ink)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(containsSelection ? StandMixerTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("\(files.count) native agent definitions for \(tool.displayName)")
        .accessibilityLabel("\(tool.displayName) agents, \(files.count) changed files")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }

    private func fileButton(_ change: FileChange) -> some View {
        let selected = selectedFile?.path == change.path
        return Button { selectedPath = change.path } label: {
            HStack(spacing: 8) {
                Image(systemName: change.isDeletion ? "minus.circle" : change.before == nil ? "plus.circle" : "doc.text")
                    .font(.system(size: 10)).foregroundStyle(selected ? StandMixerTheme.accent : StandMixerTheme.muted)
                Text(fileLabel(change)).font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(change.isDeletion ? "−" : change.before == nil ? "+" : "")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(change.isDeletion ? FileDiffPalette.removal : StandMixerTheme.green)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? StandMixerTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? StandMixerTheme.line : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain).help(change.path)
        .accessibilityLabel("\(change.path), \(change.isDeletion ? "will be removed" : change.isChanged ? "will change" : "unchanged")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func isWorker(_ change: FileChange) -> Bool {
        let url = URL(fileURLWithPath: change.path)
        return url.deletingLastPathComponent().lastPathComponent == "agents" && url.lastPathComponent.hasPrefix("standmixer-")
    }

    private func platform(for change: FileChange) -> AgentPlatform {
        store.integrationPlatform(for: change.path)
    }

    private func fileLabel(_ change: FileChange) -> String {
        let url = URL(fileURLWithPath: change.path)
        guard isWorker(change) else {
            if url.lastPathComponent == "SKILL.md" { return "StandMixer command" }
            return ["config.toml", "settings.json"].contains(url.lastPathComponent) ? "Default model & effort" : "Routing instructions"
        }
        // Shared definitions carry their readable model/effort metadata here;
        // filenames may contain a safe custom-model slug and an opaque suffix.
        let sharedPrefix = "Shared worker: "
        if change.reason.hasPrefix(sharedPrefix) {
            return String(change.reason.dropFirst(sharedPrefix.count))
        }
        let name = url.deletingPathExtension().lastPathComponent
        let stem = name.hasPrefix("standmixer-") ? String(name.dropFirst("standmixer-".count)) : name
        if let category = WorkCategory(rawValue: stem) { return category.displayTitle }
        return stem.replacingOccurrences(of: "-", with: " ").capitalized
    }

    @ViewBuilder
    private var fileContents: some View {
        if let file = selectedFile {
            FileChangeReview(file: file).id(file.path)
        } else {
            ContentUnavailableView("No files to update", systemImage: "checkmark.circle", description: Text("Your configuration is already current."))
                .frame(maxWidth: .infinity)
        }
    }

}

private struct FileChangeReview: View {
    private enum Mode: String, CaseIterable {
        case diff = "Diff", current = "Current", proposed = "Proposed"
    }

    let file: FileChange
    private let diff: TextDiff
    @State private var mode = Mode.diff

    init(file: FileChange) {
        self.file = file
        self.diff = TextDiff(before: file.before, after: file.isDeletion ? nil : file.after, contextLines: 3)
    }

    private var status: String { file.isDeletion ? "Removed" : file.before == nil ? "Added" : "Modified" }
    private var emptyDiffMessage: String {
        if file.isDeletion { return "Remove this empty file." }
        if file.before == nil { return "Create an empty file." }
        return "No line changes."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Text(URL(fileURLWithPath: file.path).lastPathComponent)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(status).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(StandMixerTheme.muted)
                    Spacer(minLength: 8)
                    Picker("File view", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().accessibilityLabel("File view")
                    .frame(width: 225)
                }
                HStack(spacing: 9) {
                    Text(file.path).font(.system(size: 9, design: .monospaced)).foregroundStyle(StandMixerTheme.muted)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(file.path)
                    Spacer(minLength: 4)
                    if diff.removedLineCount > 0 {
                        Text("−\(diff.removedLineCount)").foregroundStyle(FileDiffPalette.removal)
                            .help("\(diff.removedLineCount) removed lines")
                    }
                    if diff.addedLineCount > 0 {
                        Text("+\(diff.addedLineCount)").foregroundStyle(FileDiffPalette.addition)
                            .help("\(diff.addedLineCount) added lines")
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                Text(file.reason).font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 17).padding(.vertical, 13)
            Rectangle().fill(StandMixerTheme.line).frame(height: 1)
            Group {
                if mode == .diff {
                    FileDiffView(diff: diff, emptyMessage: emptyDiffMessage)
                } else {
                    fullContents
                }
            }
            .id(mode)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(StandMixerTheme.surface)
        }
    }

    private var fullContents: some View {
        let missing = mode == .current ? file.before == nil : file.isDeletion
        let contents = mode == .current ? file.before ?? "This file does not exist yet."
            : file.isDeletion ? "This file will be removed." : file.after
        return ScrollView([.vertical, .horizontal]) {
            Text(contents.isEmpty ? "This file is empty." : contents)
                .font(.system(size: 11, design: .monospaced)).lineSpacing(4)
                .foregroundStyle(missing || contents.isEmpty ? StandMixerTheme.muted : StandMixerTheme.ink)
                .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(18)
        }
    }
}
