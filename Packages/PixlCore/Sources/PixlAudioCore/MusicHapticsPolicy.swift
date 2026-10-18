// Music Haptics, the rules half: when the Taptic Engine may play along, what each detected event becomes, and how
// often it may fire. Pure values so the app (and the tests) decide the same way.

import Foundation
import PixlModel

/// What Music Haptics follows (Settings › Behavior › Music Haptics › Follows).
public enum MusicHapticsMode: String, Sendable, CaseIterable, Equatable {
    /// A tap on each kick and snare, plus a soft rumble under the bass.
    case everything
    /// Taps only (kicks and snares).
    case beat
    /// Kick taps plus the rumble.
    case bass
}

/// Where the sound goes, as far as haptics care: haptics only make sense when the music is played here.
public enum MusicHapticsRoute: Sendable, Equatable {
    /// The phone's speaker, wired headphones, AirPods and other Bluetooth: the audio is local.
    case local
    /// AirPlay, Spotify Connect, Cast: the audio plays elsewhere.
    case remote
}

public struct MusicHapticsConditions: Sendable, Equatable {
    public var isEnabled: Bool
    public var deviceSupportsHaptics: Bool
    public var isPlaying: Bool
    public var isForeground: Bool
    public var lowPowerMode: Bool
    public var thermal: ThermalLevel
    public var safeMode: Bool
    public var inPhoneCall: Bool
    public var route: MusicHapticsRoute

    public init(isEnabled: Bool, deviceSupportsHaptics: Bool, isPlaying: Bool, isForeground: Bool, lowPowerMode: Bool,
                thermal: ThermalLevel, safeMode: Bool, inPhoneCall: Bool, route: MusicHapticsRoute) {
        self.isEnabled = isEnabled
        self.deviceSupportsHaptics = deviceSupportsHaptics
        self.isPlaying = isPlaying
        self.isForeground = isForeground
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
        self.safeMode = safeMode
        self.inPhoneCall = inPhoneCall
        self.route = route
    }
}

/// The status line of the Settings row.
public enum MusicHapticsStatus: Sendable, Equatable {
    case on
    case off
    case notAvailable(Reason)

    public enum Reason: String, Sendable, Equatable {
        case noHaptics = "This device has no haptics"
        case lowPowerMode = "Low Power Mode is on"
        case hot = "The phone is too warm"
        case safeMode = "Safe mode is on"
        case remoteOutput = "The music plays on another device"
        case phoneCall = "In a call"
    }

    /// "On" / "Off" / "Not available".
    public var title: String {
        switch self {
        case .on: "On"
        case .off: "Off"
        case .notAvailable: "Not available"
        }
    }

    public var reason: Reason? {
        if case .notAvailable(let reason) = self { return reason }
        return nil
    }
}

public enum MusicHapticsPolicy {
    /// The first reason haptics may not run now (in the order a person would want to hear it), nil when none.
    public static func blocker(_ c: MusicHapticsConditions) -> MusicHapticsStatus.Reason? {
        if !c.deviceSupportsHaptics { return .noHaptics }
        if c.safeMode { return .safeMode }
        if c.lowPowerMode { return .lowPowerMode }
        if c.thermal >= .serious { return .hot }
        if c.inPhoneCall { return .phoneCall }
        if c.route == .remote { return .remoteOutput }
        return nil
    }

    /// The Settings row's status: Off when the switch is off, Not available (with the reason) when the switch is on
    /// but something blocks it, else On. Being paused or in the background does not make it unavailable.
    public static func status(_ c: MusicHapticsConditions) -> MusicHapticsStatus {
        if !c.deviceSupportsHaptics { return .notAvailable(.noHaptics) }
        guard c.isEnabled else { return .off }
        if let reason = blocker(c) { return .notAvailable(reason) }
        return .on
    }

    /// Whether the analysis and the haptic engine should run right now: enabled, nothing blocks it, music is playing
    /// and the app is in front (haptics need the foreground). Analysis costs battery, so this is the only gate.
    public static func shouldRun(_ c: MusicHapticsConditions) -> Bool {
        c.isEnabled && c.isPlaying && c.isForeground && blocker(c) == nil
    }
}

/// A haptic event ready for CoreHaptics.
public struct MusicHapticEvent: Sendable, Equatable {
    public enum Shape: Sendable, Equatable {
        /// One transient tap.
        case tap
        /// A continuous soft rumble level.
        case rumble
    }

    public var shape: Shape
    /// 0…1.
    public var intensity: Float
    /// 0…1 (0 = round and soft, 1 = crisp).
    public var sharpness: Float

    public init(shape: Shape, intensity: Float, sharpness: Float) {
        self.shape = shape
        self.intensity = intensity
        self.sharpness = sharpness
    }
}

public enum MusicHapticsMapper {
    public static let strengthRange: ClosedRange<Int> = 20...200
    public static let defaultStrength = 100

    /// 20…200 %, anything else clamped.
    public static func clampedStrength(_ percent: Int) -> Int {
        min(max(percent, strengthRange.lowerBound), strengthRange.upperBound)
    }

    /// The tap an onset becomes in `mode`, nil when the mode ignores it (Bass ignores snares).
    /// Intensity is the onset's strength times the strength setting (100 % = 1×), clamped to 1; sharpness: kicks are
    /// round, snares crisp.
    public static func tap(for onset: HapticOnset, mode: MusicHapticsMode, strengthPercent: Int) -> MusicHapticEvent? {
        let gain = Float(clampedStrength(strengthPercent)) / 100
        switch (mode, onset.kind) {
        case (.bass, .snare): return nil
        case (_, .kick):
            let intensity = min(max((0.35 + 0.65 * onset.strength) * gain, 0), 1)
            return MusicHapticEvent(shape: .tap, intensity: intensity, sharpness: 0.3)
        case (_, .snare):
            let intensity = min(max((0.3 + 0.7 * onset.strength) * gain, 0), 1)
            return MusicHapticEvent(shape: .tap, intensity: intensity, sharpness: 0.85)
        }
    }

    /// The soft rumble under the bass for `bassLevel` (0…1), nil when the mode has none or it is too quiet to feel.
    /// Capped at 0.5 × the setting: the rumble sits under the taps, it must not drown them.
    public static func rumble(bassLevel: Float, mode: MusicHapticsMode, strengthPercent: Int) -> MusicHapticEvent? {
        guard mode != .beat else { return nil }
        let gain = Float(clampedStrength(strengthPercent)) / 100
        let intensity = min(max(bassLevel * 0.5 * gain, 0), 0.75)
        guard intensity >= 0.04 else { return nil }
        return MusicHapticEvent(shape: .rumble, intensity: intensity, sharpness: 0.1)
    }
}

/// At most `maxPerSecond` events: an event closer than the minimum gap to the last allowed one is dropped.
public struct HapticRateLimiter: Sendable {
    public let minimumGap: Double
    private var lastAllowed: Double?

    public init(maxPerSecond: Double = 25) {
        minimumGap = 1 / max(maxPerSecond, 1)
    }

    /// True when an event at `time` (seconds, any monotonic clock) may fire; records it when so.
    public mutating func allow(at time: Double) -> Bool {
        if let lastAllowed, time - lastAllowed < minimumGap { return false }
        lastAllowed = time
        return true
    }

    public mutating func reset() { lastAllowed = nil }
}
