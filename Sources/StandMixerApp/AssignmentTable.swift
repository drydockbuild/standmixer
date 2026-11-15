import SwiftUI
import StandMixerCore

/// One shared work rail keeps both hosts aligned, including expanded exceptions.
struct AssignmentTable<Cell: View>: View {
    @EnvironmentObject private var store: AppStore
    let platforms: [AgentPlatform]
    let detail: (AgentPlatform) -> String
    let allowsEditing: Bool
    let cell: (AgentPlatform, WorkCategory) -> Cell
    @State private var expansion: [WorkCategory: Bool] = [:]
    @State private var editingCategory: WorkCategory?

    init(platforms: [AgentPlatform], detail: @escaping (AgentPlatform) -> String,
         allowsEditing: Bool = true,
         @ViewBuilder cell: @escaping (AgentPlatform, WorkCategory) -> Cell) {
        self.platforms = platforms; self.detail = detail
        self.allowsEditing = allowsEditing; self.cell = cell
    }
    private let taskWidth: CGFloat = 172

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Work").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StandMixerTheme.muted).padding(.leading, 11)
                    .frame(width: taskWidth, alignment: .leading)
                ForEach(platforms) { platform in
                    HStack(spacing: 7) {
                        Circle().fill(StandMixerTheme.provider(platform)).frame(width: 7, height: 7)
                        Text(platform.displayName).font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 3)
                        Text("Effort").font(.system(size: 9)).foregroundStyle(StandMixerTheme.muted)
                    }.padding(.horizontal, 12).frame(maxWidth: .infinity)
                }
                if allowsEditing { Color.clear.frame(width: 30) }
            }.padding(.vertical, 13)
            Divider()
            ForEach(WorkCategory.topLevelCases) { category in
                VStack(spacing: 0) {
                    row(category)
                    if expanded(category) {
                        ForEach(visibleChildren(category)) { child in row(child) }
                    }
                }
                Divider().opacity(0.7)
            }
            row(.coordinator)
        }
        .background(StandMixerTheme.surface.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StandMixerTheme.line.opacity(0.8), lineWidth: 1))
        .onChange(of: store.isEditing) { _, editing in if !editing { editingCategory = nil } }
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            guard args.contains("--snapshot") else { return }
            for flag in ["--effort", "--team"] {
                if let index = args.firstIndex(of: flag), args.indices.contains(index + 1),
                   let category = WorkCategory(rawValue: args[index + 1]) {
                    editingCategory = category
                    if let parent = category.parent { expansion[parent] = true }
                }
            }
        }
    }

    private func visibleChildren(_ category: WorkCategory) -> [WorkCategory] {
        category.children.filter { child in
            child != .algorithms || platforms.contains { platform in
                let stored = store.storedRoute(child, in: platform)
                return !stored.inheritsModel || !stored.inheritsEffort || !stored.inheritsTeam
            }
        }
    }
    private func isCustom(_ category: WorkCategory) -> Bool {
        platforms.contains { !exceptionFields(category, in: $0).isEmpty }
    }
    private func expanded(_ category: WorkCategory) -> Bool {
        expansion[category] ?? visibleChildren(category).contains(where: isCustom)
    }
    private func sameAgents(_ lhs: [AgentAssignment], _ rhs: [AgentAssignment]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
            pair.0.modelID == pair.1.modelID && pair.0.effort.semanticallyMatches(pair.1.effort)
        }
    }
    /// Default expansion compares effective values, so equal-value pins stay collapsed.
    private func exceptionFields(_ category: WorkCategory, in platform: AgentPlatform) -> [String] {
        guard let parentCategory = category.parent else { return [] }
        let route = store.route(category, in: platform)
        let parent = store.route(parentCategory, in: platform)
        var fields: [String] = []
        if route.modelID != parent.modelID {
            fields.append("Model: " + store.routedModelName(route.modelID, in: platform))
        }
        if !route.effort.semanticallyMatches(parent.effort) {
            fields.append("Effort: " + route.effort.shortLabel)
        }
        if route.additionalAgents.count != parent.additionalAgents.count {
            let count = route.additionalAgents.count + 1
            fields.append("\(count) " + (count == 1 ? "agent" : "agents"))
        }
        for (index, agent) in route.additionalAgents.enumerated() {
            guard parent.additionalAgents.indices.contains(index) else {
                fields.append("+ " + store.routedModelName(agent.modelID, in: platform) + " · " + agent.effort.shortLabel)
                continue
            }
            let previous = parent.additionalAgents[index]
            if agent.modelID != previous.modelID {
                fields.append("Worker \(index + 2): " + store.routedModelName(agent.modelID, in: platform))
            }
            if !agent.effort.semanticallyMatches(previous.effort) {
                fields.append("Worker \(index + 2) effort: " + agent.effort.shortLabel)
            }
        }
        if !route.additionalAgents.isEmpty {
            if route.teamMode != parent.teamMode {
                fields.append(route.teamMode == .parallel ? "Independent passes" : "Lead + review")
            }
            if route.resultMode != parent.resultMode { fields.append("Result: " + route.resultMode.displayTitle) }
            if route.resultMode == .ai, route.judgeModelID != parent.judgeModelID, let judge = route.judgeModelID {
                fields.append("Judge: " + store.routedModelName(judge, in: platform))
            }
        }
        if !sameAgents(route.stuckEscalation, parent.stuckEscalation) {
            let count = route.stuckEscalation.count
            fields.append(count == 0 ? "When stuck: off" : "When stuck: \(count) " + (count == 1 ? "step" : "steps"))
        }
        return fields
    }
    @ViewBuilder private func row(_ category: WorkCategory) -> some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 4) {
                if category.parent == nil && category != .coordinator {
                    Button {
                        let next = !expanded(category)
                        expansion[category] = next
                        if !next, editingCategory?.parent == category { editingCategory = nil }
                    } label: {
                        Image(systemName: expanded(category) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 28)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(category.displayTitle + (expanded(category) ? ": hide optional settings" : ": show optional settings"))
                }
                if category.parent == nil {
                    TaskCategoryLabel(category: category)
                } else {
                    Text(category.displayTitle).font(.system(size: 10))
                        .padding(.leading, 27).padding(.vertical, 8)
                        .help(category.taskDescription)
                        .accessibilityHint(category.taskDescription)
                }
            }.padding(.leading, 7).frame(width: taskWidth, alignment: .leading)
            ForEach(platforms) { platform in
                cell(platform, category).frame(maxWidth: .infinity, alignment: .leading)
                    .id(platform.rawValue + "-" + category.rawValue)
            }
            if allowsEditing {
                Button {
                    if !store.isEditing { store.beginEditing() }
                    editingCategory = editingCategory == category ? nil : category
                } label: {
                    Image(systemName: editingCategory == category ? "checkmark" : "pencil")
                        .font(.system(size: 10)).frame(width: 28, height: 30)
                }.buttonStyle(.plain).foregroundStyle(StandMixerTheme.muted)
                    .accessibilityLabel("Edit " + category.displayTitle)
                    .help("Edit this work group for both apps")
                    .disabled(store.isChecking)
            }
        }
        .frame(minHeight: category.parent == nil ? 48 : 37)
        .background(category.parent == nil ? Color.clear : StandMixerTheme.accent.opacity(0.025))
        if allowsEditing, store.isEditing, editingCategory == category {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(category.displayTitle).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("Done") { editingCategory = nil }.controlSize(.small)
                }
                Text(category.taskDescription).font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(platforms) { platform in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(platform.displayName).font(.system(size: 10, weight: .semibold))
                            RouteRow(currentSettings: store.currentSettings, platform: platform, category: category)
                        }.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }.padding(12).background(StandMixerTheme.accentSoft.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 8).padding(.bottom, 10)
        }
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
        case .algorithms, .research: return StandMixerTheme.adaptive(0x6E6BB8, 0xA8A5DC)
        case .review: return StandMixerTheme.adaptive(0x407A9C, 0x8CB7D0)
        case .mechanical: return StandMixerTheme.adaptive(0x697896, 0xA2AFC7)
        default: return StandMixerTheme.muted
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
        case .algorithms, .research:
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
        default:
            path.addEllipse(in: CGRect(x: 8, y: 8, width: 8, height: 8))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}
