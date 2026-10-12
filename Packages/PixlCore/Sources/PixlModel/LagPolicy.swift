// Pure rules behind the in-app lag telemetry (docs/handoff/2026-10-12-lag.md): when a stall of the main thread counts as
// a hang, when a frame counts as a hitch, how a minute of frames is summed up, and how many recent hangs are kept. The
// app measures (a watchdog thread and a display link); the decisions are here so they are tested on every platform.

import Foundation

public enum LagPolicy {
    /// A main thread that answers a ping later than this was hung (Apple's "hang" starts at 250 ms too).
    public static let hangThresholdMs = 250
    /// A hang still going after this is logged while it happens (the watchdog may kill the app before it ends).
    public static let stillBlockedMs = 2_000
    /// A frame is a hitch when it took more than this many times the frame time it was due in.
    public static let hitchFactor = 1.5
    /// Longer gaps between two frames are a pause (the link was paused, the app was suspended), not a hitch.
    public static let maxHitchGapMs = 2_000.0
    /// Frame hitches are summed per screen and per this many seconds.
    public static let hitchWindowSeconds = 60.0
    /// Recent hangs shown in the Diagnostics status block.
    public static let keptHangs = 5

    public static func isHang(latencyMs: Int) -> Bool { latencyMs >= hangThresholdMs }

    public static func isHitch(deltaMs: Double, expectedMs: Double) -> Bool {
        expectedMs > 0 && deltaMs > expectedMs * hitchFactor && deltaMs < maxHitchGapMs
    }

    /// `items` with `item` added, newest first, at most `keptHangs` of them.
    public static func keepingRecent<T>(_ items: [T], adding item: T) -> [T] {
        Array(([item] + items).prefix(keptHangs))
    }
}

/// The frames of one screen over (at most) one minute: how many were drawn, how many hitched, the worst gap.
public struct HitchWindow: Sendable, Equatable {
    public private(set) var frames = 0
    public private(set) var hitches = 0
    public private(set) var worstMs = 0.0
    public private(set) var startedAt: Double

    /// `startedAt`: seconds on any monotonic clock.
    public init(startedAt: Double = 0) { self.startedAt = startedAt }

    /// One frame: `deltaMs` since the previous one, `expectedMs` the time it was due in.
    public mutating func record(deltaMs: Double, expectedMs: Double) {
        frames += 1
        if LagPolicy.isHitch(deltaMs: deltaMs, expectedMs: expectedMs) {
            hitches += 1
            worstMs = max(worstMs, deltaMs)
        }
    }

    public func isDue(nowSeconds: Double) -> Bool { nowSeconds - startedAt >= LagPolicy.hitchWindowSeconds }

    /// What the log says; nil when nothing hitched (a smooth minute writes nothing).
    public var summary: String? {
        guard hitches > 0 else { return nil }
        return "\(hitches) of \(frames) frames over 1.5x, worst \(Int(worstMs.rounded())) ms"
    }

    public mutating func reset(startedAt: Double) {
        self = HitchWindow(startedAt: startedAt)
    }
}
