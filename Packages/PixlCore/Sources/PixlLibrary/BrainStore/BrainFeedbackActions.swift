// What the listener tells the brain beyond a taste change (docs/brain-spec.md, 8.4, 8.5, 8.8, 5.6): "Don't count this",
// Private session, a swipe on an engine row, the supporting facts under a reason, and the repeat activation of a
// recording. Ports of Android's `LearnExclusion.kt`, `PrivateSession.kt`, `WhyFactsLoader.kt` and
// `ActivationFeatures.kt`. The decisions are pure and tested; the engine methods carry them out on its own actor.
//
// The label the listener sees must not say "learn" (decision D15): the control reads "Don't count this".

import Foundation
import PixlModel

/// The kinds of `feedback` row (3.8) and what they point at. Never renumber.
public enum FeedbackKinds {
    public static let privateSpan: Int32 = 1
    public static let dontCount: Int32 = 2

    public static let targetSession: Int32 = 0
    public static let targetSong: Int32 = 1
    public static let targetAlbum: Int32 = 2
    public static let targetPlaylist: Int32 = 3
    public static let targetLastHour: Int32 = 4

    /// The id of a row: its time, then the kind (the same scheme as Android's `now * 8 + kind`).
    public static func rowId(nowMs: Int64, kind: Int32) -> Int64 { nowMs &* 8 &+ Int64(kind) }
}

/// The spans of a private session in this process (8.5): `[start, end]`, the end open while the span is. A play counts
/// as private when it overlapped a span at all: one that began before the switch went on and was still sounding, or one
/// that ended after it went off (the listener's intent was "not this").
public struct PrivateSpans: Sendable, Equatable {
    public static let maxSpans = 24

    private var spans: [(start: Int64, end: Int64)] = []

    public init() {}

    public static func == (a: PrivateSpans, b: PrivateSpans) -> Bool {
        a.spans.count == b.spans.count && zip(a.spans, b.spans).allSatisfy { $0.start == $1.start && $0.end == $1.end }
    }

    public var isActive: Bool { spans.last?.end == Int64.max }

    /// Opens a span at `nowMs`; nothing happens when one is already open.
    public mutating func open(at nowMs: Int64) {
        if isActive { return }
        spans.append((nowMs, Int64.max))
        // Plays are recorded within seconds of ending: nothing older than a few hours can still ask.
        if spans.count > Self.maxSpans { spans.removeFirst() }
    }

    /// Closes the open span at `nowMs`; nothing happens when none is open.
    public mutating func close(at nowMs: Int64) {
        if isActive { spans[spans.count - 1].end = nowMs }
    }

    /// True when a play from `startMs` to `endMs` overlapped a private span.
    public func overlaps(startMs: Int64, endMs: Int64) -> Bool {
        spans.contains { $0.start <= endMs && startMs <= $0.end }
    }
}

/// The repeat activation of a set of recordings from their past plays (5.6, 5.8 feature 10).
public enum ActivationFeatures {
    /// Plays older than this are not read: at the exponent 0.5 a play three months old counts for a fiftieth of one an
    /// hour old, and the read stays small.
    public static let lookBackMs: Int64 = 90 * 24 * 60 * 60 * 1000

    /// Each play weighs what the reward table says its trust weight `c` is (graded without the context of the
    /// moment, as `Affinity.subtract` does), and `RepeatActivation` turns the weights and times into
    /// `clip((B + 4) / 6, 0, 1)`. A recording with no play that counts has no entry (its feature is 0). Plays that never
    /// sounded or were excluded from the picks are left out.
    public static func compute(events: [PlayEvent], nowMs: Int64) -> [Int64: Double] {
        var histories: [Int64: RepeatActivation.History] = [:]
        let skipped = EventFlags.neverAudible | EventFlags.learnExcluded
        for event in events.sorted(by: { $0.startedAtMs < $1.startedAtMs }) where event.rid != 0 && event.flags & skipped == 0 {
            let graded = Reward.grade(event, Reward.Context(pastCompletions: 0, skipStreak: 0))
            if graded.c <= 0.0 { continue }
            histories[event.rid, default: RepeatActivation.History()].add(event.startedAtMs, graded.c)
        }
        var out: [Int64: Double] = [:]
        for (rid, history) in histories {
            let f = RepeatActivation.feature(history, nowMs: nowMs)
            if f > 0.0 { out[rid] = f }
        }
        return out
    }
}

/// How the "Why this song" facts are counted from the log.
public enum WhyFactsInputs {
    /// How many of the artist's last plays are looked at.
    public static let recentPlays = 10

    /// Whether a play counts as finished: it ended on its own, or 80% of it was heard.
    public static func finished(_ event: PlayEvent) -> Bool {
        event.endReason == EndReason.trackDone
            || (event.durationMs > 0 && Double(event.playedMs) >= 0.8 * Double(event.durationMs))
    }

