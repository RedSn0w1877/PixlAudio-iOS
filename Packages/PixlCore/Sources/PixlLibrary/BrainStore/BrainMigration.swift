// Migrating what exists into the brain (docs/brain-spec.md, 4.4, steps 1, 2 and 4): the app's own older plays are
// copied once into the event log; imported history is read, never copied; facts that are not events become
// pseudo-counts. Pure functions over ids the caller already resolved, so every rule is unit-tested without files.
// Ports of Android's `LegacyMigration.kt`, `ImportedPlayAdapter.kt` and `BrainRebuilder.kt` (`ReplayMerger`).

import Foundation
import PixlModel

/// A track resolved to its ids, with what an event stores about it.
public struct ResolvedTrack: Sendable, Equatable {
    public var rid: Int64
    public var primaryAid: Int64
    public var otherAids: [Int64]
    /// `keyAtWrite`.
    public var key: String
    public var durationMs: Int32

    public init(rid: Int64, primaryAid: Int64, otherAids: [Int64] = [], key: String, durationMs: Int32 = 0) {
        self.rid = rid
        self.primaryAid = primaryAid
        self.otherAids = otherAids
        self.key = key
        self.durationMs = durationMs
    }
}

/// The one-shot copy of the app's own older plays into the event log (4.4, step 2): `playback_history.json` rows
/// become events with origin `migratedHistory`.
///
/// Idempotent by construction: the event id is a function of the row (its start time, its origin and the key it
/// resolved to), and the log ignores an id that is already there. Rows that ended at or after the cutoff are left
/// alone: from that moment on plays are recorded live, and the legacy history keeps being written too, so copying
/// them would count them twice. The counters (`music_taste.json`, the engagement rows) are not migrated: they
/// aggregate the same sessions this history holds.
public enum LegacyMigration {
    /// Where the live log begins: legacy rows that ended at or after this are not copied.
    ///
    /// First use is written down when the brain's state is first loaded, which for most listeners is while the
    /// first finished play is being recorded, a moment AFTER that play ended. Its legacy row would then be copied
    /// although the same listen is already in the log as a live event. So the log is live from the START of its
    /// first live play, when that is earlier.
    public static func cutoff(firstUseMs: Int64, firstLiveStartMs: Int64?) -> Int64 {
        if let start = firstLiveStartMs, start >= 1, start < firstUseMs { return start }
        return firstUseMs
    }

    /// The events for `rows` that ended before `cutoffMs`. `resolved` says what a song id is; a row whose song is
    /// gone is skipped: nothing identifies it any more. `identityAt` answers for ids the log already holds.
    public static func events(rows: [PlaybackEvent], cutoffMs: Int64, resolved: [BrainKey: ResolvedTrack],
                              identityAt: (Int64) -> String?) -> [PlayEvent] {
        var out: [PlayEvent] = []
        out.reserveCapacity(rows.count)
        var takenInThisRun: [Int64: String] = [:]
        for row in rows {
            let endMs = row.endTimestamp ?? row.timestamp
            if endMs <= 0 || endMs >= cutoffMs || BrainText.isBlank(row.songId) { continue }
            guard let track = resolved[BrainKey(row.songId)] else { continue }
            let playedMs = Int32(clamping: max(row.durationMs, 0))
            // The history stores when a session ended; the log stores when a play started.
            let startedAtMs = endMs - Int64(playedMs)
            let eventId = PlayEvent.mintId(startedAtMs: startedAtMs, origin: Origin.migratedHistory, keyAtWrite: track.key) { id in
                takenInThisRun[id] ?? identityAt(id)
            }
            takenInThisRun[eventId] = PlayEvent.identityOf(origin: Origin.migratedHistory, keyAtWrite: track.key)
            out.append(PlayEvent(eventId: eventId, origin: Origin.migratedHistory, rid: track.rid,
                                 primaryAid: track.primaryAid, otherAids: track.otherAids, keyAtWrite: track.key,
                                 startedAtMs: startedAtMs, playedMs: playedMs, durationMs: track.durationMs))
        }
        return out
    }
}

/// Imported history as events (4.4, step 1). The plays are READ, never copied: `imported_history.tsv` stays their
/// single home, and a rebuild merges this stream with the event log.
public enum ImportedPlayAdapter {
    /// What makes two imported plays the same track: one resolution per distinct value.
    public static func cacheKey(_ play: ImportedPlay) -> String {
        (play.spotifyTrackId ?? "") + "|" + (play.videoId ?? "") + "|" + (Ids.nameKey(primaryArtist: play.artist, rawTitle: play.title) ?? "")
    }

    /// The keys of an imported play (`s:` from the Spotify track id, `y:` from the video id, `n:` from the names)
    /// and the one an event stores; nil when it has none.
    public static func keys(_ play: ImportedPlay) -> (keys: Ids.TrackKeys, key: String)? {
        let keys = Ids.TrackKeys(spotifyId: play.spotifyTrackId, videoId: play.videoId,
                                 nameKey: Ids.nameKey(primaryArtist: play.artist, rawTitle: play.title))
        guard let key = keys.s ?? keys.y ?? keys.n else { return nil }
        return (keys, key)
    }

