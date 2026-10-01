import SwiftUI

/// The bottom tab bar in the iOS style (Hoa, 2026-10-01: "just an ios liquid navbar just with the accent color as
/// the gliding glass pill"): a floating Liquid Glass capsule with Home, Search and Library — symbol over a small
/// label, or symbols only in compact mode (Settings › Appearance) — and one glass pill tinted with the accent colour
/// behind the selected tab. The pill glides to a tapped tab; like the system tab bar's lens it follows the finger
/// when you press and drag along the bar, swelling slightly while held, and settles on the nearest tab on release.
///
/// Custom rather than the system `TabView` bar because the system's selection platter can't take the accent colour,
/// and the player sheet expands from the mini player slot that floats above this bar (stage 8).
struct GlassNavBar: View {
    let selection: RootTab
    var compact = false
    let onSelect: (RootTab) -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0
    /// The pill's centre while a finger drags along the bar; nil at rest.
    @State private var dragX: CGFloat?
    /// The tab under the dragging finger; nil at rest.
    @State private var hovered: RootTab?

    private let tabs = RootTab.allCases
    private let inset = Tokens.Shell.navPillInset

    var body: some View {
        let height = compact ? Tokens.Shell.navBarCompactHeight : Tokens.Shell.navBarHeight
        ZStack(alignment: .leading) {
            pill(height: height)
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    item(tab)
                }
            }
            .padding(.horizontal, inset)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .glassEffect(Glass.regular, in: Capsule())
        .contentShape(Capsule())
        .gesture(drag)
        .sensoryFeedback(.selection, trigger: hovered ?? selection)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("navBar")
    }

    // MARK: Pill

    private var cellWidth: CGFloat {
        max(0, (width - inset * 2) / CGFloat(tabs.count))
    }

    private func center(of tab: RootTab) -> CGFloat {
        let index = CGFloat(tabs.firstIndex(of: tab) ?? 0)
        return inset + cellWidth * (index + 0.5)
    }

    private func tab(at x: CGFloat) -> RootTab {
        guard cellWidth > 0 else { return selection }
        let index = Int(((x - inset) / cellWidth).rounded(.down))
        return tabs[min(max(index, 0), tabs.count - 1)]
    }

    private func pill(height: CGFloat) -> some View {
        let pillWidth = cellWidth
        let lo = inset + pillWidth / 2
        let hi = max(lo, width - inset - pillWidth / 2)
        let x = dragX.map { min(max($0, lo), hi) } ?? center(of: selection)
        let isHeld = dragX != nil
        return Capsule()
            .fill(.clear)
            .frame(width: pillWidth, height: height - inset * 2)
            .glassEffect(Glass.regular.tint(theme.primary.opacity(GlassTint.prominent)), in: Capsule())
            .scaleEffect(isHeld && !reduceMotion ? 1.12 : 1)
            .animation(Self.lens, value: isHeld)
            .offset(x: x - pillWidth / 2)
            .opacity(width > 0 ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Items

    private func item(_ tab: RootTab) -> some View {
        let isLit = tab == (hovered ?? selection)
        return VStack(spacing: 2) {
            Image(systemName: isLit ? tab.selectedSystemImage : tab.systemImage)
                .font(.system(size: compact ? 21 : 19, weight: .semibold))
                .frame(height: 24)
            if !compact {
                Text(tab.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isLit ? AnyShapeStyle(theme.onPrimary) : AnyShapeStyle(.primary))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(tab == selection ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("navBar.\(tab.rawValue)")
        .accessibilityAction { onSelect(tab) }
    }

    // MARK: Gesture

    /// The pill swelling under the finger and settling back.
    private static let lens = Animation.spring(response: 0.25, dampingFraction: 0.7)
    /// The pill trailing the finger: quick enough to feel attached, soft enough to read as liquid.
    private static let follow = Animation.interactiveSpring(response: 0.18, dampingFraction: 0.86)

    /// A tap selects the tab under it; a press-and-drag carries the pill along the bar and selects where it lets go.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                guard dragX != nil || abs(value.translation.width) > 6 else { return }
                withAnimation(reduceMotion ? nil : Self.follow) {
                    dragX = value.location.x
                }
                let under = tab(at: value.location.x)
                if hovered != under { hovered = under }
            }
            .onEnded { value in
                let target = tab(at: value.location.x)
                let wasDrag = dragX != nil
                withAnimation(reduceMotion ? .easeOut(duration: 0.18) : PixlMotion.selection) {
                    dragX = nil
                    hovered = nil
                }
                // A tap on the selected tab still reaches the router (it pops that tab to its root).
                if !wasDrag || target != selection { onSelect(target) }
            }
    }
}
