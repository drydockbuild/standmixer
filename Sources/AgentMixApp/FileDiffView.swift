import SwiftUI
import AgentMixCore

enum FileDiffPalette {
    static let addition = AgentMixTheme.adaptive(0x2B6E4A, 0x8AC7A0)
    static let removal = AgentMixTheme.adaptive(0xA8384A, 0xE49AA9)
    static let additionBackground = AgentMixTheme.adaptive(0xE8F7F0, 0x162E2B)
    static let removalBackground = AgentMixTheme.adaptive(0xFCEDEF, 0x35242F)
}

/// All changed hunks are present; long untouched sections are omitted by TextDiff.
struct FileDiffView: View {
    let diff: TextDiff
    var emptyMessage = "No line changes."

    private var lineNumberWidth: CGFloat {
        let largest = diff.hunks.reduce(0) { result, hunk in
            max(result, hunk.oldStart + hunk.oldCount, hunk.newStart + hunk.newCount)
        }
        return CGFloat(max(3, String(largest).count) * 7 + 12)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    if diff.isCoarse {
                        notice("Expanded comparison", systemImage: "arrow.left.arrow.right", width: geometry.size.width)
                            .help("This large edit is shown as a replacement of the affected region. No changed content is omitted.")
                    }
                    if diff.hunks.isEmpty && !diff.hasFinalNewlineChange {
                        notice(emptyMessage, systemImage: "doc", width: geometry.size.width)
                    }
                    ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                        hunkHeading(hunk, width: geometry.size.width)
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            lineRow(line, width: geometry.size.width)
                        }
                    }
                    if diff.hasFinalNewlineChange {
                        notice(diff.afterEndsWithNewline ? "Final newline added" : "Final newline removed",
                               systemImage: "return", width: geometry.size.width)
                    }
                }
                .frame(minWidth: geometry.size.width, alignment: .leading)
                .padding(.bottom, 12)
            }
        }
    }

    private func hunkHeading(_ hunk: TextDiffHunk, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("@@ −\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(AgentMixTheme.accent.opacity(0.85))
                .padding(.leading, lineNumberWidth * 2 + 19)
            Spacer(minLength: 18)
        }
        .frame(minWidth: width, minHeight: 29, alignment: .leading)
        .background(AgentMixTheme.accentSoft.opacity(0.35))
        .accessibilityLabel("Current lines \(hunk.oldStart) through \(max(hunk.oldStart, hunk.oldStart + hunk.oldCount - 1)); proposed lines \(hunk.newStart) through \(max(hunk.newStart, hunk.newStart + hunk.newCount - 1))")
    }

    private func lineRow(_ line: TextDiffLine, width: CGFloat) -> some View {
        let ink: Color
        let background: Color
        let marker: String
        switch line.kind {
        case .context:
            ink = AgentMixTheme.ink
            background = .clear
            marker = " "
        case .addition:
            ink = FileDiffPalette.addition
            background = FileDiffPalette.additionBackground
            marker = "+"
        case .removal:
            ink = FileDiffPalette.removal
            background = FileDiffPalette.removalBackground
            marker = "−"
        }
        return HStack(alignment: .top, spacing: 0) {
            lineNumber(line.oldLineNumber, ink: ink.opacity(0.55))
            lineNumber(line.newLineNumber, ink: ink.opacity(0.55))
            Text(marker).foregroundStyle(ink).frame(width: 23, alignment: .center)
                .accessibilityLabel(line.kind == .addition ? "Added" : line.kind == .removal ? "Removed" : "")
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(ink).textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 18)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 3)
        .frame(minWidth: width, alignment: .leading)
        .background(background)
    }

    private func lineNumber(_ number: Int?, ink: Color) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(ink)
            .frame(width: lineNumberWidth - 9, alignment: .trailing).padding(.trailing, 9)
            .accessibilityHidden(true)
    }

    private func notice(_ title: String, systemImage: String, width: CGFloat) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).font(.system(size: 10))
            Text(title).font(.system(size: 10))
            Spacer(minLength: 12)
        }
        .foregroundStyle(AgentMixTheme.muted).padding(.horizontal, 17).padding(.vertical, 12)
        .frame(minWidth: width, alignment: .leading)
    }
}
