import SwiftUI
import StandMixerCore

/// One shared task rail keeps the tools aligned even when one cell needs more lines.
struct AssignmentTable<Cell: View>: View {
    let platforms: [AgentPlatform]
    let detail: (AgentPlatform) -> String
    let cell: (AgentPlatform, WorkCategory) -> Cell
    init(platforms: [AgentPlatform], detail: @escaping (AgentPlatform) -> String,
         @ViewBuilder cell: @escaping (AgentPlatform, WorkCategory) -> Cell) {
        self.platforms = platforms
        self.detail = detail
        self.cell = cell
    }
    private let taskWidth: CGFloat = 162

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: taskWidth, height: 44)
                ForEach(platforms) { platform in
                    HStack(spacing: 8) {
                        Circle().fill(StandMixerTheme.provider(platform)).frame(width: 10, height: 10)
                        Text(platform.displayName).font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 3)
                        Text(detail(platform)).font(.system(size: 8.5)).foregroundStyle(StandMixerTheme.muted)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(StandMixerTheme.provider(platform).opacity(0.085))
                }
            }
            Rectangle().fill(StandMixerTheme.line).frame(height: 1)
            ForEach(Array(WorkCategory.allCases.enumerated()), id: \.element) { index, category in
                HStack(alignment: .center, spacing: 0) {
                    TaskCategoryLabel(category: category)
                        .frame(width: taskWidth, alignment: .leading)
                    ForEach(platforms) { platform in
                        cell(platform, category)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(platform.rawValue + "-" + category.rawValue)
                    }
                }
                .frame(minHeight: 53)
                .fixedSize(horizontal: false, vertical: true)
                .background(index.isMultiple(of: 2) ? StandMixerTheme.surface.opacity(0.72) : StandMixerTheme.accent.opacity(0.025))
                if index < WorkCategory.allCases.count - 1 {
                    Rectangle().fill(StandMixerTheme.line.opacity(0.72)).frame(height: 1)
                }
            }
        }
        .background(StandMixerTheme.surface.opacity(0.8))
        .overlay {
            GeometryReader { proxy in
                Path { path in
                    path.move(to: CGPoint(x: taskWidth, y: 0))
                    path.addLine(to: CGPoint(x: taskWidth, y: proxy.size.height))
                    if platforms.count > 1 {
                        let x = taskWidth + (proxy.size.width - taskWidth) / CGFloat(platforms.count)
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    }
                }
                .stroke(StandMixerTheme.line.opacity(0.45), lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StandMixerTheme.line.opacity(0.8), lineWidth: 1))
        .shadow(color: StandMixerTheme.accent.opacity(0.035), radius: 9, y: 5)
    }
}

