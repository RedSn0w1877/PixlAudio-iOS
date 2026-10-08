import SwiftUI
import UIKit

// The UIKit core of PixlAudio's liquid-lens controls: the bottom tab bar and segmented pickers such as the song
// picker's LOCAL / CLOUD switch. On iOS 26 and later the system offers the "liquid lens" selection in only two
// controls, UITabBar and UISegmentedControl. When touched, the selection lifts off as clear glass, swells past the
// bar, follows the finger and magnifies the content under it, then settles back into the tinted pill.
// This file follows the technique of the open-source FabBar (Ryan Ashcraft, MIT,
// https://github.com/ryanashcraft/FabBar; see THIRD_PARTY_NOTICES.md):
// - A UISegmentedControl sits inside a capsule of interactive UIKit glass.
// - The segments' own labels and background images are hidden, and PixlAudio's glyphs (symbol + label) are added
//   inside each segment view, so the lens magnifies them.
// - A second, accent-coloured copy of each glyph is masked to the lens' animated frame, so whatever sits under the
//   lens takes the selection colour.
// - The lens moves on touch down, like the tab bar does; the selection itself changes on touch up.
// The segment views and the lens are found by class name ("UISegment", "_UILiquidLensView"); no private API is
// called. If a future iOS changes that hierarchy, the glyphs are not injected and the control falls back to its
// own segment titles, so it stays usable.

/// One segment of a liquid-lens control.
nonisolated struct LiquidSegmentItem: Hashable, Sendable {
    let title: String
    /// Outline symbol, shown outside the lens.
    let systemImage: String
    /// Filled symbol, shown inside the lens.
    let selectedSystemImage: String
    /// The segment view's accessibility identifier (UI tests).
    let identifier: String
}

/// How a glyph arranges its symbol and label.
nonisolated enum LiquidGlyphLayout: Sendable {
    /// Symbol over a 10 pt label (the tab bar).
    case stacked
    /// Symbol beside a 14 pt bold label (pickers).
    case inline
}

// MARK: - Tab bar

/// PixlAudio's tab bar as a SwiftUI view: Home, Search, Library on the system liquid lens.
/// `minimized` is the scroll state (Hoa, 2026-10-03: "an auto compact version that removes the labels and shrinks the
/// distance between the icons and makes it smaller and … a bit shorter as well when the user scrolls"): the capsule
/// narrows around the symbols and lowers, animated in UIKit so the lens and its masks follow every frame.
struct LiquidTabBar: UIViewRepresentable {
    let selection: RootTab
    /// Settings › Appearance compact mode: symbols only, full width.
    let compact: Bool
    /// Scrolled: symbols only, narrow and shorter.
    let minimized: Bool
    /// Tint of the resting selection pill (the accent).
    let pillColor: UIColor
    /// Glyph colour on the resting pill (`onPrimary`).
    let restingGlyphColor: UIColor
    /// Glyph colour under the lifted, clear lens (the accent, as on the system tab bar).
    let liftedGlyphColor: UIColor
    /// Takes the bar's UIKit segments out of the accessibility tree (`accessibilityElementsHidden`), e.g. while the
    /// full player covers the bar. SwiftUI's `accessibilityHidden` around this view does not reach them: the hidden
    /// tabs kept answering accessibility hit tests under the player's shuffle · repeat · favourite row.
    var accessibilityHidden = false
    let onSelect: (RootTab) -> Void

    static func items() -> [LiquidSegmentItem] {
        RootTab.allCases.map {
            LiquidSegmentItem(title: $0.title, systemImage: $0.systemImage,
                              selectedSystemImage: $0.selectedSystemImage, identifier: "navBar.\($0.rawValue)")
        }
    }

