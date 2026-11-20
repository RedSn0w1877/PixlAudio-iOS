// Tap detection (Song Tap): two phones touching is seen as a sudden, sustained jump of the other phone's signal strength
// above its recent baseline, backed by a sharp jerk on either phone. Never a fixed dBm. A transliteration of
// `SongTapDetector.kt`.
//
// Why relative: the same tap reads very differently on different phones (antenna, case, the three advertising channels
// differ by up to 15 dB), so the detector compares a peer with itself a moment ago. The only absolute numbers are
// `nearEnterDbm` and `nearExitDbm`, a loose floor for "this peer is within reach" that decides the Near state and gates
// a fire; they are not the tap threshold.
//
// Every number is a named constant so the diagnostics screen (Developer mode > Song Tap diagnostics) can show them next
// to the live signal and the owner can calibrate on the real phones. All arithmetic is in integers (signal in 1/256 dB)
// so this and the Android version match bit for bit.

public enum SongTapTuning {
    /// The baseline is a slow average: alpha = 1 / 2^baselineShift per sample.
    public static let baselineShift = 3

    /// The fast average the jump is read from: alpha = 1 / 2^fastShift per sample.
    public static let fastShift = 1

    /// A jump of at least this many dB above the baseline starts a candidate tap.
    public static let jumpDb = 15

    /// While the signal is this far above the baseline the baseline stops following it, so a tap is not absorbed.
    public static let freezeDb = 6

    /// The jump must hold this long, with a jerk on either phone close by.
    public static let holdMs: Int64 = 150

    /// Without a jerk, the jump must hold this long (a gentle tap).
    public static let dwellMs: Int64 = 400

    /// ...and the smoothed signal must also be at least this strong. A slow approach, or a phone that raises its transmit
    /// power, can make a 15 dB jump at arm's length; only a phone that is right there reads this strong. A jump that is
    /// not this strong still fires with a jerk (the loose near floor above). Calibrate on the real phones.
    public static let dwellMinDbm = -58

    /// A jump that has held this long without firing is the new normal level, not a tap: the baseline catches up to it
    /// (otherwise a phone parked at a new distance would keep the baseline frozen for good).
    public static let freezeMaxMs: Int64 = 2_000

    /// A jerk counts when it was within this long of the moment the jump has been held.
    public static let impulseWindowMs: Int64 = 400

    /// After a fire, no new fire for this long.
    public static let cooldownMs: Int64 = 2_000

    /// Within reach (loose): the smoothed signal rises above this to become Near.
    public static let nearEnterDbm = -70

    /// And falls below this to stop being Near.
    public static let nearExitDbm = -78

    /// Samples this far apart (ms) reset the detector for the peer: it was gone.
    public static let gapResetMs: Int64 = 3_000

    /// Glow: the smoothed signal at which it starts and at which it is full.
    public static let glowMinDbm = -80
    public static let glowMaxDbm = -45

    /// Accelerometer: the change between two readings (milli g, all three axes) that counts as a jerk.
    public static let jerkMilliG = 1_800

    /// After a jerk, the next one is ignored for this long.
    public static let jerkDebounceMs: Int64 = 300
}

public let songTapRssiScale = 256

public enum SongTapFireReason: String, Sendable {
    case none = "none"
    case impulse = "impulse"
    case dwell = "dwell"

    public var code: String { rawValue }
}

/// One reading of a peer's signal strength, `tMs` on this phone's monotonic clock.
public struct SongTapRssiSample: Sendable, Equatable {
    public var tMs: Int64
    public var rssi: Int

    public init(tMs: Int64, rssi: Int) {
        self.tMs = tMs
        self.rssi = rssi
    }
}

/// The detector's memory for one peer. `baselineQ` and `fastQ` are dBm times 256; `heldSinceMs` is when the signal first
/// went `SongTapTuning.jumpDb` above the baseline and has stayed there (-1 when it has not).
public struct SongTapDetectorState: Sendable, Equatable {
    public var started: Bool
    public var lastMs: Int64
    public var baselineQ: Int
    public var fastQ: Int
    public var near: Bool
    public var heldSinceMs: Int64
    public var lastFireMs: Int64

    public init(started: Bool, lastMs: Int64, baselineQ: Int, fastQ: Int, near: Bool, heldSinceMs: Int64, lastFireMs: Int64) {
        self.started = started
        self.lastMs = lastMs
        self.baselineQ = baselineQ
        self.fastQ = fastQ
        self.near = near
        self.heldSinceMs = heldSinceMs
        self.lastFireMs = lastFireMs
    }

    public static let initial = SongTapDetectorState(started: false, lastMs: -1, baselineQ: 0, fastQ: 0, near: false, heldSinceMs: -1, lastFireMs: -1)
}

public struct SongTapDetectorStep: Sendable, Equatable {
    public var state: SongTapDetectorState
    public var fire: SongTapFireReason
    /// The glow strength 0...500 (permille of full alpha) for the approach, from the smoothed signal.
    public var glowPermille: Int
}

