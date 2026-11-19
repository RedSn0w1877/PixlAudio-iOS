import Foundation
import PixlLibrary
import PixlModel
import SwiftData

/// Port of Android's `ListeningStatsTracker`: one listening session per song, accumulating real (wall-clock) listening
/// time while playing; when the song changes or playback stops, a session of at least 5 s is recorded — to
/// `playback_history.json` (Android's exact format, `PlaybackHistoryCodec`) and to the song's engagement row
/// (`EngagementRecord`: play count, total time, last played; Android `DailyMixManager.recordPlay`).
///
/// The music brain's play (docs/brain-spec.md, 4.2) is kept beside the legacy session: every play that ends, however
/// short, is handed to `onBrainPlay` with its context and the reason it ended, BEFORE the five-second floor, which
/// only guards the legacy stores. The arithmetic of that play is `OpenPlay` in PixlLibrary.
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
        /// A track from outside the library that has no library row: the legacy counters are not written for it.
        var isOutsideLibrary = false
        /// The play stays out of the picks: "Don't count this" was used on it, or a private session overlapped it. The legacy
        /// counters are not written for it, as on Android (`legacyCounters = !outsideLibrary && !learnExcluded`).
        var learnExcluded = false
        /// A private session overlapped the play (an Undo of "Don't count this" then leaves it excluded).
        var privateTouched = false
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
        /// A track Autoplay played from outside the library, not saved: it is in the play history (so it shows in
        /// Recently Played) but not in the taste counters or the engagement rows (docs/brain-spec.md, 4.2).
        var isOutsideLibrary = false
        /// The play is left out of the picks (see `Session.learnExcluded`): the legacy taste and engagement counters skip it.
        var learnExcluded = false
    }

    private(set) var session: Session?
    /// The same play as the music brain records it.
    private(set) var brainPlay: OpenPlay?
    /// Every play that ended, however short: there is no five-second floor here.
    var onBrainPlay: ((FinishedPlay) -> Void)?
    /// The play in flight, when it starts playing and when it pauses (nil clears it): a play cut off by the process
    /// ending is then still recorded.
    var onBrainOpen: ((FinishedPlay?) -> Void)?
    /// Minutes east of UTC; injectable for tests.
    var tzOffsetMin: () -> Int32 = { Int32(clamping: TimeZone.current.secondsFromGMT() / 60) }
    private var pendingVoluntarySongId: String?
    /// Monotonic milliseconds (`SystemClock.elapsedRealtime`); injectable for tests.
    var realtimeMs: () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    var epochMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    /// Called with every recorded session.
    var onRecord: ((Record) -> Void)?
    /// A private session is on: every play that overlaps it is left out of the picks (docs/brain-spec.md, 8.5). Set by the
    /// brain service; never kept across launches.
    private(set) var isPrivate = false

    init() {}

    /// The user picked this song (vs. auto-advance).
    func onVoluntarySelection(songId: String) { pendingVoluntarySongId = songId }

    /// A new track became current. `context` says what it is and how it started; `endReason` (an `EndReason` code)
    /// why the track before it ended; `isOutsideLibrary` that it has no library row and Autoplay brought it.
    func onTrackChanged(songId: String?, positionMs: Int64, durationMs: Int64, isPlaying: Bool,
                        context: PlayContext? = nil, endReason: Int32 = EndReason.unknown, isOutsideLibrary: Bool = false) {
        finalizeCurrentSession(changedTrack: songId != nil && songId != session?.songId, endReason: endReason)
        guard let songId, !songId.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let now = epochMs()
        let realtime = realtimeMs()
        session = Session(songId: songId, totalDurationMs: max(durationMs, 0), startedAtEpochMs: now,
                          lastKnownPositionMs: max(positionMs, 0), accumulatedListeningMs: 0,
                          lastRealtimeMs: realtime, lastUpdateEpochMs: now, isPlaying: isPlaying,
                          isVoluntary: pendingVoluntarySongId == songId, isOutsideLibrary: isOutsideLibrary)
        if pendingVoluntarySongId == songId { pendingVoluntarySongId = nil }
        if isPrivate {
            session?.learnExcluded = true
            session?.privateTouched = true
        }
        if let context {
            var play = OpenPlay(songId: songId, context: context, startedAtEpochMs: now, tzOffsetMin: tzOffsetMin(),
                                durationMs: durationMs, isPlaying: isPlaying, realtimeMs: realtime)
            if isPrivate { play.mark(EventFlags.learnExcluded) }
            brainPlay = play
            if isPlaying { onBrainOpen?(play.snapshot(endReason: EndReason.killed)) }
        }
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
        if var play = brainPlay {
            let writeDown = play.update(realtimeMs: now, playing: isPlaying)
            brainPlay = play
            if writeDown { onBrainOpen?(play.snapshot(endReason: EndReason.killed)) }
        }
    }

    func updateDuration(_ durationMs: Int64) {
        guard durationMs > 0 else { return }
        session?.totalDurationMs = durationMs
        if var play = brainPlay, play.durationMs != durationMs {
            play.update(realtimeMs: realtimeMs(), playing: play.isPlaying, durationMs: durationMs)
            brainPlay = play
        }
    }

    /// Something happened to `songId` while it plays (an `EventFlags` bit: liked, saved, added to a playlist). A
    /// flag for a song that is not playing is dropped: the like still reaches the brain as a library fact. True when
    /// the song is the one in flight.
    @discardableResult
    func markFlag(songId: String, flag: Int32) -> Bool {
        var hit = false
        if var play = brainPlay, play.songId == songId {
            play.mark(flag)
            brainPlay = play
            hit = true
            // "Don't count this" must outlive a process death in the middle of the play.
            if flag & EventFlags.learnExcluded != 0, play.everPlayed { onBrainOpen?(play.snapshot(endReason: EndReason.killed)) }
        }
        if flag & EventFlags.learnExcluded != 0, session?.songId == songId {
            session?.learnExcluded = true
            hit = true
        }
        return hit
    }

    /// Takes a flag back (Undo of "Don't count this"). A play a private session overlapped stays excluded.
    func unmarkFlag(songId: String, flag: Int32) {
        guard flag & EventFlags.learnExcluded != 0, session?.songId == songId, session?.privateTouched != true else { return }
        session?.learnExcluded = false
        if var play = brainPlay, play.songId == songId {
            play.unmark(flag)
            brainPlay = play
            if play.everPlayed { onBrainOpen?(play.snapshot(endReason: EndReason.killed)) }
        }
    }

    /// The private session was switched on or off. Switching it on leaves out the play in flight too (and rewrites its
    /// saved copy, so a play cut off by the process ending is not counted either).
    func setPrivate(_ on: Bool) {
        isPrivate = on
        guard on, session != nil else { return }
        session?.learnExcluded = true
        session?.privateTouched = true
        if var play = brainPlay {
            play.mark(EventFlags.learnExcluded)
            brainPlay = play
            if play.everPlayed { onBrainOpen?(play.snapshot(endReason: EndReason.killed)) }
        }
    }

    /// A seek inside the current track (a replay, or a seek back).
    func onSeek(fromPositionMs: Int64, toPositionMs: Int64) {
        guard var play = brainPlay else { return }
        play.seek(fromPositionMs: fromPositionMs, toPositionMs: toPositionMs, realtimeMs: realtimeMs())
        brainPlay = play
    }

    /// Records the session if long enough and clears it (`finalizeCurrentSession`). `endReason` is an `EndReason`
    /// code: why the play ended. The brain's play is handed over first, whatever its length.
    func finalizeCurrentSession(changedTrack: Bool = false, endReason: Int32 = EndReason.unknown) {
        if var play = brainPlay {
            brainPlay = nil
            if let finished = play.finish(endReason: endReason, realtimeMs: realtimeMs()) {
                onBrainPlay?(finished)
                if play.everPlayed { onBrainOpen?(nil) }
            }
        }
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
                             changedTrack: changedTrack, isOutsideLibrary: current.isOutsideLibrary,
                             learnExcluded: current.learnExcluded))
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
