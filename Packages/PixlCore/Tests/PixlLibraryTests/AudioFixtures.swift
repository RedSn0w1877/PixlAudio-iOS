@testable import PixlLibrary

/// Synthetic PCM for the stage 5 estimator (`audiofeatures.jsonl`): click tracks and drum grooves at known tempos, sine tones at known
/// levels, and noise. A transliteration of the Android `:brain` test source `AudioFixtures.kt`, operation by operation: it is the
/// definition of the samples, and every golden line carries the FNV-1a 64 of the 16-bit little-endian bytes to check this synth first.
enum AudioFixtures {
    static let kindClicks = "clicks"
    static let kindGroove = "groove"
    static let kindTone = "tone"
    static let kindNoise = "noise"

    struct Spec: Sendable {
        let kind: String
        let sampleRate: Int
        let channels: Int
        let seconds: Int
        /// Clicks and grooves: tempo x 10. Tone: frequency in Hz.
        let param: Int
        /// Peak level in dBFS x 10.
        let levelDbX10: Int
        let seed: Int64

        var name: String { "\(kind):\(param):\(levelDbX10):\(sampleRate):\(channels):\(seconds):\(seed)" }
    }

    static let pi = Double(bitPattern: 0x4009_21FB_5444_2D18)

    /// `sin x` and `cos x` for |x| <= pi by Taylor series to x^21 (fixtures only).
    static func sinT(_ x: Double) -> Double {
        let x2 = x * x
        var term = x
        var sum = x
        var k = 1
        while k <= 10 {
            term = -term * x2 / (Double(2 * k) * Double(2 * k + 1))
            sum += term
            k += 1
        }
        return sum
    }

    static func cosT(_ x: Double) -> Double {
        let x2 = x * x
        var term = 1.0
        var sum = 1.0
        var k = 1
        while k <= 10 {
            term = -term * x2 / (Double(2 * k - 1) * Double(2 * k))
            sum += term
            k += 1
        }
        return sum
    }

    /// `10^(db / 20)` through `BrainMath`.
    static func amplitude(_ dbX10: Int) -> Double { BrainMath.exp(Double(dbX10) / 200.0 * BrainMath.ln(10.0)) }

    /// Interleaved 16-bit samples: `x * 32767`, rounded half up, clipped to +-32767.
    static func render(_ spec: Spec) -> [Int16] {
        let frames = spec.sampleRate * spec.seconds
        var mono = [Double](repeating: 0.0, count: frames)
        var rng = BrainHash.Rng(seed: UInt64(bitPattern: spec.seed))
        let amp = amplitude(spec.levelDbX10)
        let fs = Double(spec.sampleRate)
        // A faint noise floor under the rhythmic fixtures (-60 dBFS), as real recordings have.
        let floor = amplitude(-600)
        switch spec.kind {
        case kindClicks:
            for n in 0..<frames { mono[n] = floor * (rng.uniform() * 2.0 - 1.0) }
            let period = 60.0 * fs * 10.0 / Double(spec.param)
            let len = spec.sampleRate / 100 // 10 ms bursts
            var beat = 0
            while true {
                let start = Int(BrainMath.floorToLong(Double(beat) * period + 0.5))
                if start >= frames { break }
                var env = amp
                var i = 0
                while i < len && start + i < frames {
                    mono[start + i] += env * (rng.uniform() * 2.0 - 1.0)
                    env *= 0.997
                    i += 1
                }
                beat += 1
            }
        case kindGroove:
            for n in 0..<frames { mono[n] = floor * (rng.uniform() * 2.0 - 1.0) }
            let period = 60.0 * fs * 10.0 / Double(spec.param)
            // Kick: a 60 Hz sine burst on every beat, 120 ms. Snare: noise on 2 and 4, 80 ms. Hats: high noise on every eighth, 20 ms.
            let w = 2.0 * pi * 60.0 / fs
            let c2 = 2.0 * cosT(w)
            let s1 = sinT(w)
            var eighth = 0
            while true {
                let start = Int(BrainMath.floorToLong(Double(eighth) * period * 0.5 + 0.5))
                if start >= frames { break }
                let onBeat = eighth % 2 == 0
                if onBeat {
                    let len = spec.sampleRate * 12 / 100
                    var y1 = 0.0
                    var y2 = 0.0
                    var env = amp
                    var i = 0
                    while i < len && start + i < frames {
                        let y = i == 0 ? 0.0 : (i == 1 ? s1 : c2 * y1 - y2)
                        mono[start + i] += env * y
                        y2 = y1; y1 = y
                        env *= 0.9995
                        i += 1
                    }
                    if (eighth / 2) % 2 == 1 {
                        let sl = spec.sampleRate * 8 / 100
                        var e = amp * 0.6
                        var j = 0
                        while j < sl && start + j < frames {
                            mono[start + j] += e * (rng.uniform() * 2.0 - 1.0)
                            e *= 0.9993
                            j += 1
                        }
                    }
                }
                let hl = spec.sampleRate / 50
                var e = amp * 0.25
                var prev = 0.0
                var j = 0
                while j < hl && start + j < frames {
                    let v = rng.uniform() * 2.0 - 1.0
                    mono[start + j] += e * (v - prev) * 0.5
                    prev = v
                    e *= 0.996
                    j += 1
                }
                eighth += 1
            }
        case kindTone:
            let w = 2.0 * pi * Double(spec.param) / fs
            let c2 = 2.0 * cosT(w)
            var y1 = 0.0
            var y2 = 0.0
            for n in 0..<frames {
                let y = n == 0 ? 0.0 : (n == 1 ? sinT(w) : c2 * y1 - y2)
                mono[n] = amp * y
                y2 = y1; y1 = y
            }
        case kindNoise:
            for n in 0..<frames { mono[n] = amp * (rng.uniform() * 2.0 - 1.0) }
        default:
            break
        }
        var out = [Int16](repeating: 0, count: frames * spec.channels)
        var k = 0
        for n in 0..<frames {
            var q = BrainMath.floorToLong(mono[n] * 32767.0 + 0.5)
            if q > 32767 { q = 32767 }
            if q < -32767 { q = -32767 }
            for _ in 0..<spec.channels {
                out[k] = Int16(q)
                k += 1
            }
        }
        return out
    }

