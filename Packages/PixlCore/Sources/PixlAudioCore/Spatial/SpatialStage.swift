// The on-device spatial stage (cloud audio spec of 2026-11-10, section 7, tables v1.1): stereo in, stereo out, at
// 44.1 or 48 kHz, from the coefficients of `spatial_preview_v1.json`. Per channel pair:
//
//     lo = LR4_lowpass(x, xoverHz)        two identical RBJ low-pass biquads (Q = 1/√2) in series, direct form I
//     hi = x - lo
//     rm = HP2(hi, roomHpHz)              one RBJ high-pass biquad (Q = 1/√2): the sparse room's input
//     yL = fir(hiL, direct) + fir(hiR, cross) + Σ sparseL: gainFromLeft·rmL[n-d] + gainFromRight·rmR[n-d]
//     yR = fir(hiR, direct) + fir(hiL, cross) + Σ sparseR: gainFromLeft·rmL[n-d] + gainFromRight·rmR[n-d]
//     out = gain · (y + lo[n - lowDelay]), then the soft limiter while the stage is active
//
// The reference is `process` in `cloud/runpod-worker/src/pixl_worker/spatial/preview.py`; the unit tests reproduce
// its golden file. Real-time rules: every buffer is allocated in `init`, `process` never allocates, locks or logs.
// The biquads run in Double (a 120 Hz low-pass in Float drifts from the reference); the FIRs and the room run on Float
// buffers, with vDSP where Accelerate exists and plain loops elsewhere (Windows and Linux run the tests on those).

#if canImport(Accelerate)
import Accelerate
#endif
import Foundation
import PixlModel

/// A biquad of the stage, a0 normalised to 1, as the reference designs it (`lowpass_coefficients`,
/// `highpass_coefficients`).
public struct SpatialBiquad: Sendable, Hashable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// Passes everything through unchanged.
    public static let identity = SpatialBiquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public var isIdentity: Bool { b0 == 1 && b1 == 0 && b2 == 0 && a1 == 0 && a2 == 0 }

    /// RBJ low-pass, Q = 1/√2.
    public static func lowpass(sampleRate: Double, cutoffHz: Double) -> SpatialBiquad {
        let w0 = 2.0 * Double.pi * cutoffHz / sampleRate
        let alpha = sin(w0) / (2.0 * (1.0 / 2.0.squareRoot()))
        let cos0 = cos(w0)
        let a0 = 1.0 + alpha
        return SpatialBiquad(b0: (1.0 - cos0) / 2.0 / a0, b1: (1.0 - cos0) / a0, b2: (1.0 - cos0) / 2.0 / a0,
                             a1: -2.0 * cos0 / a0, a2: (1.0 - alpha) / a0)
    }

    /// RBJ high-pass, Q = 1/√2. A cutoff of 0 or less is no filter at all (a table of the older shape).
    public static func highpass(sampleRate: Double, cutoffHz: Double) -> SpatialBiquad {
        guard cutoffHz > 0 else { return .identity }
        let w0 = 2.0 * Double.pi * cutoffHz / sampleRate
        let alpha = sin(w0) / (2.0 * (1.0 / 2.0.squareRoot()))
        let cos0 = cos(w0)
        let a0 = 1.0 + alpha
        return SpatialBiquad(b0: (1.0 + cos0) / 2.0 / a0, b1: -(1.0 + cos0) / a0, b2: (1.0 + cos0) / 2.0 / a0,
                             a1: -2.0 * cos0 / a0, a2: (1.0 - alpha) / a0)
    }
}

/// Direct form I state of one biquad (Double, as the reference).
struct SpatialBiquadState {
    var x1 = 0.0
    var x2 = 0.0
    var y1 = 0.0
    var y2 = 0.0

