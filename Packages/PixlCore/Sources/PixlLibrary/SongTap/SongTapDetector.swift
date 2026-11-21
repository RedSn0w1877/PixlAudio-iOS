// Tap detection (Song Tap): two phones touching is seen as a sudden, sustained jump of the other phone's signal strength
// above its recent baseline, optionally backed by a sharp jerk on either phone. Never a fixed dBm. A transliteration of
// `SongTapDetector.kt` (spec 6).
//
// Why relative: the same tap reads very differently on different phones (antenna, case, the three advertising channels
// differ by up to 15 dB), so the detector compares a peer with itself a moment ago.
//
// The scale (spec 6). Every number here is on the iPhone's scale, the reference: touching reads about -33 dBm, resting 20
// to 30 cm apart about -60. An Android phone reads about 15 dB hotter for the same pose, so the Android app adds an offset
// to every raw reading before it reaches the core. On iOS the offset is 0: this phone IS the reference, its readings go
// to the core unchanged. The absolute numbers are the coarse gates: `nearEnterDbm` / `nearExitDbm` (a phone has to be this
// close before a receiver connects to it, before a sender serves it the song, before a tap can fire and before the other
// phone's tap message is believed), `listEnterDbm` / `listExitDbm` (the broader gate of the nearby phones list,
// advertisements only, never connects) and `closeHoldDbm` (a gentle hold, only a few cm away).
//
// The tuning that depends on how sensitive the listener wants the tap is a `SongTapSensitivity` profile: normal is the
// iPhone's tuning (unchanged since spec 4), high (the default) reacts to a smaller, shorter jump.
//
// Every number is a named constant so the diagnostics screen (Developer mode > Song Tap diagnostics) can show them next
// to the live signal. All arithmetic is in integers (signal in 1/256 dB) so this and the Android version match bit for bit.

public enum SongTapTuning {
    /// A jump without a jerk fires (the dwell path) only when the smoothed signal is also at least this strong.
    public static let dwellMinDbm = -58

    /// A jump that has held this long without firing is the new normal level, not a tap: the baseline catches up to it
    /// (otherwise a phone parked at a new distance would keep the baseline frozen for good).
    public static let freezeMaxMs: Int64 = 2_000

    /// The tap near gate, on the iPhone scale: the smoothed signal rises to this to become Near. Everything that costs
    /// something needs it: connecting, serving the offer, firing, believing the other phone's tap message.
    public static let nearEnterDbm = -70

    /// And falls below this to stop being Near (hysteresis).
    public static let nearExitDbm = -78

    /// The broader gate of the nearby phones list (the Song Drop picker). The list is built from advertisements only, with
    /// no connection, so a phone a couple of metres away may be listed; connecting and beaming still need the near gate.
    public static let listEnterDbm = -85
    public static let listExitDbm = -92

    /// A gentle hold: the phones are brought together (no bump) and held. The smoothed signal at or above this for
    /// `closeHoldMs` fires with reason hold, whatever the jump or the jerk did. Only inside the near gate. Touching reads
    /// about -33 and resting 20 to 30 cm apart about -60, so -45 means "within a few cm" and never "at rest".
    public static let closeHoldDbm = -45
    public static let closeHoldMs: Int64 = 250

    /// After a hold fired, the hold can fire again only once the smoothed signal has fallen below this.
    public static let closeReleaseDbm = -55

    /// Samples this far apart (ms) reset the detector for the peer: it was gone.
    public static let gapResetMs: Int64 = 3_000

    /// Glow: the smoothed signal at which it starts and at which it is full.
    public static let glowMinDbm = -80
    public static let glowMaxDbm = -45

    /// After a jerk, the next one is ignored for this long.
    public static let jerkDebounceMs: Int64 = 300
}

/// How sensitive the tap is (spec 6). `normal` is the tuning of the iPhone the owner calls perfect. `high`, the default, reads a
/// 9 dB jump held 200 ms (60 ms with a jerk of 900 milli g) as a tap and may fire again after 1.2 s. The jerk is only ever an
/// optional second factor, never required. Both ride the same gates; only how little it takes to fire differs.
public enum SongTapSensitivity: String, Sendable, CaseIterable {
    case normal, high

    public static let `default`: SongTapSensitivity = .high

    public var code: String { rawValue }

