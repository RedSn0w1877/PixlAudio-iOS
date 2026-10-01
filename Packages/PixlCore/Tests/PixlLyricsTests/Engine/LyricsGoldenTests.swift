import Foundation
import Testing
import PixlFoundation
import PixlModel
@testable import PixlLyrics

/// Compares the Swift port against the Android app's compiled `PreparedLyricsBuilder`, `LyricsEngine` +
/// `LyricsClock` and lyrics maths, run on the JVM by `tools/android-reference/EngineGen.java`.
///
/// Floats are compared as bit patterns with a 4-ulp allowance (`exp`/`sin`/`cos` come from different libm builds on
/// the JVM and the platform); integers, booleans and strings must match exactly.
@Suite("Android lyrics golden vectors")
struct LyricsGoldenTests {

    static func close(_ actual: Float, _ expected: Float, ulps: Float = 4, absolute: Float = 1e-6) -> Bool {
        if actual.bitPattern == expected.bitPattern { return true }
        if actual.isNaN || expected.isNaN { return false }
        return abs(actual - expected) <= Swift.max(ulps * expected.ulp, absolute)
    }

    final class Mismatches {
        var count = 0
        var checked = 0
        func check(_ ok: Bool, _ message: @autoclosure () -> String) {
            checked += 1
            if ok { return }
            count += 1
            if count <= 25 { Issue.record(Comment(rawValue: message())) }
        }
    }

    // MARK: - PreparedLyricsBuilder

    @Test func preparedLyricsMatchAndroid() throws {
        let lines = try EngineFixture.lines("lyrics-prepared-golden")
        let m = Mismatches()
        var defs: [String: EngineFixture.LyricsDef] = [:]
        var current: EngineFixture.LyricsDef?
        var currentName = ""
        var i = 0
        var cases = 0
        while i < lines.count {
            let f = EngineFixture.fields(lines[i])
            i += 1
            if f[0] == "I" {
                let input = Array(f.dropFirst())
                if input[0] == "LYRICS" {
                    current = EngineFixture.LyricsDef()
                    currentName = String(input[1])
                } else if current != nil, current!.apply(input) {
                    defs[currentName] = current
                    current = nil
                }
                continue
            }
            guard f[0] == "P" else { Issue.record("unexpected \(f)"); continue }
            let name = String(f[1])
            cases += 1
            let prepared = PreparedLyricsBuilder.build(defs[name]!.lyrics)
            if f.count > 2 && f[2] == "null" {
                m.check(prepared == nil, "\(name): Android built nothing, Swift built \(String(describing: prepared))")
                continue
            }
            guard let p = prepared else {
                m.check(false, "\(name): Swift built nothing")
                while i < lines.count && !lines[i].hasPrefix("I\t") && !lines[i].hasPrefix("P\t") { i += 1 }
                continue
            }
            var lineIndex = -1
            var syllableIndex = 0
            var rowIndex = 0
            while i < lines.count && !lines[i].hasPrefix("I\t") && !lines[i].hasPrefix("P\t") {
                let g = EngineFixture.fields(lines[i])
                i += 1
                switch g[0] {
                case "PL":
                    lineIndex += 1
                    syllableIndex = 0
                    guard lineIndex < p.lines.count else { m.check(false, "\(name): missing line \(lineIndex)"); continue }
                    let l = p.lines[lineIndex]
                    let expected = "\(g[1]) \(g[2]) \(g[3]) \(g[4]) \(g[5]) \(g[6]) \(g[7]) [\(EngineFixture.unescape(g[8]))] [\(EngineFixture.nullable(g[9]) ?? "nil")] [\(EngineFixture.nullable(g[10]) ?? "nil")]"
                    let actual = "\(l.index) \(l.startMs) \(l.endMs) \(l.endIsExplicit ? 1 : 0) \(l.role.rawValue.uppercased()) \(l.groupLeadIndex) \(l.bgAbove ? 1 : 0) [\(l.text)] [\(l.translation ?? "nil")] [\(l.romanization ?? "nil")]"
                    m.check(expected.isIdentical(to: actual), "\(name) line \(lineIndex): expected \(expected), got \(actual)")
                case "PN":
                    m.check(lineIndex < p.lines.count && p.lines[lineIndex].syllables == nil, "\(name) line \(lineIndex): expected no syllables")
                case "PS":
                    let syl = lineIndex < p.lines.count ? p.lines[lineIndex].syllables : nil
                    guard let syl, syllableIndex < syl.count else {
                        m.check(false, "\(name) line \(lineIndex): missing syllable \(syllableIndex)")
                        continue
                    }
                    let s = syl[syllableIndex]
                    let expected = g[1...7].joined(separator: " ")
                    let actual = "\(s.charStart) \(s.charEnd) \(s.startMs) \(s.endMs) \(s.endIsExplicit ? 1 : 0) \(s.wordIndex) \(s.emphasis ? 1 : 0)"
                    m.check(expected == actual, "\(name) line \(lineIndex) syllable \(syllableIndex): expected \(expected), got \(actual)")
                    syllableIndex += 1
                case "PR":
                    let expected: PreparedRow = g[1] == "line"
                        ? .line(lineIndex: Int(g[2])!)
                        : .interlude(startMs: Int64(g[2])!, endMs: Int64(g[3])!, alignEnd: g[4] == "1")
                    m.check(rowIndex < p.rows.count && p.rows[rowIndex] == expected,
                            "\(name) row \(rowIndex): expected \(expected), got \(rowIndex < p.rows.count ? "\(p.rows[rowIndex])" : "none")")
                    rowIndex += 1
                case "PM":
                    m.check(p.lines.count == lineIndex + 1, "\(name): \(p.lines.count) lines, Android \(lineIndex + 1)")
                    m.check(p.rows.count == rowIndex, "\(name): \(p.rows.count) rows, Android \(rowIndex)")
                    let expected = g[1...4].joined(separator: " ")
                    let actual = "\(p.hasWordTiming ? 1 : 0) \(p.hasDuet ? 1 : 0) \(p.maxLineDurationMs) \(p.lastEndMs)"
                    m.check(expected == actual, "\(name) summary: expected \(expected), got \(actual)")
                    m.check(p.startsSorted == p.lines.map(\.startMs), "\(name): startsSorted")
                default:
                    Issue.record("unexpected \(g)")
                }
            }
        }
        #expect(cases >= 30)
        #expect(m.count == 0, "\(m.count) of \(m.checked) prepared-lyrics checks differ from Android")
    }

