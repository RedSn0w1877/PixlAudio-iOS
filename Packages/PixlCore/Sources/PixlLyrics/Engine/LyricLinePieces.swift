// The word-sweep pieces of a word-synced line (`LyricLineNode.buildSegments` / `LineSegments` / `drawSegments`), as
// pure data: which UTF-16 range each piece covers, where its box is, when it is sung, and how it moves per frame.
//
// The renderer supplies the line's text layout through `LyricTextLayout` (on iOS: SwiftUI `Text.Layout` /
// TextKit), builds the pieces once per line (ideally when `LyricsEngine.rowPrefetch` turns true, a second before the
// line turns hot) and calls `frame(_:tMs:activeness:metrics:role:)` per piece per frame — no allocation.

import Foundation
import PixlFoundation

/// The text layout of one lyric line, in text coordinates (origin at the top-left of the main text block).
public protocol LyricTextLayout {
    /// Visual line index of the character at a UTF-16 `offset`.
    func line(forOffset offset: Int) -> Int
    /// Left and right edges of the glyph box of the character at `offset`.
    func boundingBox(atOffset offset: Int) -> (left: Float, right: Float)
    /// Whether the bidi run at `offset` is right-to-left.
    func isRightToLeft(atOffset offset: Int) -> Bool
    /// Top and bottom of a visual line.
    func lineTop(_ line: Int) -> Float
    func lineBottom(_ line: Int) -> Float
}

/// How a piece is filled this frame.
public enum LyricPieceFill: Sendable, Hashable {
    /// Solid unsung alpha (not reached yet, or untimed text).
    case unsung
    /// Solid sung alpha (finished, or any started syllable under increased contrast).
    case sung
    /// Soft-edged sweep: sung on the sung side of `edgeCenterX − fade/2`, unsung past `edgeCenterX + fade/2`, linear
    /// in between (mirrored for right-to-left pieces).
    case gradient
}

/// Per-frame transform and fill of one piece.
public struct LyricPieceFrame: Sendable, Hashable {
    public var fill: LyricPieceFill
    /// Centre of the soft edge (row coordinates) for `.gradient`.
    public var edgeCenterX: Float
    /// Translation applied to the piece (row coordinates), lift, emphasis push and hop included.
    public var offsetX: Float
    public var offsetY: Float
    /// Scale about the piece centre (emphasis), 1 otherwise.
    public var scale: Float
    /// Glow shadow alpha (white); 0 = no shadow (Android skips it at ≤ 0.01).
    public var glowAlpha: Float

    public static let identity = LyricPieceFrame(fill: .unsung, edgeCenterX: 0, offsetX: 0, offsetY: 0, scale: 1, glowAlpha: 0)
}

/// The drawable pieces of a word-synced line, in parallel arrays (row coordinates).
public struct LyricLinePieces: Sendable, Hashable {
    public private(set) var count = 0
    /// UTF-16 range `[rangeStart, rangeEnd)` of each piece in the line text.
    public private(set) var rangeStart: [Int] = []
    public private(set) var rangeEnd: [Int] = []
    /// Visual line of each piece.
    public private(set) var visualLine: [Int] = []
    /// Top-left of the piece's own text box.
    public private(set) var left: [Float] = []
    public private(set) var top: [Float] = []
    public private(set) var timed: [Bool] = []
    public private(set) var start: [Int64] = []
    public private(set) var end: [Int64] = []
    public private(set) var liftStart: [Int64] = []
    public private(set) var liftDuration: [Int64] = []
    /// The sweep box (the owning syllable's extent on this visual line).
    public private(set) var sweepLeft: [Float] = []
    public private(set) var sweepRight: [Float] = []
    public private(set) var rtl: [Bool] = []
    public private(set) var emphasis: [Bool] = []
    public private(set) var graphemeIndex: [Int] = []
    public private(set) var graphemeCount: [Int] = []
    public private(set) var wordStart: [Int64] = []
    public private(set) var wordDurationEff: [Float] = []
    public private(set) var amount: [Float] = []
    public private(set) var glow: [Float] = []
    /// Glow blur as a CSS text-shadow blur in layout units (σ = half of it).
    public private(set) var glowBlur: [Float] = []
    /// Bottom of the piece's visual line (clip box of shaped lines; the clip box runs `sweepLeft…sweepRight`).
    public private(set) var clipBottom: [Float] = []
    /// Soft-edge width: half a line height.
    public private(set) var fadePx: Float = 0
    /// Shaped-script line: draw each piece as the whole line clipped to `sweepLeft…sweepRight × top…clipBottom`
    /// instead of measuring the piece's text on its own (and skip per-letter emphasis).
    public private(set) var clipped = false

