import Foundation
import Testing
import PixlModel
@testable import PixlAudioCore

/// Compares the Swift ports against vectors produced by the Android app's compiled classes on the JVM
/// (`tools/android-reference/AudioGen.java`, fixture `audio-android-golden.txt`): `envelope`, the crossfade gain
/// expression, `ReplayGainManager`, the focus-resume rule, `Fft`, `CtcAlignmentCore` and `MidSideVocalProcessor`.
/// Float results must be bit-identical except where libm is involved (`cos` in the S-curve, `pow` in ReplayGain),
/// which may differ by an ulp or two between Java and the platform C library.
@Suite("Android golden vectors (audio)")
struct AudioGoldenTests {
    static let lines: [Substring] = {
        guard let url = Bundle.module.url(forResource: "audio-android-golden", withExtension: "txt", subdirectory: "Fixtures"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").filter { !$0.hasPrefix("//") }
    }()

    static func lines(_ tag: String) -> [[Substring]] {
        lines.filter { $0.hasPrefix(tag + " ") }.map { $0.split(separator: " ", omittingEmptySubsequences: false) }
    }

    static func float(_ token: Substring) -> Float { Float(bitPattern: UInt32(token.dropFirst(2), radix: 16)!) }

    static func curve(_ token: Substring) -> TransitionCurve { TransitionCurve(rawValue: String(token))! }

    static func same(_ a: Float, _ b: Float, ulps: Float = 0) -> Bool {
        if a.bitPattern == b.bitPattern { return true }
        if a.isNaN && b.isNaN { return true }
        if ulps == 0 || a.isNaN || b.isNaN { return false }
        return abs(a - b) <= max(ulps * b.ulp, Float.leastNormalMagnitude)
    }

    @Test func fixtureIsPresent() {
        #expect(Self.lines.count > 9000)
    }

    @Test func envelopeMatchesAndroid() {
        var exact = 0
        let rows = Self.lines("E")
        #expect(rows.count == 4 * 1320)
        for f in rows {
            let expected = Self.float(f[3])
            let actual = TransitionEnvelope.envelope(Self.float(f[2]), Self.curve(f[1]))
            #expect(Self.same(actual, expected, ulps: f[1] == "S_CURVE" ? 2 : 0), "\(f)")
            if actual.bitPattern == expected.bitPattern || (actual.isNaN && expected.isNaN) { exact += 1 }
        }
        #expect(exact >= rows.count - 20)
    }

    @Test func crossfadeGainsMatchAndroid() {
        let rows = Self.lines("C")
        #expect(rows.count == 8 * 16 * 12)
        for f in rows {
            let settings = TransitionSettings(mode: .overlap, durationMs: Int(f[1])!, curveIn: Self.curve(f[3]),
                                              curveOut: Self.curve(f[4]))
            let run = CrossfadeRun(settings: settings, outgoingStartVolume: Self.float(f[5]))
            let target: Float? = f[6] == "-" ? nil : Self.float(f[6])
            let gains = run.gains(elapsedMs: Int64(f[2])!, incomingTarget: target)
            let sCurve = f[3] == "S_CURVE" || f[4] == "S_CURVE"
            #expect(Self.same(gains.incoming, Self.float(f[7]), ulps: sCurve ? 2 : 0), "\(f)")
            #expect(Self.same(gains.outgoing, Self.float(f[8]), ulps: sCurve ? 2 : 0), "\(f)")
        }
    }

    @Test func replayGainVolumeMatchesAndroid() {
        let rows = Self.lines("G")
        #expect(!rows.isEmpty)
        var exact = 0
        for f in rows {
            let expected = Self.float(f[3])
            let actual = ReplayGain.gainDbToVolume(Self.float(f[1]), preAmpDb: Self.float(f[2]))
            #expect(Self.same(actual, expected, ulps: 2), "\(f)")
            if actual.bitPattern == expected.bitPattern { exact += 1 }
        }
        #expect(exact >= rows.count * 9 / 10)

        for f in Self.lines("M") {
            if f[1] == "null" {
                #expect(ReplayGain.volumeMultiplier(nil, useAlbumGain: false, preAmpDb: 0) == Self.float(f[4]))
                continue
            }
            let values = ReplayGainValues(trackGainDb: f[1] == "-" ? nil : Self.float(f[1]),
                                          albumGainDb: f[2] == "-" ? nil : Self.float(f[2]))
            let actual = ReplayGain.volumeMultiplier(values, useAlbumGain: f[3] == "true", preAmpDb: Self.float(f[4]))
            #expect(Self.same(actual, Self.float(f[5]), ulps: 2), "\(f)")
        }
    }

    @Test func replayGainParsingMatchesAndroid() {
        let rows = Self.lines("P")
        #expect(rows.count == 94)
        for f in rows {
            let input: String
            if f[1] == "-" {
                input = ""
            } else {
                var bytes: [UInt8] = []
                var i = f[1].startIndex
                while i < f[1].endIndex {
                    let j = f[1].index(i, offsetBy: 2)
                    bytes.append(UInt8(f[1][i..<j], radix: 16)!)
                    i = j
                }
                input = String(decoding: bytes, as: UTF8.self)
            }
            let actual = ReplayGain.parseGainString(input)
            if f[2] == "null" {
                #expect(actual == nil, "\(input.debugDescription) → \(String(describing: actual))")
            } else {
                let expected = Self.float(f[2])
                #expect(actual.map { Self.same($0, expected) } == true,
                        "\(input.debugDescription) → \(String(describing: actual)), Android \(expected)")
            }
        }
    }