    /// The last `limit` live plays by `aid` that sounded and count, newest first: (how many, how many finished).
    public static func artistStats(events: [PlayEvent], aid: Int64, limit: Int = recentPlays) -> (plays: Int, finished: Int) {
        let skipped = EventFlags.neverAudible | EventFlags.learnExcluded
        var plays = 0
        var done = 0
        for event in events.sorted(by: { $0.startedAtMs > $1.startedAtMs })
        where event.origin == Origin.live && event.primaryAid == aid && event.flags & skipped == 0 {
            if plays >= limit { break }
            plays += 1
            if finished(event) { done += 1 }
        }
        return (plays, done)
    }
}

/// What "Don't count this" took out, and the `feedback` row that records it.
public struct ExcludedPlays: Sendable, Equatable {
    public var feedbackId: Int64
    public var eventIds: [Int64]
    /// The song whose play in flight was flagged too (Undo clears it).
    public var flaggedSongId: String?
    /// How many plays of an earlier history import the rebuild leaves out (the log holds none of them).
    public var importedPlays: Int
    public var count: Int { eventIds.count + importedPlays + (flaggedSongId == nil ? 0 : 1) }

    public init(feedbackId: Int64, eventIds: [Int64], flaggedSongId: String? = nil, importedPlays: Int = 0) {
        self.feedbackId = feedbackId
        self.eventIds = eventIds
        self.flaggedSongId = flaggedSongId
        self.importedPlays = importedPlays
    }
}

extension BrainEngine {
    // MARK: Don't count this (8.5, 5.2 "Undo")

    public static let hourMs: Int64 = 3_600_000
    private static let activationChunk = 800

    /// All the plays of the recordings in `rids`: a song, or the songs of an album or a playlist. The plays are flagged,
    /// what they added to the affinity tables is taken out at once, a `feedback` row is written, and a full rebuild
    /// from the log follows in the background (which makes the tables exact). Nothing is deleted. Nil when there is
    /// nothing to exclude.
    public func excludeRecordings(rids: Set<Int64>, targetKind: Int32, targetId: Int64, importedPlays: Int = 0,
                                   flaggedSongId: String? = nil) async -> ExcludedPlays? {
        if rids.isEmpty { return nil }
        let payloads = log.allEventPayloads()
        let found = await Task.detached(priority: .utility) {
            BrainEventLog.decodeSorted(payloads).filter { rids.contains($0.rid) }
        }.value
        return exclude(found, targetKind: targetKind, targetId: targetId, importedPlays: importedPlays, flaggedSongId: flaggedSongId)
    }

    /// Every live play of the last `windowMs` (an hour by default).
    public func excludeLastHour(windowMs: Int64 = BrainEngine.hourMs, flaggedSongId: String? = nil) -> ExcludedPlays? {
        let since = clock() - windowMs
        let found = log.events(startedSince: since).filter { $0.origin == Origin.live }
        return exclude(found, targetKind: FeedbackKinds.targetLastHour, targetId: since, importedPlays: 0, flaggedSongId: flaggedSongId)
    }

    private func exclude(_ events: [PlayEvent], targetKind: Int32, targetId: Int64, importedPlays: Int,
                         flaggedSongId: String?) -> ExcludedPlays? {
        let now = clock()
        let fresh = events.filter { !$0.has(EventFlags.learnExcluded) }
        // Nothing stored, nothing imported and no play in flight: nothing to leave out, so no row and no rebuild.
        if fresh.isEmpty && importedPlays == 0 && flaggedSongId == nil { return nil }
        if !fresh.isEmpty {
            withState { state in
                for event in fresh {
                    let graded = Reward.grade(event, Reward.Context(pastCompletions: 0, skipStreak: 0))
                    Affinity.subtract(&state.affinity, event, graded, tMs: event.startedAtMs > now ? now : event.startedAtMs)
                }
                var rows: [Affinity.Row] = []
                var seen: Set<Affinity.RowRef> = []
                for ref in state.affinity.drainTouched() where seen.insert(ref).inserted {
                    if let row = state.affinity.row(ref) { rows.append(row) }
                }
                log.upsertAffinity(rows)
            }
            log.setEventFlag(fresh.map(\.eventId), flag: EventFlags.learnExcluded, on: true)
        }
        let ids = fresh.map(\.eventId)
        let id = FeedbackKinds.rowId(nowMs: now, kind: FeedbackKinds.dontCount)
        feedbackStore.insert(FeedbackStore.Record(id: id, kind: FeedbackKinds.dontCount, targetKind: targetKind,
                                                  targetId: targetId, createdAtMs: now))
        // The quick subtraction is an approximation (the grade was made without its context); the rebuild is exact, and
        // it is also what leaves out the imported plays. A play in flight alone needs neither.
        if !ids.isEmpty || importedPlays > 0 { requestRebuild(force: true) }
        return ExcludedPlays(feedbackId: id, eventIds: ids, flaggedSongId: flaggedSongId, importedPlays: importedPlays)
    }

