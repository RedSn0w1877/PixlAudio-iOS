import PixlFoundation
import PixlLyrics
import SwiftUI

/// Tags one run of a lyric line's `Text` with the karaoke piece it belongs to (a syllable, or one grapheme of an
/// emphasised word). The renderer finds every piece's glyphs through it — no character-offset maths.
nonisolated struct KaraokePieceAttribute: TextAttribute {
    let piece: Int
}

/// The timed pieces of one word-synced line (`LyricLineNode.buildSegments` without the layout half: SwiftUI's
/// `Text.Layout` supplies the boxes at draw time). Immutable; built once per line on first use.
nonisolated final class KaraokePieceTable: Sendable {
    /// The line's text cut into runs: `piece` ≥ 0 is a timed piece, -1 is untimed text (spaces, punctuation).
    let segments: [(text: String, piece: Int)]
    let syllableCount: Int
    let syllable: [Int]
    let start: [Int64]
    let end: [Int64]
    let liftStart: [Int64]
    let liftDuration: [Int64]
    let rtl: [Bool]
    let emphasis: [Bool]
    let graphemeIndex: [Int]
    let graphemeCount: [Int]
    let wordStart: [Int64]
    let wordDurationEff: [Float]
    let amount: [Float]
    let glow: [Float]
    /// Glow as a CSS text-shadow blur, in em.
    let glowBlurEm: [Float]

    init(line: PreparedLine) {
        let units = Array(line.text.utf16)
        let length = units.count
        let syllables = line.syllables ?? []
        let shaped = LyricsRenderMetrics.needsShapedPieces(line.text)
        var owner = [Int](repeating: -1, count: length)
        var syllable: [Int] = [], start: [Int64] = [], end: [Int64] = [], liftStart: [Int64] = []
        var liftDuration: [Int64] = [], rtl: [Bool] = [], emphasis: [Bool] = [], graphemeIndex: [Int] = []
        var graphemeCount: [Int] = [], wordStart: [Int64] = [], wordDurationEff: [Float] = [], amount: [Float] = []
        var glow: [Float] = [], glowBlurEm: [Float] = []

        func isSpace(_ u: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(u) else { return false }
            return scalar.properties.isWhitespace
        }
        func substring(_ a: Int, _ b: Int) -> String { line.substring(utf16From: a, to: b) }

        var k = 0
        while k < syllables.count {
            let syl = syllables[k]
            let cs = min(max(syl.charStart, 0), length)
            let ce = min(max(syl.charEnd, cs), length)
            if syl.emphasis && !shaped {
                var j = k
                while j + 1 < syllables.count && syllables[j + 1].wordIndex == syl.wordIndex { j += 1 }
                let we = min(max(syllables[j].charEnd, cs), length)
                var wordEnd = syl.endMs
                for q in k...j { wordEnd = max(wordEnd, syllables[q].endMs) }
                let durationMs = wordEnd &- syl.startMs
                let isLast = syl.wordIndex == line.lastWordIndex
                let duEff = EmphasisMath.effectiveDurationMs(durationMs, isLastWord: isLast)
                let amt = EmphasisMath.amount(durationMs, isLastWord: isLast)
                let gl = EmphasisMath.glow(durationMs, isLastWord: isLast)
                let bounds = EmphasisMath.graphemeBoundaries(substring(cs, we))
                var nonBlank = 0
                for g in 0..<max(bounds.count - 1, 0) {
                    let a = cs + bounds[g], b = cs + bounds[g + 1]
                    if !(a..<b).allSatisfy({ isSpace(units[$0]) }) { nonBlank += 1 }
                }
                var gi = 0
                for g in 0..<max(bounds.count - 1, 0) {
                    let a = cs + bounds[g], b = cs + bounds[g + 1]
                    if (a..<b).allSatisfy({ isSpace(units[$0]) }) { continue }
                    var ownerIndex = k
                    for q in k...j where a >= syllables[q].charStart && a < syllables[q].charEnd {
                        ownerIndex = q
                        break
                    }
                    let o = syllables[ownerIndex]
                    let p = syllable.count
                    syllable.append(ownerIndex)
                    start.append(o.startMs)
                    end.append(o.endMs)
                    liftStart.append(o.startMs)
                    liftDuration.append(o.endMs &- o.startMs)
                    rtl.append(LyricsRenderMetrics.isRtlText(substring(a, b)))
                    emphasis.append(true)
                    graphemeIndex.append(gi)
                    graphemeCount.append(max(nonBlank, 1))
                    wordStart.append(syl.startMs)
                    wordDurationEff.append(duEff)
                    amount.append(amt)
                    glow.append(gl)
                    glowBlurEm.append(EmphasisMath.glowBlurEm(gl))
                    for c in a..<b { owner[c] = p }
                    gi += 1
                }
                k = j + 1
                continue
            }
            if ce > cs {
                let p = syllable.count
                syllable.append(k)
                start.append(syl.startMs)
                end.append(max(syl.endMs, syl.startMs &+ 1))
                liftStart.append(syl.startMs)
                liftDuration.append(syl.endMs &- syl.startMs)
                rtl.append(LyricsRenderMetrics.isRtlText(substring(cs, ce)))
                emphasis.append(false)
                graphemeIndex.append(0)
                graphemeCount.append(1)
                wordStart.append(0)
                wordDurationEff.append(1)
                amount.append(0)
                glow.append(0)
                glowBlurEm.append(0)
                for c in cs..<ce where owner[c] < 0 { owner[c] = p }
            }
            k += 1
        }

        // Runs of equal owners → the Text's segments.
        var segments: [(text: String, piece: Int)] = []
        var runStart = 0
        while runStart < length {
            let piece = owner[runStart]
            var runEnd = runStart + 1
            while runEnd < length && owner[runEnd] == piece { runEnd += 1 }
            segments.append((substring(runStart, runEnd), piece))
            runStart = runEnd
        }
        self.segments = segments
        syllableCount = syllables.count
        self.syllable = syllable
        self.start = start
        self.end = end
        self.liftStart = liftStart
        self.liftDuration = liftDuration
        self.rtl = rtl
        self.emphasis = emphasis
        self.graphemeIndex = graphemeIndex
        self.graphemeCount = graphemeCount
        self.wordStart = wordStart
        self.wordDurationEff = wordDurationEff
        self.amount = amount
        self.glow = glow
        self.glowBlurEm = glowBlurEm
    }

    /// How a piece fills this frame.
    enum Fill { case unsung, sung, gradient }

    /// Per-frame transform and fill of piece `p` (`LyricLinePieces.frame`).
    struct Frame {
        var fill: Fill = .unsung
        var edge: CGFloat = 0
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var scale: CGFloat = 1
        var glowAlpha: Double = 0
        var glowSigma: CGFloat = 0
    }

    func frame(_ p: Int, tMs t: Int64, activeness a: Float, em: Float, background: Bool, reducedMotion: Bool,
               highContrast: Bool, sweepLeft: CGFloat, sweepRight: CGFloat, fade: CGFloat) -> Frame {
        var f = Frame()
        let motionOn = !reducedMotion
        let lift: Float = motionOn
            ? EmphasisMath.liftEm(tMs: t, startMs: liftStart[p], durationMs: liftDuration[p], background: background) * em * a
            : 0
        let s = start[p], e = end[p]
        if t >= e {
            f.fill = .sung
        } else if t < s {
            f.fill = .unsung
        } else if highContrast {
            f.fill = .sung
        } else {
            f.fill = .gradient
            let progress = EmphasisMath.syllableProgress(tMs: t, startMs: s, endMs: e)
            let l = Float(sweepLeft), r = Float(sweepRight), w = Float(fade)
            f.edge = CGFloat(rtl[p]
                ? EmphasisMath.sweepEdgeCenterRtlPx(leftPx: l, rightPx: r, fadePx: w, p: progress)
                : EmphasisMath.sweepEdgeCenterPx(leftPx: l, rightPx: r, fadePx: w, p: progress))
        }
        f.dy = CGFloat(-lift)
        if motionOn && emphasis[p] {
            let du = wordDurationEff[p]
            let n = graphemeCount[p]
            let gi = graphemeIndex[p]
            let charStart = EmphasisMath.graphemeStartMs(wordStartMs: wordStart[p], effectiveDurationMs: du, n: n, i: gi)
            let env = EmphasisMath.envelope(EmphasisMath.graphemeProgress(tMs: t, charStartMs: charStart, effectiveDurationMs: du))
            let amt = amount[p]
            let visualIndex = rtl[p] ? n - 1 - gi : gi
            let dx = EmphasisMath.offsetXEm(e: env, amount: amt, n: n, i: visualIndex) * em
            let dy = EmphasisMath.offsetYEm(e: env, amount: amt) * em
            let hop = EmphasisMath.hopEm(tMs: t, charStartMs: charStart, effectiveDurationMs: du) * em * a
            let glowAlpha = EmphasisMath.glowAlpha(e: env, glow: glow[p]) * a
            f.dx = CGFloat(dx)
            f.dy = CGFloat(-lift + dy - hop)
            f.scale = CGFloat(EmphasisMath.scale(e: env, amount: amt))
            if glowAlpha > 0.01 {
                f.glowAlpha = Double(glowAlpha)
                // CSS text-shadow blur B has σ = B / 2.
                f.glowSigma = CGFloat(glowBlurEm[p] * em / 2)
            }
        }
        return f
    }
}

