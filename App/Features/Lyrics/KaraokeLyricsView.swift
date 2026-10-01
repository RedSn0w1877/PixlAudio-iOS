import PixlLyrics
import SwiftUI

/// Everything a row needs to lay out and draw that changes rarely (appearance, width), shared by every row.
struct KaraokeRowStyle: Equatable {
    let metrics: LyricsRenderMetrics
    let width: CGFloat
    let inactiveAlpha: Float

    var em: CGFloat { CGFloat(metrics.emPx) }

    func font(role: PreparedVoiceRole) -> Font {
        .system(size: CGFloat(metrics.fontSize(role: role)), weight: PixlWeightBoost.boosted(.bold))
    }

    func secondaryFont(size: Float) -> Font {
        .system(size: CGFloat(size), weight: PixlWeightBoost.boosted(.semibold))
    }

    /// SwiftUI adds line spacing between lines; Compose's line height (1.2059 em) is the whole line box.
    func lineSpacing(fontSize: Float) -> CGFloat {
        max(0, CGFloat(fontSize) * CGFloat(LyricsRenderMetrics.lineHeightEm - 1.19))
    }

    func textAlignment(role: PreparedVoiceRole) -> TextAlignment {
        switch metrics.textAlign(role: role) {
        case .start: .leading
        case .center: .center
        case .end: .trailing
        }
    }

    func frameAlignment(role: PreparedVoiceRole) -> Alignment {
        switch metrics.textAlign(role: role) {
        case .start: .leading
        case .center: .center
        case .end: .trailing
        }
    }

    func stackAlignment(role: PreparedVoiceRole) -> HorizontalAlignment {
        switch metrics.textAlign(role: role) {
        case .start: .leading
        case .center: .center
        case .end: .trailing
        }
    }
}

/// One visual row of the karaoke list.
enum KaraokeRowItem {
    case line(PreparedLine, text: Text, table: KaraokePieceTable?)
    case interlude(g0: Int64, g1: Int64, alignEnd: Bool)
}

/// The rows of one prepared song, with their state objects (rebuilt only when the lyrics change).
struct KaraokeModel {
    let prepared: PreparedLyrics
    let items: [KaraokeRowItem]
    let states: [LyricRowState]

    init(prepared: PreparedLyrics, states: [LyricRowState]) {
        self.prepared = prepared
        self.states = states
        items = prepared.rows.map { row in
            switch row {
            case .line(let index):
                let line = prepared.lines[index]
                guard line.hasWordTiming else { return .line(line, text: Text(verbatim: line.text), table: nil) }
                let table = KaraokePieceTable(line: line)
                var text = Text(verbatim: "")
                for segment in table.segments {
                    let piece = segment.piece >= 0
                        ? Text(verbatim: segment.text).customAttribute(KaraokePieceAttribute(piece: segment.piece))
                        : Text(verbatim: segment.text)
                    text = Text("\(text)\(piece)")
                }
                return .line(line, text: text, table: table)
            case .interlude(let startMs, let endMs, let alignEnd):
                return .interlude(g0: startMs, g1: endMs, alignEnd: alignEnd)
            }
        }
    }
}

/// The karaoke lyrics (Android `KaraokeLyricsView`, spec §1, §3.4, §4, §5): every row in one stack, placed by the
/// engine's per-row springs (no scroll view), the whole layer composited with plus-lighter (normal blending over
/// bright art or with increased contrast) and masked by the edge fade.
struct KaraokeLyricsView: View {
    let prepared: PreparedLyrics
    let songKey: String?
    let driver: LyricsDriver
    let appearance: KaraokeLyricsAppearance
    let reducedMotion: Bool
    /// Height of the chrome over the top (status bar + header); lines are hidden above it and fade in below.
    let topInset: CGFloat
    let topFadeLength: CGFloat
    /// Height of the chrome over the bottom (the control cluster × its visibility); may animate.
    let bottomInset: CGFloat
    let bottomFadeLength: CGFloat
    /// "Lyrics: <source>" under the last line for online lyrics.
    let footer: String?
    let onSeekLine: (PreparedLine) -> Void
    let onInteraction: () -> Void

    @State private var model: KaraokeModel?
    @State private var shownSongKey: String?
    @State private var hasShown = false
    @State private var size: CGSize = .zero
    @State private var pressedRow = -1
    @State private var tracker = KaraokeGestureTracker()

    private var metrics: LyricsRenderMetrics {
        appearance.metrics(hasDuet: prepared.hasDuet, reducedMotion: reducedMotion)
    }

