import PixlModel
import SwiftUI

/// Search's results filter (redesign 2, Android `SearchFilterGroup`, mockup AndroidSearchResults): one connected
/// group, 44 pt tall, 2 pt gaps, equal widths, outer corners 22 / inner 8; the selected segment is `primary` glass and
/// fully round, the others `surfaceContainerHigh` glass with an `onSurface` label (14/20 medium). Order: All, Songs,
/// Artists, Albums, Playlists. The catalogue and YouTube Music are result sections, never segments (as on Android).
struct SearchFilterChips: View {
    @Binding var selection: SearchFilterType

    @Environment(\.appTheme) private var theme

    /// Android `SearchFilterGroupOrder`.
    static let filters: [SearchFilterType] = [.all, .songs, .artists, .albums, .playlists]

    static func title(_ filter: SearchFilterType) -> String {
        switch filter {
        case .all: "All"
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        case .catalog, .youtubeMusic: "Songs" // never a segment (Android maps them to the Songs label too)
        }
    }

    var body: some View {
        // Container spacing below the 2 pt gap: the segments render together but never blend at rest.
        GlassEffectContainer(spacing: 1) {
            HStack(spacing: Redesign.groupGap) {
                ForEach(Array(Self.filters.enumerated()), id: \.element) { index, filter in
                    RedesignGroupButton(position: .of(index, count: Self.filters.count), isSelected: filter == selection,
                                        height: 44, inner: 8, horizontalPadding: 6,
                                        action: { withAnimation(PixlMotion.selection) { selection = filter } }) { tint in
                        Text(Self.title(filter))
                            .pixlFont(.redesignLabel)
                            .foregroundStyle(filter == selection ? tint : theme.onSurface)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .accessibilityIdentifier("search.filter.\(filter.rawValue.lowercased())")
                }
            }
        }
        .pixlHaptic(.selection, trigger: selection)
    }
}

/// A wrapping row (Compose `FlowRow`): children left to right, wrapping to a new line when the width runs out.
nonisolated struct SearchFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    nonisolated private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if !current.indices.isEmpty, needed > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
