import PixlFoundation
import SwiftUI
import UIKit

// Expressive SF Pro: PixlAudio's weight × width type toolkit (Android plays Google Sans Flex's axes; SF Pro has a
// width axis — compressed … expanded — and nine weights, with optical sizes built in). Four pieces:
//
// - `FitWidthTitle`: hero titles (artist name, playlist title, the player's song title) keep their size and step
//   their width down from expanded until the text fits. Measured with UIKit once per text × width × Dynamic Type
//   size, never per frame and never through a second layout pass.
// - `expressiveEmphasis(_:_:)`: selection states (nav labels, chips) move weight and width together; the string
//   stays the same and `.contentTransition(.interpolate)` makes SwiftUI morph the variable font instead of
//   cross-fading two renders.
// - `CollapsingTitleState` + `trackingTitleCollapse(_:distance:)` + `FitWidthTitle(collapse:)`: a scroll-linked
//   collapsing title, wide and heavy at the top of the page, condensed when collapsed. Scrolling feeds a quantized
//   fraction to a few stops (`CollapseStops`, with hysteresis); only the title (and the bar title reading
//   `isCollapsed`) observes the stop, so the page never re-renders while it scrolls and the title itself only a
//   handful of times per collapse. Between stops the font morphs with `.interpolate`.
// - `pixlTimeFont(_:)` / `ExpressiveFace.monospacedDigits`: tabular digits for times and counters.
//
// The pure decisions (stop stepping, fit choice, collapse bands, quantized fractions) live in PixlFoundation
// (`ExpressiveType.swift`) and are unit-tested there.

// MARK: - Axes

extension TypeWidthStop {
    nonisolated var fontWidth: Font.Width {
        switch self {
        case .compressed: .compressed
        case .condensed: .condensed
        case .standard: .standard
        case .expanded: .expanded
        }
    }

    nonisolated var uiWidth: UIFont.Width {
        switch self {
        case .compressed: .compressed
        case .condensed: .condensed
        case .standard: .standard
        case .expanded: .expanded
        }
    }
}

extension TypeWeightStop {
    nonisolated var fontWeight: Font.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }

    nonisolated var uiWeight: UIFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }

    /// The stop of a SwiftUI weight (unknown weights read as regular).
    nonisolated init(_ weight: Font.Weight) {
        switch weight {
        case .ultraLight: self = .ultraLight
        case .thin: self = .thin
        case .light: self = .light
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .heavy: self = .heavy
        case .black: self = .black
        default: self = .regular
        }
    }
}

// MARK: - Face