    var body: some View {
        let style = KaraokeRowStyle(metrics: metrics, width: size.width, inactiveAlpha: appearance.inactiveAlpha)
        ZStack(alignment: .topLeading) {
            if let model, size.width > 0 {
                ForEach(0..<model.items.count, id: \.self) { r in
                    KaraokeRowContainer(index: r, item: model.items[r], row: model.states[r], clock: driver.hotClock,
                                        style: style, pressed: pressedRow == r, driver: driver,
                                        onActivate: { activate(row: r) })
                }
                if let footer, let last = model.states.last {
                    KaraokeFooter(text: footer, row: last, height: CGFloat(max(driver.engine.rowHeightValue(model.states.count - 1), 0)))
                }
            }
        }
        .modifier(KaraokeScrollOffset(scroll: driver.scroll))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mask {
            KaraokeEdgeFadeMask(fade: LyricsEdgeFade(topInset: Float(topInset), topFadeLength: Float(topFadeLength),
                                                     bottomFadeLength: Float(bottomFadeLength)),
                                bottomInset: bottomInset)
        }
        .compositingGroup()
        .blendMode(appearance.usesAdditiveBlend ? .plusLighter : .normal)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .accessibilityElement(children: .contain)
        .accessibilityScrollAction { edge in
            let step = max(size.height * 0.4, 100)
            switch edge {
            case .top: driver.scrollBy(step)
            case .bottom: driver.scrollBy(-step)
            default: break
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
            size = newSize
            updateViewport()
        }
        .onChange(of: prepared, initial: true) { _, newValue in install(newValue) }
        .onChange(of: topInset) { updateViewport() }
        .onChange(of: appearance, initial: true) { _, newValue in
            driver.setConfig(newValue.engineConfig(reducedMotion: reducedMotion))
        }
    }

    // MARK: Model

    private func install(_ prepared: PreparedLyrics) {
        let songChanged = !hasShown || shownSongKey != songKey
        hasShown = true
        shownSongKey = songKey
        driver.setLyrics(prepared, animateIn: songChanged)
        model = KaraokeModel(prepared: prepared, states: driver.rows)
        pressedRow = -1
        updateViewport()
    }

    private func updateViewport() {
        guard size.height > 0 else { return }
        let anchor = metrics.anchor(viewportHeight: Float(size.height), topInset: Float(topInset),
                                    topFadeLength: Float(topFadeLength))
        driver.setViewport(height: size.height, anchor: CGFloat(anchor))
    }

    // MARK: Interaction

    private func activate(row r: Int) {
        guard let model, case .line(let line, _, _) = model.items[r] else { return }
        driver.lineTapped(line.index)
        onSeekLine(line)
    }

    private func tappableRow(at y: CGFloat) -> Int {
        let fade = LyricsEdgeFade(topInset: Float(topInset))
        if fade.isUnderChrome(y: Float(y), height: Float(size.height), bottomInset: Float(bottomInset)) { return -1 }
        let row = driver.engine.hitRow(y: Float(y))
        guard row >= 0, let model, row < model.items.count, case .line = model.items[row] else { return -1 }
        return row
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let slop = KaraokeGestureTracker.touchSlop
                switch tracker.phase {
                case .idle:
                    tracker.phase = .pending
                    tracker.startTime = value.time
                    tracker.lastY = 0
                    tracker.row = tappableRow(at: value.startLocation.y)
                    pressedRow = tracker.row
                    onInteraction()
                case .pending:
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if abs(dy) > slop && abs(dy) >= abs(dx) {
                        tracker.phase = .dragging
                        pressedRow = -1
                        driver.dragStart()
                        let over = dy - (dy > 0 ? slop : -slop)
                        driver.drag(over)
                        tracker.lastY = dy
                    } else if abs(dx) > slop {
                        // A horizontal swipe belongs to the screen (previous / next song).
                        tracker.phase = .ignored
                        pressedRow = -1
                    }
                case .dragging:
                    let dy = value.translation.height
                    driver.drag(dy - tracker.lastY)
                    tracker.lastY = dy
                case .ignored:
                    break
                }
            }
            .onEnded { value in
                switch tracker.phase {
                case .dragging:
                    driver.dragEnd(velocity: value.velocity.height)
                case .pending:
                    let elapsed = value.time.timeIntervalSince(tracker.startTime)
                    if tracker.row >= 0 && elapsed < 0.5 { activate(row: tracker.row) }
                case .idle, .ignored:
                    break
                }
                tracker.phase = .idle
                tracker.row = -1
                pressedRow = -1
            }
    }
}

