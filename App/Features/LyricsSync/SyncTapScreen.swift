import PixlFoundation
import PixlLyrics
import SwiftUI
import UIKit

/// The tap screen (Android `SyncTapScreen`, spec §2.5): context lines on top, the next word big, one huge pad, and
/// Undo · Play/Pause · Back 5 s. It re-renders when the draft (a tap), the phase or the play state changes; the
/// music-break ring reads the position only while it is on screen.
struct SyncTapScreen: View {
    let session: LyricsSyncSession
    let palette: SyncEditorPalette

    static let holdTipTaps = 20

    var body: some View {
        if let draft = session.draft {
            content(draft: draft, view: SyncTapModel.make(draft: draft, fixLine: session.fixLine))
        }
    }

    private func content(draft: SyncDraft, view: SyncTapModel) -> some View {
        let inFixLine = session.fixLine != nil
        let finished = !inFixLine && draft.isFinished
        let label: String = if finished {
            SyncStrings.seeResult
        } else if !session.isPlaying && !session.started {
            SyncStrings.startSong
        } else if !session.isPlaying {
            SyncStrings.paused
        } else {
            SyncStrings.tapHint
        }
        let showTip = !finished && session.isPlaying && session.sessionTaps < Self.holdTipTaps
        return SyncWeightedColumn {
            SyncTopBar(title: session.title, palette: palette, onClose: session.requestClose, speed: session.speed,
                       onSpeedChange: session.setSpeed)
            SyncProgressRow(lineNumber: view.lineNumber, lineCount: view.lineCount, fraction: view.progress, palette: palette)
                .padding(.top, 4)
            Group {
                if let breakInfo = view.musicBreak, session.isPlaying || session.frozenPositionMs != nil {
                    SyncMusicBreakOrContext(breakInfo: breakInfo, session: session, palette: palette) {
                        SyncLyricContext(draft: draft, view: view, palette: palette, allowJump: !inFixLine,
                                         onJump: session.jumpToLine)
                    }
                } else {
                    SyncLyricContext(draft: draft, view: view, palette: palette, allowJump: !inFixLine,
                                     onJump: session.jumpToLine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.top, 8)
            .syncLayoutWeight(1)
            if !inFixLine && view.canSkip && !finished {
                Button(action: session.skipLine) {
                    Text(SyncStrings.skipLine)
                        .pixlFont(.custom(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .contentShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .transition(.opacity)
            }
            SyncNextWordLabel(word: finished ? nil : view.nextWord)
                .padding(.top, 8)
                .padding(.bottom, 12)
            SyncTapPad(label: label, tip: showTip ? SyncStrings.holdTip : nil, session: session, palette: palette)
                .syncLayoutWeight(1.25, minHeight: 200)
            Color.clear.frame(height: 12)
            HStack(spacing: 10) {
                EditorStackedButton(systemImage: "arrow.uturn.backward", label: SyncStrings.undo, palette: palette,
                                    enabled: view.canUndo, action: session.undo)
                    .accessibilityIdentifier("sync.undo")
                EditorStackedButton(systemImage: session.isPlaying ? "pause.fill" : "play.fill",
                                    label: session.isPlaying ? SyncStrings.pause : SyncStrings.play, palette: palette,
                                    action: session.togglePlay)
                    .accessibilityIdentifier("sync.playPause")
                EditorStackedButton(systemImage: "gobackward.5", label: SyncStrings.back5, palette: palette,
                                    action: session.rewind)
                    .accessibilityIdentifier("sync.back5")
            }
            Color.clear.frame(height: 12)
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.2), value: view.canSkip && !finished && !inFixLine)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync.tap")
    }
}

// MARK: - What the screen shows, derived once per draft change

/// A music break: the next word opens a line whose anchor is far from the last tap.
nonisolated struct SyncMusicBreak: Hashable, Sendable {
    let anchorMs: Int64
    let fromMs: Int64
}

/// Android `TapView`.
nonisolated struct SyncTapModel: Equatable, Sendable {
    static let compactTokens = 12
    static let musicBreakMinMs: Int64 = 5_000

    let currentLine: Int
    let previousLine: Int?
    let nextLine: Int?
    /// Next token to tap, or `tokens.count` when finished.
    let nextIndex: Int
    /// The word being sung: the last stamped token before `nextIndex` in the current line.
    let sungIndex: Int
    let nextWord: String?
    let lineNumber: Int
    let lineCount: Int
    let canUndo: Bool
    let canSkip: Bool
    let musicBreak: SyncMusicBreak?
    /// Tapped share of the tappable words, 0…1 (1 when there is nothing to tap).
    let progress: Double

    static func make(draft: SyncDraft, fixLine: Int?) -> SyncTapModel {
        let nextIndex = LyricsTapSync.nextTappable(draft, from: draft.cursor)
        let currentLine = draft.tokens.indices.contains(nextIndex) ? draft.tokens[nextIndex].line
            : (fixLine ?? (draft.lines.count - 1))
        let openLines = draft.lines.indices.filter { !draft.lines[$0].locked && draft.lines[$0].tokenCount > 0 }
        let position = max(openLines.firstIndex(of: currentLine) ?? 0, 0)
        let previousLine = position - 1 >= 0 && position - 1 < openLines.count ? openLines[position - 1] : nil
        let nextLine = position + 1 < openLines.count ? openLines[position + 1] : nil
        let line = draft.lines[max(currentLine, 0)]
        var sung = -1
        var i = min(nextIndex, line.endToken) - 1
        while i >= line.firstToken {
            if draft.tokens[i].rawStartMs != nil { sung = i; break }
            i -= 1
        }
        let floor = fixLine.map { draft.lines[$0].firstToken } ?? 0
        var canUndo = false
        i = min(draft.cursor, draft.tokens.count) - 1
        while i >= floor {
            if draft.tokens[i].rawStartMs != nil && !draft.lines[draft.tokens[i].line].locked { canUndo = true; break }
            i -= 1
        }
        var musicBreak: SyncMusicBreak?
        if nextIndex < draft.tokens.count, nextIndex == line.firstToken, let anchor = line.anchorMs {
            var lastStart: Int64 = 0
            var j = nextIndex - 1
            while j >= 0 {
                if let start = LyricsTapSync.builtStartMs(draft, j, offsetMs: 0) { lastStart = start; break }
                j -= 1
            }
            if anchor - lastStart > musicBreakMinMs { musicBreak = SyncMusicBreak(anchorMs: anchor, fromMs: lastStart) }
        }
        let total = draft.tappableCount
        return SyncTapModel(
            currentLine: max(currentLine, 0), previousLine: previousLine, nextLine: nextLine, nextIndex: nextIndex,
            sungIndex: sung,
            nextWord: draft.tokens.indices.contains(nextIndex)
                ? draft.tokens[nextIndex].text.trimmingCharacters(in: .whitespaces) : nil,
            lineNumber: position + 1, lineCount: max(openLines.count, 1), canUndo: canUndo,
            canSkip: LyricsTapSync.canSkipLine(draft), musicBreak: musicBreak,
            progress: total == 0 ? 1 : Double(draft.tappedCount) / Double(total))
    }
}

// MARK: - Pieces

/// "Line 3 of 24" (13 pt medium, 70 %) over a 3 pt bar: white 18 % track, accent fill (Android `ProgressRow`).
private struct SyncProgressRow: View {
    let lineNumber: Int
    let lineCount: Int
    let fraction: Double
    let palette: SyncEditorPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SyncStrings.lineOf(lineNumber, lineCount))
                .pixlFont(.custom(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Capsule()
                .fill(.white.opacity(0.18))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(palette.accent)
                        .scaleEffect(x: min(max(fraction, 0), 1), anchor: .leading)
                }
                .animation(.easeOut(duration: 0.2), value: fraction)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The previous line (tappable: redo from there), the current line's words, the next line (Android `LyricContext`).
private struct SyncLyricContext: View {
    let draft: SyncDraft
    let view: SyncTapModel
    let palette: SyncEditorPalette
    let allowJump: Bool
    let onJump: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let index = view.previousLine {
                contextLine(draft.lines[index].text, onTap: allowJump ? { onJump(index) } : nil)
            }
            let line = draft.lines[view.currentLine]
            let size: CGFloat = line.tokenCount > SyncTapModel.compactTokens ? 24 : 30
            // Not tappable: it sits right above the pad, where a novice naturally taps along.
            SyncFlowLayout(lineSpacing: 4) {
                ForEach(line.firstToken..<line.endToken, id: \.self) { i in
                    let token = draft.tokens[i]
                    SyncWordChip(text: token.text.trimmingCharacters(in: .whitespaces),
                                 trailingSpace: token.text.hasSuffix(" "),
                                 state: state(of: i, token: token), fontSize: size, palette: palette)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let index = view.nextLine {
                contextLine(draft.lines[index].text, onTap: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func state(of i: Int, token: SyncToken) -> SyncWordState {
        if i == view.nextIndex { return .next }
        if i == view.sungIndex { return .sung }
        return token.rawStartMs != nil ? .done : .later
    }

    @ViewBuilder
    private func contextLine(_ text: String, onTap: (() -> Void)?) -> some View {
        let label = Text(text)
            .pixlFont(.custom(size: 18, weight: .medium))
            .foregroundStyle(.white.opacity(0.35))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let onTap {
            Button(action: onTap) { label.contentShape(.rect(cornerRadius: 10)) }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.98))
        } else {
            label
        }
    }
}

nonisolated enum SyncWordState: Sendable, Equatable { case done, sung, next, later }

/// One word of the current line (Android `WordChip`). The white box marks the word being sung (the last one tapped)
/// with a small spring pop. Tapped words are coloured in: the accent sweeps across the letters from the first to the
/// last (right to left for RTL words) in 260 ms when the word is tapped, and stays. Untapped words are white (the next
/// one) or dim (later).
private struct SyncWordChip: View {
    let text: String
    let trailingSpace: Bool
    let state: SyncWordState
    let fontSize: CGFloat
    let palette: SyncEditorPalette

    static let fillSweep: Animation = .timingCurve(0.4, 0, 0.2, 1, duration: 0.26)
    /// Android `spring(dampingRatio = 0.6, stiffness = 900)`: damping = 2 · 0.6 · √900.
    static let popSpring: Animation = .interpolatingSpring(mass: 1, stiffness: 900, damping: 36)
    static let popScale: CGFloat = 1.06

    @State private var fill: CGFloat
    @State private var pop: CGFloat = 1

    init(text: String, trailingSpace: Bool, state: SyncWordState, fontSize: CGFloat, palette: SyncEditorPalette) {
        self.text = text
        self.trailingSpace = trailingSpace
        self.state = state
        self.fontSize = fontSize
        self.palette = palette
        _fill = State(initialValue: state == .done || state == .sung ? 1 : 0)
    }

    private var tapped: Bool { state == .done || state == .sung }

    var body: some View {
        let rtl = TextScripts.isRtlWord(text)
        let base = Text(text)
            .pixlFont(.custom(size: fontSize, weight: .semibold, lineHeight: fontSize * 1.2))
        base
            .foregroundStyle(state == .later ? Color.white.opacity(0.4) : .white)
            .mask(alignment: rtl ? .leading : .trailing) {
                Rectangle().scaleEffect(x: tapped ? 1 - fill : 1, anchor: rtl ? .leading : .trailing)
            }
            .overlay {
                if tapped {
                    base
                        .foregroundStyle(palette.accent)
                        .mask(alignment: rtl ? .trailing : .leading) {
                            Rectangle().scaleEffect(x: fill, anchor: rtl ? .trailing : .leading)
                        }
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 6)
            .overlay {
                if state == .sung {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.55), lineWidth: 1.5)
                }
            }
            .scaleEffect(pop)
            .padding(.trailing, trailingSpace ? 4 : 0)
            .onChange(of: state) { _, newState in apply(newState) }
            .accessibilityLabel(text)
    }

    private func apply(_ newState: SyncWordState) {
        switch newState {
        case .sung:
            guard fill < 1 else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { pop = Self.popScale }
            withAnimation(Self.popSpring) { pop = 1 }
            withAnimation(Self.fillSweep) { fill = 1 }
        case .done:
            // A tap that lands mid-sweep: finish the fill and settle the box at once.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                pop = 1
                fill = 1
            }
        case .next, .later:
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                pop = 1
                fill = 0
            }
        }
    }
}

/// "NEXT" (12 pt semibold, 60 %, 1.2 tracking) over the next word, bold and fitted between 24 and 40 pt, in a fixed
/// 70 pt block (Android `NextWordLabel`).
private struct SyncNextWordLabel: View {
    let word: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let word {
                Text(SyncStrings.nextLabel.uppercased())
                    .pixlFont(.custom(size: 12, weight: .semibold, tracking: 1.2))
                    .foregroundStyle(.white.opacity(0.6))
                Text(word)
                    .pixlFont(.custom(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(word)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.09)),
                                            removal: .opacity.animation(.easeIn(duration: 0.06))))
                    .accessibilityIdentifier("sync.nextWord")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 70, alignment: .top)
        .clipped()
    }
}

/// Replaces the context with "Music break" and a ring counting down to the next line (Android
/// `MusicBreakOrContext`). A cheap poll decides whether the break is on; only the ring reads the position per frame.
private struct SyncMusicBreakOrContext<Context: View>: View {
    let breakInfo: SyncMusicBreak
    let session: LyricsSyncSession
    let palette: SyncEditorPalette
    @ViewBuilder let context: () -> Context

