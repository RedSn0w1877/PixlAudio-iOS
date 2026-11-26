// Tempo and loudness measured on the phone from decoded audio (docs/brain-spec.md, 3.3 "Stage 5", 14 "Stage 5"). A
// transliteration of the Android `:brain` module's `AudioFeatures.kt`, operation by operation (`audiofeatures.jsonl`).
//
// The platform decodes a short window of a track (40 s from 20% in) to 16-bit PCM and feeds it here, block by block. Nothing is
// kept but a few small arrays sized from the window, allocated once per `Estimator`: the decoder loop allocates nothing per block.
//
// Pure and deterministic: `+ - * /`, `sqrt` and the functions of `BrainMath` only, sums in index order, so both apps give the
// same bits from the same samples. THE EXPRESSION ORDER IN THIS FILE IS THE DEFINITION.
//
// Tempo: three-band onset strength (one-pole splits at 200 Hz and 3 kHz; per band the log energy of each 5 ms hop, half-wave
// rectified difference, the low band counted `lowWeight` times), with its mean removed; the unbiased autocorrelation of that
// curve; a comb score per candidate tempo (1-4 beat lags, minus a part of the off-beat lags and of the thirds of a beat); a
// log-Gaussian preference around `priorBpm` that settles the octave; then a fine search around the winner with eight beat lags.
// Confidence (0...1000) is how far the winner's comb stands above the mean comb of the whole range.
//
// Loudness: ITU-R BS.1770 / EBU R128 integrated loudness, approximately: the K-weighting filter (pyloudnorm's biquad formulas at the
// actual rate), mean square per 100 ms, 400 ms blocks with 75% overlap, the absolute gate at -70 LUFS and the relative gate 10 LU
// below. Every channel weighs 1. The brain stores LUFS x 10, which runs in the same direction as Deezer's `gain`.

public enum AudioFeatures {
    /// Bumped when anything here changes a result: cached measurements of an older version are measured again.
    public static let version = 1

    /// Where the window starts, as a share of the track, and how long it is.
    public static let windowStartPermille: Int64 = 200
    public static let windowMs = 40_000
    /// Shorter than this and the tempo is not trusted.
    public static let minTempoMs = 12_000
    /// Loudness needs at least one gated block.
    public static let minLoudnessMs = 3_000

    /// A measured tempo replaces Deezer's from this confidence up.
    public static let trustConf = 550
    /// Below this a measured tempo is not kept at all (a held tone, noise).
    public static let weakConf = 250

    public static let minBpm = 50.0
    public static let maxBpm = 220.0
    public static let priorBpm = 120.0
    /// Width of the octave preference in octaves.
    public static let priorOctaves = 1.1

    /// Hops per second (the hop is `sampleRate / hopRate` samples, integer division).
    public static let hopRate = 200

    /// No loudness (silence, or too short). Same value as `TrackDna.gainUnknown`.
    public static let loudnessUnknown = TrackDna.gainUnknown

    static let pi = Double(bitPattern: 0x4009_21FB_5444_2D18)
    static let ln10 = BrainMath.ln(10.0)

    public struct Result: Sendable, Equatable {
        /// Tempo x 10; 0 when not measured.
        public var bpmX10: Int
        /// 0...1000.
        public var tempoConf: Int
        /// Integrated loudness in LUFS x 10, or `loudnessUnknown`.
        public var lufsX10: Int
        /// How much audio was analysed.
        public var analysedMs: Int
        /// The standard deviation of the onset curve x 1000; 0 when not measured.
        public var onsetX1000: Int
        public var version: Int

        public init(bpmX10: Int, tempoConf: Int, lufsX10: Int, analysedMs: Int, onsetX1000: Int = 0,
                    version: Int = AudioFeatures.version) {
            self.bpmX10 = bpmX10
            self.tempoConf = tempoConf
            self.lufsX10 = lufsX10
            self.analysedMs = analysedMs
            self.onsetX1000 = onsetX1000
            self.version = version
        }

        public var tempoTrusted: Bool { bpmX10 > 0 && tempoConf >= AudioFeatures.trustConf }
        public var loudnessKnown: Bool { lufsX10 != AudioFeatures.loudnessUnknown }
    }