/// Draws a lyric line's `Text` with the karaoke word fill (spec §1.4): solid sung / unsung syllables, the active
/// syllable's soft edge (a linear ramp half a line height wide), the lift scaled by activeness, and the emphasis
/// letters' scale / spread / hop / glow. Inactive lines draw as one block at one alpha.
nonisolated struct KaraokeTextRenderer: TextRenderer {
    let table: KaraokePieceTable?
    var timeMs: Int64
    var activeness: Float
    /// Draw word pieces (hot, or still fading out); otherwise the whole line at `wholeAlpha`.
    var animateWords: Bool
    var wholeAlpha: Double
    var sung: Double
    var unsung: Double
    var em: CGFloat
    var fade: CGFloat
    var background: Bool
    var reducedMotion: Bool
    var highContrast: Bool

    var displayPadding: EdgeInsets {
        // Room for the lift, hop, emphasis scale and glow outside the text box.
        EdgeInsets(top: em * 0.45, leading: em * 0.35, bottom: em * 0.3, trailing: em * 0.35)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        guard animateWords, let table, table.syllableCount > 0 else {
            context.opacity = wholeAlpha
            for line in layout { context.draw(line) }
            return
        }
        let count = table.syllableCount
        withUnsafeTemporaryAllocation(of: CGFloat.self, capacity: 2 * count) { box in
            for line in layout {
                // Each syllable's extent on this visual line: the sweep box.
                for i in 0..<count {
                    box[2 * i] = .infinity
                    box[2 * i + 1] = -.infinity
                }
                for run in line {
                    guard let piece = run[KaraokePieceAttribute.self]?.piece else { continue }
                    let s = table.syllable[piece]
                    let rect = run.typographicBounds.rect
                    box[2 * s] = min(box[2 * s], rect.minX)
                    box[2 * s + 1] = max(box[2 * s + 1], rect.maxX)
                }
                for run in line {
                    drawRun(run, table: table, box: box, in: context)
                }
            }
        }
    }

    private func drawRun(_ run: Text.Layout.Run, table: KaraokePieceTable, box: UnsafeMutableBufferPointer<CGFloat>,
                         in context: GraphicsContext) {
        var ctx = context
        guard let piece = run[KaraokePieceAttribute.self]?.piece else {
            ctx.opacity = unsung
            ctx.draw(run)
            return
        }
        let s = table.syllable[piece]
        let rect = run.typographicBounds.rect
        let f = table.frame(piece, tMs: timeMs, activeness: activeness, em: Float(em), background: background,
                            reducedMotion: reducedMotion, highContrast: highContrast,
                            sweepLeft: box[2 * s], sweepRight: box[2 * s + 1], fade: fade)
        ctx.translateBy(x: f.dx, y: f.dy)
        if f.scale != 1 {
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: f.scale, y: f.scale)
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
        }
        if f.glowAlpha > 0 {
            ctx.addFilter(.shadow(color: .white.opacity(f.glowAlpha), radius: f.glowSigma, x: 0, y: 0))
        }
        switch f.fill {
        case .sung:
            ctx.opacity = sung
            ctx.draw(run)
        case .unsung:
            ctx.opacity = unsung
            ctx.draw(run)
        case .gradient:
            let rtl = table.rtl[piece]
            let from = rtl ? unsung : sung
            let to = rtl ? sung : unsung
            let x0 = f.edge - fade / 2
            let x1 = f.edge + fade / 2
            // The ramp spans the whole mask so nothing depends on how a gradient pads past its end points.
            let maskRect = rect.insetBy(dx: -em, dy: -em)
            let width = max(maskRect.width, 1)
            let l0 = min(max((x0 - maskRect.minX) / width, 0), 1)
            let l1 = min(max((x1 - maskRect.minX) / width, l0), 1)
            let gradient = Gradient(stops: [.init(color: .white.opacity(from), location: 0),
                                            .init(color: .white.opacity(from), location: l0),
                                            .init(color: .white.opacity(to), location: l1),
                                            .init(color: .white.opacity(to), location: 1)])
            ctx.drawLayer { layer in
                layer.draw(run)
                layer.blendMode = .destinationIn
                layer.fill(Path(maskRect),
                           with: .linearGradient(gradient, startPoint: CGPoint(x: maskRect.minX, y: rect.midY),
                                                 endPoint: CGPoint(x: maskRect.maxX, y: rect.midY)))
            }
        }
    }
}