    static var endMs: Int64 { 1_500 }
    @State private var inBreak = false

    var body: some View {
        ZStack(alignment: .leading) {
            if inBreak {
                HStack(spacing: 0) {
                    TimelineView(.animation(minimumInterval: nil, paused: !session.isPlaying)) { _ in
                        ring(positionMs: session.positionMs())
                    }
                    .frame(width: 72, height: 72)
                    Spacer().frame(width: 16)
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer().frame(width: 6)
                    Text(SyncStrings.musicBreak)
                        .pixlFont(.custom(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            } else {
                context().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: inBreak)
        .task(id: breakInfo) {
            while !Task.isCancelled {
                let now = session.positionMs()
                let next = breakInfo.anchorMs - now > Self.endMs
                if next != inBreak { inBreak = next }
                try? await Task.sleep(for: .milliseconds(next ? 50 : 150))
            }
        }
    }

    private func ring(positionMs: Int64) -> some View {
        let span = Double(max(breakInfo.anchorMs - breakInfo.fromMs, 1))
        let left = min(max(Double(breakInfo.anchorMs - positionMs) / span, 0), 1)
        let seconds = max((breakInfo.anchorMs - positionMs + 999) / 1000, 0)
        return ZStack {
            Circle().stroke(.white.opacity(0.16), lineWidth: 5).padding(2.5)
            Circle()
                .trim(from: 0, to: left)
                .stroke(palette.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(2.5)
            Text("\(seconds)")
                .pixlFont(.custom(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }
}

/// The giant pad (Android `TapPad`): stamps on touch *down* with the touch's own timestamp (the moment the finger
/// landed, not when the frame ran); a hold ≥ 350 ms marks the word's end on release; extra fingers landing during a
/// hold are taps too. Press feedback (scale 0.97, glow, haptic) starts before any other work.
private struct SyncTapPad: View {
    let label: String
    let tip: String?
    let session: LyricsSyncSession
    let palette: SyncEditorPalette

    static let pressedScale: CGFloat = 0.97
    /// Android `spring(dampingRatio = 1, stiffness = 1400)` / `spring(0.7, 900)`.
    static let pressSpring: Animation = .interpolatingSpring(mass: 1, stiffness: 1_400, damping: 2 * 1 * 37.42)
    static let releaseSpring: Animation = .interpolatingSpring(mass: 1, stiffness: 900, damping: 2 * 0.7 * 30)

    @State private var pressed = false
    @State private var glow: Double = 0

    var body: some View {
        ZStack {
            VStack(spacing: 6) {
                Text(label)
                    .pixlFont(.custom(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .id(label)
                    .transition(.opacity)
                if let tip {
                    Text(tip)
                        .pixlFont(.custom(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
            }
            .padding(24)
            .animation(.easeInOut(duration: 0.16), value: label)
            .animation(.easeInOut(duration: 0.2), value: tip)
            .allowsHitTesting(false)
            TapPadTouchSurface(
                onDown: { timestamp in
                    pressFeedback()
                    return session.onTapDown(eventUptime: timestamp)
                },
                onUp: { index, down, up in
                    releaseFeedback()
                    session.onTapUp(tokenIndex: index, downUptime: down, upUptime: up)
                })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            SyncShapes.pad.fill(.white.opacity(0.10 * glow)).allowsHitTesting(false)
        }
        .glassEffect(palette.padGlass, in: SyncShapes.pad)
        .scaleEffect(pressed ? Self.pressedScale : 1)
        .pixlHaptic(.impact(weight: .light), trigger: session.haptics ? session.pressCount : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("sync.pad")
        .accessibilityAction {
            let now = ProcessInfo.processInfo.systemUptime
            let index = session.onTapDown(eventUptime: now)
            session.onTapUp(tokenIndex: index, downUptime: now, upUptime: now)
        }
    }

    private func pressFeedback() {
        withAnimation(Self.pressSpring) { pressed = true }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { glow = 1 }
    }

    private func releaseFeedback() {
        withAnimation(Self.releaseSpring) { pressed = false }
        withAnimation(.easeOut(duration: 0.22)) { glow = 0 }
    }
}

/// The pad's touch surface: a UIKit view, because SwiftUI gestures carry neither the touch's timestamp nor extra
/// fingers. `UITouch.timestamp` is on the `ProcessInfo.systemUptime` clock.
private struct TapPadTouchSurface: UIViewRepresentable {
    let onDown: (TimeInterval) -> Int
    let onUp: (Int, TimeInterval, TimeInterval) -> Void

    func makeUIView(context: Context) -> TapPadTouchView {
        let view = TapPadTouchView()
        view.onDown = onDown
        view.onUp = onUp
        return view
    }

    func updateUIView(_ view: TapPadTouchView, context: Context) {
        view.onDown = onDown
        view.onUp = onUp
    }
}

final class TapPadTouchView: UIView {
    var onDown: ((TimeInterval) -> Int)?
    var onUp: ((Int, TimeInterval, TimeInterval) -> Void)?
    private weak var primary: UITouch?
    private var primaryIndex = -1
    private var primaryDown: TimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let index = onDown?(touch.timestamp) ?? -1
            if primary == nil {
                primary = touch
                primaryIndex = index
                primaryDown = touch.timestamp
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches, cancelled: true)
    }

    private func release(_ touches: Set<UITouch>, cancelled: Bool) {
        guard let primary, touches.contains(primary) else { return }
        let up = cancelled ? ProcessInfo.processInfo.systemUptime : primary.timestamp
        self.primary = nil
        onUp?(primaryIndex, primaryDown, up)
        primaryIndex = -1
    }
}

// MARK: - Layout

/// A column that gives its children their ideal heights and splits the rest between the weighted ones (Compose
/// `Modifier.weight`), honouring a minimum height — the tap screen's context (weight 1) and pad (1.25, ≥ 200 pt).
nonisolated struct SyncWeightedColumn: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let height = proposal.height ?? heights(width: width, total: nil, subviews: subviews).reduce(0, +)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = heights(width: bounds.width, total: bounds.height, subviews: subviews)
        var y = bounds.minY
        for (subview, height) in zip(subviews, sizes) {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }

    private func heights(width: CGFloat, total: CGFloat?, subviews: Subviews) -> [CGFloat] {
        var result = [CGFloat](repeating: 0, count: subviews.count)
        var fixed: CGFloat = 0
        var weighted: [Int] = []
        for (i, subview) in subviews.enumerated() {
            if subview[SyncLayoutWeightKey.self] > 0 {
                weighted.append(i)
            } else {
                result[i] = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                fixed += result[i]
            }
        }
        guard let total else {
            for i in weighted { result[i] = subviews[i][SyncLayoutMinHeightKey.self] }
            return result
        }
        var remaining = max(0, total - fixed)
        var open = weighted
        // Children whose share falls under their minimum take the minimum; the others split what is left.
        while !open.isEmpty {
            let weightSum = open.reduce(CGFloat(0)) { $0 + subviews[$1][SyncLayoutWeightKey.self] }
            let short = open.first { remaining * subviews[$0][SyncLayoutWeightKey.self] / weightSum < subviews[$0][SyncLayoutMinHeightKey.self] }
            if let short {
                result[short] = subviews[short][SyncLayoutMinHeightKey.self]
                remaining = max(0, remaining - result[short])
                open.removeAll { $0 == short }
            } else {
                for i in open { result[i] = remaining * subviews[i][SyncLayoutWeightKey.self] / weightSum }
                break
            }
        }
        return result
    }
}

nonisolated private struct SyncLayoutWeightKey: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

nonisolated private struct SyncLayoutMinHeightKey: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

extension View {
    /// The child's weight (and minimum height) in a `SyncWeightedColumn`.
    func syncLayoutWeight(_ weight: CGFloat, minHeight: CGFloat = 0) -> some View {
        layoutValue(key: SyncLayoutWeightKey.self, value: weight)
            .layoutValue(key: SyncLayoutMinHeightKey.self, value: minHeight)
    }
}

/// Words left to right, wrapping (Compose `FlowRow` with 4 pt between rows).
nonisolated struct SyncFlowLayout: Layout {
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !current.indices.isEmpty && current.width + size.width > width {
                rows.append(current)
                current = Row()
            }
            current.indices.append(index)
            current.width += size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
