import PixlFoundation
import SwiftUI

/// The bottom navigation bar as a split pill (new UI, owner decision 2026-11-16): one big see-through glass capsule
/// and one small glass circle side by side, floating at the bottom. It replaces the single liquid-lens capsule
/// (`LiquidTabBar`) and stays PixlAudio's own bar, not the system `TabView` bar (the player sheet expands from the mini
/// player slot above it).
///
/// - Home and Library: the big capsule holds the Home and Library segments, symbol beside a 15 pt label. The selected
///   segment sits in a tonal capsule (`primaryContainer` glass tint) that glides between segments while the segment
///   widens (1.3 : 1, `SplitPillNav.emphasisWeight`) and its label morphs heavier and wider (`expressiveEmphasis`,
///   `.navInline`). The circle is Search.
/// - Search: the shapes flip. The big capsule shrinks into the Home circle ("back to your stuff") and the circle grows
///   into the search field, bound to `Router.searchText` (focus, keyboard, clear and submit as the field on the Search
///   page had). Both shapes keep their glass and only resize inside one `GlassEffectContainer`, so the change is a
///   liquid morph, not a cut.
///
/// Touch, as the liquid lens did: a finger down on the big capsule lifts the selection capsule (it swells and clears,
/// the label under it turns the accent) and it follows the finger from segment to segment; the tab changes on
/// release. Re-tapping the selected tab pops it to its root (`Router.select`). Each segment is a button for
/// VoiceOver (`navBar.home`, `navBar.library`, `navBar.search`).
///
/// While a tab root scrolls down the bar minimizes (`TabBarMinimizer`): labels go, the big capsule narrows to 58 pt per
/// segment and both shapes lower to 48 pt. Compact mode (Settings › Appearance) shows symbols only at 54 pt.
struct GlassNavBar: View {
    let selection: RootTab
    var compact = false
    var minimized = false
    /// The search field's text (`Router.searchText`).
    @Binding var searchText: String
    /// The search field's focus, owned by the shell (which drops it when Search is left).
    var searchFocus: FocusState<Bool>.Binding
    let onSelect: (RootTab) -> Void
    /// The keyboard's search key.
    let onSubmitSearch: () -> Void

    @Environment(\.appTheme) private var theme
    @Namespace private var glassNamespace

    /// The two glass shapes. Each keeps its id across the flip; only its size and content change.
    nonisolated private enum NavGlassID: Hashable, Sendable {
        case leading
        case trailing
    }

    /// The segments of the big capsule.
    static let tabs: [RootTab] = [.home, .library]

    /// The shapes' height in each state; the shell's clearance uses the same values.
    static func height(compact: Bool, minimized: Bool) -> CGFloat {
        minimized ? Tokens.Shell.navBarMinimizedHeight
            : compact ? Tokens.Shell.navBarCompactHeight : Tokens.Shell.navBarHeight
    }

