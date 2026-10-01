import Foundation
import PixlBackup

/// What a restore did, for the report screen: per module how much was restored and how many entries could not be
/// matched to a song in this library, the modules that failed, the settings that were skipped and the warnings.
///
/// Android only toasts "Data restored successfully"; the report is iOS's addition because an Android backup names
/// songs by Android's MediaStore ids. They are found again by the title / artist / album / duration stored with the
/// playlists — so favourites, play counts, history, lyrics and transition rules of songs that are in none of the
/// backup's playlists can't be matched, and the report says so.
nonisolated struct BackupRestoreReport: Sendable, Equatable {
    nonisolated enum Outcome: Sendable, Equatable {
        case success
        /// Some modules restored, some failed.
        case partial
        /// Nothing was restored (unreadable file, fatal validation error).
        case failed(String)
    }

    nonisolated struct Entry: Sendable, Equatable, Identifiable {
        var section: BackupSection
        /// Items written (playlists, liked songs, settings, events …).
        var restored: Int
        /// Entries dropped because their song isn't in this library.
        var unmatched: Int = 0
        var id: String { section.key }
    }

    nonisolated struct Failure: Sendable, Equatable, Identifiable {
        var section: BackupSection
        var message: String
        var id: String { section.key }
    }

    var fileName: String
    var createdAt: Int64
    var appVersion: String
    /// Written by the Android app (its manifest carries an Android version).
    var fromAndroid: Bool
    var outcome: Outcome
    var entries: [Entry] = []
    var failures: [Failure] = []
    var warnings: [String] = []
    /// Android-only, per-device and id-keyed settings that were not applied.
    var skippedSettings: [String] = []
    /// Playlist songs not found yet; PixlAudio retries after the next library scan (Android's pending restore).
    var pendingPlaylistSongs: Int = 0
    /// Settings were restored: screens that read them only at launch pick them up after a restart.
    var restoredSettings: Bool = false

    /// Modules whose entries are matched through the playlists' song details.
    static let songMatchedSections: Set<BackupSection> = [.favorites, .lyrics, .engagementStats, .playbackHistory,
                                                          .transitions]

    var totalUnmatched: Int { entries.reduce(0) { $0 + $1.unmatched } }

    /// True when favourites / plays / history / lyrics / rules were dropped for songs the playlists don't describe.
    var hasUnmatchedSongData: Bool {
        entries.contains { Self.songMatchedSections.contains($0.section) && $0.unmatched > 0 }
    }

    static func failure(_ message: String, fileName: String) -> BackupRestoreReport {
        BackupRestoreReport(fileName: fileName, createdAt: 0, appVersion: "", fromAndroid: false, outcome: .failed(message))
    }
}

extension BackupRestoreReport {
    /// A report for screenshots and previews: an Android backup restored into the demo library.
    static let demo = BackupRestoreReport(
        fileName: "PixelPlayer_Backup_1759300000000.pxpl", createdAt: 1_759_300_000_000, appVersion: "0.7.7-beta2",
        fromAndroid: true, outcome: .partial,
        entries: [
            Entry(section: .playlists, restored: 6),
            Entry(section: .globalSettings, restored: 48),
            Entry(section: .favorites, restored: 112, unmatched: 37),
            Entry(section: .engagementStats, restored: 240, unmatched: 85),
            Entry(section: .playbackHistory, restored: 1_830, unmatched: 412),
            Entry(section: .lyrics, restored: 18, unmatched: 4),
            Entry(section: .equalizer, restored: 2),
        ],
        failures: [Failure(section: .aiUsageLogs, message: "AI Activity Logs payload has an incomplete entry.")],
        warnings: ["This is a legacy backup (v2). Some new modules may not be available."],
        skippedSettings: ["nav_bar_corner_radius", "use_smooth_corners", "hi_fi_mode_enabled", "favorite_song_ids"],
        pendingPlaylistSongs: 9, restoredSettings: true)
}