    public init() {}

    /// `buildSegments`: splits the line into timed pieces (one per syllable run per visual line, or one per grapheme
    /// for emphasis words) and untimed pieces (text no syllable covers).
    ///
    /// - Parameters:
    ///   - originX / originY: where the main text block sits in the row (`LyricRowLayout.textLeft/textTop`).
    public static func build(line: PreparedLine, layout: some LyricTextLayout, metrics: LyricsRenderMetrics,
                             originX: Float, originY: Float) -> LyricLinePieces {
        let text = Array(line.text.utf16)
        let length = text.count
        let syllables = line.syllables ?? []
        let isBg = line.role == .background
        let em = isBg ? metrics.bgEmPx : metrics.emPx
        let lineHeight = em * LyricsRenderMetrics.lineHeightEm
        var covered = [Bool](repeating: false, count: length)
        let shaped = LyricsRenderMetrics.needsShapedPieces(line.text)
        var out = LyricLinePieces()

        func lineOf(_ offset: Int) -> Int { layout.line(forOffset: offset.coerced(in: 0, Swift.max(length - 1, 0))) }
        func boxLeft(_ a: Int, _ b: Int) -> Float {
            let r1 = layout.boundingBox(atOffset: a)
            let r2 = layout.boundingBox(atOffset: Swift.max(b - 1, a))
            return ComposeBezier.javaMin(r1.left, r2.left)
        }
        func boxRight(_ a: Int, _ b: Int) -> Float {
            let r1 = layout.boundingBox(atOffset: a)
            let r2 = layout.boundingBox(atOffset: Swift.max(b - 1, a))
            return ComposeBezier.javaMax(r1.right, r2.right)
        }
        func rtlAt(_ a: Int) -> Bool { layout.isRightToLeft(atOffset: a) }
        /// Splits `[a, b)` into runs that each stay on one visual line.
        func runs(_ a: Int, _ b: Int, _ onRun: (Int, Int, Int) -> Void) {
            var runStart = a
            var runLine = lineOf(a)
            var c = a + 1
            while c < b {
                let l = lineOf(c)
                if l != runLine {
                    onRun(runStart, c, runLine)
                    runStart = c
                    runLine = l
                }
                c += 1
            }
            if b > runStart { onRun(runStart, b, runLine) }
        }
        func isBlank(_ a: Int, _ b: Int) -> Bool {
            var i = a
            while i < b {
                if !PreparedText.isWhitespace(text[i]) { return false }
                i += 1
            }
            return true
        }
        func append(a: Int, b: Int, visual: Int, timed: Bool, start: Int64, end: Int64, liftStart: Int64,
                    liftDuration: Int64, sweepLeft: Float, sweepRight: Float, rtl: Bool, emphasis: Bool = false,
                    graphemeIndex: Int = 0, graphemeCount: Int = 1, wordStart: Int64 = 0, wordDurationEff: Float = 1,
                    amount: Float = 0, glow: Float = 0, glowBlur: Float = 0) {
            out.count += 1
            out.rangeStart.append(a)
            out.rangeEnd.append(b)
            out.visualLine.append(visual)
            out.left.append(originX + boxLeft(a, b))
            out.top.append(originY + layout.lineTop(visual))
            out.timed.append(timed)
            out.start.append(start)
            out.end.append(end)
            out.liftStart.append(liftStart)
            out.liftDuration.append(liftDuration)
            out.sweepLeft.append(originX + sweepLeft)
            out.sweepRight.append(originX + sweepRight)
            out.rtl.append(rtl)
            out.emphasis.append(emphasis)
            out.graphemeIndex.append(graphemeIndex)
            out.graphemeCount.append(graphemeCount)
            out.wordStart.append(wordStart)
            out.wordDurationEff.append(wordDurationEff)
            out.amount.append(amount)
            out.glow.append(glow)
            out.glowBlur.append(glowBlur)
            out.clipBottom.append(originY + layout.lineBottom(visual))
        }

        var k = 0
        while k < syllables.count {
            let syl = syllables[k]
            let cs = syl.charStart.coerced(in: 0, length)
            let ce = syl.charEnd.coerced(in: cs, length)
            if syl.emphasis && !shaped {
                var j = k
                while j + 1 < syllables.count && syllables[j + 1].wordIndex == syl.wordIndex { j += 1 }
                let ws = cs
                let we = syllables[j].charEnd.coerced(in: ws, length)
                var wordEnd = syl.endMs
                for q in k...j { wordEnd = Swift.max(wordEnd, syllables[q].endMs) }
                let wordStart = syl.startMs
                let durationMs = wordEnd &- wordStart
                let isLast = syl.wordIndex == line.lastWordIndex
                let duEff = EmphasisMath.effectiveDurationMs(durationMs, isLastWord: isLast)
                let amount = EmphasisMath.amount(durationMs, isLastWord: isLast)
                let glow = EmphasisMath.glow(durationMs, isLastWord: isLast)
                let glowBlur = EmphasisMath.glowBlurEm(glow) * em
                let bounds = EmphasisMath.graphemeBoundaries(PreparedText.string(text[ws..<we]))
                var n = 0
                for g in 0..<(bounds.count - 1) where !isBlank(ws + bounds[g], ws + bounds[g + 1]) { n += 1 }
                var gi = 0
                for g in 0..<(bounds.count - 1) {
                    let ga = ws + bounds[g]
                    let gb = ws + bounds[g + 1]
                    if isBlank(ga, gb) { continue }
                    var owner = syl
                    for q in k...j {
                        let o = syllables[q]
                        if ga >= o.charStart && ga < o.charEnd {
                            owner = o
                            break
                        }
                    }
                    let gl = lineOf(ga)
                    // Sweep box: the owning syllable's characters on this grapheme's visual line.
                    var sa = owner.charStart.coerced(in: 0, length)
                    var sb = owner.charEnd.coerced(in: sa, length)
                    while sa < ga && lineOf(sa) != gl { sa += 1 }
                    while sb > gb && lineOf(sb - 1) != gl { sb -= 1 }
                    append(a: ga, b: gb, visual: gl, timed: true, start: owner.startMs, end: owner.endMs,
                           liftStart: owner.startMs, liftDuration: owner.endMs &- owner.startMs,
                           sweepLeft: boxLeft(sa, sb), sweepRight: boxRight(sa, sb), rtl: rtlAt(ga),
                           emphasis: true, graphemeIndex: gi, graphemeCount: Swift.max(n, 1),
                           wordStart: wordStart, wordDurationEff: duEff, amount: amount, glow: glow, glowBlur: glowBlur)
                    gi += 1
                }
                for c in ws..<we { covered[c] = true }
                k = j + 1
                continue
            }

            if ce > cs {
                // Split across visual lines; each run gets a share of the time by width.
                var total: Float = 0
                runs(cs, ce) { a, b, _ in total += boxRight(a, b) - boxLeft(a, b) }
                let duration = Swift.max(syl.endMs &- syl.startMs, 1)
                var acc = Float(syl.startMs)
                runs(cs, ce) { a, b, l in
                    let left = boxLeft(a, b)
                    let right = boxRight(a, b)
                    let share: Float = total > 0 ? (right - left) / total : 1
                    let runStart = acc
                    acc += Float(duration) * share
                    let runStartMs = KotlinMath.toLong(runStart)
                    append(a: a, b: b, visual: l, timed: true, start: runStartMs,
                           end: Swift.max(KotlinMath.toLong(acc), runStartMs &+ 1),
                           liftStart: syl.startMs, liftDuration: syl.endMs &- syl.startMs,
                           sweepLeft: left, sweepRight: right, rtl: rtlAt(a))
                }
                for c in cs..<ce { covered[c] = true }
            }
            k += 1
        }

        // Text no syllable covers (punctuation, untimed tails): drawn in the unsung colour.
        var c = 0
        while c < length {
            if covered[c] || PreparedText.isWhitespace(text[c]) {
                c += 1
                continue
            }
            var e = c + 1
            while e < length && !covered[e] && !PreparedText.isWhitespace(text[e]) { e += 1 }
            runs(c, e) { a, b, l in
                append(a: a, b: b, visual: l, timed: false, start: Int64.max, end: Int64.max, liftStart: 0,
                       liftDuration: 0, sweepLeft: boxLeft(a, b), sweepRight: boxRight(a, b), rtl: rtlAt(a))
            }
            c = e
        }

        out.fadePx = EmphasisMath.fadeWidthPx(lineHeightPx: lineHeight)
        out.clipped = shaped
        return out
    }