/// One point on SF Pro's size × weight × width space. Weights are drawn as given: hero faces are chosen heavy on
/// purpose (`PixlWeightBoost` is for the Type.kt roles; `init(style:width:)` applies it to build a face from one).
nonisolated struct ExpressiveFace: Hashable, Sendable {
    var size: CGFloat
    var weight: TypeWeightStop
    var width: TypeWidthStop
    var tracking: CGFloat = 0
    /// Tabular (monospaced) digits, for times and counters.
    var monospacedDigits = false

    init(size: CGFloat, weight: TypeWeightStop, width: TypeWidthStop = .standard, tracking: CGFloat = 0,
         monospacedDigits: Bool = false) {
        self.size = size
        self.weight = weight
        self.width = width
        self.tracking = tracking
        self.monospacedDigits = monospacedDigits
    }

    /// A PixlAudio text style (boosted like `pixlFont`) at a width.
    init(style: PixlTextStyle, width: TypeWidthStop = .standard) {
        self.init(size: style.size, weight: TypeWeightStop(PixlWeightBoost.boosted(style.weight)), width: width,
                  tracking: style.tracking)
    }

    func with(width: TypeWidthStop) -> ExpressiveFace {
        var copy = self
        copy.width = width
        return copy
    }

    func with(weight: TypeWeightStop) -> ExpressiveFace {
        var copy = self
        copy.weight = weight
        return copy
    }

    /// The SwiftUI font at a Dynamic Type factor (`DynamicTypeScale.factor`).
    func font(scale: CGFloat = 1) -> Font {
        let font = Font.system(size: size * scale, weight: weight.fontWeight).width(width.fontWidth)
        return monospacedDigits ? font.monospacedDigit() : font
    }

    /// The matching UIKit font, for measuring only.
    func uiFont(scale: CGFloat = 1) -> UIFont {
        UIFont.systemFont(ofSize: size * scale, weight: weight.uiWeight, width: width.uiWidth)
    }

    /// `text` measured in this face: its single-line advance and its longest word's, rounded up.
    func measure(_ text: String, scale: CGFloat = 1) -> WidthFit.Measurement {
        let attributes: [NSAttributedString.Key: Any] = [.font: uiFont(scale: scale), .kern: tracking]
        func advance(_ string: String) -> Double {
            Double((string as NSString).size(withAttributes: attributes).width.rounded(.up))
        }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        let line = advance(text)
        let longestWord = words.count > 1 ? words.map { advance(String($0)) }.max() ?? line : line
        return WidthFit.Measurement(line: line, longestWord: longestWord)
    }

    // Hero faces (sizes from the approved mockups; weights one step past them, as SF Pro reads lighter than
    // PixlAudio's Google Sans). Their width is the widest stop tried; `FitWidthTitle` steps it down to fit.
    /// Artist name over the blurred artist image: very large, black, wide.
    static let artistHero = ExpressiveFace(size: 46, weight: .black, width: .expanded, tracking: -0.6)
    /// Playlist title over the blurred cover.
    static let playlistHero = ExpressiveFace(size: 34, weight: .heavy, width: .expanded, tracking: -0.2)
    /// Song title on the player.
    static let playerTitle = ExpressiveFace(size: 26, weight: .heavy, width: .expanded, tracking: -0.2)
    /// The title in a collapsed top bar: condensed, so long names keep more of themselves.
    static let collapsedBarTitle = ExpressiveFace(size: 17, weight: .bold, width: .condensed)
    /// Times on scrubbers and queue rows.
    static let time = ExpressiveFace(size: 12, weight: .bold, width: .standard, tracking: 0.4, monospacedDigits: true)
}

// MARK: - Motion

nonisolated enum ExpressiveMotion {
    /// Weight / width morphs: quick and barely bouncy, interruptible.
    static let morph = Animation.snappy(duration: 0.32, extraBounce: 0.06)
}

// MARK: - Emphasis

/// The rest and emphasized faces of a selectable label. Keep the size equal so only weight and width move.
nonisolated struct EmphasisFaces: Hashable, Sendable {
    var rest: ExpressiveFace
    var emphasized: ExpressiveFace

    /// Nav bar labels: the selected tab's label goes black and expanded inside its tonal capsule.
    static let navLabel = EmphasisFaces(rest: ExpressiveFace(size: 11, weight: .semibold, width: .standard),
                                        emphasized: ExpressiveFace(size: 11, weight: .black, width: .expanded))
    /// Filter chips / segmented pills.
    static let chip = EmphasisFaces(rest: ExpressiveFace(size: 14, weight: .semibold, width: .condensed),
                                    emphasized: ExpressiveFace(size: 14, weight: .heavy, width: .standard))
    /// Section tabs (Library categories).
    static let tab = EmphasisFaces(rest: ExpressiveFace(size: 15, weight: .medium, width: .standard),
                                   emphasized: ExpressiveFace(size: 15, weight: .heavy, width: .expanded))
}

private struct ExpressiveEmphasisModifier: ViewModifier {
    let isOn: Bool
    let faces: EmphasisFaces
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let face = isOn ? faces.emphasized : faces.rest
        content
            .font(face.font(scale: DynamicTypeScale.factor(dynamicTypeSize)))
            .tracking(face.tracking)
            .contentTransition(.interpolate)
            .animation(reduceMotion ? nil : ExpressiveMotion.morph, value: isOn)
    }
}

