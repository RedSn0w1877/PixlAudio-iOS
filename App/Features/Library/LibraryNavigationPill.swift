import PixlModel
import SwiftUI

/// Android `LibraryNavigationMode` storage keys (`library_navigation_mode`).
nonisolated enum LibraryNavigationMode {
    static let tabRow = "tab_row"
    static let compactPill = "compact_pill"
}

/// Android `LibraryNavigationPill` (Library Navigation › Compact pill & grid): the current tab's icon and name in
/// the title half, the arrow in the other half (4 pt apart, 26 pt outer and 4 pt inner corners, 52 pt tall), in
/// place of the "Library" title. The Material surfaces are glass tinted `primaryContainer`; Android's tab-switcher
/// sheet is the system menu opening out of the pill (owner decision: small menus are native menus), listing the
/// tabs in the user's order and "Reorder tabs".
struct LibraryNavigationPill: View {
    let tab: LibraryTab
    let tabs: [LibraryTab]
    let onSelect: (LibraryTab) -> Void
    let onReorder: () -> Void

    /// TopAppBar's 16 pt title inset plus the pill's own 4 pt (`padding(start = 4.dp)`).
    static let leadingInset: CGFloat = 20
    static let height: CGFloat = 52
    private static let outerRadius: CGFloat = 26
    private static let innerRadius: CGFloat = 4

    @Environment(\.appTheme) private var theme

    var body: some View {
        Menu {
            Picker("Library tab", selection: Binding(get: { tab }, set: onSelect)) {
                ForEach(tabs, id: \.self) { item in
                    Label(item.tabTitle, systemImage: item.systemImage).tag(item)
                }
            }
            Divider()
            Button("Reorder tabs", systemImage: "pencil", action: onReorder)
        } label: {
            HStack(spacing: 4) {
                titleHalf
                arrowHalf
            }
            .frame(height: Self.height)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(tab.tabTitle)
        .accessibilityHint("Shows the Library tabs")
        .accessibilityIdentifier("library.navigationPill")
    }

    private var titleHalf: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: Self.outerRadius, bottomLeadingRadius: Self.outerRadius,
                                           bottomTrailingRadius: Self.innerRadius, topTrailingRadius: Self.innerRadius,
                                           style: .continuous)
        return HStack(spacing: 10) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 22, height: 22)
            Text(tab.tabTitle)
                .pixlFont(.custom(size: 26, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(theme.onPrimaryContainer)
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .contentShape(shape)
        .pixlGlass(in: shape, tint: theme.primaryContainer.opacity(GlassTint.prominent), interactive: true)
    }

    private var arrowHalf: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: Self.innerRadius, bottomLeadingRadius: Self.innerRadius,
                                           bottomTrailingRadius: Self.outerRadius, topTrailingRadius: Self.outerRadius,
                                           style: .continuous)
        return Image(systemName: "chevron.down")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(theme.onPrimaryContainer)
            .frame(width: 36)
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .contentShape(shape)
            .pixlGlass(in: shape, tint: theme.primaryContainer.opacity(GlassTint.prominent), interactive: true)
    }
}

/// Android `CompactLibraryPagerIndicator`: one 4 pt capsule per tab, the current one 22 pt wide at full `primary`,
/// the others 10 pt at 35 %.
struct CompactLibraryPagerIndicator: View {
    let currentIndex: Int
    let pageCount: Int

    @Environment(\.appTheme) private var theme

    var body: some View {
        if pageCount > 1 {
            HStack(spacing: 0) {
                ForEach(0..<pageCount, id: \.self) { index in
                    let isSelected = index == currentIndex
                    Capsule()
                        .fill(theme.primary.opacity(isSelected ? 1 : 0.35))
                        .frame(width: isSelected ? 22 : 10, height: 4)
                        .padding(.horizontal, 3)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(PixlMotion.state, value: currentIndex)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(currentIndex + 1) of \(pageCount)")
        }
    }
}
