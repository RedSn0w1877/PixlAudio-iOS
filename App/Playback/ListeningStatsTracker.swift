import Foundation
import PixlLibrary
import PixlModel
import SwiftData

/// Port of Android's `ListeningStatsTracker`: one listening session per song, accumulating real (wall-clock) listening
/// time while playing; when the song changes or playback stops, a session of at least 5 s is recorded — to
/// `playback_history.json` (Android's exact format, `PlaybackHistoryCodec`) and to the song's engagement row
/// (`EngagementRecord`: play count, total time, last played; Android `DailyMixManager.recordPlay`).
@MainActor
final class ListeningStatsTracker {
    /// `MIN_SESSION_LISTEN_MS`.
    static let minimumSessionMs: Int64 = 5_000

    struct Session: Equatable {
        let songId: String
        var totalDurationMs: Int64
        let startedAtEpochMs: Int64
        var lastKnownPositionMs: Int64
        var accumulatedListeningMs: Int64
        var lastRealtimeMs: Int64
        var lastUpdateEpochMs: Int64
        var isPlaying: Bool
        let isVoluntary: Bool
    }

    /// A finished session to persist.
    struct Record: Equatable, Sendable {
        let songId: String
        let listenedMs: Int64
        let timestamp: Int64
        let totalDurationMs: Int64
        let isVoluntary: Bool
        /// The session ended because another song started (Android's `trackChanged`: an early skip counts as one
        /// for music intelligence).
        var changedTrack = false
    }

    private(set) var session: Session?
    private var pendingVoluntarySongId: String?
    /// Monotonic milliseconds (`SystemClock.elapsedRealtime`); injectable for tests.
    var realtimeMs: () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    var epochMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    /// Called with every recorded session.
    var onRecord: ((Record) -> Void)?

    init() {}

    /// The user picked this song (vs. auto-advance).
    func onVoluntarySelection(songId: String) { pendingVoluntarySongId = songId }

    func onTrackChanged(songId: String?, positionMs: Int64, durationMs: Int64, isPlaying: Bool) {
        finalizeCurrentSession(changedTrack: songId != nil && songId != session?.songId)
        guard let songId, !songId.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let now = epochMs()
        session = Session(songId: songId, totalDurationMs: max(durationMs, 0), startedAtEpochMs: now,
                          lastKnownPositionMs: max(positionMs, 0), accumulatedListeningMs: 0,
                          lastRealtimeMs: realtimeMs(), lastUpdateEpochMs: now, isPlaying: isPlaying,
                          isVoluntary: pendingVoluntarySongId == songId)
        if pendingVoluntarySongId == songId { pendingVoluntarySongId = nil }
    }

    func onPlayStateChanged(isPlaying: Bool, positionMs: Int64) {
        guard var current = session else { return }
        let now = realtimeMs()
        accumulate(&current, now: now)
        current.isPlaying = isPlaying
        current.lastRealtimeMs = now
        current.lastKnownPositionMs = max(positionMs, 0)
        current.lastUpdateEpochMs = epochMs()
        session = current
    }

    func updateDuration(_ durationMs: Int64) {
        guard durationMs > 0 else { return }
        session?.totalDurationMs = durationMs
    }

    /// Records the session if long enough and clears it (`finalizeCurrentSession`).
    func finalizeCurrentSession(changedTrack: Bool = false) {
        guard var current = session else { return }
        let nowEpoch = epochMs()
        accumulate(&current, now: realtimeMs())
        let listened = max(current.accumulatedListeningMs, 0)
        if listened >= Self.minimumSessionMs {
            let rawEnd: Int64
            if current.isPlaying {
                rawEnd = nowEpoch
            } else if current.lastUpdateEpochMs > 0 {
                rawEnd = current.lastUpdateEpochMs
            } else {
                rawEnd = current.startedAtEpochMs + listened
            }
            let timestamp = min(max(rawEnd, max(current.startedAtEpochMs, 0)), nowEpoch)
            onRecord?(Record(songId: current.songId, listenedMs: listened, timestamp: timestamp,
                             totalDurationMs: current.totalDurationMs, isVoluntary: current.isVoluntary,
                             changedTrack: changedTrack))
        }
        session = nil
        if pendingVoluntarySongId == current.songId { pendingVoluntarySongId = nil }
    }