extension View {
    /// Draws text in `faces.rest`, or `faces.emphasized` while `isOn`, morphing the variable font between them
    /// (weight and width together) instead of cross-fading. Apply it to a `Text` whose string doesn't change with
    /// `isOn`. The label's own width changes; toggle `isOn` inside `withAnimation` so the container (a nav capsule)
    /// moves with it.
    func expressiveEmphasis(_ isOn: Bool, _ faces: EmphasisFaces = .navLabel) -> some View {
        modifier(ExpressiveEmphasisModifier(isOn: isOn, faces: faces))
    }

    /// A PixlAudio text style with tabular digits, for times and counters that tick in place.
    func pixlTimeFont(_ style: PixlTextStyle) -> some View {
        pixlFont(style).monospacedDigit()
    }
}

// MARK: - Scroll-linked collapse

/// The typographic stop of a collapsing title, fed by `trackingTitleCollapse`. Only views that read `stop` (the
/// hero title) or `isCollapsed` (the bar title) re-render, and only when it changes: a few times per collapse.
@Observable
final class CollapsingTitleState {
    /// 0 (open) … `stopCount - 1` (collapsed).
    private(set) var stop = 0
    /// True on the last stop: the top bar shows its own condensed title.
    private(set) var isCollapsed = false
    @ObservationIgnored private var stops: CollapseStops

    var stopCount: Int { stops.count }

    init(stops: Int = 3) {
        self.stops = CollapseStops(count: stops)
    }

    /// Feeds a collapse fraction (0 open … 1 collapsed).
    func update(fraction: Double) {
        guard let next = stops.update(fraction: fraction) else { return }
        stop = next
        let collapsed = next == stops.count - 1
        if collapsed != isCollapsed { isCollapsed = collapsed }
    }
}

extension View {
    /// Feeds a `CollapsingTitleState` from this scroll view: the title collapses across `distance` points of scroll
    /// starting at `start`. The transform returns a fraction quantized to 1 %, so the action runs only on visible
    /// changes, and the state publishes only when the stop changes.
    func trackingTitleCollapse(_ state: CollapsingTitleState, start: CGFloat = 0, distance: CGFloat) -> some View {
        onScrollGeometryChange(for: Double.self) { geometry in
            ScrollCollapse.fraction(offset: Double(geometry.contentOffset.y + geometry.contentInsets.top),
                                    start: Double(start), distance: Double(distance))
        } action: { _, fraction in
            state.update(fraction: fraction)
        }
    }
}

/// How a collapsing title changes per stop: each stop is `widthSteps` narrower and `weightSteps` lighter than the
/// last (clamped to the fit range's narrowest width and `lightest`). Size stays: the page doesn't re-lay out.
nonisolated struct CollapseRamp: Hashable, Sendable {
    var widthSteps = 1
    var weightSteps = 1
    var lightest: TypeWeightStop = .bold

    /// Wide and heavy at the top → narrower and lighter as it scrolls away.
    static let display = CollapseRamp()

    func face(stop: Int, from base: ExpressiveFace, narrowest: TypeWidthStop) -> ExpressiveFace {
        guard stop > 0 else { return base }
        var face = base
        face.width = base.width.narrowed(by: widthSteps * stop, within: min(narrowest, base.width) ... base.width)
        face.weight = base.weight.lightened(by: weightSteps * stop, within: min(lightest, base.weight) ... base.weight)
        return face
    }
}

// MARK: - Fit-by-width title

/// A hero title that keeps its size and takes the widest SF Pro width (from `face.width` down to `narrowest`) at
/// which it fits `lines` lines without breaking a word; the narrowest stop truncates if nothing fits.
///
/// With `collapse`, it also follows a scroll-linked collapse: each stop morphs it narrower and lighter
/// (`CollapseRamp`), interpolating the variable font. The resting face reserves the layout, so the page never
/// re-lays out while the title morphs.
struct FitWidthTitle: View {
    let text: String
    var face: ExpressiveFace = .playlistHero
    var narrowest: TypeWidthStop = .compressed
    var lines = 2
    var alignment: TextAlignment = .leading
    var collapse: CollapsingTitleState?
    var ramp: CollapseRamp = .display

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var availableWidth: CGFloat = 0
    @State private var fitted: Fitted?

