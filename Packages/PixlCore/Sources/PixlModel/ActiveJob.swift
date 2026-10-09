// The "Active jobs" list on Home (Android `PixelPlayJob` / `JobsStateHolder` / `JobsBottomSheet`): one value type for
// everything long-running that exposes real progress, and the pure rules that order it, count it and describe it.
// The app's `ActiveJobs` aggregator turns each source (library scan, Spotify, downloads, TAIS Studio, Cloud Studio)
// into these values; nothing here knows about any of them.

import Foundation

/// One row of the jobs sheet: what is running (or just finished), how far along it is and where a tap goes.
public struct ActiveJob: Sendable, Hashable, Identifiable {
    /// What kind of work it is (Android `PixelPlayJobKind`, plus the iOS-only model download).
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case libraryScan
        case spotifyImport
        case spotifyMatch
        case songDownload
        case modelDownload
        case lyricsSync
        case instrumental
        case roformer
        case cloud

        /// Android's labels (`PixelPlayJobKind.label`) where it has one.
        public var label: String {
            switch self {
            case .libraryScan: "Library sync"
            case .spotifyImport: "Spotify sync"
            case .spotifyMatch: "Finding audio"
            case .songDownload: "Downloading song"
            case .modelDownload: "Downloading model"
            case .lyricsSync: "Syncing lyrics"
            case .instrumental: "Separating stems"
            case .roformer: "Rendering instrumental"
            case .cloud: "Cloud processing"
            }
        }

        /// The SF Symbol of the row's leading badge.
        public var systemImage: String {
            switch self {
            case .libraryScan: "arrow.triangle.2.circlepath"
            case .spotifyImport: "arrow.down.circle"
            case .spotifyMatch: "magnifyingglass"
            case .songDownload: "arrow.down.to.line"
            case .modelDownload: "cpu"
            case .lyricsSync: "text.word.spacing"
            case .instrumental: "waveform"
            case .roformer: "waveform.badge.magnifyingglass"
            case .cloud: "icloud.and.arrow.up"
            }
        }

        /// Where the kind sits in the list among rows in the same state (the person's own work first).
        var rank: Int {
            switch self {
            case .cloud: 0
            case .lyricsSync: 1
            case .instrumental: 2
            case .roformer: 3
            case .songDownload: 4
            case .modelDownload: 5
            case .spotifyImport: 6
            case .spotifyMatch: 7
            case .libraryScan: 8
            }
        }
    }

    public enum State: Sendable, Hashable {
        /// Waiting its turn (Android `ENQUEUED`).
        case queued
        /// Doing work (Android `RUNNING`).
        case running
        /// Finished well (shown for a while under "Recently finished").
        case done
        /// Stopped, or needs the person.
        case failed
    }

    /// What a tap on the row does.
    public enum Destination: Sendable, Hashable {
        case none
        /// Cloud Studio's queue screen.
        case cloudQueue
    }

    public var id: String
    public var kind: Kind
    /// The first line (the kind's label, or a cloud batch's song).
    public var title: String
    /// The second line: the song or step, "Queued", or what went wrong.
    public var subtitle: String?
    /// 0…100 when known; nil means indeterminate (a spinner).
    public var percent: Int?
    public var state: State
    public var destination: Destination
    /// When it last changed (Unix ms): orders "Recently finished" newest first.
    public var updatedAtMs: Int64

    public init(id: String, kind: Kind, title: String? = nil, subtitle: String? = nil, percent: Int? = nil,
                state: State, destination: Destination = .none, updatedAtMs: Int64 = 0) {
        self.id = id
        self.kind = kind
        self.title = title ?? kind.label
        self.subtitle = subtitle
        self.percent = percent.map { ActiveJobBoard.clampPercent($0) }
        self.state = state
        self.destination = destination
        self.updatedAtMs = updatedAtMs
    }

    /// Counts toward the button's badge: queued or running.
    public var isActive: Bool { state == .queued || state == .running }
}

/// The ordering, counting and wording of the jobs list.
public enum ActiveJobBoard {
    /// How many finished rows stay under "Recently finished".
    public static let recentLimit = 5
    /// A finished row is dropped after this long.
    public static let recentWindowMs: Int64 = 24 * 3_600_000

    public static func clampPercent(_ value: Int) -> Int { min(max(value, 0), 100) }

    /// A percentage from counts (nil while the total is unknown). A finished count never shows 100 % before it is done
    /// unless the total says so.
    public static func percent(completed: Int, total: Int) -> Int? {
        guard total > 0 else { return nil }
        return clampPercent(Int((Double(completed) / Double(total) * 100).rounded(.down)))
    }

    /// The same for a 0…1 fraction.
    public static func percent(fraction: Double?) -> Int? {
        guard let fraction, fraction.isFinite else { return nil }
        return clampPercent(Int((fraction * 100).rounded(.down)))
    }

    /// Running rows first, then queued ones; inside a state by kind, then in the order the sources gave them.
    public static func active(_ jobs: [ActiveJob]) -> [ActiveJob] {
        jobs.enumerated()
            .filter { $0.element.isActive }
            .sorted { lhs, rhs in
                let l = lhs.element, r = rhs.element
                if l.state != r.state { return l.state == .running }
                if l.kind.rank != r.kind.rank { return l.kind.rank < r.kind.rank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Finished and failed rows from the last day, newest first, at most `recentLimit`.
    public static func recent(_ jobs: [ActiveJob], nowMs: Int64) -> [ActiveJob] {
        let finished = jobs.filter { !$0.isActive && (nowMs <= 0 || nowMs - $0.updatedAtMs <= recentWindowMs) }
        let sorted = finished.enumerated().sorted { lhs, rhs in
            if lhs.element.updatedAtMs != rhs.element.updatedAtMs { return lhs.element.updatedAtMs > rhs.element.updatedAtMs }
            return lhs.offset < rhs.offset
        }
        return sorted.prefix(recentLimit).map(\.element)
    }

    /// The button's badge: how many jobs are queued or running.
    public static func badgeCount(_ jobs: [ActiveJob]) -> Int { jobs.reduce(0) { $0 + ($1.isActive ? 1 : 0) } }

    /// The button's symbol animates only while something is actually running.
    public static func isWorking(_ jobs: [ActiveJob]) -> Bool { jobs.contains { $0.state == .running } }

    /// VoiceOver's value for the button: "3 active jobs".
    public static func accessibilityValue(count: Int) -> String {
        switch count {
        case ..<1: "No active jobs"
        case 1: "1 active job"
        default: "\(count) active jobs"
        }
    }

    /// VoiceOver's reading of one row: "Syncing lyrics, Neon Harbor, 64 percent".
    public static func accessibilityLabel(_ job: ActiveJob) -> String {
        var parts = [job.title]
        if let subtitle = job.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        if let percent = job.percent, job.isActive { parts.append("\(percent) percent") }
        switch job.state {
        case .queued: if job.subtitle != "Queued" { parts.append("queued") }
        case .running: break
        case .done: parts.append("finished")
        case .failed: parts.append("needs attention")
        }
        return parts.joined(separator: ", ")
    }
}
