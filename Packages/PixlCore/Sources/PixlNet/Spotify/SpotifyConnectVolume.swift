// Spotify Connect: the phone's volume buttons drive the Connect device while PixlAudio is open (owner request
// 2026-10-07; Android gets the same through Media3's remote `DeviceInfo`). iOS has no API for volume button presses:
// the app watches the audio session's `outputVolume` and turns each one-step change into ±1 press, then sets the
// phone's volume back to a centre value so the next press is seen too (docs/api-notes.md › Connect volume buttons).
// Everything decided here — what a change means, the centre, which devices take part, when a PUT goes out — is pure
// and unit-tested; the app owns the audio session, the hidden system volume view and the network.

import Foundation

/// Turning `outputVolume` changes into presses.
public enum SpotifyConnectVolumeKeys {
    /// Percent per press (Android `SpotifyConnectController.VOLUME_STEP`).
    public static let step = 5
    /// One hardware step of the phone's volume (16 steps from silent to full).
    public static let systemStep: Float = 1.0 / 16
    /// A change this size is a press. `outputVolume` is reported rounded to about 0.05 (Apple forums thread 756484),
    /// so a 1/16 step reads as 0.05, 0.0625 or 0.10; smaller changes are a slider drag, larger ones a route change.
    public static let pressDelta: ClosedRange<Float> = 0.03...0.13
    /// Above this a change is two presses (2/16 = 0.125); the rounded 0.10 report of one step stays one.
    public static let doublePressDelta: Float = 0.115
    /// The centre the phone's volume is set back to stays two steps from either end, so a burst of presses never
    /// reaches silent or full before the reset lands.
    public static let centreRange: ClosedRange<Float> = 0.125...0.875
    /// How close a change must land to the centre to be the reset's own echo (the 0.05 rounding of 1/16 steps is at
    /// most 0.025 off).
    public static let echoTolerance: Float = 0.035
    /// Connect device types that are a phone or a tablet (this iPhone's own Spotify app among them): the buttons
    /// never take over there, so PixlAudio never interrupts audio playing on the phone.
    public static let excludedTypes: Set<String> = ["smartphone", "tablet"]

    public enum Event: Sendable, Hashable {
        /// The user pressed volume up (positive) or down (negative), this many steps.
        case press(Int)
        /// The phone's volume moving back to the centre after a reset (`settled` once it is there).
        case echo(settled: Bool)
        /// Not a press (a route change, a drag in Control Center): this is the phone's volume now.
        case reanchor(Float)
    }

    /// Whether the volume buttons drive this device (`supports_volume`, and not a phone or tablet).
    public static func controls(type: String, supportsVolume: Bool) -> Bool {
        supportsVolume && !excludedTypes.contains(NetText.lowercased(type))
    }

    /// The centre for the user's own phone volume: snapped to the 1/16 grid the buttons step on, then kept inside
    /// `centreRange`.
    public static func centre(for original: Float) -> Float {
        let snapped = (original / systemStep).rounded() * systemStep
        return min(max(snapped, centreRange.lowerBound), centreRange.upperBound)
    }

    /// What one `outputVolume` change (`old` → `new`) means. `awaitingEcho`: a reset to `centre` was just made.
    public static func classify(old: Float, new: Float, centre: Float, awaitingEcho: Bool) -> Event {
        if awaitingEcho {
            let distance = abs(new - centre)
            if distance <= echoTolerance { return .echo(settled: true) }
            // A reset that lands in more than one change moves towards the centre each time.
            if distance < abs(old - centre) - 0.001 { return .echo(settled: false) }
        }
        let delta = new - old
        let magnitude = abs(delta)
        guard pressDelta.contains(magnitude) else { return .reanchor(new) }
        let presses = magnitude > doublePressDelta ? 2 : 1
        return .press(delta > 0 ? presses : -presses)
    }

    /// The device volume after `presses` from `current` (50 when the device never reported one), clamped to 0…100.
    public static func percent(after presses: Int, from current: Int?) -> Int {
        min(max((current ?? 50) + presses * step, 0), 100)
    }

    /// Without the reset the phone's own volume sits at an end: more presses that way change nothing iOS reports.
    public static func reachedEnd(phoneVolume: Float, presses: Int) -> Bool {
        (presses > 0 && phoneVolume >= 0.999) || (presses < 0 && phoneVolume <= 0.001)
    }
}

/// When a device volume `PUT` goes out: the first change at once (leading edge), then at most one request every
/// `minIntervalMs`, always with the latest value, one at a time, and nothing before a Retry-After gate opens. A held
/// button changes the volume about ten times a second; this keeps it to about three requests a second inside
/// Spotify's rolling 30-second window, which the 1-second poll shares.
public struct SpotifyConnectVolumeLane: Sendable, Equatable {
    public static let minIntervalMs: Int64 = 300

    public enum Action: Sendable, Equatable {
        /// Send this percent now.
        case send(Int)
        /// Something is waiting: ask again after this many milliseconds.
        case wait(Int64)
        /// Nothing to send, or a request is in flight.
        case idle
    }

    /// The latest value not sent yet.
    public private(set) var pending: Int?
    /// The value of the request in flight.
    public private(set) var inFlight: Int?
    public private(set) var lastSentAtMs: Int64?
    public private(set) var notBeforeMs: Int64 = 0

    public init() {}

    /// Nothing waiting and nothing in flight.
    public var isIdle: Bool { pending == nil && inFlight == nil }

    public mutating func enqueue(_ percent: Int) {
        pending = min(max(percent, 0), 100)
    }

    public mutating func next(nowMs: Int64) -> Action {
        guard inFlight == nil, let value = pending else { return .idle }
        var earliest = notBeforeMs
        if let last = lastSentAtMs { earliest = max(earliest, last + Self.minIntervalMs) }
        if nowMs < earliest { return .wait(earliest - nowMs) }
        pending = nil
        inFlight = value
        lastSentAtMs = nowMs
        return .send(value)
    }

    /// The request went through.
    public mutating func completed() {
        inFlight = nil
    }

    /// 429: the value goes again once the gate opens, unless a newer one is already waiting.
    public mutating func rateLimited(retryAfterMs: Int64, nowMs: Int64) {
        if pending == nil { pending = inFlight }
        inFlight = nil
        gate(untilMs: nowMs + max(retryAfterMs, 0))
    }

    /// Any other failure: that value is dropped (a newer one still goes).
    public mutating func failed() {
        inFlight = nil
    }

    /// A Retry-After gate another request hit (the poller): no send before it opens.
    public mutating func gate(untilMs: Int64) {
        notBeforeMs = max(notBeforeMs, untilMs)
    }
}