    /// `tan(x)` for `0 <= x < 0.8` by its Taylor series (the K-filter needs `tan(pi f / fs)`, at most 0.13 at 40 kHz).
    public static func tanSmall(_ x: Double) -> Double {
        let x2 = x * x
        let p = 1.0 + x2 * (t3 + x2 * (t5 + x2 * (t7 + x2 * (t9 + x2 * (t11 + x2 * (t13 + x2 * t15))))))
        return x * p
    }

    static let t3 = 1.0 / 3.0
    static let t5 = 2.0 / 15.0
    static let t7 = 17.0 / 315.0
    static let t9 = 62.0 / 2835.0
    static let t11 = 1382.0 / 155925.0
    static let t13 = 21844.0 / 6081075.0
    static let t15 = 929569.0 / 638512875.0

    /// 10 log10(x) and 10^(db/20), through `BrainMath`.
    static func db10(_ x: Double) -> Double { 10.0 * (BrainMath.ln(x) / ln10) }
    static func undb20(_ db: Double) -> Double { BrainMath.exp(db / 20.0 * ln10) }

    /// One biquad, direct form I, with its state.
    struct Biquad {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var x1 = 0.0
        var x2 = 0.0
        var y1 = 0.0
        var y2 = 0.0

        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = b0
            self.b1 = b1
            self.b2 = b2
            self.a1 = a1
            self.a2 = a2
        }

        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// The BS.1770 pre-filter (high shelf, +4 dB above about 1.7 kHz).
    static func shelf(_ sampleRate: Int) -> Biquad {
        let g = 3.99984385397
        let q = 0.7071752369554193
        let fc = 1681.974450955533
        let k = tanSmall(pi * fc / Double(sampleRate))
        let vh = undb20(g)
        let vb = BrainMath.exp(0.499666774155 * BrainMath.ln(vh))
        let a0 = 1.0 + k / q + k * k
        return Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2.0 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2.0 * (k * k - 1.0) / a0,
            a2: (1.0 - k / q + k * k) / a0
        )
    }

    /// The BS.1770 RLB high-pass (about 38 Hz).
    static func highPass(_ sampleRate: Int) -> Biquad {
        let q = 0.5003270373253953
        let fc = 38.13547087613982
        let k = tanSmall(pi * fc / Double(sampleRate))
        let a0 = 1.0 + k / q + k * k
        return Biquad(b0: 1.0, b1: -2.0, b2: 1.0, a1: 2.0 * (k * k - 1.0) / a0, a2: (1.0 - k / q + k * k) / a0)
    }

    static let floorEnergy = 1e-9
    /// The low band (kick, bass) carries the beat; the others carry subdivisions too.
    public static let lowWeight = 4.0
    /// How much the off-beat lags count against a tempo.
    public static let offbeatW = 0.35
    /// How much the lags at a third and two thirds of a beat count against it.
    public static let thirdW = 0.3
    static let third1 = 1.0 / 3.0
    static let third2 = 2.0 / 3.0
    /// Below this onset strength the tempo has no confidence.
    public static let onsetFloor = 0.05

    /// Streams PCM in, one result out. `sampleRate` 8,000 to 192,000, `channels` 1 or more (interleaved). At most `maxMs` of audio
    /// is read; the rest is ignored. Not thread-safe; one per window.
    public final class Estimator {
        public let sampleRate: Int
        public let channels: Int
        private let ok: Bool
        private let hop: Int
        private let frameRate: Double
        private let maxFrames: Int
        private let sub: Int

        private let aLow: Double
        private let aMid: Double
        private var lp1 = 0.0
        private var lp2 = 0.0
        private var eLow = 0.0
        private var eMid = 0.0
        private var eHigh = 0.0
        private var inHop = 0
        private var prevLow = 0.0
        private var prevMid = 0.0
        private var prevHigh = 0.0
        private var hops = 0
        private var flux: [Double]

        private var shelves: [Biquad]
        private var highs: [Biquad]
        private var subSum = 0.0
        private var inSub = 0
        private var subs = 0
        private var subPower: [Double]

        private var frames = 0

        public init(sampleRate: Int, channels: Int, maxMs: Int = AudioFeatures.windowMs + 5_000) {
            self.sampleRate = sampleRate
            self.channels = channels
            let ok = sampleRate >= 8_000 && sampleRate <= 192_000 && channels >= 1
            self.ok = ok
            let hop = ok ? sampleRate / AudioFeatures.hopRate : 1
            self.hop = hop
            frameRate = ok ? Double(sampleRate) / Double(hop) : 1.0
            let maxFrames = ok ? Int((Int64(maxMs) * Int64(sampleRate)) / 1000) : 0
            self.maxFrames = maxFrames
            let sub = ok ? sampleRate / 10 : 1
            self.sub = sub
            flux = [Double](repeating: 0.0, count: maxFrames / hop + 1)
            subPower = [Double](repeating: 0.0, count: maxFrames / sub + 1)
            aLow = 1.0 - BrainMath.exp(-2.0 * AudioFeatures.pi * 200.0 / Double(sampleRate))
            aMid = 1.0 - BrainMath.exp(-2.0 * AudioFeatures.pi * 3000.0 / Double(sampleRate))
            let n = ok ? channels : 0
            shelves = (0..<n).map { _ in AudioFeatures.shelf(sampleRate) }
            highs = (0..<n).map { _ in AudioFeatures.highPass(sampleRate) }
        }

        /// Interleaved 16-bit samples: `count` frames from `offset` (in samples).
        public func feed(_ pcm: UnsafeBufferPointer<Int16>, offset: Int, count: Int) {
            if !ok { return }
            var i = offset
            var f = 0
            while f < count && frames < maxFrames {
                var mono = 0.0
                var c = 0
                var power = 0.0
                while c < channels {
                    let x = Double(pcm[i + c]) / 32768.0
                    mono += x
                    let y = highs[c].run(shelves[c].run(x))
                    power += y * y
                    c += 1
                }
                sample(mono / Double(channels), power)
                i += channels
                f += 1
            }
        }

        public func feed(_ pcm: [Int16], offset: Int, count: Int) {
            pcm.withUnsafeBufferPointer { feed($0, offset: offset, count: count) }
        }

        /// Interleaved samples in [-1, 1].
        public func feed(_ pcm: UnsafeBufferPointer<Float>, offset: Int, count: Int) {
            if !ok { return }
            var i = offset
            var f = 0
            while f < count && frames < maxFrames {
                var mono = 0.0
                var c = 0
                var power = 0.0
                while c < channels {
                    let x = Double(pcm[i + c])
                    mono += x
                    let y = highs[c].run(shelves[c].run(x))
                    power += y * y
                    c += 1
                }
                sample(mono / Double(channels), power)
                i += channels
                f += 1
            }
        }

        public func feed(_ pcm: [Float], offset: Int, count: Int) {
            pcm.withUnsafeBufferPointer { feed($0, offset: offset, count: count) }
        }

        /// True once `maxMs` has been read: the caller may stop decoding.
        public var full: Bool { frames >= maxFrames }

        private func sample(_ m: Double, _ power: Double) {
            frames += 1
            lp1 += aLow * (m - lp1)
            lp2 += aMid * (m - lp2)
            let low = lp1
            let mid = lp2 - lp1
            let high = m - lp2
            eLow += low * low
            eMid += mid * mid
            eHigh += high * high
            inHop += 1
            if inHop == hop {
                let n = Double(hop)
                let l = BrainMath.ln(eLow / n + AudioFeatures.floorEnergy)
                let md = BrainMath.ln(eMid / n + AudioFeatures.floorEnergy)
                let h = BrainMath.ln(eHigh / n + AudioFeatures.floorEnergy)
                if hops > 0 && hops < flux.count {
                    var v = 0.0
                    if l > prevLow { v += AudioFeatures.lowWeight * (l - prevLow) }
                    if md > prevMid { v += md - prevMid }
                    if h > prevHigh { v += h - prevHigh }
                    flux[hops] = v
                }
                prevLow = l; prevMid = md; prevHigh = h
                if hops < flux.count { hops += 1 }
                eLow = 0.0; eMid = 0.0; eHigh = 0.0
                inHop = 0
            }
            subSum += power
            inSub += 1
            if inSub == sub {
                if subs < subPower.count {
                    subPower[subs] = subSum / Double(sub)
                    subs += 1
                }
                subSum = 0.0
                inSub = 0
            }
        }

        public func finish() -> Result {
            let analysedMs = ok ? Int((Int64(frames) * 1000) / Int64(sampleRate)) : 0
            let lufs = analysedMs >= AudioFeatures.minLoudnessMs ? loudness() : AudioFeatures.loudnessUnknown
            var bpmX10 = 0
            var conf = 0
            var onset = 0
            if analysedMs >= AudioFeatures.minTempoMs {
                let t = tempo()
                bpmX10 = t.0
                conf = t.1
                onset = t.2
            }
            return Result(bpmX10: bpmX10, tempoConf: conf, lufsX10: lufs, analysedMs: analysedMs, onsetX1000: onset)
        }

        // MARK: Loudness

        private func loudness() -> Int {
            if subs < 4 { return AudioFeatures.loudnessUnknown }
            let blocks = subs - 3
            var z = [Double](repeating: 0.0, count: blocks)
            for b in 0..<blocks { z[b] = (subPower[b] + subPower[b + 1] + subPower[b + 2] + subPower[b + 3]) / 4.0 }
            // Absolute gate: -70 LUFS, i.e. z > 10^((-70 + 0.691) / 10).
            let absGate = BrainMath.exp((-70.0 + 0.691) / 10.0 * AudioFeatures.ln10)
            var sum = 0.0
            var n = 0
            for b in 0..<blocks where z[b] > absGate {
                sum += z[b]
                n += 1
            }
            if n == 0 { return AudioFeatures.loudnessUnknown }
            let ungated = -0.691 + AudioFeatures.db10(sum / Double(n))
            let relGate = BrainMath.exp((ungated - 10.0 + 0.691) / 10.0 * AudioFeatures.ln10)
            var sum2 = 0.0
            var n2 = 0
            for b in 0..<blocks where z[b] > absGate && z[b] > relGate {
                sum2 += z[b]
                n2 += 1
            }
            if n2 == 0 { return AudioFeatures.loudnessUnknown }
            let lufs = -0.691 + AudioFeatures.db10(sum2 / Double(n2))
            return Int(BrainMath.floorToLong(BrainMath.clip(lufs, -99.0, 9.0) * 10.0 + 0.5))
        }

        // MARK: Tempo

        /// `(bpmX10, conf, onsetX1000)`.
        private func tempo() -> (Int, Int, Int) {
            let n = hops
            if n < 64 { return (0, 0, 0) }
            // The onset curve without its mean.
            var mean = 0.0
            for t in 1..<n { mean += flux[t] }
            mean /= Double(n - 1)
            var o = [Double](repeating: 0.0, count: n)
            for t in 1..<n { o[t] = flux[t] - mean }
            // Autocorrelation up to eight beats at the slowest tempo the fine search reads.
            let maxLag = Swift.min(n - 32, Int(8.0 * 60.0 * frameRate / (AudioFeatures.minBpm - 2.0)) + 2)
            if maxLag < Int(60.0 * frameRate / AudioFeatures.minBpm) + 2 { return (0, 0, 0) }
            var r = [Double](repeating: 0.0, count: maxLag + 1)
            o.withUnsafeBufferPointer { ob in
                for lag in 0...maxLag {
                    var s = 0.0
                    var t = 1
                    let end = n - lag
                    while t < end {
                        s += ob[t] * ob[t + lag]
                        t += 1
                    }
                    r[lag] = s / Double(end - 1)
                }
            }
            let r0 = r[0]
            if !(r0 > 0.0) { return (0, 0, 0) }

            // Coarse: every half BPM, four beats, times the octave preference.
            var best = 0.0
            var bestScore = 0.0
            var first = true
            var combSum = 0.0
            var combN = 0
            var bestComb = 0.0
            var b = AudioFeatures.minBpm
            while b <= AudioFeatures.maxBpm {
                let c = AudioFeatures.comb(r, maxLag, 60.0 * frameRate / b, 4) / r0
                let s = c * AudioFeatures.prior(b)
                combSum += c
                combN += 1
                if first || s > bestScore {
                    best = b
                    bestScore = s
                    bestComb = c
                    first = false
                }
                b += 0.5
            }
            if bestComb <= 0.0 { return (0, 0, 0) }

            // Fine: +-1.5 BPM every 0.02 with eight beats, no preference (the octave is settled).
            var fine = best
            var fineScore = 0.0
            first = true
            var k = -75
            while k <= 75 {
                let bb = best + Double(k) * 0.02
                if bb >= AudioFeatures.minBpm - 2.0 {
                    let c = AudioFeatures.comb(r, maxLag, 60.0 * frameRate / bb, 8)
                    if first || c > fineScore {
                        fine = bb
                        fineScore = c
                        first = false
                    }
                }
                k += 1
            }
            let meanComb = combSum / Double(combN)
            // A curve with almost no onsets (a held tone, a drone) has an autocorrelation of rounding noise: nothing to trust.
            let strength = BrainMath.sqrt(r0)
            let conf = strength < AudioFeatures.onsetFloor ? 0.0 : BrainMath.clip((bestComb - meanComb) * 2.5, 0.0, 1.0)
            return (
                Int(BrainMath.floorToLong(fine * 10.0 + 0.5)),
                Int(BrainMath.floorToLong(conf * 1000.0 + 0.5)),
                Int(BrainMath.floorToLong(BrainMath.clip(strength, 0.0, 1000.0) * 1000.0 + 0.5))
            )
        }
    }

    /// The autocorrelation at a fractional lag, by linear interpolation; 0 past the end.
    static func at(_ r: [Double], _ maxLag: Int, _ lag: Double) -> Double {
        if lag < 0.0 { return 0.0 }
        let i = Int(BrainMath.floorToLong(lag))
        if i + 1 > maxLag { return 0.0 }
        let f = lag - Double(i)
        return r[i] * (1.0 - f) + r[i + 1] * f
    }

    /// Mean of the autocorrelation at 1...`beats` beat lags, minus `offbeatW` times the mean at the off-beat lags between them,
    /// minus `thirdW` times the mean at the thirds of a beat.
    static func comb(_ r: [Double], _ maxLag: Int, _ period: Double, _ beats: Int) -> Double {
        var on = 0.0
        var off = 0.0
        var third = 0.0
        var k = 1
        while k <= beats {
            let kd = Double(k)
            on += at(r, maxLag, period * kd)
            off += at(r, maxLag, period * (kd - 0.5))
            third += at(r, maxLag, period * (kd - third1)) + at(r, maxLag, period * (kd - third2))
            k += 1
        }
        return (on - offbeatW * off - thirdW * 0.5 * third) / Double(beats)
    }

    /// `exp(-0.5 (log2(b / priorBpm) / priorOctaves)^2)`.
    static func prior(_ bpm: Double) -> Double {
        let o = BrainMath.log2(bpm / priorBpm) / priorOctaves
        return BrainMath.exp(-0.5 * o * o)
    }

    /// Where the decode window starts for a track of `durationMs`: 20% in, but never so late that it runs off the end.
    public static func windowStartMs(_ durationMs: Int64) -> Int64 {
        if durationMs <= 0 { return 0 }
        let start = durationMs * windowStartPermille / 1000
        let latest = durationMs - Int64(windowMs)
        return latest <= 0 ? 0 : Swift.min(start, latest)
    }

    /// The tempo the DNA keeps (3.2 `tempoBpmX10`, `tempoSource`): a trusted measurement first, then Deezer's, then an untrusted
    /// measurement rather than nothing.
    public static func chooseTempo(_ deezerBpmX10: Int, _ measured: Result?) -> (bpmX10: Int, source: Int) {
        if let m = measured, m.tempoTrusted { return (m.bpmX10, TrackDna.tempoOnDevice) }
        if deezerBpmX10 > 0 { return (deezerBpmX10, TrackDna.tempoDeezer) }
        if let m = measured, m.bpmX10 > 0 && m.tempoConf >= weakConf { return (m.bpmX10, TrackDna.tempoOnDeviceWeak) }
        return (0, TrackDna.tempoUnknown)
    }

    /// The loudness the DNA keeps: Deezer's `gain` when it has one, the measurement otherwise.
    public static func chooseGain(_ deezerGainX10: Int, _ measured: Result?) -> (gainDbX10: Int, measured: Int) {
        if deezerGainX10 != TrackDna.gainUnknown { return (deezerGainX10, 0) }
        if let m = measured, m.loudnessKnown { return (m.lufsX10, 1) }
        return (TrackDna.gainUnknown, 0)
    }
}