    // MARK: - LyricsEngine traces

    @Test func engineTracesMatchAndroid() throws {
        let lines = try EngineFixture.lines("lyrics-engine-golden")
        let m = Mismatches()
        let runner = EngineScenarioRunner()
        var current: EngineFixture.LyricsDef?
        var currentName = ""
        var scenario = ""
        var cursor = 0
        var frames = 0

        runner.onDump = { r in
            frames += 1
            let e = r.engine
            let f = EngineFixture.fields(lines[cursor])
            cursor += 1
            guard f[0] == "F" else {
                m.check(false, "\(scenario): expected an F line, found \(f)")
                return
            }
            let where_ = "\(scenario) @\(f[1])"
            m.check(Int64(f[1])! == r.frameNanos, "\(where_): frame clock \(r.frameNanos)")
            m.check(Int64(f[2])! == e.clock.currentMs, "\(where_): clock \(e.clock.currentMs), Android \(f[2])")
            m.check(Int(f[3])! == e.scrollTargetRow, "\(where_): target \(e.scrollTargetRow), Android \(f[3])")
            m.check(Self.close(e.scrollOffset, EngineFixture.float(f[4])), "\(where_): offset \(e.scrollOffset), Android \(EngineFixture.float(f[4]))")
            m.check((f[5] == "1") == e.isUserScrolling, "\(where_): userScrolling \(e.isUserScrolling)")
            m.check((f[6] == "1") == e.isAtRest, "\(where_): atRest \(e.isAtRest)")
            m.check((f[7] == "1") == e.needsFrame, "\(where_): needsFrame \(e.needsFrame)")
            m.check((f[8] == "1") == e.isLaidOut, "\(where_): laidOut \(e.isLaidOut)")
            while cursor < lines.count && lines[cursor].hasPrefix("R\t") {
                let g = EngineFixture.fields(lines[cursor])
                cursor += 1
                let row = Int(g[1])!
                guard row < e.rowCount else { m.check(false, "\(where_): no row \(row)"); continue }
                let checks: [(String, Float, Substring)] = [
                    ("y", e.rowY[row], g[2]), ("scale", e.rowScale[row], g[3]), ("blur", e.rowBlurRadiusPx[row], g[4]),
                    ("depthAlpha", e.rowDepthAlpha[row], g[5]), ("activeness", e.rowActiveness[row], g[6]),
                    ("expand", e.rowExpand[row], g[8]), ("presence", e.rowPresence[row], g[9]),
                    ("springY", e.rowSpringY(row), g[11]), ("sigmaTarget", e.rowSigmaTargetDp(row), g[13]),
                ]
                for (field, actual, hex) in checks {
                    let expected = EngineFixture.float(hex)
                    m.check(Self.close(actual, expected), "\(where_) row \(row) \(field): \(actual), Android \(expected)")
                }
                m.check((g[7] == "1") == e.rowHot[row], "\(where_) row \(row) hot: \(e.rowHot[row])")
                m.check((g[10] == "1") == e.rowPrefetch[row], "\(where_) row \(row) prefetch: \(e.rowPrefetch[row])")
                m.check(Int64(g[12])! == e.rowPendingAtNanos(row), "\(where_) row \(row) pendingAt: \(e.rowPendingAtNanos(row)), Android \(g[12])")
            }
        }

        while cursor < lines.count {
            let f = EngineFixture.fields(lines[cursor])
            cursor += 1
            guard f[0] == "I" else {
                m.check(false, "unconsumed output line \(f.prefix(3)) in \(scenario)")
                continue
            }
            let input = Array(f.dropFirst())
            if let def = current {
                var d = def
                if d.apply(input) {
                    runner.defs[currentName] = d
                    current = nil
                } else {
                    current = d
                }
                continue
            }
            switch input[0] {
            case "LYRICS":
                current = EngineFixture.LyricsDef()
                currentName = String(input[1])
            case "SCENARIO": scenario = String(input[1])
            case "ENDSCENARIO": break
            default: runner.run(input)
            }
        }
        #expect(frames > 1_000)
        #expect(m.checked > 100_000)
        #expect(m.count == 0, "\(m.count) of \(m.checked) engine checks differ from Android over \(frames) frames")
    }