    /// The end reason an imported play carries: `trackDone` when the export says it played out, `next` when it says
    /// the listener skipped it, `unknown` otherwise (Android's outcome codes 1, 2 and 0 / 3).
    public static func endReason(_ play: ImportedPlay) -> Int32 {
        guard play.source == .spotifyExport else { return EndReason.unknown }
        if let reason = play.reasonEnd {
            if BrainKey.sameBytes(BrainText.fold(reason), "trackdone") { return EndReason.trackDone }
            let folded = BrainText.fold(reason)
            if BrainKey.sameBytes(folded, "fwdbtn") || BrainKey.sameBytes(folded, "backbtn") { return EndReason.next }
        }
        if play.skipped == true { return EndReason.next }
        return EndReason.unknown
    }

    /// Every imported play as an event, in no particular order. `resolved` is keyed by `cacheKey`; `durationOfRid`
    /// gives the length of a recording that is a library track, 0 otherwise.
    public static func events(plays: [ImportedPlay], resolved: [BrainKey: ResolvedTrack],
                              durationOfRid: (Int64) -> Int32) -> [PlayEvent] {
        var out: [PlayEvent] = []
        out.reserveCapacity(plays.count)
        var taken: [Int64: String] = [:]
        for play in plays {
            guard let track = resolved[BrainKey(cacheKey(play))] else { continue }
            let origin = play.source.isSpotify ? Origin.importSpotify : Origin.importYtm
            // 0 means "unknown" in the imported file; the event log says that with -1.
            let playedMs: Int32 = play.msPlayed > 0 ? Int32(clamping: play.msPlayed) : -1
            // The imported time is when the play ended.
            let startedAtMs = play.timestampMs - (playedMs > 0 ? Int64(playedMs) : 0)
            let eventId = PlayEvent.mintId(startedAtMs: startedAtMs, origin: origin, keyAtWrite: track.key) { taken[$0] }
            taken[eventId] = PlayEvent.identityOf(origin: origin, keyAtWrite: track.key)
            out.append(PlayEvent(eventId: eventId, origin: origin, rid: track.rid, primaryAid: track.primaryAid,
                                 keyAtWrite: track.key, startedAtMs: startedAtMs, playedMs: playedMs,
                                 durationMs: durationOfRid(track.rid), endReason: endReason(play)))
        }
        return out
    }
}

/// Merges the stored event log with the imported plays and replays the result (4.4).
public enum ReplayMerger {
    public static let duplicateWindowMs: Int64 = 90_000
    static let recentMs: Int64 = 24 * 60 * 60 * 1000

    public struct Result: Sendable {
        public let state: Affinity.State
        /// Ids of the stored events the rebuild read that started in its last day (a play recorded while it ran is
        /// then not applied twice).
        public let recentEventIds: Set<Int64>
        public let importedUsed: Int
        public let importedDropped: Int
    }

    /// `stored` in ascending event id; `imported` in any order. `survivorOf` maps a merged recording to the one it
    /// was merged into. An imported play whose end is within `duplicateWindowMs` of a stored play of the same
    /// recording is the same listen seen twice and is dropped.
    public static func rebuild(stored: [PlayEvent], imported: [PlayEvent], facts: LibraryFacts, nowMs: Int64,
                               survivorOf: (Int64) -> Int64) -> Result {
        // Pass 1 over the log: when each recording's stored plays ended.
        var endsByRid: [Int64: [Int64]] = [:]
        for e in stored { endsByRid[survivorOf(e.rid), default: []].append(e.endedAtMs) }
        var dropped = 0
        var kept: [PlayEvent] = []
        kept.reserveCapacity(imported.count)
        for e in imported {
            var duplicate = false
            if let ends = endsByRid[survivorOf(e.rid)] {
                let end = e.endedAtMs
                for other in ends {
                    let delta = end > other ? end - other : other - end
                    if delta <= duplicateWindowMs {
                        duplicate = true
                        break
                    }
                }
            }
            if duplicate { dropped += 1 } else { kept.append(e) }
        }
        kept.sort { $0.eventId < $1.eventId }

        // Pass 2: both streams in ascending event id, the order the replay is defined on.
        var recent: Set<Int64> = []
        var merged: [PlayEvent] = []
        merged.reserveCapacity(stored.count + kept.count)
        var at = 0
        var importedAt = 0
        while at < stored.count || importedAt < kept.count {
            var next: PlayEvent
            if at < stored.count && (importedAt >= kept.count || stored[at].eventId <= kept[importedAt].eventId) {
                next = stored[at]
                at += 1
                if next.startedAtMs >= nowMs - recentMs { recent.insert(next.eventId) }
            } else {
                next = kept[importedAt]
                importedAt += 1
            }
            let survivor = survivorOf(next.rid)
            if survivor != next.rid { next.rid = survivor }
            merged.append(next)
        }
        return Result(state: Replay.rebuild(merged, facts: facts, nowMs: nowMs), recentEventIds: recent,
                      importedUsed: kept.count, importedDropped: dropped)
    }
}