    @inline(__always)
    mutating func run(_ x: Double, _ c: SpatialBiquad) -> Double {
        let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}

/// One table as the stage reads it: plain pointers into `SpatialStageCoefficients`' storage.
struct SpatialStageTable {
    /// The FIRs reversed (`h[taps - 1 - p]`), so a correlation over the history is the convolution.
    var directReversed: UnsafeMutablePointer<Float>
    var crossReversed: UnsafeMutablePointer<Float>
    var taps: Int
    /// The left ear's room taps first, then the right ear's.
    var sparseLeftCount: Int
    var sparseRightCount: Int
    var sparseDelays: UnsafeMutablePointer<Int>
    var sparseFromLeft: UnsafeMutablePointer<Float>
    var sparseFromRight: UnsafeMutablePointer<Float>
    var lowDelay: Int
    var gain: Float
    var lowpass: SpatialBiquad
    var roomHighpass: SpatialBiquad
}

/// Every table of the file in the form the stage reads on the render thread: built once (it allocates), never changed
/// afterwards, shared by every stage. A change of profile is then an index change, never an allocation.
public final class SpatialStageCoefficients: @unchecked Sendable {
    /// The profiles in the order their indices count (`index(of:)`): the spec's order.
    public static let profiles: [SpatialProfile] = SpatialProfile.allCases
    /// The rates in the order their indices count.
    public static let sampleRates: [Int] = SpatialPreviewTables.sampleRates
    /// `profiles.count` and `sampleRates.count` as constants (the render thread reads no global arrays).
    public static var profileCount: Int { 6 }
    public static var rateCount: Int { 2 }

    /// The headroom built into every table's gain (4 dB): what the level rule gives back while the stage is heard.
    public let headroomDb: Double
    /// The longest FIR of any table.
    public let maxTaps: Int
    /// The longest sparse delay of any table.
    public let maxSparseDelay: Int

    private let tables: UnsafeMutablePointer<SpatialStageTable>
    private let tableCount: Int
    private let floats: UnsafeMutablePointer<Float>
    private let ints: UnsafeMutablePointer<Int>

    public init(_ source: SpatialPreviewTables) {
        headroomDb = source.headroomDb
        let profiles = Self.profiles, rates = Self.sampleRates
        var all: [SpatialPreviewTable] = []
        for profile in profiles {
            for rate in rates {
                // `decode` guarantees every profile at every rate; an empty table only stands in for a hand-built set.
                all.append(source.table(for: profile, sampleRate: rate)
                    ?? SpatialPreviewTable(xoverHz: 120, lowDelay: 0, taps: 1, direct: [0], cross: [0], sparseL: [],
                                           sparseR: [], gain: 1))
            }
        }
        var floatCount = 0, intCount = 0, longestTaps = 1, longestDelay = 0
        for table in all {
            let sparse = table.sparseL.count + table.sparseR.count
            floatCount += 2 * table.taps + 2 * sparse
            intCount += sparse
            longestTaps = max(longestTaps, table.taps)
            longestDelay = max(longestDelay, table.maxSparseDelay)
        }
        maxTaps = longestTaps
        maxSparseDelay = longestDelay
        floats = .allocate(capacity: max(floatCount, 1))
        floats.initialize(repeating: 0, count: max(floatCount, 1))
        ints = .allocate(capacity: max(intCount, 1))
        ints.initialize(repeating: 0, count: max(intCount, 1))
        tableCount = all.count
        tables = .allocate(capacity: all.count)
        var f = 0, n = 0
        for (index, table) in all.enumerated() {
            let rate = Double(rates[index % rates.count])
            let direct = floats + f
            for p in 0..<table.taps { direct[p] = Float(table.direct[table.taps - 1 - p]) }
            f += table.taps
            let cross = floats + f
            for p in 0..<table.taps { cross[p] = Float(table.cross[table.taps - 1 - p]) }
            f += table.taps
            let room = table.sparseL + table.sparseR
            let delays = ints + n
            let fromLeft = floats + f
            let fromRight = floats + f + room.count
            for (k, tap) in room.enumerated() {
                delays[k] = tap.delay
                fromLeft[k] = Float(tap.gainFromLeft)
                fromRight[k] = Float(tap.gainFromRight)
            }
            f += 2 * room.count
            n += room.count
            (tables + index).initialize(to: SpatialStageTable(
                directReversed: direct, crossReversed: cross, taps: table.taps,
                sparseLeftCount: table.sparseL.count, sparseRightCount: table.sparseR.count, sparseDelays: delays,
                sparseFromLeft: fromLeft, sparseFromRight: fromRight, lowDelay: table.lowDelay, gain: Float(table.gain),
                lowpass: .lowpass(sampleRate: rate, cutoffHz: table.xoverHz),
                roomHighpass: .highpass(sampleRate: rate, cutoffHz: table.roomHpHz)))
        }
    }