    private func accumulate(_ session: inout Session, now: Int64) {
        guard session.isPlaying else { return }
        let delta = max(now - session.lastRealtimeMs, 0)
        session.accumulatedListeningMs += delta
    }
}

/// `playback_history.json` in Application Support, read and written with PixlLibrary's Gson-exact codec
/// (Android `PlaybackStatsRepository.recordPlayback`: sanitised event, events older than two years dropped).
actor PlaybackHistoryStore {
    /// `MAX_HISTORY_AGE_MS` (730 days).
    nonisolated static let maxHistoryAgeMs: Int64 = 730 * 24 * 60 * 60 * 1000

    private let url: URL
    private var cached: [PlaybackEvent]?

    init(url: URL) { self.url = url }

    nonisolated static func defaultURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return support.appendingPathComponent(PlaybackHistoryCodec.fileName)
    }

    func events() -> [PlaybackEvent] {
        if let cached { return cached }
        let data = (try? Data(contentsOf: url)) ?? Data()
        let events = PlaybackHistoryCodec.decode(utf8: Array(data))
        cached = events
        return events
    }

    func recordPlayback(songId: String, durationMs: Int64, timestamp: Int64) {
        guard !songId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let end = max(timestamp, 0)
        let duration = max(durationMs, 0)
        let event = PlaybackEvent(songId: songId, timestamp: end, durationMs: duration,
                                  startTimestamp: max(end - duration, 0), endTimestamp: end)
        var all = events()
        let cutoff = end - Self.maxHistoryAgeMs
        if cutoff > 0 { all.removeAll { ($0.endTimestamp ?? $0.timestamp) < cutoff } }
        all.append(event)
        cached = all
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(PlaybackHistoryCodec.encodeUTF8(all)).write(to: url, options: .atomic)
        } catch {
            // Keep the in-memory copy; the next record retries the write.
        }
    }
}

extension PersistenceActor {
    /// Android `EngagementDao.recordPlay`: insert (1, duration, timestamp) or add to the existing row.
    func recordEngagement(songId: String, durationMs: Int64, timestamp: Int64) throws {
        let descriptor = FetchDescriptor<EngagementRecord>(predicate: #Predicate { $0.songId == songId })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.playCount += 1
            existing.totalPlayDurationMs += max(durationMs, 0)
            existing.lastPlayedTimestamp = max(timestamp, 0)
        } else {
            modelContext.insert(EngagementRecord(songId: songId, playCount: 1, totalPlayDurationMs: max(durationMs, 0),
                                                 lastPlayedTimestamp: max(timestamp, 0)))
        }
        try modelContext.save()
    }

    /// The engagement row of a song (play count, total time, last played).
    func engagement(songId: String) throws -> (playCount: Int, totalPlayDurationMs: Int64, lastPlayedTimestamp: Int64)? {
        let descriptor = FetchDescriptor<EngagementRecord>(predicate: #Predicate { $0.songId == songId })
        guard let row = try modelContext.fetch(descriptor).first else { return nil }
        return (row.playCount, row.totalPlayDurationMs, row.lastPlayedTimestamp)
    }

    /// Per-playlist transition rules (`TransitionRuleRecord.settingsJSON` holds `TransitionSettings` JSON).
    func transitionRules() throws -> [TransitionRule] {
        let rows = try modelContext.fetch(FetchDescriptor<TransitionRuleRecord>())
        let decoder = JSONDecoder()
        return rows.enumerated().compactMap { index, row in
            guard let data = row.settingsJSON.data(using: .utf8),
                  let settings = try? decoder.decode(TransitionSettings.self, from: data) else { return nil }
            return TransitionRule(id: Int64(index), playlistId: row.playlistId, fromTrackId: row.fromTrackId,
                                  toTrackId: row.toTrackId, settings: settings)
        }
    }
}
