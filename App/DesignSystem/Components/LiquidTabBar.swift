import SwiftUI
import UIKit

// The bottom tab bar's UIKit core. On iOS 26 and later the system's "liquid lens" selection is offered by just two
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

/// PixlAudio's tab bar as a SwiftUI view: Home, Search, Library on the system liquid lens.
struct LiquidTabBar: UIViewRepresentable {
    let selection: RootTab
    let compact: Bool
    /// Tint of the resting selection pill (the accent).
    let pillColor: UIColor
    /// Glyph colour on the resting pill (`onPrimary`).
    let restingGlyphColor: UIColor
    /// Glyph colour under the lifted, clear lens (the accent, as on the system tab bar).
    let liftedGlyphColor: UIColor
    let onSelect: (RootTab) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIView(context: Context) -> LiquidTabBarView {
        let view = LiquidTabBarView(tabs: RootTab.allCases, compact: compact)
        let coordinator = context.coordinator
        view.control.addTarget(coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        view.control.onReselect = { [weak coordinator] index in coordinator?.reselect(index: index) }
        apply(to: view, coordinator: coordinator)
        return view
    }

    func updateUIView(_ view: LiquidTabBarView, context: Context) {
        context.coordinator.onSelect = onSelect
        apply(to: view, coordinator: context.coordinator)
    }

    private func apply(to view: LiquidTabBarView, coordinator: Coordinator) {
        let control = view.control
        control.setCompact(compact)
        control.pillColor = pillColor
        control.restingGlyphColor = restingGlyphColor
        control.liftedGlyphColor = liftedGlyphColor
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

/// The capsule of interactive glass holding the segmented control.
final class LiquidTabBarView: UIView {
    let glassView: UIVisualEffectView // holds a UIGlassEffect (real Liquid Glass)
    let control: LiquidTabSegmentedControl

    init(tabs: [RootTab], compact: Bool) {
        let glass = UIGlassEffect()
        glass.isInteractive = true
        glassView = UIVisualEffectView(effect: glass) // UIGlassEffect, interactive
        control = LiquidTabSegmentedControl(items: tabs.map(\.title))
        super.init(frame: .zero)
        control.configure(tabs: tabs, compact: compact)
        backgroundColor = .clear

        addSubview(glassView)
        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView.addSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        let padding = Tokens.Shell.navGlassPadding
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    override func layoutSubviews() {
        super.layoutSubviews()
        glassView.cornerConfiguration = .capsule()
    }
}

/// A UISegmentedControl working as the tab bar: PixlAudio's glyphs inside the segments, the lens moving on touch
/// down, the selection changing on touch up, and a re-tap reported separately.
final class LiquidTabSegmentedControl: UISegmentedControl {
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

    private var tabs: [RootTab] = []
    private var compact = false
    /// Outline glyphs in the label colour, cut out where the lens is.
    private var baseGlyphs: [TabGlyphView] = []
    /// Filled glyphs in the selection colour, shown only inside the lens.
    private var accentGlyphs: [TabGlyphView] = []
    private var injected = false
    /// A finger is down: the lens is lifted (clear glass), so glyphs under it take the accent colour.
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

    override init(items: [Any]?) {
        super.init(items: items)
        accessibilityTraits = .tabBar
        showsLargeContentViewer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(tabs: [RootTab], compact: Bool) {
        self.tabs = tabs
        self.compact = compact
        rebuildGlyphs()
    }

    func setCompact(_ compact: Bool) {
        guard compact != self.compact else { return }
        self.compact = compact
        rebuildGlyphs()
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

    private func rebuildGlyphs() {
        for segment in segmentViews() {
            segment.viewWithTag(Self.baseTag)?.removeFromSuperview()
            segment.viewWithTag(Self.accentTag)?.removeFromSuperview()
        }
        baseGlyphs = tabs.map { TabGlyphView(symbolName: $0.systemImage, title: $0.title, showsTitle: !compact) }
        accentGlyphs = tabs.map { TabGlyphView(symbolName: $0.selectedSystemImage, title: $0.title, showsTitle: !compact) }
        injected = false
        cachedLens = nil
        updateGlyphColors(animated: false)
        setNeedsLayout()
    }

    private func injectGlyphsIfNeeded() {
        let segments = segmentViews()
        guard !tabs.isEmpty, segments.count == tabs.count else { return }
        for (index, segment) in segments.enumerated() {
            segment.accessibilityIdentifier = "navBar.\(tabs[index].rawValue)"
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
        for glyph in baseGlyphs { glyph.tintColor = .label }
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
        return segments[selectedSegmentIndex].frame
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
            // Pause once the lens has rested for a few frames; any touch or layout wakes it again.
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
    weak var control: LiquidTabSegmentedControl?

    init(control: LiquidTabSegmentedControl) {
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

/// One tab glyph — SF Symbol over a 10 pt semibold label (symbol only in compact mode) — drawn in `draw(_:)` in its
/// tint colour. It supports archiving because the system's large-content popover archives segment content; an
/// unarchived copy hides itself so the popover shows the segment's own title.
@objc(PixlTabGlyphView)
final class TabGlyphView: UIView {
    private var symbolName = ""
    private var title = ""
    private var showsTitle = true

    private static let titleFont = UIFont.systemFont(ofSize: 10, weight: .semibold)
    private static let iconAreaHeight: CGFloat = 28

    init(symbolName: String, title: String, showsTitle: Bool) {
        self.symbolName = symbolName
        self.title = title
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

    private var icon: UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: showsTitle ? 18 : 21, weight: .semibold, scale: .large)
        return UIImage(systemName: symbolName, withConfiguration: config)
    }

    override var intrinsicContentSize: CGSize {
        let iconSize = icon?.size ?? .zero
        guard showsTitle else { return iconSize }
        let textSize = (title as NSString).size(withAttributes: [.font: Self.titleFont])
        return CGSize(width: ceil(max(iconSize.width, textSize.width)), height: ceil(Self.iconAreaHeight + textSize.height))
    }

    override func draw(_ rect: CGRect) {
        let color = tintColor ?? .label
        if let icon {
            let iconSize = icon.size
            let areaHeight = showsTitle ? Self.iconAreaHeight : bounds.height
            let iconRect = CGRect(x: (bounds.width - iconSize.width) / 2,
                                  y: (areaHeight - iconSize.height) / 2 - (showsTitle ? 1 : 0),
                                  width: iconSize.width, height: iconSize.height)
            color.setFill()
            icon.withRenderingMode(.alwaysTemplate).withTintColor(color).draw(in: iconRect)
        }
        guard showsTitle else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.titleFont, .foregroundColor: color]
        let textSize = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: CGPoint(x: (bounds.width - textSize.width) / 2, y: Self.iconAreaHeight),
                                 withAttributes: attributes)
    }
}