/// Facts that are not events (4.4, step 4), from what the app holds, by id.
public enum LibraryFactsBuilder {
    static func range(_ range: ExternalTasteSnapshot.Range) -> Int32 {
        switch range {
        case .shortTerm: return LibraryFacts.rangeShort
        case .mediumTerm: return LibraryFacts.rangeMedium
        case .longTerm: return LibraryFacts.rangeLong
        }
    }

    /// The artist names and the top tracks the facts need ids for, in a fixed order: the caller resolves them and
    /// hands the ids back to `build`.
    public struct Names: Sendable {
        public var artists: [String] = []
        public var topTracks: [TrackRequest] = []
    }

    public static func names(library: [Song], taste: ExternalTasteSnapshot, adjustments: [TasteAdjustment]) -> Names {
        var names = Names()
        var seen: Set<BrainKey> = []
        func add(_ name: String) {
            if BrainText.isBlank(name) || !seen.insert(BrainKey(name)).inserted { return }
            names.artists.append(name)
        }
        for song in library where song.isFavorite { add(BrainLibraryIndex.primaryArtistName(song)) }
        for artist in taste.topArtists { add(artist.name) }
        for track in taste.topTracks {
            add(track.artist)
            names.topTracks.append(TrackRequest(
                keys: Ids.TrackKeys(spotifyId: track.spotifyTrackId,
                                    nameKey: Ids.nameKey(primaryArtist: track.artist, rawTitle: track.title)),
                durationMs: 0))
        }
        for name in taste.followedArtists { add(name) }
        for adjustment in adjustments where adjustment.targetType == .artist && adjustment.kind.isWeight {
            add(adjustment.label)
        }
        return names
    }

    /// `ridBySongId`: the library by recording; `aidByName`: the ids of `names(...).artists`; `topTrackRids`: the
    /// ids of `names(...).topTracks`, in order. Only in-app favourites count as liked; genre and album adjustments
    /// give no pseudo-counts (they need the ids of stage 2); mute and block are hard exclusions (5.11), not counts.
    public static func build(library: [Song], ridBySongId: [BrainKey: Int64], taste: ExternalTasteSnapshot,
                             adjustments: [TasteAdjustment], aidByName: [BrainKey: Int64],
                             topTrackRids: [Int64]) -> LibraryFacts {
        func aid(_ name: String) -> Int64 { aidByName[BrainKey(name)] ?? 0 }
        var liked: [LibraryFacts.TrackFact] = []
        for song in library where song.isFavorite {
            guard let rid = ridBySongId[BrainKey(song.id)] else { continue }
            liked.append(LibraryFacts.TrackFact(rid: rid, primaryAid: aid(BrainLibraryIndex.primaryArtistName(song))))
        }
        var artistListSize: [Int32: Int32] = [:]
        for artist in taste.topArtists { artistListSize[range(artist.range), default: 0] += 1 }
        var topArtists: [LibraryFacts.TopArtist] = []
        for artist in taste.topArtists {
            let id = aid(artist.name)
            if id == 0 { continue }
            let r = range(artist.range)
            topArtists.append(LibraryFacts.TopArtist(aid: id, range: r, position: Int32(clamping: artist.rank),
                                                     listSize: artistListSize[r] ?? 1))
        }
        var trackListSize: [Int32: Int32] = [:]
        for track in taste.topTracks { trackListSize[range(track.range), default: 0] += 1 }
        var topTracks: [LibraryFacts.TopTrack] = []
        for (i, track) in taste.topTracks.enumerated() where i < topTrackRids.count && topTrackRids[i] != 0 {
            let r = range(track.range)
            topTracks.append(LibraryFacts.TopTrack(rid: topTrackRids[i], primaryAid: aid(track.artist), range: r,
                                                   position: Int32(clamping: track.rank), listSize: trackListSize[r] ?? 1))
        }
        var followed: [Int64] = []
        for name in taste.followedArtists {
            let id = aid(name)
            if id != 0 { followed.append(id) }
        }
        var out: [LibraryFacts.Adjustment] = []
        for adjustment in adjustments where adjustment.kind.isWeight {
            let more = adjustment.kind == .boost
            switch adjustment.targetType {
            case .artist:
                let id = aid(adjustment.label)
                if id != 0 {
                    out.append(LibraryFacts.Adjustment(family: Family.artist, key: id, more: more,
                                                       strength: Int32(clamping: adjustment.strength)))
                }
            case .song:
                guard let song = library.first(where: { TasteKey.recording($0) == adjustment.key }),
                      let rid = ridBySongId[BrainKey(song.id)] else { continue }
                out.append(LibraryFacts.Adjustment(family: Family.track, key: rid, more: more,
                                                   strength: Int32(clamping: adjustment.strength)))
            default:
                continue
            }
        }
        return LibraryFacts(liked: liked, topArtists: topArtists, topTracks: topTracks, followed: followed, adjustments: out)
    }
}
