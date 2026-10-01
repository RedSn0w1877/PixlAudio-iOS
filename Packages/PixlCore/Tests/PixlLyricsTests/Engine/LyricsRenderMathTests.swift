import Foundation
import Testing
import PixlModel
@testable import PixlLyrics

/// A monospaced fake layout: every UTF-16 unit is `advance` wide, lines wrap every `perLine` units, LTR unless told.
struct FakeLayout: LyricTextLayout {
    var advance: Float = 10
    var perLine = 1_000
    var lineHeight: Float = 41
    var rtl = false

    func line(forOffset offset: Int) -> Int { offset / perLine }
    func boundingBox(atOffset offset: Int) -> (left: Float, right: Float) {
        let col = Float(offset % perLine)
        return rtl ? (1_000 - (col + 1) * advance, 1_000 - col * advance) : (col * advance, (col + 1) * advance)
    }
    func isRightToLeft(atOffset offset: Int) -> Bool { rtl }
    func lineTop(_ line: Int) -> Float { Float(line) * lineHeight }
    func lineBottom(_ line: Int) -> Float { Float(line + 1) * lineHeight }
}

/// Swift-only tests of the renderer maths taken out of `LyricsView.kt`, `LyricLineNode.kt` and `InterludeDots.kt`
/// (no Android unit test covered them; the formulas are checked by hand from the Kotlin).
@Suite("Lyrics renderer maths")
struct LyricsRenderMathTests {

    func line(_ lyrics: Lyrics, _ index: Int = 0) throws -> PreparedLine {
        try #require(PreparedLyricsBuilder.build(lyrics)).lines[index]
    }

    @Test func paddingsAlignmentAndPivots() throws {
        let m = LyricsRenderMetrics()
        #expect(m.emPx == 34)
        #expect(m.startPadding(role: .lead, width: 400) == 24)
        #expect(m.endPadding(role: .lead, width: 400) == 44)
        #expect(m.contentWidth(role: .lead, width: 400) == 332)
        let centre = LyricsRenderMetrics(alignment: .center)
        #expect(centre.startPadding(role: .lead, width: 400) == 34)
        #expect(centre.textAlign(role: .lead) == .center)
        let end = LyricsRenderMetrics(alignment: .end)
        #expect(end.startPadding(role: .lead, width: 400) == 44)
        #expect(end.endPadding(role: .lead, width: 400) == 24)
        let duet = LyricsRenderMetrics(hasDuet: true)
        #expect(abs(duet.startPadding(role: .duet, width: 400) - 60) <= 1e-4) // 15 %
        #expect(abs(duet.endPadding(role: .lead, width: 400) - 60) <= 1e-4)
        #expect(duet.endPadding(role: .duet, width: 400) == 24)
        #expect(duet.textAlign(role: .duet) == .end)

        let rtlLine = try line(Lyrics(synced: [SyncedLine(time: 0, line: "שלום")]))
        let ltrLine = try line(Lyrics(synced: [SyncedLine(time: 0, line: "hello")]))
        #expect(m.pivotX(rtlLine) == 1)
        #expect(m.pivotX(ltrLine) == 0)
        #expect(centre.pivotX(rtlLine) == 0.5)
        #expect(end.pivotX(ltrLine) == 1)
        #expect(LyricsRenderMetrics.fontSize(textScale: 5) == 68)
        #expect(LyricsRenderMetrics.fontSize(textScale: 0.1) == 34 * 0.6)
    }