    // MARK: - Maths

    @Test func lyricsMathsMatchAndroid() throws {
        let lines = try EngineFixture.lines("lyrics-math-golden")
        let m = Mismatches()
        var art: [UInt32] = []
        func fl(_ s: Substring) -> Float { EngineFixture.float(s) }
        func eq(_ name: String, _ actual: Float, _ hex: Substring, _ context: String) {
            let expected = fl(hex)
            m.check(Self.close(actual, expected), "\(name) \(context): \(actual), Android \(expected)")
        }
        for line in lines {
            let f = EngineFixture.fields(line)
            let ctx = f.dropFirst(2).prefix(4).joined(separator: " ")
            switch f[1] {
            case "springs":
                eq("slowζ", LyricsSprings.slowDampingRatio, f[2], ctx)
                eq("slowK", LyricsSprings.slowStiffness, f[3], ctx)
                eq("endedζ", LyricsSprings.endedDampingRatio, f[4], ctx)
                eq("endedK", LyricsSprings.endedStiffness, f[5], ctx)
                eq("scaleζ", LyricsSprings.scaleDampingRatio, f[6], ctx)
                eq("scaleK", LyricsSprings.scaleStiffness, f[7], ctx)
                eq("normalζ", LyricsSprings.normalDampingRatio, f[8], ctx)
            case "normalStiffness":
                eq("normalStiffness", LyricsSprings.normalPlaybackStiffness(gapMs: Int64(f[2])!), f[3], ctx)
            case "depthSigma":
                eq("depthSigma", LyricsBlurMath.depthSigmaDp(distance: Int(f[2])!, strength: fl(f[3])), f[4], ctx)
            case "fallbackAlpha":
                eq("fallbackAlpha", LyricsBlurMath.fallbackAlphaFactor(distance: Int(f[2])!), f[3], ctx)
            case "radius":
                let sigma = fl(f[2])
                let density = fl(f[3])
                let r = LyricsBlurMath.sigmaDpToRadiusPx(sigma, density: density)
                eq("radius", r, f[4], ctx)
                eq("quantized", LyricsBlurMath.quantizeRadiusPx(r), f[5], ctx)
                eq("cssShadow", LyricsBlurMath.cssShadowBlurToRadiusPx(sigma * 2, density: density), f[6], ctx)
            case "quantize":
                eq("quantize", LyricsBlurMath.quantizeRadiusPx(fl(f[2])), f[3], ctx)
            case "cascade":
                let tops: [[Float]] = [[0, 100, 200, 300, 400], [-300, -150, 0, 100], [0, 100, 100, 200], [-80, -20, 30, 90, 160, 700, 1400, 2000]]
                let heights: [[Float]] = [[100, 100, 100, 100, 100], [100, 100, 100, 100], [100, 0, 100, 100], [50, 60, 0.4, 70, 80, 90, 0, 55]]
                let c = Int(f[2])!
                var out = [Float](repeating: 0, count: tops[c].count)
                LyricsCascade.computeDelays(tops: tops[c], heights: heights[c], count: tops[c].count, targetRow: Int(f[3])!, out: &out)
                for k in out.indices { eq("cascade[\(k)]", out[k], f[4 + k], ctx) }
            case "emphasis":
                let du = Int64(f[2])!
                let last = f[3] == "1"
                eq("amount", EmphasisMath.amount(du, isLastWord: last), f[4], ctx)
                eq("glow", EmphasisMath.glow(du, isLastWord: last), f[5], ctx)
                eq("effective", EmphasisMath.effectiveDurationMs(du, isLastWord: last), f[6], ctx)
                eq("peakScale", EmphasisMath.peakScale(du, isLastWord: last), f[7], ctx)
                eq("peakGlow", EmphasisMath.peakGlowAlpha(du, isLastWord: last), f[8], ctx)
                eq("glowBlur", EmphasisMath.glowBlurEm(EmphasisMath.glow(du, isLastWord: last)), f[9], ctx)
            case "envelope":
                let x = fl(f[2])
                let k = Int(KotlinMath.roundToInt(x * 1000))
                let e = EmphasisMath.envelope(x)
                eq("envelope", e, f[3], ctx)
                eq("strength", EmphasisMath.strengthCurve(x * 3), f[4], ctx)
                eq("scale", EmphasisMath.scale(e: e, amount: 0.84), f[5], ctx)
                eq("offsetX", EmphasisMath.offsetXEm(e: e, amount: 0.84, n: 5, i: k % 5), f[6], ctx)
                eq("offsetY", EmphasisMath.offsetYEm(e: e, amount: 0.84), f[7], ctx)
                eq("glowAlpha", EmphasisMath.glowAlpha(e: e, glow: 0.6), f[8], ctx)
            case "lift":
                let dur = Int64(f[2])!
                let t = Int64(f[3])!
                eq("lift", EmphasisMath.liftEm(tMs: t, startMs: 1000, durationMs: dur), f[4], ctx)
                eq("liftBg", EmphasisMath.liftEm(tMs: t, startMs: 1000, durationMs: dur, background: true), f[5], ctx)
                eq("progress", EmphasisMath.syllableProgress(tMs: t, startMs: 1000, endMs: 1000 + dur), f[6], ctx)
            case "grapheme":
                let du = fl(f[2])
                let n = Int(f[3])!
                let gi = Int(f[4])!
                let t = Int64(f[5])!
                let cs = EmphasisMath.graphemeStartMs(wordStartMs: 5000, effectiveDurationMs: du, n: n, i: gi)
                eq("charStart", cs, f[6], ctx)
                eq("graphemeProgress", EmphasisMath.graphemeProgress(tMs: t, charStartMs: cs, effectiveDurationMs: du), f[7], ctx)
                eq("hop", EmphasisMath.hopEm(tMs: t, charStartMs: cs, effectiveDurationMs: du), f[8], ctx)
            case "sweep":
                eq("sweep", EmphasisMath.sweepEdgeCenterPx(leftPx: 10.5, rightPx: 117.25, fadePx: 24.6, p: fl(f[2])), f[3], ctx)
            case "alpha":
                let inactive = fl(f[2])
                let a = fl(f[3])
                eq("unsung", KaraokeAlpha.unsung(a, inactive: inactive), f[4], ctx)
                eq("sung", KaraokeAlpha.sung(a, inactive: inactive), f[5], ctx)
                eq("translation", KaraokeAlpha.translation(a), f[6], ctx)
            case "interlude":
                let g0 = Int64(f[2])!
                let g1 = Int64(f[3])!
                let t = Int64(f[4])!
                m.check(InterludeTimeline.isActive(tMs: t, g0: g0, g1: g1) == (f[5] == "1"), "isActive \(ctx)")
                eq("presence", InterludeTimeline.presence(tMs: t, g0: g0, g1: g1), f[6], ctx)
                eq("scale", InterludeTimeline.scale(tMs: t, g0: g0, g1: g1), f[7], ctx)
                eq("baseScale", InterludeTimeline.baseScale(tMs: t, g0: g0, g1: g1), f[8], ctx)
                for k in 0..<3 { eq("dot\(k)", InterludeTimeline.dotAlpha(tMs: t, g0: g0, g1: g1, k: k), f[9 + k], ctx) }
            case "gradeMatrix":
                for k in 0..<20 { eq("grade[\(k)]", LyricsBackgroundGrade.gradeMatrix[k], f[2 + k], "") }
            case "grade":
                let c = LyricsBackgroundGrade.gradeReference(fl(f[2]), fl(f[3]), fl(f[4]))
                eq("gradeR", c.r, f[5], ctx)
                eq("gradeG", c.g, f[6], ctx)
                eq("gradeB", c.b, f[7], ctx)
                eq("luma", LyricsBackgroundGrade.gradedLuma(fl(f[2]), fl(f[3]), fl(f[4])), f[8], ctx)
            case "boxRadii":
                let radii = SpriteBlur.boxRadiiForGaussian(fl(f[2]))
                m.check(radii == [Int(f[3])!, Int(f[4])!, Int(f[5])!], "boxRadii \(ctx): \(radii)")
            case "art":
                art = f.dropFirst(2).map { UInt32($0, radix: 16)! }
            case "bake":
                let px = SpriteBlur.bakeSprite(art: art, artSize: 12, pad: Int(f[2])!, sigma: fl(f[3]), opaque: f[4] == "1")
                let expected = f.dropFirst(5).map { UInt32($0, radix: 16)! }
                m.check(px.count == expected.count, "bake \(ctx): size \(px.count)")
                var diffs = 0
                for k in 0..<Swift.min(px.count, expected.count) {
                    // Each channel may round across .5 differently only when the float sums differ: allow ±1.
                    let a = px[k], b = expected[k]
                    for shift in stride(from: 0, through: 24, by: 8) {
                        let ca = Int((a >> UInt32(shift)) & 0xFF), cb = Int((b >> UInt32(shift)) & 0xFF)
                        if abs(ca - cb) > 1 { diffs += 1 }
                    }
                }
                m.check(diffs == 0, "bake \(ctx): \(diffs) channels off by more than 1")
            case "sprites":
                let w = Int(f[2])!, h = Int(f[3])!
                m.check(ArtworkSprites.aspectBucket(width: w, height: h) == Int(f[4])!, "aspectBucket \(ctx)")
                for k in 0..<4 { eq("spriteArtSize\(k)", ArtworkSprites.spriteArtSize(k, width: Float(w), height: Float(h)), f[5 + k], ctx) }
            case "sanitize":
                let raw = EngineFixture.unescape(f[2])
                let a = LyricsSheetLogic.sanitizeLyricLineText(raw)
                let b = LyricsSheetLogic.stripLrcTimestamps(raw)
                m.check(a.isIdentical(to: EngineFixture.unescape(f[3])), "sanitize [\(raw)]: [\(a)]")
                m.check(b.isIdentical(to: EngineFixture.unescape(f[4])), "strip [\(raw)]: [\(b)]")
            case "counts":
                let text = EngineFixture.unescape(f[2])
                m.check(PreparedLyricsBuilder.graphemeCount(text) == Int(f[3])!, "graphemeCount [\(text)]")
                m.check(PreparedLyricsBuilder.estimateWordCount(text) == Int(f[4])!, "estimateWordCount [\(text)]")
                m.check(EmphasisMath.graphemeBoundaries(text) == f.dropFirst(5).map { Int($0)! }, "graphemeBoundaries [\(text)]")
            case "shaping":
                let text = EngineFixture.unescape(f[2])
                m.check(LyricsRenderMetrics.needsShapedPieces(text) == (f[3] == "1"), "needsShapedPieces [\(text)]")
                m.check(LyricsRenderMetrics.isRtlText(text) == (f[4] == "1"), "isRtlText [\(text)]")
            default:
                Issue.record("unknown maths line \(f[1])")
            }
        }
        #expect(m.checked > 20_000)
        #expect(m.count == 0, "\(m.count) of \(m.checked) maths checks differ from Android")
    }
}