    /// The glass capsule's height in each state; the SwiftUI frame around the bar uses the same values.
    static func height(compact: Bool, minimized: Bool) -> CGFloat {
        minimized ? Tokens.Shell.navBarMinimizedHeight
            : compact ? Tokens.Shell.navBarCompactHeight : Tokens.Shell.navBarHeight
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIView(context: Context) -> LiquidLensBarView {
        let control = LiquidLensSegmentedControl(items: Self.items(), layout: .stacked, showsTitles: !compact && !minimized)
        control.accessibilityTraits = .tabBar
        let view = LiquidLensBarView(control: control)
        let coordinator = context.coordinator
        control.addTarget(coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        control.onReselect = { [weak coordinator] index in coordinator?.reselect(index: index) }
        apply(to: view, coordinator: coordinator, animated: false)
        return view
    }

    func updateUIView(_ view: LiquidLensBarView, context: Context) {
        context.coordinator.onSelect = onSelect
        apply(to: view, coordinator: context.coordinator, animated: true)
    }

    private func apply(to view: LiquidLensBarView, coordinator: Coordinator, animated: Bool) {
        let control = view.control
        control.pillColor = pillColor
        control.restingGlyphColor = restingGlyphColor
        control.liftedGlyphColor = liftedGlyphColor
        control.baseGlyphColor = .label
        if view.accessibilityElementsHidden != accessibilityHidden {
            view.accessibilityElementsHidden = accessibilityHidden
        }
        let width: CGFloat? = minimized
            ? CGFloat(RootTab.allCases.count) * Tokens.Shell.navBarMinimizedSegmentWidth + 2 * Tokens.Shell.navGlassPadding
            : nil
        view.setShape(height: Self.height(compact: compact, minimized: minimized), width: width, animated: animated)
        control.setShowsTitles(!compact && !minimized, animated: animated)
        let index = RootTab.allCases.firstIndex(of: selection) ?? 0
        coordinator.currentIndex = index
        // While a finger is on the bar the control owns the selection (the lens follows the finger).
        if !control.isTracking, control.selectedSegmentIndex != index {
            control.selectedSegmentIndex = index
        }
    }

    final class Coordinator: NSObject {
        var onSelect: (RootTab) -> Void
        var currentIndex = 0

        init(onSelect: @escaping (RootTab) -> Void) {
            self.onSelect = onSelect
        }

        @objc func valueChanged(_ control: UISegmentedControl) {
            let index = control.selectedSegmentIndex
            // One callback per real change (a re-tap goes through `reselect`, which pops the tab to its root).
            guard index != currentIndex, RootTab.allCases.indices.contains(index) else { return }
            currentIndex = index
            onSelect(RootTab.allCases[index])
        }

        func reselect(index: Int) {
            guard RootTab.allCases.indices.contains(index) else { return }
            onSelect(RootTab.allCases[index])
        }
    }
}

// MARK: - Segmented picker

/// A segmented picker on the liquid lens (the song picker's LOCAL / CLOUD switch). Hoa, 2026-10-03: "the local/cloud
/// like buttons need to implement the same liquid magnifying mechanism as the main home screen implementation".
struct LiquidSegmentedPicker<Value: Hashable>: UIViewRepresentable {
    let options: [Value]
    let items: [LiquidSegmentItem]
    @Binding var selection: Value
    /// The SwiftUI animation a change of `selection` runs in (the lens animates itself).
    var animation: Animation?
    let pillColor: UIColor
    let restingGlyphColor: UIColor
    let liftedGlyphColor: UIColor
    let baseGlyphColor: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> LiquidLensBarView {
        let control = LiquidLensSegmentedControl(items: items, layout: .inline, showsTitles: true)
        let view = LiquidLensBarView(control: control)
        control.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        apply(to: view)
        return view
    }

    func updateUIView(_ view: LiquidLensBarView, context: Context) {
        context.coordinator.parent = self
        apply(to: view)
    }

    private func apply(to view: LiquidLensBarView) {
        let control = view.control
        control.pillColor = pillColor
        control.restingGlyphColor = restingGlyphColor
        control.liftedGlyphColor = liftedGlyphColor
        control.baseGlyphColor = baseGlyphColor
        let index = options.firstIndex(of: selection) ?? 0
        if !control.isTracking, control.selectedSegmentIndex != index {
            control.selectedSegmentIndex = index
        }
    }

    final class Coordinator: NSObject {
        var parent: LiquidSegmentedPicker

        init(parent: LiquidSegmentedPicker) {
            self.parent = parent
        }

        @objc func valueChanged(_ control: UISegmentedControl) {
            let index = control.selectedSegmentIndex
            guard parent.options.indices.contains(index), parent.options[index] != parent.selection else { return }
            let value = parent.options[index]
            withAnimation(parent.animation) { parent.selection = value }
        }
    }
}

// MARK: - Glass capsule

/// The capsule of interactive glass holding a liquid-lens segmented control. Its shape (height, and a fixed width or
/// the full width) animates in UIKit, so the segments, the lens and the accent masks follow on every frame. The glass
/// sits at the bottom centre of the view; touches outside it fall through.
final class LiquidLensBarView: UIView {
    let glassView: UIVisualEffectView // holds a UIGlassEffect (real Liquid Glass)
    let control: LiquidLensSegmentedControl

    private var heightConstraint: NSLayoutConstraint!
    private var fullWidthConstraint: NSLayoutConstraint!
    private var fixedWidthConstraint: NSLayoutConstraint!

    init(control: LiquidLensSegmentedControl) {
        let glass = UIGlassEffect()
        glass.isInteractive = true
        glassView = UIVisualEffectView(effect: glass) // UIGlassEffect, interactive
        self.control = control
        super.init(frame: .zero)
        backgroundColor = .clear

        addSubview(glassView)
        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView.addSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        let padding = Tokens.Shell.navGlassPadding
        heightConstraint = glassView.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.priority = .defaultHigh
        fullWidthConstraint = glassView.widthAnchor.constraint(equalTo: widthAnchor)
        fixedWidthConstraint = glassView.widthAnchor.constraint(equalToConstant: 0)
        // Before the first `setShape`, the glass fills the view.
        let fillHeight = glassView.heightAnchor.constraint(equalTo: heightAnchor)
        fillHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            glassView.centerXAnchor.constraint(equalTo: centerXAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            fullWidthConstraint,
            fillHeight,
            control.leadingAnchor.constraint(equalTo: glassView.contentView.leadingAnchor, constant: padding),
            control.trailingAnchor.constraint(equalTo: glassView.contentView.trailingAnchor, constant: -padding),
            control.topAnchor.constraint(equalTo: glassView.contentView.topAnchor, constant: padding),
            // The segmented control sits 1 pt high inside its frame; this centres its content in the capsule.
            control.bottomAnchor.constraint(equalTo: glassView.contentView.bottomAnchor, constant: -padding - 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The capsule's height, and its width (`nil`: the view's full width).
    func setShape(height: CGFloat, width: CGFloat?, animated: Bool) {
        let changed = heightConstraint.constant != height || !heightConstraint.isActive
            || (width == nil) != fullWidthConstraint.isActive
            || (width.map { $0 != fixedWidthConstraint.constant } ?? false)
        guard changed else { return }
        heightConstraint.constant = height
        heightConstraint.isActive = true
        if let width {
            fixedWidthConstraint.constant = width
            fullWidthConstraint.isActive = false
            fixedWidthConstraint.isActive = true
        } else {
            fixedWidthConstraint.isActive = false
            fullWidthConstraint.isActive = true
        }
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            setNeedsLayout()
            return
        }
        UIView.animate(springDuration: 0.5, bounce: 0.2, initialSpringVelocity: 0, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.layoutIfNeeded()
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        glassView.frame.contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassView.cornerConfiguration = .capsule()
    }
}

// MARK: - Segmented control

/// A UISegmentedControl with PixlAudio's glyphs inside the segments, the lens moving on touch down, the selection
/// changing on touch up, and a re-tap reported separately.
final class LiquidLensSegmentedControl: UISegmentedControl {
    var onReselect: ((Int) -> Void)?

    var pillColor: UIColor = .tintColor {
        didSet { if pillColor != oldValue { selectedSegmentTintColor = pillColor } }
    }
    var restingGlyphColor: UIColor = .white {
        didSet { if restingGlyphColor != oldValue { updateGlyphColors(animated: false) } }
    }
    var liftedGlyphColor: UIColor = .tintColor {
        didSet { if liftedGlyphColor != oldValue { updateGlyphColors(animated: false) } }
    }
    /// Colour of the glyphs outside the lens.
    var baseGlyphColor: UIColor = .label {
        didSet { if baseGlyphColor != oldValue { updateGlyphColors(animated: false) } }
    }

    private let items: [LiquidSegmentItem]
    /// Outline glyphs in the base colour, cut out where the lens is.
    private let baseGlyphs: [TabGlyphView]
    /// Filled glyphs in the selection colour, shown only inside the lens.
    private let accentGlyphs: [TabGlyphView]
    private var injected = false
    /// A finger is down: the lens is lifted (clear glass), so glyphs under it take the lifted colour.
    private var isLifted = false
    /// The selection before the touch began, to restore on cancel and to detect a re-tap.
    private var originalIndex: Int?

    private weak var cachedLens: UIView?
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: LiquidTabDisplayLinkProxy?
    private var lastLensRect: CGRect = .null
    private var stableFrames = 0

    private static let baseTag = 7_801
    private static let accentTag = 7_802
    private static let segmentClassName = "UISegment"
    private static let lensClassName = "_UILiquidLensView"

    init(items: [LiquidSegmentItem], layout: LiquidGlyphLayout, showsTitles: Bool) {
        self.items = items
        baseGlyphs = items.map { TabGlyphView(symbolName: $0.systemImage, title: $0.title, layout: layout, showsTitle: showsTitles) }
        accentGlyphs = items.map {
            TabGlyphView(symbolName: $0.selectedSystemImage, title: $0.title, layout: layout, showsTitle: showsTitles)
        }
        super.init(items: items.map(\.title))
        showsLargeContentViewer = false
        updateGlyphColors(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows or hides the glyphs' labels, cross-fading (the glyphs keep their size, so nothing re-lays out).
    func setShowsTitles(_ showsTitles: Bool, animated: Bool) {
        for glyph in baseGlyphs + accentGlyphs where glyph.showsTitle != showsTitles {
            if animated, window != nil {
                UIView.transition(with: glyph, duration: 0.22,
                                  options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]) {
                    glyph.showsTitle = showsTitles
                }
            } else {
                glyph.showsTitle = showsTitles
            }
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        injectGlyphsIfNeeded()
        if injected { hideNativeChrome(in: self) }
        wakeDisplayLink()
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        // The control may recreate its labels on layout; keep them hidden once our glyphs are in.
        if injected { hideNativeChrome(in: subview) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startDisplayLink() } else { stopDisplayLink() }
    }

    // MARK: Glyphs

    private func injectGlyphsIfNeeded() {
        let segments = segmentViews()
        guard !items.isEmpty, segments.count == items.count else { return }
        for (index, segment) in segments.enumerated() {
            segment.accessibilityIdentifier = items[index].identifier
            if segment.viewWithTag(Self.baseTag) == nil {
                attach(baseGlyphs[index], tag: Self.baseTag, to: segment)
            }
            if segment.viewWithTag(Self.accentTag) == nil {
                let accent = accentGlyphs[index]
                attach(accent, tag: Self.accentTag, to: segment)
                let mask = CAShapeLayer()
                mask.path = UIBezierPath(rect: .zero).cgPath
                accent.layer.mask = mask
            }
        }
        if !injected {
            injected = true
            hideNativeChrome(in: self)
        }
    }

    private func attach(_ glyph: TabGlyphView, tag: Int, to segment: UIView) {
        glyph.tag = tag
        glyph.translatesAutoresizingMaskIntoConstraints = false
        segment.addSubview(glyph)
        let size = glyph.intrinsicContentSize
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: segment.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: segment.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: size.width),
            glyph.heightAnchor.constraint(equalToConstant: size.height),
        ])
    }

    private func updateGlyphColors(animated: Bool) {
        for glyph in baseGlyphs { glyph.tintColor = baseGlyphColor }
        let accentColor = isLifted ? liftedGlyphColor : restingGlyphColor
        for glyph in accentGlyphs {
            if animated {
                UIView.transition(with: glyph, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    glyph.tintColor = accentColor
                }
            } else {
                glyph.tintColor = accentColor
            }
        }
    }

    /// Hides the control's own labels and its segment background and separator images (the glass comes from the
    /// capsule around the control). Our glyphs are skipped by their tags.
    private func hideNativeChrome(in view: UIView) {
        if let label = view as? UILabel, label.superview?.tag != Self.baseTag, label.superview?.tag != Self.accentTag {
            label.isHidden = true
        }
        if view.superview === self, view is UIImageView {
            view.alpha = 0
        }
        for subview in view.subviews {
            hideNativeChrome(in: subview)
        }
    }

    // MARK: Hierarchy lookup

    private func segmentViews() -> [UIView] {
        var found: [UIView] = []
        func search(_ view: UIView) {
            for subview in view.subviews {
                if String(describing: type(of: subview)) == Self.segmentClassName {
                    found.append(subview)
                } else {
                    search(subview)
                }
            }
        }
        search(self)
        return found.sorted { $0.frame.minX < $1.frame.minX }
    }

    private func lensView() -> UIView? {
        if let cachedLens, cachedLens.window != nil { return cachedLens }
        func search(_ view: UIView) -> UIView? {
            for subview in view.subviews {
                if String(describing: type(of: subview)) == Self.lensClassName { return subview }
                if let found = search(subview) { return found }
            }
            return nil
        }
        cachedLens = search(self)
        return cachedLens
    }

    /// The lens' on-screen frame in this control's coordinates (presentation layers, so it follows the animation);
    /// the selected segment's frame if the lens can't be found.
    private func lensRect() -> CGRect {
        let selfLayer = layer.presentation() ?? layer
        if let lens = lensView() {
            let lensLayer = lens.layer.presentation() ?? lens.layer
            return selfLayer.convert(lensLayer.bounds, from: lensLayer)
        }
        let segments = segmentViews()
        guard segments.indices.contains(selectedSegmentIndex) else { return .zero }
        let segment = segments[selectedSegmentIndex]
        let segmentLayer = segment.layer.presentation() ?? segment.layer
        return selfLayer.convert(segmentLayer.bounds, from: segmentLayer)
    }

    // MARK: Accent masking (per frame while the lens moves)

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let proxy = LiquidTabDisplayLinkProxy(control: self)
        let link = CADisplayLink(target: proxy, selector: #selector(LiquidTabDisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLinkProxy = proxy
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
    }

    private func wakeDisplayLink() {
        stableFrames = 0
        displayLink?.isPaused = false
    }

    fileprivate func updateAccentMasks() {
        guard injected else { return }
        let rect = lensRect()
        if rect == lastLensRect {
            stableFrames += 1
            // Pause once the lens has rested for a few frames; any touch or layout wakes it again. A resize of the
            // capsule (the tab bar minimizing) is a layout, and its segments move with the lens, so the masks follow.
            if stableFrames >= 3 {
                displayLink?.isPaused = true
                return
            }
        } else {
            stableFrames = 0
            lastLensRect = rect
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (base, accent) in zip(baseGlyphs, accentGlyphs) {
            mask(base: base, accent: accent, lens: rect)
        }
        CATransaction.commit()
    }

    private func mask(base: TabGlyphView, accent: TabGlyphView, lens: CGRect) {
        let selfLayer = layer.presentation() ?? layer
        let accentLayer = accent.layer.presentation() ?? accent.layer
        let glyphRect = selfLayer.convert(accentLayer.bounds, from: accentLayer)
        let local = lens.offsetBy(dx: -glyphRect.minX, dy: -glyphRect.minY)
        let capsule = UIBezierPath(roundedRect: local, cornerRadius: lens.height / 2)

        let accentMask = accent.layer.mask as? CAShapeLayer ?? CAShapeLayer()
        accentMask.path = capsule.cgPath
        accent.layer.mask = accentMask

        if lens.intersects(glyphRect) {
            let baseMask = base.layer.mask as? CAShapeLayer ?? CAShapeLayer()
            let path = UIBezierPath(rect: base.bounds)
            path.append(capsule)
            baseMask.fillRule = .evenOdd
            baseMask.path = path.cgPath
            base.layer.mask = baseMask
        } else {
            base.layer.mask = nil
        }
    }

    // MARK: Touches

    private func segmentIndex(at point: CGPoint) -> Int {
        guard numberOfSegments > 0, bounds.width > 0 else { return 0 }
        let width = bounds.width / CGFloat(numberOfSegments)
        return min(max(Int(point.x / width), 0), numberOfSegments - 1)
    }

    /// At accessibility text sizes the control shows its large-content popover on touch; moving the selection on
    /// touch down would fight it.
    private var movesLensOnTouchDown: Bool {
        !traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }

    private func setLifted(_ lifted: Bool) {
        guard lifted != isLifted else { return }
        isLifted = lifted
        updateGlyphColors(animated: true)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        wakeDisplayLink()
        setLifted(true)
        if movesLensOnTouchDown, let touch = touches.first {
            originalIndex = selectedSegmentIndex
            selectedSegmentIndex = segmentIndex(at: touch.location(in: self))
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        wakeDisplayLink()
        if movesLensOnTouchDown, let touch = touches.first {
            let index = segmentIndex(at: touch.location(in: self))
            if index != selectedSegmentIndex { selectedSegmentIndex = index }
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        wakeDisplayLink()
        setLifted(false)
        if movesLensOnTouchDown, let originalIndex {
            if selectedSegmentIndex != originalIndex {
                sendActions(for: .valueChanged)
            } else {
                onReselect?(selectedSegmentIndex)
            }
        }
        originalIndex = nil
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        wakeDisplayLink()
        setLifted(false)
        if movesLensOnTouchDown, let originalIndex {
            selectedSegmentIndex = originalIndex
        }
        originalIndex = nil
        super.touchesCancelled(touches, with: event)
    }
}

/// Weak proxy so the display link doesn't retain the control.
private final class LiquidTabDisplayLinkProxy: NSObject {
    weak var control: LiquidLensSegmentedControl?

    init(control: LiquidLensSegmentedControl) {
        self.control = control
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let control else {
            link.invalidate()
            return
        }
        control.updateAccentMasks()
    }
}

// MARK: - Glyph

/// One segment glyph, drawn in `draw(_:)` in its tint colour:
/// - stacked: an SF Symbol over a 10 pt semibold label, or a larger symbol alone (compact / minimized);
/// - inline: a symbol beside a 14 pt bold label.
/// Its size is the largest of its forms, so hiding the label only redraws (no layout). It supports archiving because
/// the system's large-content popover archives segment content; an unarchived copy hides itself so the popover shows
/// the segment's own title.
@objc(PixlTabGlyphView)
final class TabGlyphView: UIView {
    private var symbolName = ""
    private var title = ""
    private var layout: LiquidGlyphLayout = .stacked
    var showsTitle = true {
        didSet { if showsTitle != oldValue { setNeedsDisplay() } }
    }

    private static let stackedTitleFont = UIFont.systemFont(ofSize: 10, weight: .semibold)
    private static let inlineTitleFont = UIFont.systemFont(ofSize: 14, weight: .bold)
    private static let iconAreaHeight: CGFloat = 28
    private static let inlineSpacing: CGFloat = 8

    init(symbolName: String, title: String, layout: LiquidGlyphLayout, showsTitle: Bool) {
        self.symbolName = symbolName
        self.title = title
        self.layout = layout
        self.showsTitle = showsTitle
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        symbolName = coder.decodeObject(forKey: "symbolName") as? String ?? ""
        title = coder.decodeObject(forKey: "title") as? String ?? ""
        showsTitle = coder.decodeBool(forKey: "showsTitle")
        super.init(coder: coder)
        isHidden = true
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(symbolName, forKey: "symbolName")
        coder.encode(title, forKey: "title")
        coder.encode(showsTitle, forKey: "showsTitle")
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        setNeedsDisplay()
    }

    private func icon(titled: Bool) -> UIImage? {
        let pointSize: CGFloat = switch layout {
        case .stacked: titled ? 18 : 21
        case .inline: 16
        }
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold,
                                                 scale: layout == .stacked ? .large : .medium)
        return UIImage(systemName: symbolName, withConfiguration: config)
    }

    private var titleFont: UIFont {
        layout == .stacked ? Self.stackedTitleFont : Self.inlineTitleFont
    }

    private var titleSize: CGSize {
        (title as NSString).size(withAttributes: [.font: titleFont])
    }

    override var intrinsicContentSize: CGSize {
        let titledIcon = icon(titled: true)?.size ?? .zero
        let bareIcon = icon(titled: false)?.size ?? .zero
        let text = titleSize
        switch layout {
        case .stacked:
            return CGSize(width: ceil(max(titledIcon.width, bareIcon.width, text.width)),
                          height: ceil(max(Self.iconAreaHeight + text.height, bareIcon.height)))
        case .inline:
            return CGSize(width: ceil(titledIcon.width + Self.inlineSpacing + text.width),
                          height: ceil(max(titledIcon.height, text.height)))
        }
    }

    override func draw(_ rect: CGRect) {
        let color = tintColor ?? .label
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: color]
        switch layout {
        case .stacked:
            if let icon = icon(titled: showsTitle) {
                let size = icon.size
                let iconRect: CGRect
                if showsTitle {
                    iconRect = CGRect(x: (bounds.width - size.width) / 2, y: (Self.iconAreaHeight - size.height) / 2 - 1,
                                      width: size.width, height: size.height)
                } else {
                    iconRect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                      width: size.width, height: size.height)
                }
                icon.withRenderingMode(.alwaysTemplate).withTintColor(color).draw(in: iconRect)
            }
            guard showsTitle else { return }
            let text = titleSize
            (title as NSString).draw(at: CGPoint(x: (bounds.width - text.width) / 2, y: Self.iconAreaHeight),
                                     withAttributes: attributes)
        case .inline:
            let text = titleSize
            let iconSize = icon(titled: true)?.size ?? .zero
            let contentWidth = showsTitle ? iconSize.width + Self.inlineSpacing + text.width : iconSize.width
            var x = (bounds.width - contentWidth) / 2
            if let icon = icon(titled: true) {
                icon.withRenderingMode(.alwaysTemplate).withTintColor(color)
                    .draw(in: CGRect(x: x, y: (bounds.height - iconSize.height) / 2,
                                     width: iconSize.width, height: iconSize.height))
                x += iconSize.width + Self.inlineSpacing
            }
            guard showsTitle else { return }
            (title as NSString).draw(at: CGPoint(x: x, y: (bounds.height - text.height) / 2), withAttributes: attributes)
        }
    }
}