    /// Takes `excluded` back: the plays count again, from the rebuild that follows.
    public func undoExclusion(_ excluded: ExcludedPlays) {
        log.setEventFlag(excluded.eventIds, flag: EventFlags.learnExcluded, on: false)
        feedbackStore.undo(id: excluded.feedbackId, nowMs: clock())
        if !excluded.eventIds.isEmpty || excluded.importedPlays > 0 { requestRebuild(force: true) }
    }

    /// How many plays of an earlier history import belong to the track with `keys` (the log holds none of them; the rebuild
    /// that "Don't count this" starts leaves them out). Plays of a Spotify export count only while the Spotify switch is on.
    public func importedPlayCount(keys: Ids.TrackKeys) async -> Int {
        guard let sources else { return 0 }
        let shapes = sources.spotifyShapesPicks()
        let plays = await sources.imported().plays
        return await Task.detached(priority: .utility) {
            var count = 0
            for play in plays where shapes || !play.source.isSpotify {
                guard let found = ImportedPlayAdapter.keys(play)?.keys else { continue }
                if (keys.s != nil && found.s == keys.s) || (keys.y != nil && found.y == keys.y) || (keys.n != nil && found.n == keys.n) {
                    count += 1
                }
            }
            return count
        }.value
    }

    /// The `feedback` rows that were not undone, oldest first (3.8).
    public func activeFeedback() -> [FeedbackStore.Record] { feedbackStore.active() }

    /// How many `feedback` rows there are, undone ones included.
    public func feedbackCount() -> Int { feedbackStore.count }

    // MARK: Private session (8.5)

    /// True while a private session is on.
    public var isPrivate: Bool { privateSpans.isActive }

    /// Switches the private session on or off. Each switch is a `feedback` row (a span with its end).
    public func setPrivate(_ on: Bool) {
        if on == privateSpans.isActive { return }
        let now = clock()
        if on {
            privateSpans.open(at: now)
            privateRowId = FeedbackKinds.rowId(nowMs: now, kind: FeedbackKinds.privateSpan)
            feedbackStore.insert(FeedbackStore.Record(id: privateRowId, kind: FeedbackKinds.privateSpan,
                                                      targetKind: FeedbackKinds.targetSession, targetId: now,
                                                      createdAtMs: now))
        } else {
            privateSpans.close(at: now)
            if privateRowId != 0 { feedbackStore.undo(id: privateRowId, nowMs: now) }
            privateRowId = 0
        }
    }

    /// True when a play from `startMs` to `endMs` overlaps a private span.
    public func privateOverlaps(startMs: Int64, endMs: Int64) -> Bool { privateSpans.overlaps(startMs: startMs, endMs: endMs) }

    // MARK: A swipe on an engine row (8.4)

    /// The listener removed an engine pick from the queue without hearing it: a weak negative for the session, no event,
    /// no block. Only while the brain is in memory; nothing is loaded for it.
    public func weakNegative(rid: Int64, aid: Int64) {
        guard loaded != nil, rid != 0 else { return }
        withState { Session.weakNegative(&$0.session, rid: rid, aid: aid) }
    }

    // MARK: Supporting facts (8.8) and repeat activation (5.6)

    /// The supporting facts of the pick `rid` / `aid`, from the listener's own log: how many of the last plays by the
    /// artist were finished, how often this track was finished, the year when the caller knows it. A brain that is not
    /// in memory yet gives no track fact.
    public func whyFacts(rid: Int64, aid: Int64, year: Int) async -> [WhyFacts.Fact] {
        var artistPlays = 0
        var artistFinished = 0
        if aid != 0 {
            let payloads = log.eventPayloads(startedSince: clock() - ActivationFeatures.lookBackMs)
            let stats = await Task.detached(priority: .utility) {
                WhyFactsInputs.artistStats(events: BrainEventLog.decodeSorted(payloads), aid: aid)
            }.value
            artistPlays = stats.plays
            artistFinished = stats.finished
        }
        var trackFinished = 0
        if loaded != nil, rid != 0 { trackFinished = Int(loaded!.affinity.completions[rid] ?? 0) }
        return WhyFacts.pick(artistPlays: artistPlays, artistFinished: artistFinished, trackFinished: trackFinished, year: year)
    }

    /// Feature 10 of the recordings in `rids`, from their plays in the last 90 days. A recording with no play that
    /// counts has no entry.
    public func activation(rids: Set<Int64>, nowMs: Int64) async -> [Int64: Double] {
        if rids.isEmpty { return [:] }
        let payloads = log.eventPayloads(startedSince: nowMs - ActivationFeatures.lookBackMs)
        return await Task.detached(priority: .utility) {
            ActivationFeatures.compute(events: BrainEventLog.decodeSorted(payloads).filter { rids.contains($0.rid) }, nowMs: nowMs)
        }.value
    }
}