    deinit {
        tables.deinitialize(count: tableCount)
        tables.deallocate()
        floats.deallocate()
        ints.deallocate()
    }

    /// The index the stage takes for `profile` (0 …< 6).
    public static func index(of profile: SpatialProfile) -> Int {
        switch profile {
        case .studio: 0
        case .wide: 1
        case .intimate: 2
        case .hall: 3
        case .surround: 4
        case .night: 5
        }
    }

    /// The index of a supported rate (44.1 or 48 kHz within half a hertz), else nil: the stage is then bypassed.
    public static func rateIndex(_ sampleRate: Double) -> Int? {
        guard let rate = SpatialPreviewTables.supportedRate(sampleRate) else { return nil }
        return sampleRates.firstIndex(of: rate)
    }

    @inline(__always)
    func table(profileIndex: Int, rateIndex: Int) -> SpatialStageTable {
        tables[profileIndex * Self.rateCount + rateIndex]
    }
}

/// The stage of one item (one processing tap): its history, its room and its ramps. Nothing is shared between items
/// but the read-only coefficients.
///
/// Ramps (spec 7: never a click). The output is `(1 − m)·dry + m·level·wet` with `m = engaged × swap`:
/// - `engaged` moves over 80 ms towards 1 while a profile is wanted and towards 0 when the stage is bypassed;
/// - a change of profile while engaged takes `swap` down to 0 over 40 ms, swaps the coefficients and brings it back up
///   over 40 ms: about 80 ms from one profile to the other, through the dry sound for an instant;
/// - `dry` is the input delayed by `lowDelay`, which lines it up with the wet sound's centre. An item that has not been
///   delayed yet (the stage was never fully on in it) fades from its undelayed input instead: switching the delay on
///   under the sound would be the click. Once the stage has been fully on, the delay stays for the rest of the item.
/// A stage that starts with a profile wanted (the item's first buffer) starts fully on, from silence: that is the
/// reference's zero state.
public final class SpatialStage: @unchecked Sendable {
    /// The most frames processed in one pass (longer buffers are processed in parts).
    public static let chunkFrames = 512
    /// The time of a full engage or bypass (a change of profile takes the same, half down and half up).
    public static let rampSeconds = 0.08
    /// The target that bypasses the stage.
    public static let bypass = -1

    public let sampleRate: Int
    public let coefficients: SpatialStageCoefficients
    /// Every output sample goes through `SoftLimiter` (−1 dBFS) while the stage is active (spec 7). Off only in the
    /// golden tests, which compare the stage before the limiter.
    public var limits = true

    private let rateIndex: Int
    private let accelerated: Bool
    /// Samples of history before the current part (`maxTaps − 1`).
    private let history: Int
    private let span: Int
    private let storage: UnsafeMutablePointer<Float>
    private let storageCount: Int
    private let xL: UnsafeMutablePointer<Float>, xR: UnsafeMutablePointer<Float>
    private let hiL: UnsafeMutablePointer<Float>, hiR: UnsafeMutablePointer<Float>
    private let loL: UnsafeMutablePointer<Float>, loR: UnsafeMutablePointer<Float>
    private let yL: UnsafeMutablePointer<Float>, yR: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    private let roomL: UnsafeMutablePointer<Float>, roomR: UnsafeMutablePointer<Float>
    /// The room's ring: a power of two at least the longest sparse delay plus one part.
    public let ringCapacity: Int
    private let ringMask: Int
    private var ringWrite = 0

