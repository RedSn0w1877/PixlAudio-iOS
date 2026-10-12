// Pure rules behind "safe mode" (docs/handoff/2026-10-10-crash-diagnostics.md): when the previous run of the app ended
// abnormally (a crash, the watchdog, the system ending it for memory), heavy local work must not start by itself at
// the next launch, or a job that kills the app would kill it again every time it is opened. No clocks, files or
// threads in here: the app passes what it observed and stores the returned state.

import Foundation

/// How the previous process ended, as the app could tell at launch.
public enum PreviousRunEnd: Sendable, Equatable {
    /// No earlier run is known (a fresh install, or the first build with this feature).
    case firstLaunch
    /// The run wrote its clean-exit marker (the app went to the background idle, or it was told to terminate).
    case clean
    /// The run never wrote it (killed while working), or MetricKit reported a crash for it.
    case abnormal(AbnormalSource)
}

public enum AbnormalSource: String, Sendable, Codable, Equatable {
    /// The clean-exit marker was missing at launch.
    case missingCleanMarker
    /// MetricKit delivered a crash / hang / CPU-exception / disk-write-exception diagnostic.
    case metricKitDiagnostic
}

/// What the app keeps between launches about safe mode (a few bytes in `UserDefaults`).
public struct SafeModeState: Sendable, Equatable, Codable {
    /// Abnormal ends in a row (reset by a clean session, a retry that survived, or the person turning safe mode off).
    public var consecutiveAbnormal: Int
    /// Heavy local work is paused: nothing starts by itself.
    public var isActive: Bool
    /// The Home banner has not been dismissed yet.
    public var bannerPending: Bool
    /// The person pressed Retry: heavy work is allowed this run while the safe-mode record stays, so a second crash
    /// counts, and a clean end clears it.
    public var liftedByUser: Bool
    /// Unix ms of the last abnormal end.
    public var lastAbnormalAtMs: Int64

    public init(consecutiveAbnormal: Int = 0, isActive: Bool = false, bannerPending: Bool = false,
                liftedByUser: Bool = false, lastAbnormalAtMs: Int64 = 0) {
        self.consecutiveAbnormal = consecutiveAbnormal
        self.isActive = isActive
        self.bannerPending = bannerPending
        self.liftedByUser = liftedByUser
        self.lastAbnormalAtMs = lastAbnormalAtMs
    }

    /// Two abnormal ends in a row: safe mode stays on until the person turns it off in Settings.
    public var isSticky: Bool { consecutiveAbnormal >= SafeModePolicy.stickyAfter }

    /// Nothing heavy may start on its own.
    public var blocksAutomaticHeavyWork: Bool { isActive }

    /// The one-time banner on Home.
    public var showsBanner: Bool { isActive && bannerPending }
}

public enum SafeModePolicy {
    /// Abnormal ends in a row after which safe mode stays on until it is turned off by hand.
    public static let stickyAfter = 2

    /// The state for this launch, from the state the last launch stored and how that run ended.
    public static func launch(previous: SafeModeState, end: PreviousRunEnd, nowMs: Int64) -> SafeModeState {
        var state = previous
        switch end {
        case .firstLaunch:
            return state
        case .abnormal:
            state.consecutiveAbnormal = min(previous.consecutiveAbnormal + 1, 99)
            state.isActive = true
            state.bannerPending = true
            state.liftedByUser = false
            state.lastAbnormalAtMs = nowMs
        case .clean:
            // A run that the person had lifted safe mode for, and that ended cleanly, proves the work is fine now.
            if previous.liftedByUser {
                return SafeModeState()
            }
            // A sticky safe mode (two crashes in a row) stays until it is turned off in Settings.
            if previous.isSticky { return state }
            // One abnormal end, then a clean session: back to normal.
            if previous.isActive || previous.consecutiveAbnormal > 0 { return SafeModeState() }
        }
        return state
    }

    /// MetricKit reported a crash that the clean-marker check did not already count for this launch.
    public static func metricKitCrash(_ state: SafeModeState, alreadyCounted: Bool, nowMs: Int64) -> SafeModeState {
        guard !alreadyCounted else { return state }
        return launch(previous: state, end: .abnormal(.metricKitDiagnostic), nowMs: nowMs)
    }

    /// "Retry" on an interrupted job (or the banner's "Resume"): heavy work may run now.
    public static func userRetried(_ state: SafeModeState) -> SafeModeState {
        guard state.isActive else { return state }
        var next = state
        next.isActive = false
        next.bannerPending = false
        next.liftedByUser = true
        return next
    }

    /// The banner was dismissed (its X, or opening the sheet it points to).
    public static func bannerDismissed(_ state: SafeModeState) -> SafeModeState {
        var next = state
        next.bannerPending = false
        return next
    }

    /// Settings: the switch. Turning it off clears the record; turning it on makes it sticky.
    public static func setByUser(_ state: SafeModeState, on: Bool) -> SafeModeState {
        if on {
            var next = state
            next.isActive = true
            next.liftedByUser = false
            next.consecutiveAbnormal = max(next.consecutiveAbnormal, stickyAfter)
            return next
        }
        return SafeModeState()
    }
}

/// Which jobs were in flight when the app was last alive: written when a heavy job starts and removed when it ends, read
/// at launch after an abnormal end to say what was interrupted (opaque ids and kinds only).
public struct InFlightEntry: Sendable, Equatable, Codable, Hashable {
    /// The job's kind (`ActiveJob.Kind` raw value).
    public var kind: String
    /// What it works on: a song id or a model id. Never written to the shared log.
    public var reference: String
    public var startedAtMs: Int64

    public init(kind: String, reference: String, startedAtMs: Int64) {
        self.kind = kind
        self.reference = reference
        self.startedAtMs = startedAtMs
    }

    public var key: String { "\(kind)|\(reference)" }
}

public enum InFlightJournal {
    /// The entries after `entry` started (a repeat of the same job replaces the old line).
    public static func adding(_ entry: InFlightEntry, to entries: [InFlightEntry]) -> [InFlightEntry] {
        entries.filter { $0.key != entry.key } + [entry]
    }

    public static func removing(kind: String, reference: String, from entries: [InFlightEntry]) -> [InFlightEntry] {
        entries.filter { !($0.kind == kind && $0.reference == reference) }
    }

    /// The Active jobs row id of an interrupted job ("interrupted.<kind>.<reference>").
    public static func rowId(_ entry: InFlightEntry) -> String { "interrupted.\(entry.kind).\(entry.reference)" }

    /// Reads a row id back: the kind never holds a dot, the reference may.
    public static func parse(rowId: String) -> (kind: String, reference: String)? {
        let prefix = "interrupted."
        guard rowId.hasPrefix(prefix) else { return nil }
        let tail = rowId.dropFirst(prefix.count)
        guard let dot = tail.firstIndex(of: ".") else { return nil }
        let kind = String(tail[..<dot])
        let reference = String(tail[tail.index(after: dot)...])
        return kind.isEmpty || reference.isEmpty ? nil : (kind, reference)
    }
}