    @Test func rowLayoutStacksBlocksAndRoundsTheHeight() throws {
        let m = LyricsRenderMetrics()
        let row = LyricRowLayout.compute(metrics: m, role: .lead, width: 400, mainHeight: 41, romanizationHeight: 26.2,
                                         translationHeight: 22.1, inkMinX: 0, inkMaxX: 200)
        #expect(row.textTop == 15)
        let romanTop = try #require(row.romanizationTop)
        let transTop = try #require(row.translationTop)
        let expectedRoman: Float = 15 + 41 + 4
        let expectedTrans: Float = 15 + 41 + 4 + 26.2 + 4
        #expect(romanTop == expectedRoman)
        #expect(transTop == expectedTrans)
        #expect(row.height == Float(KotlinMathRef.roundToInt(15 + 41 + 4 + 26.2 + 4 + 22.1 + 15)))
        #expect(abs(row.highlightLeft - (24 - 34 * 0.3)) <= 1e-4)
        #expect(abs(row.highlightRight - (24 + 200 + 34 * 0.3)) <= 1e-4)
        let bg = LyricRowLayout.compute(metrics: m, role: .background, width: 400, mainHeight: 27, romanizationHeight: nil,
                                        translationHeight: nil, inkMinX: nil, inkMaxX: nil)
        #expect(bg.textTop == 7.5)
        #expect(bg.height == 42)
        #expect(bg.romanizationTop == Optional<Float>.none)
    }

    @Test func lineAlphas() {
        let normal = LyricLineAlphas.resolve(activeness: 1, role: .lead, highContrast: false, inactive: KaraokeAlpha.inactive)
        #expect(normal.unsung == 0.35 && normal.sung == 1)
        #expect(abs(normal.translation - 0.45) <= 1e-6)
        let bg = LyricLineAlphas.resolve(activeness: 1, role: .background, highContrast: false, inactive: 0.2)
        #expect(bg.unsung == 0.175 && abs(bg.sung - 0.35) <= 1e-6)
        let hc = LyricLineAlphas.resolve(activeness: 1, role: .lead, highContrast: true, inactive: 0.55)
        #expect(abs(hc.unsung - 0.6) <= 1e-6)
        let bright = LyricLineAlphas.resolve(activeness: 0, role: .lead, highContrast: false, inactive: 0.5)
        #expect(abs(bright.translation - 0.45) <= 1e-6, "inactive translation never above 0.45")
        #expect(bright.wholeLine(hasWordTiming: true) == bright.unsung)
        #expect(LyricLineAlphas.animatesWords(hasWordTiming: true, hot: false, activeness: 0.01))
        #expect(!LyricLineAlphas.animatesWords(hasWordTiming: true, hot: false, activeness: 0.001))
        #expect(!LyricLineAlphas.animatesWords(hasWordTiming: false, hot: true, activeness: 1))
    }