    private var lowL1 = SpatialBiquadState(), lowL2 = SpatialBiquadState(), roomFilterL = SpatialBiquadState()
    private var lowR1 = SpatialBiquadState(), lowR2 = SpatialBiquadState(), roomFilterR = SpatialBiquadState()

    // Ramps and state.
    private let engageStep: Float
    private let swapStep: Float
    private var started = false
    private var target = SpatialStage.bypass
    private var current = SpatialStage.bypass
    private var engaged: Float = 0
    private var swap: Float = 1
    private var swapping = false
    private var dryDelay = 0
    private var wetWarm = false
    private var wetLevel: Float = 1
    /// The first buffer takes its level as it is (no ramp from an earlier value that was never heard).
    private var levelSet = false

    /// A stage for `sampleRate`, or nil at a rate the stage does not take (anything but 44.1 or 48 kHz).
    /// `accelerated`: vDSP where Accelerate exists (false runs the portable loops everywhere; tests compare the two).
    public init?(coefficients: SpatialStageCoefficients, sampleRate: Double, accelerated: Bool = true) {
        guard let rateIndex = SpatialStageCoefficients.rateIndex(sampleRate) else { return nil }
        let rate = SpatialStageCoefficients.sampleRates[rateIndex]
        self.coefficients = coefficients
        self.rateIndex = rateIndex
        self.sampleRate = rate
        self.accelerated = accelerated
        history = coefficients.maxTaps - 1
        span = history + Self.chunkFrames
        var capacity = 1
        while capacity < coefficients.maxSparseDelay + Self.chunkFrames + 1 { capacity <<= 1 }
        ringCapacity = capacity
        ringMask = capacity - 1
        storageCount = 6 * span + 3 * Self.chunkFrames + 2 * capacity
        storage = .allocate(capacity: storageCount)
        storage.initialize(repeating: 0, count: storageCount)
        var p = storage
        func take(_ count: Int) -> UnsafeMutablePointer<Float> {
            defer { p += count }
            return p
        }
        xL = take(span); xR = take(span)
        hiL = take(span); hiR = take(span)
        loL = take(span); loR = take(span)
        yL = take(Self.chunkFrames); yR = take(Self.chunkFrames); scratch = take(Self.chunkFrames)
        roomL = take(capacity); roomR = take(capacity)
        let rampFrames = Float(Self.rampSeconds * Double(rate))
        engageStep = 1 / rampFrames
        swapStep = 2 / rampFrames
    }

    deinit {
        storage.deallocate()
    }

    // MARK: State seen from outside (any thread may read; the owner's thread writes)

    /// How far the stage is engaged now: 0 bypassed … 1 fully on.
    public var engagement: Float { engaged }
    /// The profile index whose coefficients run now (−1 before the stage first ran).
    public var currentProfile: Int { current }
    /// The wet path runs (the stage is active, or ramping).
    public var isActive: Bool { wetWarm }
    /// The input is delayed by `lowDelay` (the stage has been fully on in this item).
    public var isDelayed: Bool { dryDelay > 0 }

    // MARK: Processing (the render thread: no allocation, locks or logging)

    /// Step one of a buffer: takes the wanted profile (`0 …< 6`, see `SpatialStageCoefficients.index(of:)`, or
    /// `bypass`) and answers how engaged the stage is at the buffer's first and last frame, so the caller can fade the
    /// effects the stage replaces (the old stereo width) along the same ramp. The first call of an item jumps straight
    /// to the target.
    @discardableResult
    public func begin(frames: Int, target wanted: Int) -> (start: Float, end: Float) {
        let target = wanted >= 0 && wanted < SpatialStageCoefficients.profileCount ? wanted : Self.bypass
        if !started {
            started = true
            if target >= 0 {
                current = target
                engaged = 1
                swap = 1
                wetWarm = true
                dryDelay = coefficients.table(profileIndex: target, rateIndex: rateIndex).lowDelay
            }
        }
        self.target = target
        let start = engaged
        let distance = engageStep * Float(max(frames, 0))
        let end = target >= 0 ? min(1, start + distance) : max(0, start - distance)
        return (start, end)
    }