    @Test func focusResumeRuleMatchesAndroid() {
        let rows = Self.lines("R")
        #expect(rows.count == 32)
        for f in rows {
            let b = f[1...5].map { $0 == "true" }
            #expect(AudioFocusResumePolicy.shouldResumeAfterTransientLoss(
                masterPlayWhenReady: b[0], masterIsPlaying: b[1], transitionRunning: b[2],
                auxiliaryPlayWhenReady: b[3], auxiliaryIsPlaying: b[4]) == (f[6] == "true"))
        }
    }

    @Test func fftMatchesAndroidBitForBit() throws {
        let rows = Self.lines("T")
        #expect(rows.count == 38)
        for f in rows {
            let n = Int(f[1])!
            let inverse = f[2] == "true"
            var re = (0..<n).map { Self.float(f[3 + $0]) }
            var im = (0..<n).map { Self.float(f[3 + n + $0]) }
            #expect(f[3 + 2 * n] == "->")
            let base = 4 + 2 * n
            var wr = re, wi = im
            Fft.transform(re: &re, im: &im, inverse: inverse)
            var workspace = try Fft.Workspace(size: n)
            try workspace.transform(re: &wr, im: &wi, inverse: inverse)
            var mismatches = 0
            for i in 0..<n {
                let er = Self.float(f[base + i]), ei = Self.float(f[base + n + i])
                if re[i].bitPattern != er.bitPattern || im[i].bitPattern != ei.bitPattern { mismatches += 1 }
                #expect(wr[i].bitPattern == re[i].bitPattern && wi[i].bitPattern == im[i].bitPattern)
            }
            #expect(mismatches == 0, "size \(n) inverse \(inverse): \(mismatches) of \(n) bins differ")
        }
    }

    @Test func ctcWindowsMatchAndroid() {
        let rows = Self.lines("W")
        #expect(rows.count == 58)
        for f in rows {
            let samples = Int(f[1])!
            let expected = f.dropFirst(2).filter { !$0.isEmpty }.map { token -> CtcAlignmentCore.Window in
                let p = token.split(separator: ",").map { Int($0)! }
                return CtcAlignmentCore.Window(firstFrame: p[0], endFrame: p[1], inputStartSample: p[2], inputEndSample: p[3])
            }
            #expect(CtcAlignmentCore.windows(sampleCount: samples) == expected, "samples \(samples)")
        }
    }

    @Test func ctcAlignmentMatchesAndroid() throws {
        let rows = Self.lines("A")
        #expect(rows.count == 402)
        var aligned = 0
        for f in rows {
            if f.contains("SIZE") {
                let frames = Int(f[2])!, length = Int(f[4])!
                let logProbs = [[Float]](repeating: [], count: frames)
                var tooLong = false
                do { _ = try CtcAlignmentCore.align(logProbs: logProbs, extended: [Int](repeating: 0, count: length)) }
                catch CtcAlignmentError.tooLong { tooLong = true }
                catch {}
                #expect(tooLong == (f.last == "THROW"), "\(frames)×\(length)")
                continue
            }
            let blank = Int(f[1])!, frames = Int(f[2])!, vocab = Int(f[3])!, length = Int(f[4])!
            var index = 5
            var logProbs: [[Float]] = []
            for _ in 0..<frames {
                logProbs.append((0..<vocab).map { Self.float(f[index + $0]) })
                index += vocab
            }
            let extended = (0..<length).map { Int(f[index + $0])! }
            index += length
            #expect(f[index] == "->")
            let expected = f[(index + 1)...]
            let path = try CtcAlignmentCore.align(logProbs: logProbs, extended: extended, blankId: blank)
            if expected.first == "null" {
                #expect(path == nil, "\(f.prefix(5))")
            } else {
                #expect(path == expected.map { Int($0)! }, "\(f.prefix(5))")
                aligned += 1
            }
            // The flat-buffer entry point agrees.
            let flat = logProbs.flatMap { $0 }
            let flatPath = try flat.withUnsafeBufferPointer {
                try CtcAlignmentCore.align(logProbs: $0, vocabularySize: vocab, extended: extended, blankId: blank)
            }
            if frames > 0 { #expect(flatPath == path) }
        }
        #expect(aligned > 100)
    }

    @Test func wordEvidenceMatchesAndroid() {
        let rows = Self.lines("V")
        #expect(rows.count == 300)
        for f in rows {
            let arrow = f.firstIndex(of: "->")!
            let scores = f[1..<arrow].map { Self.float($0) }
            #expect(CtcAlignmentCore.acceptsWordEvidence(scores) == (f[arrow + 1] == "true"), "\(scores)")
        }
    }

    @Test func midSideMatchesAndroidBitForBit() {
        let rows = Self.lines("S")
        #expect(rows.count == 18)
        for f in rows {
            let isFloat = f[1] == "float"
            let attenuation = Self.float(f[2])
            let frames = Int(f[3])!
            let count = frames * 2
            #expect(f[4 + count] == "->")
            if isFloat {
                var samples = (0..<count).map { Self.float(f[4 + $0]) }
                let expected = (0..<count).map { Self.float(f[5 + count + $0]) }
                samples.withUnsafeMutableBufferPointer {
                    MidSideVocal.process($0.baseAddress!, frames: frames, attenuation: attenuation)
                }
                #expect(zip(samples, expected).allSatisfy { $0.bitPattern == $1.bitPattern }, "attenuation \(attenuation)")
                // Planar variant gives the same result.
                var left = (0..<frames).map { Self.float(f[4 + 2 * $0]) }
                var right = (0..<frames).map { Self.float(f[5 + 2 * $0]) }
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in
                        MidSideVocal.process(left: l.baseAddress!, right: r.baseAddress!, frames: frames, attenuation: attenuation)
                    }
                }
                for i in 0..<frames {
                    #expect(left[i].bitPattern == expected[2 * i].bitPattern)
                    #expect(right[i].bitPattern == expected[2 * i + 1].bitPattern)
                }
            } else {
                var samples = (0..<count).map { Int16(f[4 + $0])! }
                let expected = (0..<count).map { Int16(f[5 + count + $0])! }
                samples.withUnsafeMutableBufferPointer {
                    MidSideVocal.process($0.baseAddress!, frames: frames, attenuation: attenuation)
                }
                #expect(samples == expected, "attenuation \(attenuation)")
            }
        }
    }
}