    var body: some View {
        let isSearch = selection == .search
        let height = Self.height(compact: compact, minimized: minimized)
        // Spacing below the gap: the shapes never blend at rest, yet morph as one family.
        GlassEffectContainer(spacing: Tokens.Shell.navPillSpacing * 0.4) {
            HStack(spacing: Tokens.Shell.navPillSpacing) {
                leadingShape(isSearch: isSearch, height: height)
                trailingShape(isSearch: isSearch, height: height)
            }
            .frame(height: height)
        }
        .frame(maxWidth: .infinity)
        .pixlHaptic(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("navBar")
    }

    // MARK: Leading shape: the tab segments, or the Home circle on Search

    private func leadingShape(isSearch: Bool, height: CGFloat) -> some View {
        let fixedWidth: CGFloat? = isSearch ? height
            : minimized ? CGFloat(SplitPillNav.minimizedWidth(count: Self.tabs.count,
                                                               segmentWidth: Double(Tokens.Shell.navBarMinimizedSegmentWidth),
                                                               spacing: Double(Tokens.Shell.navSegmentSpacing),
                                                               padding: Double(Tokens.Shell.navPillPadding)))
            : nil
        return ZStack {
            if isSearch {
                circleButton(.home, systemImage: RootTab.home.systemImage, height: height)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else {
                NavTabsPill(tabs: Self.tabs, selection: selection, showsLabels: !compact && !minimized,
                            onSelect: onSelect)
                    .transition(.opacity)
            }
        }
        .frame(width: fixedWidth, height: height)
        .frame(maxWidth: fixedWidth == nil ? .infinity : nil)
        .contentShape(.capsule)
        .glassEffect(Glass.regular.interactive(), in: Capsule())
        .glassEffectID(NavGlassID.leading, in: glassNamespace)
    }

    // MARK: Trailing shape: the Search circle, or the search field on Search

    private func trailingShape(isSearch: Bool, height: CGFloat) -> some View {
        ZStack {
            if isSearch {
                NavSearchField(text: $searchText, focus: searchFocus, height: height, onSubmit: onSubmitSearch)
                    .transition(.opacity)
            } else {
                circleButton(.search, systemImage: RootTab.search.systemImage, height: height)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .frame(width: isSearch ? nil : height, height: height)
        .frame(maxWidth: isSearch ? .infinity : nil)
        .contentShape(.capsule)
        .glassEffect(Glass.regular.interactive(), in: Capsule())
        .glassEffectID(NavGlassID.trailing, in: glassNamespace)
    }

    /// The small circle's glyph as a button filling the circle (no second glass: the shape is already glass).
    private func circleButton(_ tab: RootTab, systemImage: String, height: CGFloat) -> some View {
        Button {
            onSelect(tab)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: height >= Tokens.Shell.navBarHeight ? 22 : 20, weight: .semibold))
                .foregroundStyle(theme.onSurface)
                .frame(width: height, height: height)
                .contentShape(.circle)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
        .accessibilityIdentifier("navBar.\(tab.rawValue)")
    }
}

// MARK: - Segments

/// The big capsule's Home / Library segments with the gliding tonal selection capsule. Only this small view
/// re-renders while a finger moves along it, and only when the segment under the finger changes.
private struct NavTabsPill: View {
    let tabs: [RootTab]
    let selection: RootTab
    let showsLabels: Bool
    let onSelect: (RootTab) -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The segment under a finger that is down on the capsule (the lifted selection).
    @State private var pressed: RootTab?
    /// The segments' width (the capsule minus its padding), for the finger's hit test.
    @State private var contentWidth: CGFloat = 0
    /// True while a touch is down; resets by itself when the system cancels the touch, which clears `pressed`.
    @GestureState private var isTouching = false

    private var motion: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : PixlMotion.selection
    }

    var body: some View {
        let shown = pressed ?? selection
        let shownIndex = tabs.firstIndex(of: shown)
        let lifted = pressed != nil
        NavSegmentsLayout(emphasized: shownIndex, spacing: Tokens.Shell.navSegmentSpacing) {
            selectionCapsule(lifted: lifted)
                .opacity(shownIndex == nil ? 0 : 1)
            ForEach(tabs) { tab in
                segment(tab, isEmphasized: tab == shown, lifted: lifted)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            contentWidth = width
        }
        .padding(Tokens.Shell.navPillPadding)
        .contentShape(.capsule)
        .gesture(press)
        .onChange(of: isTouching) { _, touching in
            if !touching, pressed != nil {
                withAnimation(motion) { pressed = nil }
            }
        }
    }

    /// One gesture for taps and press-and-drag: the lifted capsule follows the finger, the tab changes on release.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($isTouching) { _, state, _ in state = true }
            .onChanged { value in
                guard let tab = segmentTab(at: value.location.x), tab != pressed else { return }
                withAnimation(motion) { pressed = tab }
            }
            .onEnded { value in
                let target = pressed ?? segmentTab(at: value.location.x)
                withAnimation(motion) { pressed = nil }
                if let target { onSelect(target) }
            }
    }

    /// The segment under `x` (in the padded capsule's coordinates), with the shown segment drawn wide.
    private func segmentTab(at x: CGFloat) -> RootTab? {
        guard contentWidth > 0 else { return nil }
        let emphasized = tabs.firstIndex(of: pressed ?? selection)
        let index = SplitPillNav.index(at: Double(x - Tokens.Shell.navPillPadding), width: Double(contentWidth),
                                       count: tabs.count, emphasized: emphasized,
                                       spacing: Double(Tokens.Shell.navSegmentSpacing))
        return index.map { tabs[$0] }
    }

    /// The tonal capsule behind the shown segment: `primaryContainer` at rest; lifted, it swells and clears so the
    /// glass shows through it (a fill, not a second glass layer on the capsule's glass).
    private func selectionCapsule(lifted: Bool) -> some View {
        Capsule()
            .fill(theme.primaryContainer.opacity(lifted ? 0.3 : GlassTint.container))
            .overlay {
                Capsule().strokeBorder(theme.onSurface.opacity(lifted ? 0.22 : 0.08), lineWidth: 1)
            }
            .scaleEffect(lifted && !reduceMotion ? 1.06 : 1)
            .accessibilityHidden(true)
    }

    private func segment(_ tab: RootTab, isEmphasized: Bool, lifted: Bool) -> some View {
        let isSelected = tab == selection
        let color: Color = isEmphasized ? (lifted ? theme.primary : theme.onPrimaryContainer) : theme.onSurface.opacity(0.86)
        return HStack(spacing: 7) {
            Image(systemName: isEmphasized ? tab.selectedSystemImage : tab.systemImage)
                .font(.system(size: showsLabels ? 19 : 21, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            if showsLabels {
                Text(tab.title)
                    .expressiveEmphasis(isEmphasized, .navInline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
            }
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("navBar.\(tab.rawValue)")
        .accessibilityAction { onSelect(tab) }
    }
}

/// Lays the segments out by weight (`SplitPillNav.spans`) and puts the selection capsule — the first subview —
/// under the emphasized one. A change of `emphasized` inside an animation glides the capsule and resizes the segments
/// in the same layout pass; nothing is measured per frame.
nonisolated struct NavSegmentsLayout: Layout {
    var emphasized: Int?
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let segments = subviews.dropFirst()
        let sizes = segments.map { $0.sizeThatFits(.unspecified) }
        let idealWidth = sizes.reduce(CGFloat(0)) { $0 + $1.width } + spacing * CGFloat(max(sizes.count - 1, 0))
        let idealHeight = sizes.map(\.height).max() ?? 0
        return CGSize(width: proposal.width ?? idealWidth, height: proposal.height ?? idealHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count > 1 else { return }
        let count = subviews.count - 1
        let spans = SplitPillNav.spans(width: Double(bounds.width),
                                       weights: SplitPillNav.weights(count: count, emphasized: emphasized),
                                       spacing: Double(spacing))
        for (offset, span) in spans.enumerated() {
            subviews[offset + 1].place(at: CGPoint(x: bounds.minX + CGFloat(span.x), y: bounds.minY), anchor: .topLeading,
                                       proposal: ProposedViewSize(width: CGFloat(span.width), height: bounds.height))
        }
        let target = emphasized.flatMap { spans.indices.contains($0) ? spans[$0] : nil } ?? spans[0]
        subviews[0].place(at: CGPoint(x: bounds.minX + CGFloat(target.x), y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: CGFloat(target.width), height: bounds.height))
    }
}

// MARK: - Search field

/// The search field inside the big capsule on the Search tab (the field that used to sit at the top of the Search
/// page): search symbol, the text field, and a clear button once there is text.
private struct NavSearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let height: CGFloat
    let onSubmit: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let isBlank = text.isKotlinBlank
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(theme.primary)
                .frame(width: 44, height: height)
                .padding(.leading, 6)
                .accessibilityHidden(true)
            TextField("", text: $text, prompt: Text("Search…").foregroundStyle(theme.primary))
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurface)
                .tint(theme.primary)
                .focused(focus)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(onSubmit)
                .padding(.trailing, isBlank ? 20 : 4)
                .accessibilityLabel("Search")
                .accessibilityIdentifier("search.field")
            if !isBlank {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(theme.primary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(theme.primaryContainer.opacity(0.3)))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(PressScaleButtonStyle())
                .padding(.trailing, max(4, (height - 44) / 2))
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("search.clear")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(PixlMotion.state, value: isBlank)
    }
}