    /// Step two: processes `frames` stereo frames in place (`stride` 2 for interleaved, 1 for planar channels).
    /// `wetLevel` multiplies the spatial sound only (the level rule, spec 6.3); it moves linearly from the previous
    /// buffer's value across this one.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, stride: Int,
                        frames: Int, wetLevel newLevel: Float = 1) {
        guard frames > 0, started else { return }
        let level = newLevel.isFinite ? max(newLevel, 0) : 1
        let levelFrom = levelSet ? wetLevel : level
        wetLevel = level
        levelSet = true
        var done = 0
        while done < frames {
            let n = min(Self.chunkFrames, frames - done)
            let l0 = levelFrom + (level - levelFrom) * Float(done) / Float(frames)
            let l1 = levelFrom + (level - levelFrom) * Float(done + n) / Float(frames)
            processPart(left: left + done * stride, right: right + done * stride, stride: stride, n: n,
                        levelFrom: l0, levelTo: l1)
            done += n
        }
    }

    /// Forgets the sound so far (a seek: the room must not ring with the old position). The ramps stay where they are.
    public func reset() {
        storage.update(repeating: 0, count: storageCount)
        clearFilters()
        ringWrite = 0
    }

    private func clearFilters() {
        lowL1 = SpatialBiquadState(); lowL2 = SpatialBiquadState(); roomFilterL = SpatialBiquadState()
        lowR1 = SpatialBiquadState(); lowR2 = SpatialBiquadState(); roomFilterR = SpatialBiquadState()
    }

    /// Starts the wet path from silence (it was idle: its history is stale).
    private func warmUp() {
        let h = history
        hiL.update(repeating: 0, count: h)
        hiR.update(repeating: 0, count: h)
        loL.update(repeating: 0, count: h)
        loR.update(repeating: 0, count: h)
        roomL.update(repeating: 0, count: ringCapacity)
        roomR.update(repeating: 0, count: ringCapacity)
        clearFilters()
        ringWrite = 0
        wetWarm = true
    }