public enum SongTapDetector {
    /// Feeds one `sample`. `impulseMs` is the latest jerk, own or the peer's converted to this clock, or -1.
    public static func step(_ state: SongTapDetectorState, _ sample: SongTapRssiSample, impulseMs: Int64) -> SongTapDetectorStep {
        let sampleQ = sample.rssi * songTapRssiScale
        var s = state
        if !s.started || (s.lastMs >= 0 && sample.tMs - s.lastMs > SongTapTuning.gapResetMs) {
            s = SongTapDetectorState(started: true, lastMs: sample.tMs, baselineQ: sampleQ, fastQ: sampleQ, near: false, heldSinceMs: -1,
                              lastFireMs: s.lastFireMs)
        }
        let fastQ = s.fastQ + ((sampleQ - s.fastQ) >> SongTapTuning.fastShift)
        let deltaQ = fastQ - s.baselineQ
        var baselineQ: Int
        if deltaQ < SongTapTuning.freezeDb * songTapRssiScale {
            baselineQ = s.baselineQ + ((sampleQ - s.baselineQ) >> SongTapTuning.baselineShift)
        } else {
            baselineQ = s.baselineQ
        }
        let fastDbm = floorDiv(fastQ, songTapRssiScale)
        let near = s.near ? fastDbm >= SongTapTuning.nearExitDbm : fastDbm >= SongTapTuning.nearEnterDbm
        var held = s.heldSinceMs
        if deltaQ >= SongTapTuning.jumpDb * songTapRssiScale {
            held = held < 0 ? sample.tMs : held
        } else {
            held = -1
        }

        var fire = SongTapFireReason.none
        var lastFire = s.lastFireMs
        let cooled = lastFire < 0 || sample.tMs - lastFire >= SongTapTuning.cooldownMs
        if held >= 0 && near && cooled {
            let heldFor = sample.tMs - held
            let jerkNear = impulseMs >= 0 && absDiff(sample.tMs, impulseMs) <= SongTapTuning.impulseWindowMs
            if heldFor >= SongTapTuning.holdMs && jerkNear {
                fire = .impulse
            } else if heldFor >= SongTapTuning.dwellMs && fastDbm >= SongTapTuning.dwellMinDbm {
                fire = .dwell
            }
        }
        if fire != .none {
            lastFire = sample.tMs
            held = -1
            // The phones stay together after a tap: the signal stays high, so the baseline must catch up or the same
            // contact would fire again as soon as the cooldown ends.
            baselineQ = fastQ
        } else if held >= 0 && sample.tMs - held >= SongTapTuning.freezeMaxMs {
            held = -1
            baselineQ = fastQ
        }
        let next = SongTapDetectorState(started: true, lastMs: sample.tMs, baselineQ: baselineQ, fastQ: fastQ, near: near, heldSinceMs: held,
                                 lastFireMs: lastFire)
        return SongTapDetectorStep(state: next, fire: fire, glowPermille: glowPermille(fastQ))
    }

    /// 0...500 from the smoothed signal: nothing at `glowMinDbm`, half strength at `glowMaxDbm`.
    public static func glowPermille(_ fastQ: Int) -> Int {
        let lo = SongTapTuning.glowMinDbm * songTapRssiScale
        let hi = SongTapTuning.glowMaxDbm * songTapRssiScale
        if fastQ <= lo { return 0 }
        if fastQ >= hi { return 500 }
        return Int(Int64(fastQ - lo) * 500 / Int64(hi - lo))
    }

    public static func floorDiv(_ a: Int, _ b: Int) -> Int {
        var q = a / b
        if a % b != 0 && ((a < 0) != (b < 0)) { q -= 1 }
        return q
    }

    private static func absDiff(_ a: Int64, _ b: Int64) -> Int64 { a >= b ? a - b : b - a }
}

/// One accelerometer reading in milli g, `tMs` on this phone's monotonic clock.
public struct SongTapAccelSample: Sendable, Equatable {
    public var tMs: Int64
    public var xMg: Int
    public var yMg: Int
    public var zMg: Int

    public init(tMs: Int64, xMg: Int, yMg: Int, zMg: Int) {
        self.tMs = tMs
        self.xMg = xMg
        self.yMg = yMg
        self.zMg = zMg
    }
}

/// The accelerometer's memory: the previous reading and the last jerk time.
public struct SongTapImpulseState: Sendable, Equatable {
    public var hasPrevious: Bool
    public var prev: SongTapAccelSample
    public var lastImpulseMs: Int64

    public init(hasPrevious: Bool, prev: SongTapAccelSample, lastImpulseMs: Int64) {
        self.hasPrevious = hasPrevious
        self.prev = prev
        self.lastImpulseMs = lastImpulseMs
    }

    public static let initial = SongTapImpulseState(hasPrevious: false, prev: SongTapAccelSample(tMs: 0, xMg: 0, yMg: 0, zMg: 0), lastImpulseMs: -1)
}

public struct SongTapImpulseStep: Sendable, Equatable {
    public var state: SongTapImpulseState
    public var impulse: Bool
}

/// A sharp jerk is a large change between two consecutive readings, on any axis combination.
public enum SongTapImpulse {
    public static func step(_ state: SongTapImpulseState, _ sample: SongTapAccelSample) -> SongTapImpulseStep {
        if !state.hasPrevious {
            return SongTapImpulseStep(state: SongTapImpulseState(hasPrevious: true, prev: sample, lastImpulseMs: state.lastImpulseMs), impulse: false)
        }
        let dx = Int64(sample.xMg - state.prev.xMg)
        let dy = Int64(sample.yMg - state.prev.yMg)
        let dz = Int64(sample.zMg - state.prev.zMg)
        let jerk = Int64(SongTapTuning.jerkMilliG)
        let strong = dx * dx + dy * dy + dz * dz >= jerk * jerk
        let debounced = state.lastImpulseMs >= 0 && sample.tMs - state.lastImpulseMs < SongTapTuning.jerkDebounceMs
        let hit = strong && !debounced
        return SongTapImpulseStep(state: SongTapImpulseState(hasPrevious: true, prev: sample, lastImpulseMs: hit ? sample.tMs : state.lastImpulseMs),
                           impulse: hit)
    }
}