private struct TaskCategoryLabel: View {
    let category: WorkCategory
    var body: some View {
        HStack(spacing: 8) {
            TaskCategoryIcon(category: category)
            Text(category.displayTitle)
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityHint(category.taskDescription)
        .help(category.taskDescription)
    }
}

/// Seven small diagrams: a coordinating hub, a plan's route, a UI canvas,
/// code brackets, a decision tree, a review shield, and a mechanical tool.
private struct TaskCategoryIcon: View {
    let category: WorkCategory
    private var tint: Color {
        switch category {
        case .coordinator: return StandMixerTheme.adaptive(0x475CCF, 0x9BA9EE)
        case .planning: return StandMixerTheme.adaptive(0x4075BA, 0x8FB1DD)
        case .ui: return StandMixerTheme.adaptive(0x7A5EBF, 0xB9A1E6)
        case .implementation: return StandMixerTheme.adaptive(0x337D8C, 0x83BCC6)
        case .algorithms: return StandMixerTheme.adaptive(0x6E6BB8, 0xA8A5DC)
        case .review: return StandMixerTheme.adaptive(0x407A9C, 0x8CB7D0)
        case .mechanical: return StandMixerTheme.adaptive(0x697896, 0xA2AFC7)
        }
    }
    var body: some View {
        TaskGlyph(category: category)
            .stroke(tint, style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
            .frame(width: 19, height: 19)
            .frame(width: 28, height: 28)
            .background(LinearGradient(colors: [StandMixerTheme.surface, tint.opacity(0.045)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.15), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

private struct TaskGlyph: Shape {
    let category: WorkCategory
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func line(_ points: CGPoint...) {
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        switch category {
        case .coordinator:
            path.addEllipse(in: CGRect(x: 9.5, y: 2, width: 5, height: 5))
            path.addEllipse(in: CGRect(x: 2, y: 16, width: 5, height: 5))
            path.addEllipse(in: CGRect(x: 17, y: 16, width: 5, height: 5))
            path.addEllipse(in: CGRect(x: 9.5, y: 10, width: 5, height: 5))
            line(CGPoint(x: 12, y: 7), CGPoint(x: 12, y: 10))
            line(CGPoint(x: 6.5, y: 16.5), CGPoint(x: 10, y: 14))
            line(CGPoint(x: 17.5, y: 16.5), CGPoint(x: 14, y: 14))
        case .planning:
            path.addEllipse(in: CGRect(x: 2.5, y: 17, width: 5, height: 5))
            line(CGPoint(x: 5, y: 17), CGPoint(x: 5, y: 12), CGPoint(x: 12, y: 12), CGPoint(x: 12, y: 5), CGPoint(x: 18, y: 5))
            line(CGPoint(x: 18, y: 10), CGPoint(x: 18, y: 2), CGPoint(x: 23, y: 4), CGPoint(x: 18, y: 6))
        case .ui:
            path.addRoundedRect(in: CGRect(x: 2, y: 4, width: 20, height: 16), cornerSize: CGSize(width: 2.5, height: 2.5))
            line(CGPoint(x: 2, y: 9), CGPoint(x: 22, y: 9))
            line(CGPoint(x: 8, y: 9), CGPoint(x: 8, y: 20))
            line(CGPoint(x: 5, y: 6.5), CGPoint(x: 5.1, y: 6.5))
            path.addRoundedRect(in: CGRect(x: 11, y: 12, width: 8, height: 5), cornerSize: CGSize(width: 1, height: 1))
        case .implementation:
            line(CGPoint(x: 8, y: 6), CGPoint(x: 3, y: 12), CGPoint(x: 8, y: 18))
            line(CGPoint(x: 16, y: 6), CGPoint(x: 21, y: 12), CGPoint(x: 16, y: 18))
            line(CGPoint(x: 14, y: 4), CGPoint(x: 10, y: 20))
        case .algorithms:
            line(CGPoint(x: 12, y: 2), CGPoint(x: 17, y: 7), CGPoint(x: 12, y: 12), CGPoint(x: 7, y: 7), CGPoint(x: 12, y: 2))
            line(CGPoint(x: 12, y: 12), CGPoint(x: 12, y: 15), CGPoint(x: 5, y: 15), CGPoint(x: 5, y: 18))
            line(CGPoint(x: 12, y: 15), CGPoint(x: 19, y: 15), CGPoint(x: 19, y: 18))
            path.addRoundedRect(in: CGRect(x: 2, y: 18, width: 6, height: 4), cornerSize: CGSize(width: 1, height: 1))
            path.addRoundedRect(in: CGRect(x: 16, y: 18, width: 6, height: 4), cornerSize: CGSize(width: 1, height: 1))
        case .review:
            path.move(to: CGPoint(x: 12, y: 2))
            path.addLine(to: CGPoint(x: 21, y: 5))
            path.addLine(to: CGPoint(x: 20, y: 13))
            path.addQuadCurve(to: CGPoint(x: 12, y: 22), control: CGPoint(x: 19, y: 19))
            path.addQuadCurve(to: CGPoint(x: 4, y: 13), control: CGPoint(x: 5, y: 19))
            path.addLine(to: CGPoint(x: 3, y: 5))
            path.closeSubpath()
            line(CGPoint(x: 7, y: 12), CGPoint(x: 10.5, y: 15.5), CGPoint(x: 17, y: 8.5))
        case .mechanical:
            path.move(to: CGPoint(x: 18, y: 3))
            path.addCurve(to: CGPoint(x: 12, y: 8), control1: CGPoint(x: 14, y: 2), control2: CGPoint(x: 11, y: 4))
            path.addLine(to: CGPoint(x: 3.5, y: 16.5))
            path.addQuadCurve(to: CGPoint(x: 7.5, y: 20.5), control: CGPoint(x: 1, y: 22.5))
            path.addLine(to: CGPoint(x: 16, y: 12))
            path.addCurve(to: CGPoint(x: 21, y: 6), control1: CGPoint(x: 20, y: 13), control2: CGPoint(x: 23, y: 10))
            line(CGPoint(x: 21, y: 6), CGPoint(x: 18, y: 9), CGPoint(x: 15, y: 6), CGPoint(x: 18, y: 3))
            path.addEllipse(in: CGRect(x: 5, y: 17, width: 1, height: 1))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}