    private func processPart(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, stride: Int,
                             n: Int, levelFrom: Float, levelTo: Float) {
        let target = self.target
        // What runs in this part.
        if target >= 0 {
            if !wetWarm {
                // Idle until now: the new profile starts at once (nothing wet is heard yet).
                current = target
                swapping = false
                swap = 1
                // The dry path needs its history only once the delay is on; start it clean too.
                if dryDelay == 0 {
                    xL.update(repeating: 0, count: history)
                    xR.update(repeating: 0, count: history)
                }
                warmUp()
            } else if swapping {
                if target == current {
                    swapping = false
                } else if swap <= 0 {
                    current = target
                    swapping = false
                }
            } else if target != current {
                swapping = true
            }
        } else if swapping {
            swapping = false
        }
        if !wetWarm && dryDelay == 0 { return }   // bypassed and never delayed: untouched

        let h = history
        var i = 0
        var s = 0
        while i < n {
            xL[h + i] = left[s]
            xR[h + i] = right[s]
            i += 1
            s += stride
        }

        // `current` is a profile whenever the wet path runs (and whenever the input is delayed).
        let table = coefficients.table(profileIndex: max(current, 0), rateIndex: rateIndex)
        if wetWarm {
            runFilters(table, n: n)
            let offset = h - (table.taps - 1)
            fir(hiL + offset, table.directReversed, taps: table.taps, into: yL, n: n)
            fir(hiR + offset, table.crossReversed, taps: table.taps, into: scratch, n: n)
            add(scratch, into: yL, n: n)
            fir(hiR + offset, table.directReversed, taps: table.taps, into: yR, n: n)
            fir(hiL + offset, table.crossReversed, taps: table.taps, into: scratch, n: n)
            add(scratch, into: yR, n: n)
            addRoom(into: yL, delays: table.sparseDelays, fromLeft: table.sparseFromLeft,
                    fromRight: table.sparseFromRight, count: table.sparseLeftCount, n: n)
            let right0 = table.sparseLeftCount
            addRoom(into: yR, delays: table.sparseDelays + right0, fromLeft: table.sparseFromLeft + right0,
                    fromRight: table.sparseFromRight + right0, count: table.sparseRightCount, n: n)
            add(loL + h - table.lowDelay, into: yL, n: n)
            add(loR + h - table.lowDelay, into: yR, n: n)
            scale(yL, by: table.gain, n: n)
            scale(yR, by: table.gain, n: n)
        }

        // Mix, ramps and the limiter.
        let engageTarget: Float = target >= 0 ? 1 : 0
        let swapTarget: Float = swapping ? 0 : 1
        let steady = engaged == engageTarget && swap == swapTarget && levelFrom == levelTo
        let limiting = limits && wetWarm
        let dryOffset = h - dryDelay
        let levelStep = (levelTo - levelFrom) / Float(n)
        i = 0
        s = 0
        if wetWarm && steady && engaged == 1 && swap == 1 {
            // Fully on (the common case): the wet sound alone.
            let g = levelTo
            while i < n {
                var outL = g == 1 ? yL[i] : g * yL[i]
                var outR = g == 1 ? yR[i] : g * yR[i]
                if limiting {
                    outL = SoftLimiter.limit(outL)
                    outR = SoftLimiter.limit(outR)
                }
                left[s] = outL
                right[s] = outR
                i += 1
                s += stride
            }
        } else if !wetWarm {
            // Bypassed after having been on: the input, still delayed by `lowDelay` (no jump in the delay).
            while i < n {
                left[s] = xL[dryOffset + i]
                right[s] = xR[dryOffset + i]
                i += 1
                s += stride
            }
        } else {
            while i < n {
                engaged = engaged < engageTarget ? min(engageTarget, engaged + engageStep)
                                                 : max(engageTarget, engaged - engageStep)
                swap = swap < swapTarget ? min(swapTarget, swap + swapStep) : max(swapTarget, swap - swapStep)
                let m = engaged * swap
                let g = m * (levelFrom + levelStep * Float(i + 1))
                var outL = (1 - m) * xL[dryOffset + i] + g * yL[i]
                var outR = (1 - m) * xR[dryOffset + i] + g * yR[i]
                if limiting {
                    outL = SoftLimiter.limit(outL)
                    outR = SoftLimiter.limit(outR)
                }
                left[s] = outL
                right[s] = outR
                i += 1
                s += stride
            }
        }

        // Keep the last `history` samples for the next part.
        shiftHistory(xL, n: n)
        shiftHistory(xR, n: n)
        if wetWarm {
            shiftHistory(hiL, n: n)
            shiftHistory(hiR, n: n)
            shiftHistory(loL, n: n)
            shiftHistory(loR, n: n)
            ringWrite = (ringWrite + n) & ringMask
            if engaged >= 1 && swap >= 1 {
                // Fully on: the dry sound is lined up with the wet one from now on (switching the delay is silent here).
                dryDelay = table.lowDelay
            }
            if engaged <= 0 && target < 0 {
                // Fully bypassed: the wet path rests until a profile is wanted again.
                wetWarm = false
            }
        }
    }