    /// The profile for a stored code; the default for anything else.
    public static func fromCode(_ code: String?) -> SongTapSensitivity {
        allCases.first { $0.code == code } ?? .default
    }

    /// The baseline is a slow average: alpha = 1 / 2^baselineShift per sample.
    public var baselineShift: Int { 3 }

    /// The fast average the jump is read from: alpha = 1 / 2^fastShift per sample.
    public var fastShift: Int { 1 }

    /// A jump of at least this many dB above the baseline starts a candidate tap.
    public var jumpDb: Int { self == .normal ? 15 : 9 }

    /// While the signal is this far above the baseline the baseline stops following it, so a tap is not absorbed.
    public var freezeDb: Int { 6 }

    /// The jump must hold this long, with a jerk on either phone close by.
    public var holdMs: Int64 { self == .normal ? 150 : 60 }

    /// Without a jerk, the jump must hold this long (a gentle tap).
    public var dwellMs: Int64 { self == .normal ? 400 : 200 }

    /// A jerk counts when it was within this long of the moment the jump has been held.
    public var impulseWindowMs: Int64 { 400 }

    /// The change between two accelerometer readings (milli g, all three axes) that counts as a jerk.
    public var jerkMilliG: Int { self == .normal ? 1_800 : 900 }

    /// After a fire, no new fire for this long.
    public var cooldownMs: Int64 { self == .normal ? 2_000 : 1_200 }
}

public let songTapRssiScale = 256

public enum SongTapFireReason: String, Sendable {
    case none = "none"
    case impulse = "impulse"
    case dwell = "dwell"
    case hold = "hold"

    public var code: String { rawValue }
}

/// One reading of a peer's signal strength (already on the iPhone scale), `tMs` on this phone's monotonic clock.
public struct SongTapRssiSample: Sendable, Equatable {
    public var tMs: Int64
    public var rssi: Int

    public init(tMs: Int64, rssi: Int) {
        self.tMs = tMs
        self.rssi = rssi
    }
}

/// The detector's memory for one peer. `baselineQ` and `fastQ` are dBm times 256; `heldSinceMs` is when the signal first
/// went `SongTapSensitivity.jumpDb` above the baseline and has stayed there (-1 when it has not). `closeSinceMs` is when the
/// smoothed signal first reached `SongTapTuning.closeHoldDbm` and has stayed there: -1 when it is not that strong,
/// `closeUsed` after a fire (it must drop below the release level before it can count again).
public struct SongTapDetectorState: Sendable, Equatable {
    public var started: Bool
    public var lastMs: Int64
    public var baselineQ: Int
    public var fastQ: Int
    public var near: Bool
    public var heldSinceMs: Int64
    public var lastFireMs: Int64
    public var closeSinceMs: Int64

    public init(started: Bool, lastMs: Int64, baselineQ: Int, fastQ: Int, near: Bool, heldSinceMs: Int64, lastFireMs: Int64,
                closeSinceMs: Int64 = -1) {
        self.started = started
        self.lastMs = lastMs
        self.baselineQ = baselineQ
        self.fastQ = fastQ
        self.near = near
        self.heldSinceMs = heldSinceMs
        self.lastFireMs = lastFireMs
        self.closeSinceMs = closeSinceMs
    }

    public static let initial = SongTapDetectorState(started: false, lastMs: -1, baselineQ: 0, fastQ: 0, near: false, heldSinceMs: -1,
                                                     lastFireMs: -1, closeSinceMs: -1)

    /// `closeSinceMs` after a fire: consumed until the signal falls below the release level.
    public static let closeUsed: Int64 = -2
}

public struct SongTapDetectorStep: Sendable, Equatable {
    public var state: SongTapDetectorState
    public var fire: SongTapFireReason
    /// The glow strength 0...500 (permille of full alpha) for the approach, from the smoothed signal.
    public var glowPermille: Int
}