    /// The resolved width for one set of inputs (re-measured only when they change).
    nonisolated private struct Fitted: Equatable {
        var key: FitKey
        var width: TypeWidthStop
    }

    nonisolated private struct FitKey: Hashable {
        var text: String
        var face: ExpressiveFace
        var narrowest: TypeWidthStop
        var lines: Int
        var scale: CGFloat
        var available: CGFloat
    }

    var body: some View {
        let scale = DynamicTypeScale.factor(dynamicTypeSize)
        let resting = face.with(width: fitted?.width ?? face.width)
        Group {
            if let collapse {
                titleText(resting, scale: scale)
                    .hidden()
                    .overlay(alignment: overlayAlignment) {
                        CollapsingTitleText(text: text, resting: resting, narrowest: narrowest, lines: lines,
                                            alignment: alignment, ramp: ramp, scale: scale, state: collapse,
                                            animated: !reduceMotion)
                    }
            } else {
                titleText(resting, scale: scale)
            }
        }
        // Hidden until the first fit, so a long name never flashes at the widest width.
        .opacity(fitted == nil ? 0 : 1)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width in
            availableWidth = width
            refit(available: width, scale: scale)
        }
        .onChange(of: InputKey(text: text, face: face, narrowest: narrowest, lines: lines, scale: scale)) { _, _ in
            refit(available: availableWidth, scale: scale)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
    }

    nonisolated private struct InputKey: Hashable {
        var text: String
        var face: ExpressiveFace
        var narrowest: TypeWidthStop
        var lines: Int
        var scale: CGFloat
    }

    private func titleText(_ face: ExpressiveFace, scale: CGFloat) -> some View {
        Text(text)
            .font(face.font(scale: scale))
            .tracking(face.tracking)
            .lineLimit(lines)
            .multilineTextAlignment(alignment)
            .truncationMode(.tail)
    }

    private func refit(available: CGFloat, scale: CGFloat) {
        guard available > 0 else { return }
        let key = FitKey(text: text, face: face, narrowest: narrowest, lines: lines, scale: scale, available: available)
        guard fitted?.key != key else { return }
        let range = min(narrowest, face.width) ... face.width
        let width = WidthFit.widestFitting(available: Double(available), lines: lines, range: range) { stop in
            face.with(width: stop).measure(text, scale: scale)
        }
        fitted = Fitted(key: key, width: width)
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }

    private var overlayAlignment: Alignment {
        switch alignment {
        case .center: .bottom
        case .trailing: .bottomTrailing
        default: .bottomLeading
        }
    }
}

/// The morphing layer of a collapsing `FitWidthTitle`. It alone reads the collapse stop.
private struct CollapsingTitleText: View {
    let text: String
    let resting: ExpressiveFace
    let narrowest: TypeWidthStop
    let lines: Int
    let alignment: TextAlignment
    let ramp: CollapseRamp
    let scale: CGFloat
    let state: CollapsingTitleState
    let animated: Bool

    var body: some View {
        let stop = state.stop
        let face = ramp.face(stop: stop, from: resting, narrowest: narrowest)
        Text(text)
            .font(face.font(scale: scale))
            .tracking(face.tracking)
            .lineLimit(lines)
            .multilineTextAlignment(alignment)
            .truncationMode(.tail)
            .contentTransition(.interpolate)
            .animation(animated ? ExpressiveMotion.morph : nil, value: stop)
    }
}

/// The condensed title of a collapsed top bar: it fades and rises in on the last collapse stop. Reads only
/// `isCollapsed`.
struct CollapsedBarTitle: View {
    let text: String
    let state: CollapsingTitleState
    var face: ExpressiveFace = .collapsedBarTitle

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = state.isCollapsed
        Text(text)
            .font(face.font(scale: DynamicTypeScale.factor(dynamicTypeSize)))
            .tracking(face.tracking)
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 6)
            .animation(reduceMotion ? nil : ExpressiveMotion.morph, value: shown)
            .accessibilityHidden(!shown)
    }
}