    /// FNV-1a 64 over the samples as 16-bit little-endian bytes.
    static func hash(_ pcm: [Int16]) -> Int64 {
        var bytes = [UInt8](repeating: 0, count: pcm.count * 2)
        for i in 0..<pcm.count {
            let v = UInt16(bitPattern: pcm[i])
            bytes[2 * i] = UInt8(v & 0xFF)
            bytes[2 * i + 1] = UInt8(v >> 8)
        }
        return Int64(bitPattern: BrainHash.fnv1a64(bytes: bytes))
    }

    /// Runs the estimator on `pcm` in blocks of `block` frames, the way the app's decoder hands them over.
    static func estimate(_ spec: Spec, _ pcm: [Int16], block: Int = 4096) -> AudioFeatures.Result {
        let est = AudioFeatures.Estimator(sampleRate: spec.sampleRate, channels: spec.channels)
        let frames = pcm.count / spec.channels
        pcm.withUnsafeBufferPointer { buf in
            var f = 0
            while f < frames {
                let n = Swift.min(block, frames - f)
                est.feed(buf, offset: f * spec.channels, count: n)
                f += n
            }
        }
        return est.finish()
    }

    /// The fixture set of the golden file and of the accuracy test.
    static func specs() -> [Spec] {
        var out: [Spec] = []
        var seed: Int64 = 1
        func next() -> Int64 { defer { seed += 1 }; return seed }
        for bpm in [600, 750, 900, 1000, 1200, 1280, 1400, 1600, 1740] {
            out.append(Spec(kind: kindClicks, sampleRate: 44_100, channels: 2, seconds: 40, param: bpm, levelDbX10: -60, seed: next()))
        }
        out.append(Spec(kind: kindClicks, sampleRate: 48_000, channels: 1, seconds: 40, param: 1235, levelDbX10: -120, seed: next()))
        for bpm in [850, 1000, 1200, 1280, 1500] {
            out.append(Spec(kind: kindGroove, sampleRate: 44_100, channels: 2, seconds: 40, param: bpm, levelDbX10: -60, seed: next()))
        }
        out.append(Spec(kind: kindGroove, sampleRate: 48_000, channels: 2, seconds: 30, param: 965, levelDbX10: -90, seed: next()))
        // EBU R128: a stereo 1 kHz sine at -23 dBFS reads -23 LUFS; the K-filter barely touches 1 kHz.
        out.append(Spec(kind: kindTone, sampleRate: 48_000, channels: 2, seconds: 20, param: 1000, levelDbX10: -230, seed: next()))
        out.append(Spec(kind: kindTone, sampleRate: 44_100, channels: 2, seconds: 20, param: 1000, levelDbX10: -180, seed: next()))
        out.append(Spec(kind: kindTone, sampleRate: 44_100, channels: 2, seconds: 20, param: 1000, levelDbX10: -100, seed: next()))
        out.append(Spec(kind: kindTone, sampleRate: 48_000, channels: 1, seconds: 20, param: 1000, levelDbX10: -230, seed: next()))
        out.append(Spec(kind: kindTone, sampleRate: 44_100, channels: 2, seconds: 20, param: 100, levelDbX10: -200, seed: next()))
        out.append(Spec(kind: kindTone, sampleRate: 44_100, channels: 2, seconds: 20, param: 5000, levelDbX10: -200, seed: next()))
        out.append(Spec(kind: kindNoise, sampleRate: 44_100, channels: 2, seconds: 30, param: 0, levelDbX10: -200, seed: next()))
        out.append(Spec(kind: kindNoise, sampleRate: 44_100, channels: 2, seconds: 2, param: 0, levelDbX10: -200, seed: next()))
        return out
    }

    struct Rendered: Sendable {
        let spec: Spec
        let pcmHash: Int64
        let samples: Int
        let result: AudioFeatures.Result
    }

    /// Every fixture rendered and measured once per test run (rendering is the slow part, and two suites read it).
    static let rendered: [Rendered] = specs().map { spec in
        let pcm = render(spec)
        return Rendered(spec: spec, pcmHash: hash(pcm), samples: pcm.count, result: estimate(spec, pcm))
    }
}
