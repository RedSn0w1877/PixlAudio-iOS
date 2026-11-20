// The numbers behind the tap detector, for the person calibrating it on two real phones: Developer mode > Song Tap
// diagnostics. A port of Android's `SongTapDiagnostics`. The log keeps the last `eventCapacity` events and the snapshot is
// published only while that screen is open, at most `publishEveryMs` apart, so a normal session pays for a few integer
// writes per signal reading and nothing else. A small ring of recent readings (preallocated, no allocation per reading)
// goes into "Copy log" so the signal can be read off at 0, 1, 3 and 10 cm.

/// One line of the diagnostics log: `tMs` is on the monotonic clock.
public struct SongTapDiagEvent: Sendable, Equatable {
    public var tMs: Int64
    public var text: String

    public init(tMs: Int64, text: String) {
        self.tMs = tMs
        self.text = text
    }
}

/// What the diagnostics screen shows right now. Integers only; dB values are whole dB (the signal in 1/256 dB is rounded).
public struct SongTapDiagSnapshot: Sendable, Equatable {
    public var status: SongTapBleStatus = .idle
    public var role = "-"
    public var peersSeen = 0
    /// The peer the detector is following, as "#3 sending", or empty.
    public var focus = ""
    public var rssi = 0
    public var smoothed = 0
    public var baseline = 0
    /// Smoothed minus baseline, whole dB: a tap is a jump of at least `SongTapTuning.jumpDb`.
    public var jump = 0
    /// How long the jump has held, ms; -1 when there is none.
    public var heldMs: Int64 = -1
    public var near = false
    public var connection = "-"
    /// Milliseconds since this phone's last jerk, -1 when none; same for the peer's.
    public var ownJerkAgeMs: Int64 = -1
    public var peerJerkAgeMs: Int64 = -1
    public var detector = "idle"
    public var lastFire = "-"
    public var samples = 0

    public init() {}
}

@MainActor
public final class SongTapDiagnostics {
    public static let eventCapacity = 20
    public static let ring = 150
    public static let publishEveryMs: Int64 = 150

    public private(set) var snapshot = SongTapDiagSnapshot()
    public private(set) var events: [SongTapDiagEvent] = []

    /// Called when `snapshot` or `events` changed; the screen sets it while it is open.
    public var onChange: (() -> Void)?

    private var enabled = false
    private var lastPublishMs: Int64 = 0

    private var ringT = [Int64](repeating: 0, count: SongTapDiagnostics.ring)
    private var ringRssi = [Int](repeating: 0, count: SongTapDiagnostics.ring)
    private var ringSmoothed = [Int](repeating: 0, count: SongTapDiagnostics.ring)
    private var ringBaseline = [Int](repeating: 0, count: SongTapDiagnostics.ring)
    private var ringCount = 0
    private var ringNext = 0
    private var sampleTotal = 0

    public init() {}

    /// The diagnostics screen is open: publish snapshots.
    public func setEnabled(_ on: Bool) {
        enabled = on
        if !on { onChange = nil }
    }

    public func isEnabled() -> Bool { enabled }

    public func log(_ tMs: Int64, _ text: String) {
        if events.count >= Self.eventCapacity { events.removeFirst(events.count - Self.eventCapacity + 1) }
        events.append(SongTapDiagEvent(tMs: tMs, text: text))
        if enabled { onChange?() }
    }

    /// One signal reading of the peer the detector follows.
    public func sample(_ tMs: Int64, rssi: Int, smoothedDbm: Int, baselineDbm: Int) {
        ringT[ringNext] = tMs
        ringRssi[ringNext] = rssi
        ringSmoothed[ringNext] = smoothedDbm
        ringBaseline[ringNext] = baselineDbm
        ringNext = (ringNext + 1) % Self.ring
        if ringCount < Self.ring { ringCount += 1 }
        sampleTotal += 1
    }

    public func sampleCount() -> Int { sampleTotal }

    /// Publishes `snap()` if the screen is open and it has been a moment since the last one.
    public func publish(_ tMs: Int64, _ snap: () -> SongTapDiagSnapshot) {
        if !enabled { return }
        if tMs - lastPublishMs < Self.publishEveryMs { return }
        lastPublishMs = tMs
        snapshot = snap()
        onChange?()
    }

    public func publishNow(_ snap: SongTapDiagSnapshot) {
        if !enabled { return }
        snapshot = snap
        onChange?()
    }

    public func clear() {
        events = []
        ringCount = 0
        ringNext = 0
        sampleTotal = 0
        snapshot = SongTapDiagSnapshot()
        if enabled { onChange?() }
    }

    /// Everything worth pasting into a message: the phone, the tuning, the last events and the recent signal. `device` is
    /// one line the app writes (model and system version).
    public func copyLog(device: String) -> String {
        var out = "Song Tap diagnostics\n"
        out += "device: \(device)\n"
        let s = snapshot
        out += "status \(s.status.rawValue), role \(s.role), peers \(s.peersSeen)\n"
        out += "tuning: baselineShift=\(SongTapTuning.baselineShift) fastShift=\(SongTapTuning.fastShift) jumpDb=\(SongTapTuning.jumpDb)"
        out += " freezeDb=\(SongTapTuning.freezeDb) holdMs=\(SongTapTuning.holdMs) dwellMs=\(SongTapTuning.dwellMs)"
        out += " impulseWindowMs=\(SongTapTuning.impulseWindowMs) cooldownMs=\(SongTapTuning.cooldownMs)"
        out += " nearEnter=\(SongTapTuning.nearEnterDbm) nearExit=\(SongTapTuning.nearExitDbm) jerkMilliG=\(SongTapTuning.jerkMilliG)\n"
        out += "last events (ms since boot, oldest first):\n"
        for e in events { out += "  \(e.tMs)  \(e.text)\n" }
        out += "recent signal (t, rssi, smoothed, baseline), oldest first:\n"
        let start = ringCount < Self.ring ? 0 : ringNext
        for i in 0..<ringCount {
            let k = (start + i) % Self.ring
            out += "  \(ringT[k]), \(ringRssi[k]), \(ringSmoothed[k]), \(ringBaseline[k])\n"
        }
        return out
    }
}