    /// The crossover and the room's high-pass for one part: `hi`, `lo` into their histories, `rm` into the ring.
    @inline(__always)
    private func runFilters(_ table: SpatialStageTable, n: Int) {
        let h = history
        let low = table.lowpass, room = table.roomHighpass
        let filtersRoom = !room.isIdentity
        var w = ringWrite
        for i in 0..<n {
            let x0 = Double(xL[h + i])
            let lo0 = lowL2.run(lowL1.run(x0, low), low)
            let hi0 = x0 - lo0
            loL[h + i] = Float(lo0)
            hiL[h + i] = Float(hi0)
            roomL[w] = Float(filtersRoom ? roomFilterL.run(hi0, room) : hi0)
            let x1 = Double(xR[h + i])
            let lo1 = lowR2.run(lowR1.run(x1, low), low)
            let hi1 = x1 - lo1
            loR[h + i] = Float(lo1)
            hiR[h + i] = Float(hi1)
            roomR[w] = Float(filtersRoom ? roomFilterR.run(hi1, room) : hi1)
            w = (w + 1) & ringMask
        }
    }

    /// `out[i] = Σ_p signal[i + p] · reversed[p]`: the FIR over the history (the signal starts `taps − 1` samples
    /// before the part).
    @inline(__always)
    private func fir(_ signal: UnsafeMutablePointer<Float>, _ reversed: UnsafeMutablePointer<Float>, taps: Int,
                     into out: UnsafeMutablePointer<Float>, n: Int) {
        #if canImport(Accelerate)
        if accelerated {
            vDSP_conv(signal, 1, reversed, 1, out, 1, vDSP_Length(n), vDSP_Length(taps))
            return
        }
        #endif
        for i in 0..<n {
            var sum: Float = 0
            let base = signal + i
            for p in 0..<taps { sum += base[p] * reversed[p] }
            out[i] = sum
        }
    }

    /// The sparse room of one ear: every tap reads the ring `delay` samples back (in at most two runs, where the ring
    /// wraps) and adds both channels' room input.
    @inline(__always)
    private func addRoom(into y: UnsafeMutablePointer<Float>, delays: UnsafeMutablePointer<Int>,
                         fromLeft: UnsafeMutablePointer<Float>, fromRight: UnsafeMutablePointer<Float>, count: Int,
                         n: Int) {
        for k in 0..<count {
            var start = (ringWrite - delays[k]) & ringMask
            var done = 0
            while done < n {
                let run = min(n - done, ringCapacity - start)
                #if canImport(Accelerate)
                if accelerated {
                    vDSP_vsma(roomL + start, 1, fromLeft + k, y + done, 1, y + done, 1, vDSP_Length(run))
                    vDSP_vsma(roomR + start, 1, fromRight + k, y + done, 1, y + done, 1, vDSP_Length(run))
                    done += run
                    start = 0
                    continue
                }
                #endif
                let gl = fromLeft[k], gr = fromRight[k]
                for j in 0..<run { y[done + j] += gl * roomL[start + j] + gr * roomR[start + j] }
                done += run
                start = 0
            }
        }
    }

    @inline(__always)
    private func add(_ source: UnsafeMutablePointer<Float>, into y: UnsafeMutablePointer<Float>, n: Int) {
        #if canImport(Accelerate)
        if accelerated {
            vDSP_vadd(source, 1, y, 1, y, 1, vDSP_Length(n))
            return
        }
        #endif
        for i in 0..<n { y[i] += source[i] }
    }

    @inline(__always)
    private func scale(_ y: UnsafeMutablePointer<Float>, by gain: Float, n: Int) {
        #if canImport(Accelerate)
        if accelerated {
            var g = gain
            vDSP_vsmul(y, 1, &g, y, 1, vDSP_Length(n))
            return
        }
        #endif
        for i in 0..<n { y[i] *= gain }
    }

    /// Moves the last `history` samples to the front (the two regions overlap: `copyMemory` is a memmove).
    @inline(__always)
    private func shiftHistory(_ buffer: UnsafeMutablePointer<Float>, n: Int) {
        UnsafeMutableRawPointer(buffer).copyMemory(from: UnsafeRawPointer(buffer + n),
                                                   byteCount: history * MemoryLayout<Float>.stride)
    }
}