    /// The text of piece `i` (what a separately measured piece shows).
    public func text(of i: Int, in line: PreparedLine) -> String {
        line.substring(utf16From: rangeStart[i], to: rangeEnd[i])
    }

    /// Glow σ of piece `i` (half the CSS blur).
    public func glowSigma(_ i: Int) -> Float { glowBlur[i] / 2 }

    /// `drawSegments` for one piece at lyrics time `tMs`.
    ///
    /// - Parameter activeness: the row's `rowActiveness` (`a`), which scales the lift, hop and glow.
    public func frame(_ i: Int, tMs t: Int64, activeness a: Float, metrics: LyricsRenderMetrics,
                      role: PreparedVoiceRole) -> LyricPieceFrame {
        if !timed[i] { return .identity }
        let isBg = role == .background
        let em = isBg ? metrics.bgEmPx : metrics.emPx
        let motionOn = !metrics.reducedMotion
        let lift: Float = motionOn ? EmphasisMath.liftEm(tMs: t, startMs: liftStart[i], durationMs: liftDuration[i],
                                                         background: isBg) * em * a : 0
        let s = start[i]
        let e = end[i]
        let fill: LyricPieceFill
        if t >= e {
            fill = .sung
        } else if t < s {
            fill = .unsung
        } else if metrics.highContrast {
            fill = .sung
        } else {
            fill = .gradient
        }
        var edge: Float = 0
        if fill == .gradient {
            let p = EmphasisMath.syllableProgress(tMs: t, startMs: s, endMs: e)
            edge = rtl[i]
                ? EmphasisMath.sweepEdgeCenterRtlPx(leftPx: sweepLeft[i], rightPx: sweepRight[i], fadePx: fadePx, p: p)
                : EmphasisMath.sweepEdgeCenterPx(leftPx: sweepLeft[i], rightPx: sweepRight[i], fadePx: fadePx, p: p)
        }
        if !clipped && motionOn && emphasis[i] {
            let du = wordDurationEff[i]
            let n = graphemeCount[i]
            let gi = graphemeIndex[i]
            let charStart = EmphasisMath.graphemeStartMs(wordStartMs: wordStart[i], effectiveDurationMs: du, n: n, i: gi)
            let env = EmphasisMath.envelope(EmphasisMath.graphemeProgress(tMs: t, charStartMs: charStart, effectiveDurationMs: du))
            let amt = amount[i]
            let sc = EmphasisMath.scale(e: env, amount: amt)
            // Letters spread out from the word's visual middle: mirror the index for RTL.
            let visualIndex = rtl[i] ? n - 1 - gi : gi
            let dx = EmphasisMath.offsetXEm(e: env, amount: amt, n: n, i: visualIndex) * em
            let dy = EmphasisMath.offsetYEm(e: env, amount: amt) * em
            let hop = EmphasisMath.hopEm(tMs: t, charStartMs: charStart, effectiveDurationMs: du) * em * a
            let glowAlpha = EmphasisMath.glowAlpha(e: env, glow: glow[i]) * a
            return LyricPieceFrame(fill: fill, edgeCenterX: edge, offsetX: dx, offsetY: -lift + dy - hop, scale: sc,
                                   glowAlpha: glowAlpha > 0.01 ? glowAlpha : 0)
        }
        return LyricPieceFrame(fill: fill, edgeCenterX: edge, offsetX: 0, offsetY: -lift, scale: 1, glowAlpha: 0)
    }

    /// Alpha of the fill at row x-coordinate `x` for a `.gradient` frame (what the soft-edge brush draws).
    public func gradientAlpha(_ i: Int, x: Float, edgeCenterX: Float, sung: Float, unsung: Float) -> Float {
        let half = fadePx / 2
        var f = fadePx > 0 ? ((x - (edgeCenterX - half)) / fadePx).coerced(in: 0, 1) : (x < edgeCenterX ? 0 : 1)
        if rtl[i] { f = 1 - f }
        return sung + (unsung - sung) * f
    }
}