    @Test func piecesCoverSyllablesUntimedTextAndEmphasisGraphemes() throws {
        // "Hello world!" — "Hello" (1.5 s, explicit → emphasis), "world" (300 ms), "!" untimed.
        let l = try line(Lyrics(synced: [SyncedLine(time: 1_000, line: "Hello world!", words: [
            SyncedWord(time: 1_000, word: "Hello", endTime: 2_500), SyncedWord(time: 2_600, word: "world", endTime: 2_900),
        ])]))
        let m = LyricsRenderMetrics()
        let pieces = LyricLinePieces.build(line: l, layout: FakeLayout(), metrics: m, originX: 24, originY: 15)
        #expect(pieces.count == 5 + 1 + 1, "5 grapheme pieces, one syllable piece, one untimed piece")
        #expect(pieces.emphasis.prefix(5).allSatisfy { $0 })
        #expect(pieces.graphemeIndex.prefix(5).elementsEqual(0..<5))
        #expect(pieces.graphemeCount[0] == 5)
        #expect(pieces.text(of: 5, in: l) == "world")
        #expect(pieces.text(of: 6, in: l) == "!")
        #expect(!pieces.timed[6])
        #expect(pieces.left[5] == 24 + 60)
        #expect(pieces.sweepLeft[0] == 24 && pieces.sweepRight[0] == 24 + 50, "emphasis pieces sweep across the whole syllable")
        #expect(abs(pieces.fadePx - 0.5 * 34 * 1.2059) <= 1e-4)
        #expect(pieces.amount[0] == EmphasisMath.amount(1_500, isLastWord: false))

        // Mid-sweep of "world": gradient with the edge between its box ends.
        let f = pieces.frame(5, tMs: 2_750, activeness: 1, metrics: m, role: .lead)
        #expect(f.fill == .gradient)
        #expect(f.edgeCenterX > pieces.sweepLeft[5] - pieces.fadePx / 2 && f.edgeCenterX < pieces.sweepRight[5] + pieces.fadePx / 2)
        #expect(f.offsetY < 0, "lifted")
        #expect(pieces.frame(5, tMs: 3_000, activeness: 1, metrics: m, role: .lead).fill == .sung)
        #expect(pieces.frame(5, tMs: 2_000, activeness: 1, metrics: m, role: .lead).fill == .unsung)
        #expect(pieces.frame(6, tMs: 2_750, activeness: 1, metrics: m, role: .lead) == .identity)
        // Emphasis grapheme at its peak scales up and glows.
        let peak = pieces.frame(2, tMs: 1_900, activeness: 1, metrics: m, role: .lead)
        #expect(peak.scale > 1)
        // High contrast never draws a gradient; reduced motion never moves.
        let hc = LyricsRenderMetrics(highContrast: true, reducedMotion: true)
        let hf = pieces.frame(5, tMs: 2_750, activeness: 1, metrics: hc, role: .lead)
        #expect(hf.fill == .sung && hf.offsetY == 0 && hf.scale == 1)
        // Gradient alpha: sung left of the edge, unsung right of it.
        #expect(pieces.gradientAlpha(5, x: f.edgeCenterX - 100, edgeCenterX: f.edgeCenterX, sung: 1, unsung: 0.35) == 1)
        #expect(pieces.gradientAlpha(5, x: f.edgeCenterX + 100, edgeCenterX: f.edgeCenterX, sung: 1, unsung: 0.35) - 0.35 <= 1e-6)
    }

    @Test func syllablesSplitAcrossVisualLinesShareTimeByWidth() throws {
        let l = try line(Lyrics(synced: [SyncedLine(time: 0, line: "abcdef", words: [SyncedWord(time: 0, word: "abcdef", endTime: 600)])]))
        let pieces = LyricLinePieces.build(line: l, layout: FakeLayout(perLine: 4), metrics: LyricsRenderMetrics(),
                                           originX: 0, originY: 0)
        #expect(pieces.count == 2)
        #expect(pieces.visualLine == [0, 1])
        #expect(pieces.start == [0, 400])
        #expect(pieces.end == [400, 600])
        #expect(pieces.top[1] == 41)
        #expect(pieces.liftStart == [0, 0] && pieces.liftDuration == [600, 600])
    }

    @Test func shapedScriptsUseClippedPiecesWithoutEmphasis() throws {
        let l = try line(Lyrics(synced: [SyncedLine(time: 0, line: "حبيبي", words: [SyncedWord(time: 0, word: "حبيبي", endTime: 2_000)])]))
        let pieces = LyricLinePieces.build(line: l, layout: FakeLayout(rtl: true), metrics: LyricsRenderMetrics(), originX: 0, originY: 0)
        #expect(pieces.clipped)
        #expect(pieces.count == 1)
        #expect(!pieces.emphasis[0])
        #expect(pieces.rtl[0])
        let f = pieces.frame(0, tMs: 100, activeness: 1, metrics: LyricsRenderMetrics(), role: .lead)
        #expect(f.scale == 1)
        #expect(f.edgeCenterX > pieces.sweepRight[0] - pieces.fadePx, "right-to-left sweep starts at the right edge")
    }

