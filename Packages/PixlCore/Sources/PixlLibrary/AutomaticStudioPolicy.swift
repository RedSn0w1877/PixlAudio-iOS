// Android `data/worker/AutomaticStudioPolicy.kt`: the limits of unattended lyric sync and instrumental work
// (Settings › AI › "Ready when you play"), and its persistent retry ledger. Manual controls keep their behaviour.

import Foundation

/// `AutomaticStudioKind`.
public enum AutomaticStudioKind: String, Sendable, Hashable, CaseIterable {
    case lyrics = "LYRICS"
    case instrumental = "INSTRUMENTAL"
}

/// `AutomaticStudioPolicy`.
public enum AutomaticStudioPolicy {
    public static let maxSongDurationMs: Int64 = 6 * 60_000
    public static let maxWorkDurationMs: Int64 = 8 * 60_000
    public static let minFreeBytes: Int64 = 1_073_741_824
    /// Unattended work is metered over a rolling window, not per process.
    public static let maxJobsPerWindow = 8
    public static let backgroundWindowMs: Int64 = 6 * 60 * 60_000
    public static let failureCooldownMs: Int64 = 6 * 60 * 60_000
    public static let catalogCooldownMs: Int64 = 24 * 60 * 60_000
    public static let deferredCooldownMs: Int64 = 2 * 60_000
    /// `AutomaticStudioManager`: a scheduled song isn't scheduled again for 15 minutes (a crash / restart loop), and
    /// a finished one is checked again after a week.
    public static let scheduledCooldownMs: Int64 = 15 * 60_000
    public static let completedCooldownMs: Int64 = 7 * 24 * 60 * 60_000
    /// `allowPlaybackToSettle`: no unattended work for 15 s after the app opens or the song changes.
    public static let settleMs: Int64 = 15_000

    /// `Conditions`. `thermalStatus` uses Android's scale (0 none, 1 light, 2 moderate…); iOS's `ThermalState`
    /// raw values map onto it (nominal 0, fair 1, serious 2, critical 3).
    public struct Conditions: Sendable, Hashable {
        public var appVisible: Bool
        public var lyricsEnabled: Bool
        public var instrumentalsEnabled: Bool
        public var batteryPercent: Int
        public var charging: Bool
        public var thermalStatus: Int
        public var freeBytes: Int64
        public var validatedNetwork: Bool

        public init(appVisible: Bool, lyricsEnabled: Bool, instrumentalsEnabled: Bool, batteryPercent: Int,
                    charging: Bool, thermalStatus: Int, freeBytes: Int64, validatedNetwork: Bool = true) {
            self.appVisible = appVisible
            self.lyricsEnabled = lyricsEnabled
            self.instrumentalsEnabled = instrumentalsEnabled
            self.batteryPercent = batteryPercent
            self.charging = charging
            self.thermalStatus = thermalStatus
            self.freeBytes = freeBytes
            self.validatedNetwork = validatedNetwork
        }
    }

    /// `blockedReason`: why `kind` can't run now, nil when it can.
    public static func blockedReason(_ conditions: Conditions, _ kind: AutomaticStudioKind) -> String? {
        if kind == .lyrics && !conditions.lyricsEnabled { return "Automatic lyrics are off" }
        if kind == .instrumental && !conditions.instrumentalsEnabled { return "Automatic instrumentals are off" }
        if kind == .lyrics && !conditions.validatedNetwork { return "Waiting for internet to find synced lyrics" }
        if !conditions.charging && conditions.batteryPercent < 40 { return "Waiting for charging or at least 40% battery" }
        if conditions.thermalStatus >= 2 { return "Waiting for the phone to cool down" }
        if conditions.freeBytes < minFreeBytes { return "Waiting for at least 1 GB of free storage" }
        return nil
    }

    /// `canProcessDuration`: unknown durations and long recordings stay manual.
    public static func canProcessDuration(_ durationMs: Int64) -> Bool {
        durationMs >= 1 && durationMs <= maxSongDurationMs
    }

    /// `orderedIds`: current, recent, favourites, then the rest; blanks and repeats dropped; at most 40.
    public static func orderedIds(current: String?, recent: [String], favorites: [String], local: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in (current.map { [$0] } ?? []) + recent + favorites + local
        where !id.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert(id).inserted {
            result.append(id)
            if result.count == 40 { break }
        }
        return result
    }

    /// `priority`: recent, played and favourite songs first; never-played ones stay eligible behind them.
    public static func priority(songId: String, currentId: String?, favorite: Bool, playCount: Int,
                                lastPlayedMs: Int64, nowMs: Int64) -> Int64 {
        if songId == currentId { return 1_000_000 }
        let age = max(nowMs - lastPlayedMs, 0)
        let recency: Int64
        if lastPlayedMs <= 0 {
            recency = 0
        } else if age <= 7 * 24 * 60 * 60_000 {
            recency = 50_000
        } else if age <= 30 * 24 * 60 * 60_000 {
            recency = 25_000
        } else {
            recency = 10_000
        }
        return recency + (playCount > 0 ? 10_000 : 0) + (favorite ? 5_000 : 0) + Int64(min(max(playCount, 0), 100))
    }

    /// `canSchedule`: not done yet, past its cooldown, and — for an instrumental — with audio on the device.
    public static func canSchedule(_ kind: AutomaticStudioKind, hasLocalAudio: Bool, alreadyComplete: Bool,
                                   cooldownUntil: Int64, now: Int64) -> Bool {
        !alreadyComplete && cooldownUntil <= now && (kind == .lyrics || hasLocalAudio)
    }

    /// `ledgerKey`.
    public static func ledgerKey(_ kind: AutomaticStudioKind, songId: String) -> String { "\(kind.rawValue):\(songId)" }
}

/// `AutomaticStudioCooldowns`: a small persistent retry ledger, oldest deadline evicted first.
public struct AutomaticStudioCooldowns: Sendable, Equatable {
    private var order: [String]
    private var deadlines: [String: Int64]
    public let capacity: Int

    /// Loads a saved ledger, keeping the `capacity` latest deadlines (sorted by deadline, as Android).
    public init(_ initial: [String: Int64] = [:], capacity: Int = 256) {
        precondition(capacity > 0)
        self.capacity = capacity
        let sorted = initial.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
        order = sorted.map(\.key)
        deadlines = initial
        trim()
    }

    public func until(_ key: String) -> Int64 { deadlines[key] ?? 0 }

    /// Records a deadline; the key moves to the end, and the oldest entries go past `capacity`.
    public mutating func record(_ key: String, _ deadline: Int64) {
        order.removeAll { $0 == key }
        order.append(key)
        deadlines[key] = deadline
        trim()
    }

    public func snapshot() -> [String: Int64] { deadlines }

    private mutating func trim() {
        while order.count > capacity {
            deadlines[order.removeFirst()] = nil
        }
    }
}
