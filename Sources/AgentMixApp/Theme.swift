import SwiftUI
import AppKit
import AgentMixCore

enum AgentMixTheme {
    // NSColor resolves against the window appearance, including live system changes.
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    static let background = adaptive(0xF7FAFB, 0x0B1220)
    static let surface = adaptive(0xFFFFFF, 0x131E2E)
    static let sidebar = adaptive(0xE6F2F0, 0x11242C)
    static let ink = adaptive(0x21212E, 0xE9EEF5)
    static let muted = adaptive(0x6E6E82, 0x9CAEB5)
    static let line = adaptive(0xD5E3E1, 0x293847)
    static let accent = adaptive(0x0B756D, 0x6FB3B8)
    static let accentInk = adaptive(0xFFFFFF, 0x0B1220)
    static let accentSoft = adaptive(0xE7F6F3, 0x1B353B)
    static let green = adaptive(0x3B7A5E, 0x8AC7A0)
    static let amber = adaptive(0xA66E24, 0xDDB96E)
    static let brandTeal = adaptive(0x0E9488, 0x6FB3B8)
    static let windowGradient = [background, adaptive(0xF4FAF8, 0x0D1725), adaptive(0xEEF6F3, 0x0F1D29)]
    static let sidebarGradient = [adaptive(0xDFEEE8, 0x11242C), adaptive(0xEDF4EF, 0x11202B), adaptive(0xE6F0F4, 0x142231)]
    static func provider(_ platform: AgentPlatform) -> Color {
        platform == .codex ? adaptive(0x307AF0, 0x8CAFF0) : adaptive(0x946EE6, 0xC49CDE)
    }
}

struct AgentMixPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AgentMixTheme.accentInk)
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(AgentMixTheme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}

struct AgentMixSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AgentMixTheme.ink)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(configuration.isPressed ? AgentMixTheme.sidebar : AgentMixTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AgentMixTheme.line, lineWidth: 1))
    }
}

struct SectionEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(AgentMixTheme.muted)
    }
}

struct ProviderMark: View {
    let platform: AgentPlatform
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: platform == .codex ? "terminal" : "asterisk")
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(platform == .codex ? AgentMixTheme.ink : AgentMixTheme.adaptive(0xA36147, 0xDEAB98))
            .frame(width: size, height: size)
            .background(platform == .codex ? AgentMixTheme.surface.opacity(0.8) : AgentMixTheme.adaptive(0xF5E3D6, 0x382B28), in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

extension WorkCategory {
    var displayTitle: String {
        switch self {
        case .ui: return "Visual"
        case .implementation: return "Implementation"
        case .algorithms: return "Algorithms"
        case .review: return "Review & Security"
        default: return title
        }
    }
    var taskDescription: String {
        switch self {
        case .coordinator: return "The current native model handles the conversation and combines results. Auto keeps it unchanged; pins apply to new sessions."
        case .planning: return "Plans complex work when a separate plan helps; routine chat and small edits proceed directly."
        case .ui: return "Website and app design, layout, styling, and frontend implementation."
        case .implementation: return "Builds features and implements application logic."
        case .algorithms: return "Develops algorithms and solves complex technical problems."
        case .review: return "Reviews correctness, code quality, and security."
        case .mechanical: return "Handles routine edits and repetitive maintenance."
        }
    }

}

extension EffortPolicy {
    func semanticallyMatches(_ other: EffortPolicy) -> Bool {
        guard mode == other.mode else { return false }
        switch mode {
        case .auto: return true
        case .fixed: return value == other.value
        case .range: return minimum == other.minimum && maximum == other.maximum
        }
    }
    var shortLabel: String {
        switch mode {
        case .auto: return "Auto"
        case .fixed: return value.effortLabel
        case .range: return "\(minimum.effortLabel)–\(maximum.effortLabel)"
        }
    }
}

extension String {
    var effortLabel: String { self == "xhigh" ? "X-high" : capitalized }
}

/// Labels the outlined proposal without taking space from the model line.
struct ChangedCellBadge: View {
    var showsDisclosure = false
    var isEdited = false
    var body: some View {
        Text(isEdited ? "Edited" : showsDisclosure ? "Will change ⌄" : "Will change")
            .font(.system(size: 7, weight: .medium))
            .foregroundStyle(AgentMixTheme.accent)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(AgentMixTheme.surface, in: Capsule())
            .accessibilityLabel(isEdited ? "Edited since entering Edit" : "Will change from the reported setting")
    }
}
