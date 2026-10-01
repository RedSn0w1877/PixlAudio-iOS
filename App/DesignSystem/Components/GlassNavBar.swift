import SwiftUI

/// PixlAudio's bottom bar (Android `PlayerInternalNavigationBar` + `CustomNavigationBarItem`, compact mode): three
/// icons without labels — Home, Search, Library — spread evenly, with a 56×32 selection bubble behind the selected
/// icon (secondary-container tint) that glides between items. The selected icon is `primary`, filled and 1.1×;
/// the others `onSurfaceVariant`. The bar is a glass shape: 32 pt bottom corners, top corners 10 pt while the mini
/// player sits on it (32 pt otherwise). Custom on purpose — not the system tab bar (decision 10).
struct GlassNavBar: View {
    let selection: RootTab
    var topCornerRadius: CGFloat = Tokens.Shell.navBarCornerRadius
    let onSelect: (RootTab) -> Void

    @Environment(\.appTheme) private var theme
    @Namespace private var bubbleNamespace

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: topCornerRadius,
                                           bottomLeadingRadius: Tokens.Shell.navBarCornerRadius,
                                           bottomTrailingRadius: Tokens.Shell.navBarCornerRadius,
                                           topTrailingRadius: topCornerRadius, style: .continuous)
        HStack(spacing: 0) {
            ForEach(RootTab.allCases) { tab in
                item(tab)
            }
        }
        .padding(.horizontal, Tokens.Shell.navRowPadding)
        .frame(height: Tokens.Shell.navBarHeight)
        .frame(maxWidth: .infinity)
        .pixlGlass(in: shape, tint: theme.surfaceContainer.opacity(GlassTint.bar))
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("navBar")
    }

    private func item(_ tab: RootTab) -> some View {
        let isSelected = tab == selection
        let s = Tokens.Shell.self
        return Button {
            onSelect(tab)
        } label: {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: s.indicatorHeight / 2, style: .continuous)
                        .fill(.clear)
                        .frame(width: s.indicatorWidth - 2 * s.indicatorInset, height: s.indicatorHeight)
                        .glassEffect(Glass.regular.tint(theme.secondaryContainer.opacity(GlassTint.prominent)),
                                     in: RoundedRectangle(cornerRadius: s.indicatorHeight / 2, style: .continuous))
                        .matchedGeometryEffect(id: "navBubble", in: bubbleNamespace)
                }
                Image(systemName: isSelected ? tab.selectedSystemImage : tab.systemImage)
                    .font(.system(size: 20, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? theme.primary : theme.onSurfaceVariant)
                    .scaleEffect(isSelected ? s.navIconSelectedScale : 1)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: s.indicatorWidth, height: s.indicatorHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("navBar.\(tab.rawValue)")
    }
}