/// Gesture bookkeeping (a reference, so updating it never re-renders the view).
final class KaraokeGestureTracker {
    enum Phase { case idle, pending, dragging, ignored }
    /// Android `viewConfiguration.touchSlop` (8 dp).
    static let touchSlop: CGFloat = 8
    var phase: Phase = .idle
    var startTime = Date()
    var lastY: CGFloat = 0
    var row = -1
}

/// Applies the user scroll offset; only this modifier observes it, so a drag re-renders no row.
private struct KaraokeScrollOffset: ViewModifier {
    let scroll: LyricsScrollState

    func body(content: Content) -> some View {
        content.offset(y: scroll.offset)
    }
}

/// The edge fade (§1.1) as a mask: cleared above the top inset, fading in over `topFadeLength`, fading out over
/// `bottomFadeLength` above the bottom chrome and cleared below it.
private struct KaraokeEdgeFadeMask: View, Animatable {
    let fade: LyricsEdgeFade
    /// Animates with the control cluster (the mask follows it as it slides away).
    var bottomInset: CGFloat

    var animatableData: CGFloat {
        get { bottomInset }
        set { bottomInset = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let h = max(geometry.size.height, 1)
            let r = fade.resolve(height: Float(h), bottomInset: Float(bottomInset))
            let l0 = clamp(CGFloat(r.topClearEnd) / h)
            let l1 = max(l0, clamp(CGFloat(r.topFadeEnd) / h))
            let l2 = max(l1, clamp(CGFloat(r.bottomFadeStart) / h))
            let l3 = max(l2, clamp(CGFloat(r.bottomEdge) / h))
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: l0),
                                   .init(color: .black, location: l1), .init(color: .black, location: l2),
                                   .init(color: .clear, location: l3), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
}

/// One row: the row content placed and transformed by its engine state.
private struct KaraokeRowContainer: View {
    let index: Int
    let item: KaraokeRowItem
    let row: LyricRowState
    let clock: LyricsHotClock
    let style: KaraokeRowStyle
    let pressed: Bool
    let driver: LyricsDriver
    let onActivate: () -> Void

    var body: some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                driver.setRowHeight(index, height)
            }
            .scaleEffect(row.scale, anchor: UnitPoint(x: pivotX, y: 0.5))
            .blur(radius: row.blur)
            .opacity(row.culled ? 0 : Double(row.alpha))
            .offset(y: min(row.y, 100_000))
    }

    @ViewBuilder private var content: some View {
        switch item {
        case .line(let line, let text, let table):
            KaraokeLineRow(line: line, text: text, table: table, row: row, clock: clock, style: style, pressed: pressed)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: line.text))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text("Play from here"), onActivate)
                .accessibilityAction(onActivate)
        case .interlude(let g0, let g1, let alignEnd):
            InterludeDotsRow(g0: g0, g1: g1, alignEnd: alignEnd, row: row, clock: clock, style: style)
                .accessibilityHidden(true)
        }
    }

    private var pivotX: CGFloat {
        switch item {
        case .line(let line, _, _): CGFloat(style.metrics.pivotX(line))
        case .interlude(_, _, let alignEnd): CGFloat(LyricsRenderMetrics.interludePivotX(alignEnd: alignEnd))
        }
    }
}

/// A lyric line: the main text (word fill via `KaraokeTextRenderer`), then romanisation and translation.
private struct KaraokeLineRow: View {
    let line: PreparedLine
    let text: Text
    let table: KaraokePieceTable?
    let row: LyricRowState
    let clock: LyricsHotClock
    let style: KaraokeRowStyle
    let pressed: Bool