public enum SongTapDetector {
    /// Feeds one `sample` (already on the iPhone scale: on iOS the raw reading as it is). `impulseMs` is the latest jerk, own
    /// or the peer's converted to this clock, or -1. `profile` is how sensitive the tap is; it may change between two
    /// samples (the next sample just uses the new one).
    public static func step(_ state: SongTapDetectorState, _ sample: SongTapRssiSample, impulseMs: Int64,
                            profile: SongTapSensitivity = .default) -> SongTapDetectorStep {
        let sampleQ = sample.rssi * songTapRssiScale
        var s = state
        if !s.started || (s.lastMs >= 0 && sample.tMs - s.lastMs > SongTapTuning.gapResetMs) {
            s = SongTapDetectorState(started: true, lastMs: sample.tMs, baselineQ: sampleQ, fastQ: sampleQ, near: false, heldSinceMs: -1,
                                     lastFireMs: s.lastFireMs, closeSinceMs: -1)
        }
        let fastQ = s.fastQ + ((sampleQ - s.fastQ) >> profile.fastShift)
        let deltaQ = fastQ - s.baselineQ
        var baselineQ: Int
        if deltaQ < profile.freezeDb * songTapRssiScale {
            baselineQ = s.baselineQ + ((sampleQ - s.baselineQ) >> profile.baselineShift)
        } else {
            baselineQ = s.baselineQ
        }
        let fastDbm = floorDiv(fastQ, songTapRssiScale)
        let near = s.near ? fastDbm >= SongTapTuning.nearExitDbm : fastDbm >= SongTapTuning.nearEnterDbm
        var held = s.heldSinceMs
        if deltaQ >= profile.jumpDb * songTapRssiScale {
            held = held < 0 ? sample.tMs : held
        } else {
            held = -1
        }

        // The hold timer: running while the smoothed signal is at the hold level. After a fire it is consumed (`closeUsed`) and
        // stays so until the phones have come apart (the signal fell below `closeReleaseDbm`), so one contact is one fire.
        var close = s.closeSinceMs
        if !near {
            close = -1
        } else if close == SongTapDetectorState.closeUsed {
            if fastDbm < SongTapTuning.closeReleaseDbm { close = -1 }
        } else if fastDbm >= SongTapTuning.closeHoldDbm {
            if close == -1 { close = sample.tMs }
        } else {
            close = -1
        }

        var fire = SongTapFireReason.none
        var lastFire = s.lastFireMs
        let cooled = lastFire < 0 || sample.tMs - lastFire >= profile.cooldownMs
        if held >= 0 && near && cooled {
            let heldFor = sample.tMs - held
            let jerkNear = impulseMs >= 0 && absDiff(sample.tMs, impulseMs) <= profile.impulseWindowMs
            if heldFor >= profile.holdMs && jerkNear {
                fire = .impulse
            } else if heldFor >= profile.dwellMs && fastDbm >= SongTapTuning.dwellMinDbm {
                fire = .dwell
            }
        }
        if fire == .none && near && cooled && close >= 0 && sample.tMs - close >= SongTapTuning.closeHoldMs {
            fire = .hold
        }
        if fire != .none {
            lastFire = sample.tMs
            held = -1
            close = SongTapDetectorState.closeUsed
            // The phones stay together after a tap: the signal stays high, so the baseline must catch up or the same
            // contact would fire again as soon as the cooldown ends.
            baselineQ = fastQ
        } else if held >= 0 && sample.tMs - held >= SongTapTuning.freezeMaxMs {
            held = -1
            baselineQ = fastQ
        }
        let next = SongTapDetectorState(started: true, lastMs: sample.tMs, baselineQ: baselineQ, fastQ: fastQ, near: near, heldSinceMs: held,
                                        lastFireMs: lastFire, closeSinceMs: close)
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
    public static func step(_ state: SongTapImpulseState, _ sample: SongTapAccelSample,
                            profile: SongTapSensitivity = .default) -> SongTapImpulseStep {
        if !state.hasPrevious {
            return SongTapImpulseStep(state: SongTapImpulseState(hasPrevious: true, prev: sample, lastImpulseMs: state.lastImpulseMs), impulse: false)
        }
        let dx = Int64(sample.xMg - state.prev.xMg)
        let dy = Int64(sample.yMg - state.prev.yMg)
        let dz = Int64(sample.zMg - state.prev.zMg)
        let jerk = Int64(profile.jerkMilliG)
        let strong = dx * dx + dy * dy + dz * dz >= jerk * jerk
        let debounced = state.lastImpulseMs >= 0 && sample.tMs - state.lastImpulseMs < SongTapTuning.jerkDebounceMs
        let hit = strong && !debounced
        return SongTapImpulseStep(state: SongTapImpulseState(hasPrevious: true, prev: sample, lastImpulseMs: hit ? sample.tMs : state.lastImpulseMs),
                           impulse: hit)
    }
}
