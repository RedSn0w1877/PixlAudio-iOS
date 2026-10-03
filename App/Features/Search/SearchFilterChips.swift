import PixlModel
import SwiftUI

/// Search's filter chips (Android `SearchFilterChip`s in a `FlowRow`): All, Songs, Albums, Artists, Playlists.
/// Each Material `FilterChip` (32 pt capsule inside its 48 pt touch target; selected = `primary` with a check icon,
/// others `secondaryContainer`) becomes a glass capsule tinted with that role. The selected tint is one glass shape
/// with a shared `glassEffectID`, so it glides to the newly selected chip. The catalogue and YouTube Music are
/// result sections, never chips (as on Android).
struct SearchFilterChips: View {
    @Binding var selection: SearchFilterType

    @Environment(\.appTheme) private var theme
    @Namespace private var glassNamespace

    /// Android `GlassSearchFilters` / the chips' order and labels.
    static let filters: [SearchFilterType] = [.all, .songs, .albums, .artists, .playlists]

    static func title(_ filter: SearchFilterType) -> String {
        switch filter {
        case .all: "All"
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        case .catalog, .youtubeMusic: "Songs" // never a chip (Android maps them to the Songs label too)
        }
    }

    nonisolated private enum GlassID: Hashable, Sendable {
        case selection
        case chip(String)
    }

    var body: some View {
        // Container spacing well below the 8 pt gap: chips render together but never blend at rest.
        GlassEffectContainer(spacing: 3) {
            SearchFlowLayout(horizontalSpacing: 8, verticalSpacing: 0) {
                ForEach(Self.filters, id: \.self) { filter in
                    chip(filter, title: Self.title(filter))
                }
            }
        }
        .pixlHaptic(.selection, trigger: selection)
    }

    private func chip(_ filter: SearchFilterType, title: String) -> some View {
        let isSelected = filter == selection
        return Button {
            withAnimation(PixlMotion.selection) { selection = filter }
        } label: {
            HStack(spacing: 8) {
                if isSelected {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(title)
                    .pixlFont(.labelLarge)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? theme.onPrimary : theme.onSecondaryContainer)
            // FilterChip: 8 pt outer padding + 8 pt around the label; 8 pt before a leading icon.
            .padding(.leading, isSelected ? 8 : 16)
            .padding(.trailing, 16)
            .frame(height: 32)
            .contentShape(.capsule)
            .glassEffect(
                Glass.regular
                    .tint(isSelected ? theme.primary.opacity(GlassTint.prominent)
                                     : theme.secondaryContainer.opacity(GlassTint.container))
                    .interactive(),
                in: Capsule()
            )
            .glassEffectID(isSelected ? GlassID.selection : GlassID.chip(title), in: glassNamespace)
            // Material's 48 pt minimum touch target around the 32 pt chip.
            .frame(height: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("search.filter.\(filter.rawValue.lowercased())")
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