    @Test func interludeDots() {
        let m = LyricsRenderMetrics()
        #expect(InterludeDotsGeometry.rowHeight(emPx: 34) == 37) // round(34 × 1.1)
        let g = InterludeDotsGeometry.compute(metrics: m, width: 400, rowHeight: 37, presence: 0.5, alignEnd: false)
        #expect(g.left == 24)
        #expect(abs(g.centerY - 9.25) <= 1e-5)
        #expect(abs(g.dotDiameter - 10.2) <= 1e-5)
        #expect(abs(g.centersX[2] - (24 + 5.1 + 2 * (10.2 + 5.1))) <= 1e-4)
        let end = InterludeDotsGeometry.compute(metrics: m, width: 400, rowHeight: 37, presence: 1, alignEnd: true)
        #expect(abs(end.left + end.groupWidth - (400 - 24)) <= 1e-4)
        #expect(end.pivotX == end.left + end.groupWidth)
        let centred = InterludeDotsGeometry.compute(metrics: LyricsRenderMetrics(alignment: .center), width: 400, rowHeight: 37,
                                                    presence: 1, alignEnd: false)
        #expect(abs(centred.left - (400 - centred.groupWidth) / 2) <= 1e-4)
        #expect(InterludeDotsGeometry.dotAlpha(tMs: 10_000, g0: 10_000, g1: 30_000, k: 0) == 0)
        #expect(!InterludeDotsGeometry.isVisible(presence: 0.0005))
    }

    @Test func edgeFadeAndAnchor() {
        let plain = LyricsEdgeFade().resolve(height: 1_000)
        #expect(plain.topClearEnd == 0 && plain.topFadeEnd == 100)
        #expect(plain.bottomEdge == 1_000 && plain.bottomFadeStart == 880)
        #expect(plain.alpha(atY: 50) == 0.5)
        #expect(plain.alpha(atY: 500) == 1)
        #expect(abs(plain.alpha(atY: 940) - 0.5) <= 1e-5)
        let chrome = LyricsEdgeFade(topInset: 120, topFadeLength: 40, bottomFadeLength: 60).resolve(height: 1_000, bottomInset: 150)
        #expect(chrome.topClearEnd == 120 && chrome.topFadeEnd == 160)
        #expect(chrome.bottomEdge == 850 && chrome.bottomFadeStart == 790)
        #expect(chrome.alpha(atY: 100) == 0 && chrome.alpha(atY: 900) == 0)
        let tallInset = LyricsEdgeFade(topInset: 300).resolve(height: 1_000)
        #expect(tallInset.topClearEnd == 0 && tallInset.topFadeEnd == 300, "plain fade covers max(10 %, inset)")
        let m = LyricsRenderMetrics()
        #expect(m.anchor(viewportHeight: 1_000, topInset: 0, topFadeLength: nil) == 250)
        #expect(m.anchor(viewportHeight: 1_000, topInset: 250, topFadeLength: 40) == 306)
        #expect(LyricsEdgeFade(topInset: 100).isUnderChrome(y: 50, height: 1_000, bottomInset: 0))
    }

    @Test func appearancePrefsMapping() {
        let prefs = LyricsAppearancePrefs(alignment: "right", animatedBlurEnabled: true, disableBlurAllOver: true, blurStrength: 2.4)
        let a = prefs.toAppearance(textSize: 33, brightArt: true)
        #expect(a.textScale == 1.5)
        #expect(a.alignment == .end)
        #expect(!a.blurEnabled)
        #expect(a.blurStrength == 2)
        #expect(a.inactiveAlpha == 0.5)
        #expect(!a.usesAdditiveBlend)
        #expect(LyricsAppearancePrefs().toAppearance(textSize: nil, brightArt: false).usesAdditiveBlend)
        #expect(LyricsAppearancePrefs.alignment(from: "center") == .center)
        #expect(LyricsAppearancePrefs.alignment(from: "left") == .start)
        let hc = KaraokeLyricsAppearance(highContrast: true)
        #expect(!hc.engineConfig(reducedMotion: false).blurEnabled)
        #expect(hc.inactiveAlpha == 0.55)
        #expect(KaraokeLyricsAppearance().metrics(hasDuet: true, reducedMotion: false).hasDuet)
    }
}

import PixlFoundation
enum KotlinMathRef {
    static func roundToInt(_ x: Float) -> Int { Int(KotlinMath.roundToInt(x)) }
}