    var body: some View {
        let metrics = style.metrics
        let role = line.role
        let width = Float(style.width)
        let a = row.activeness
        let hot = row.hot
        let alphas = LyricLineAlphas.resolve(activeness: a, role: role, highContrast: metrics.highContrast,
                                             inactive: style.inactiveAlpha)
        let animate = LyricLineAlphas.animatesWords(hasWordTiming: line.hasWordTiming, hot: hot, activeness: a)
        // Only a hot line subscribes to the per-frame clock; a fading one samples it unobserved.
        let t: Int64 = animate ? (hot ? clock.nowMs : clock.peekMs) : 0
        let fontSize = metrics.fontSize(role: role)
        let em = CGFloat(fontSize)
        let isBackground = role == .background
        let padV = CGFloat(isBackground ? metrics.padVerticalPx * 0.5 : metrics.padVerticalPx)
        let roman = metrics.showRomanization ? nonBlank(line.romanization) : nil
        let translation = metrics.showTranslation ? nonBlank(line.translation) : nil
        let renderer = KaraokeTextRenderer(
            table: table, timeMs: t, activeness: a, animateWords: animate,
            wholeAlpha: Double(alphas.wholeLine(hasWordTiming: line.hasWordTiming)),
            sung: Double(alphas.sung), unsung: Double(alphas.unsung), em: em,
            fade: CGFloat(EmphasisMath.fadeWidthPx(lineHeightPx: fontSize * LyricsRenderMetrics.lineHeightEm)),
            background: isBackground, reducedMotion: metrics.reducedMotion, highContrast: metrics.highContrast)

        VStack(alignment: style.stackAlignment(role: role), spacing: CGFloat(metrics.extraGapPx)) {
            text
                .font(style.font(role: role))
                .tracking(em * CGFloat(LyricsRenderMetrics.letterSpacingEm))
                .lineSpacing(style.lineSpacing(fontSize: fontSize))
                .multilineTextAlignment(style.textAlignment(role: role))
                .foregroundStyle(.white)
                .textRenderer(renderer)
                .fixedSize(horizontal: false, vertical: true)
            if let roman {
                Text(verbatim: roman)
                    .font(style.secondaryFont(size: metrics.romanizationEmPx))
                    .multilineTextAlignment(style.textAlignment(role: role))
                    .foregroundStyle(.white.opacity(Double(alphas.unsung)))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let translation {
                Text(verbatim: translation)
                    .font(style.secondaryFont(size: metrics.translationEmPx))
                    .multilineTextAlignment(style.textAlignment(role: role))
                    .foregroundStyle(.white.opacity(Double(alphas.translation)))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background {
            if pressed {
                RoundedRectangle(cornerRadius: style.em * CGFloat(LyricsRenderMetrics.pressRadiusEm), style: .continuous)
                    .fill(.white.opacity(Double(KaraokeAlpha.pressHighlight)))
                    .padding(.horizontal, -style.em * CGFloat(LyricsRenderMetrics.pressInsetHEm))
                    .padding(.vertical, -style.em * CGFloat(LyricsRenderMetrics.pressInsetVEm))
            }
        }
        .frame(width: CGFloat(metrics.contentWidth(role: role, width: width)), alignment: style.frameAlignment(role: role))
        .padding(.leading, CGFloat(metrics.startPadding(role: role, width: width)))
        .padding(.vertical, padV)
        .frame(width: style.width, alignment: .leading)
    }

    private func nonBlank(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

/// Interlude dots (spec §1.6): three dots that expand, fill one by one, breathe, pulse and collapse.
private struct InterludeDotsRow: View {
    let g0: Int64
    let g1: Int64
    let alignEnd: Bool
    let row: LyricRowState
    let clock: LyricsHotClock
    let style: KaraokeRowStyle

    var body: some View {
        let height = CGFloat(InterludeDotsGeometry.rowHeight(emPx: style.metrics.emPx))
        let t: Int64? = row.hot ? clock.nowMs : nil
        let metrics = style.metrics
        let g0 = g0, g1 = g1, alignEnd = alignEnd
        Canvas { context, size in
            guard let t else { return }
            let presence = InterludeTimeline.presence(tMs: t, g0: g0, g1: g1)
            guard InterludeDotsGeometry.isVisible(presence: presence) else { return }
            let geometry = InterludeDotsGeometry.compute(metrics: metrics, width: Float(size.width),
                                                         rowHeight: Float(size.height), presence: presence,
                                                         alignEnd: alignEnd)
            let scale = CGFloat(InterludeTimeline.scale(tMs: t, g0: g0, g1: g1))
            let pivot = CGPoint(x: CGFloat(geometry.pivotX), y: CGFloat(geometry.pivotY))
            context.translateBy(x: pivot.x, y: pivot.y)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -pivot.x, y: -pivot.y)
            let r = CGFloat(geometry.dotDiameter) / 2
            for k in 0..<InterludeTimeline.dotCount {
                let alpha = InterludeDotsGeometry.dotAlpha(tMs: t, g0: g0, g1: g1, k: k)
                let cx = CGFloat(geometry.centersX[k])
                let rect = CGRect(x: cx - r, y: CGFloat(geometry.centerY) - r, width: 2 * r, height: 2 * r)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(Double(alpha))))
            }
        }
        .frame(width: style.width, height: height)
    }
}

/// The lyrics source under the last line ("Lyrics: LRCLIB"), placed right after it.
private struct KaraokeFooter: View {
    let text: String
    let row: LyricRowState
    let height: CGFloat

    var body: some View {
        Text(verbatim: text)
            .pixlFont(.labelMedium)
            .foregroundStyle(.white.opacity(0.5))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .opacity(row.culled && row.y > 100_000 ? 0 : 1)
            .offset(y: min(row.y + height, 100_000))
    }
}
