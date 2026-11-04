import SwiftUI
import AgentMixCore

/// Routing is separate from the model's intensity color.
struct ProviderBadge: View {
    let platform: AgentPlatform
    var subdued = false
    private var ink: Color {
        platform == .codex ? AgentMixTheme.adaptive(0x3863BF, 0x8CAFF0)
            : AgentMixTheme.adaptive(0x6B4ABA, 0xC49CDE)
    }
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(subdued ? AgentMixTheme.muted : AgentMixTheme.provider(platform)).frame(width: 4.5, height: 4.5)
            Text("via " + platform.displayName).font(.system(size: 8.5, weight: .semibold))
        }
        .foregroundStyle(subdued ? AgentMixTheme.muted : ink)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background((subdued ? AgentMixTheme.muted : AgentMixTheme.provider(platform)).opacity(0.10), in: Capsule())
        .fixedSize()
        .accessibilityLabel((subdued ? "Previous route " : "Route ") + "via " + platform.displayName)
    }
}

/// A proposal and its known previous model remain in the same compact cell.
struct AssignmentChangeLine: View {
    @EnvironmentObject private var store: AppStore
    let platform: AgentPlatform
    let modelID: String
    var effort: EffortPolicy? = nil
    var oldModelID: String? = nil
    var oldPlatform: AgentPlatform? = nil
    var oldEffort: EffortPolicy? = nil
    var prefix: String? = nil
    var removed = false
    var added = false
    var previousLabel = "Currently"
    var showEffort = false
    var showsComparison = true

    private var provider: AgentPlatform? { store.model(modelID)?.platform }
    private var previousProvider: AgentPlatform? { oldModelID.flatMap { store.model($0)?.platform } ?? oldPlatform }
    private var modelChanged: Bool { oldModelID.map { $0 != modelID } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            InlineFlowLayout(spacing: 5, lineSpacing: 2) {
                if let prefix { Text(prefix).font(.system(size: 9)).foregroundStyle(AgentMixTheme.muted) }
                ModelIdentityLabel(modelID: modelID, reportedPlatform: removed ? oldPlatform : nil,
                                   previous: removed, emphasized: modelChanged || added)
                if let provider = provider ?? (removed ? oldPlatform : nil), provider != platform {
                    ProviderBadge(platform: provider, subdued: removed)
                }
                if showsComparison && removed { Text("Removed").font(.system(size: 9, weight: .medium)).foregroundStyle(AgentMixTheme.accent) }
                if showsComparison && added { Text("Added").font(.system(size: 8.5, weight: .medium)).foregroundStyle(AgentMixTheme.accent) }
            }
            .font(.system(size: 12))
            if showsComparison, modelChanged, let oldModelID, !removed {
                InlineFlowLayout(spacing: 4, lineSpacing: 2) {
                    Text(previousLabel).foregroundStyle(AgentMixTheme.muted)
                    ModelIdentityLabel(modelID: oldModelID, reportedPlatform: previousProvider, previous: true, showsMark: false)
                    if let previousProvider, previousProvider != platform { ProviderBadge(platform: previousProvider, subdued: true) }
                }
                .font(.system(size: 9)).padding(.leading, prefix == nil ? 22 : 34)
            }
            if showEffort, modelID != Route.autoControllerModelID, let effort, !removed,
               oldEffort.map({ !$0.semanticallyMatches(effort) }) ?? (effort.mode != .auto) {
                (Text("Effort ").foregroundColor(AgentMixTheme.muted) + effortDifference(effort))
                    .font(.system(size: 9)).padding(.leading, prefix == nil ? 22 : 34)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func effortDifference(_ effort: EffortPolicy) -> Text {
        let label = effort.mode == .auto ? "Auto · follows caller" : effort.shortLabel
        if let oldEffort, !oldEffort.semanticallyMatches(effort) {
            return Text(oldEffort.shortLabel).strikethrough().foregroundColor(AgentMixTheme.muted)
                + Text(" → ").foregroundColor(AgentMixTheme.muted)
                + Text(label).foregroundColor(AgentMixTheme.accent).fontWeight(.medium)
        }
        return Text(label).foregroundColor(AgentMixTheme.muted)
    }
}

/// Small inline fragments retain their own styling and stay adjacent across adaptive line breaks.
struct InlineFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 2
    private struct Item { let index: Int; let size: CGSize; var origin: CGPoint }
    private func arrangement(_ subviews: Subviews, width: CGFloat) -> (items: [Item], size: CGSize) {
        var items: [Item] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var rowStart = 0
        func alignRow() {
            for index in rowStart..<items.count {
                items[index].origin.y = y + (rowHeight - items[index].size.height) / 2
            }
        }
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = ideal.width > width ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
            if x > 0 && x + size.width > width {
                alignRow()
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
                rowStart = items.count
            }
            items.append(Item(index: index, size: size, origin: CGPoint(x: x, y: y)))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        alignRow()
        return (items, CGSize(width: usedWidth, height: y + rowHeight))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangement(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? result.size.width, height: result.size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for item in arrangement(subviews, width: bounds.width).items {
            subviews[item.index].place(at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                                      proposal: ProposedViewSize(item.size))
        }
    }
}
