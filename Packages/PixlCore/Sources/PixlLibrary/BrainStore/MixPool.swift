// What a Daily Mix or Your Mix is planned from (docs/brain-spec.md, 5.11, 6.1, 6.2, 8.2, stage 2a): the listener's
// constraints, what the app hands over, the pool of candidates, and the seeds of the refresh. A port of Android's
// `MixPool.kt` and the constraint half of its `TasteConstraintAdapter.kt`.

import Foundation
import PixlModel

// MARK: - What the app hands over

/// The listener's hard constraints as the brain reads them (docs/brain-spec.md, 5.11, 13.2): blocked artists and the
/// taste adjustments ("Not for me", mute, boost, reduce). They are applied outside the scorer, so an explicit
/// instruction is exact: music that is excluded or blocked is never a candidate, and a boost or reduce enters the value
/// as `ln(product)`. The stores and screens stay as they are; this is the one place the brain asks them. One value
/// answers a whole pool: take it once, off the main actor, and ask it for every song.
public struct MixConstraints: Sendable {
    public var blocked: BlockedArtistMatcher
    public var adjustments: TasteAdjustmentSet
    /// Ids of the library songs the listener likes (the library's favourites).
    public var favoriteIds: Set<String>
    /// Changes whenever the adjustments or the blocked artists change: what a saved list was built from.
    public var signature: String

    public init(blocked: BlockedArtistMatcher = .empty, adjustments: TasteAdjustmentSet = .empty,
                favoriteIds: Set<String> = [], signature: String = "") {
        self.blocked = blocked
        self.adjustments = adjustments
        self.favoriteIds = favoriteIds
        self.signature = signature
    }

    /// False for a song the listener muted, blocked, or sent away with "Not for me".
    public func allows(_ song: Song) -> Bool {
        !blocked.isBlocked(song) && !adjustments.isExcluded(song) && !adjustments.isBlocked(song)
    }

    /// `ln(product of the boost and reduce strengths)` of `song`, 0 for none (5.11).
    public func boostLn(_ song: Song) -> Double { AutoplayPool.boostLn(adjustments, song) }
}

/// What the mixes read from the rest of the app. Closures, so nothing is loaded until a mix is built.
public struct MixSources: Sendable {
    /// The whole library (a value already in memory).
    public var library: @Sendable () async -> [Song]
    /// Library songs by id (a saved mix is read back through this).
    public var librarySongs: @Sendable ([String]) async -> [String: Song]
    /// The existing ranking's best `limit` library songs: it knows the library's own engagement counters. The mixes
    /// shortlist from it, so a listener with a long history gets their own music first. `epochDay` is the local day.
    public var legacyPicks: @Sendable (_ library: [Song], _ limit: Int, _ nowMs: Int64, _ epochDay: Int64) async -> [Song]
    public var constraints: @Sendable () async -> MixConstraints
    /// `BrainEngineChoice.legacy` or `.brain`.
    public var engine: @Sendable () async -> Int
    /// The Familiar / Blend / Discover position (`Novelty`).
    public var noveltyLevel: @Sendable () async -> Int
    public var tzOffsetMin: @Sendable (_ nowMs: Int64) -> Int32
    /// How a track from outside the library becomes the queue's own song (the app gives it the ids of its own scheme).
    public var song: @Sendable (EngineTrack) -> Song
    /// The stored YouTube match of a Spotify track id.
    public var matchedVideoId: @Sendable (String) async -> String?
    /// A mix was built: the refresh job is scheduled now, after the brain was first used and never at app start.
    public var mixBuilt: @Sendable () -> Void
    /// A timing worth reporting (`brain_mix_build`, milliseconds).
    public var timing: @Sendable (_ name: String, _ ms: Int64) -> Void

    public init(library: @escaping @Sendable () async -> [Song],
                librarySongs: @escaping @Sendable ([String]) async -> [String: Song],
                legacyPicks: @escaping @Sendable ([Song], Int, Int64, Int64) async -> [Song] = { _, _, _, _ in [] },
                constraints: @escaping @Sendable () async -> MixConstraints = { MixConstraints() },
                engine: @escaping @Sendable () async -> Int = { BrainEngineChoice.brain },
                noveltyLevel: @escaping @Sendable () async -> Int = { Novelty.blend },
                tzOffsetMin: @escaping @Sendable (Int64) -> Int32 = { _ in 0 },
                song: @escaping @Sendable (EngineTrack) -> Song = { $0.song() },
                matchedVideoId: @escaping @Sendable (String) async -> String? = { _ in nil },
                mixBuilt: @escaping @Sendable () -> Void = {},
                timing: @escaping @Sendable (String, Int64) -> Void = { _, _ in }) {
        self.library = library
        self.librarySongs = librarySongs
        self.legacyPicks = legacyPicks
        self.constraints = constraints
        self.engine = engine
        self.noveltyLevel = noveltyLevel
        self.tzOffsetMin = tzOffsetMin
        self.song = song
        self.matchedVideoId = matchedVideoId
        self.mixBuilt = mixBuilt
        self.timing = timing
    }
}

// MARK: - The pool

/// A library track the mixes may pick, with the ids the brain knows it by.
public struct LibraryTrack: Sendable {
    public var song: Song
    public var rid: Int64
    /// Primary artist id; 0 when unknown.
    public var aid: Int64
    public var liked: Bool
    /// `ln(product)` of the listener's boost / reduce (5.11); 0 for none.
    public var boostLn: Double

    public init(song: Song, rid: Int64, aid: Int64, liked: Bool, boostLn: Double = 0.0) {
        self.song = song
        self.rid = rid
        self.aid = aid
        self.liked = liked
        self.boostLn = boostLn
    }
}

/// One seed of a mix: a track the listener chose, and what the cache holds about its radio.
public struct MixSeed: Sendable {
    public var rid: Int64
    public var aid: Int64
    public var title: String
    public var artistName: String
    /// The song radio (or the Related tab), or nil when none is cached.
    public var list: StoredRadio?
    /// The artist's top songs and radio (the `+artist` list), or empty.
    public var artistRows: [StoredRadioRow]

    public init(rid: Int64, aid: Int64, title: String, artistName: String, list: StoredRadio?, artistRows: [StoredRadioRow] = []) {
        self.rid = rid
        self.aid = aid
        self.title = title
        self.artistName = artistName
        self.list = list
        self.artistRows = artistRows
    }
}

/// A track from outside the library that a mix may pick, with where it came from.
public struct NovelEntry: Sendable {
    public var stored: StoredRadioRow
    public var track: EngineTrack
    /// The best rank in any seed's list (1-based); 0 for an artist list.
    public var radioRank: Int
    public var seedAid: Int64
    public var seedArtist: String
    public var fromArtistRadio: Bool
}

public struct MixPool: Sendable {
    public var candidates: [Candidate]
    public var seedLists: [Retrieval.SeedList]
    public var library: [Int64: LibraryTrack]
    public var novel: [Int64: NovelEntry]
    /// Primary artist name by aid, for the reason lines ("Fans of X also play this").
    public var artistNames: [Int64: String]
}

/// The pool a Daily Mix or Your Mix is planned from (6.1, 6.2): the library shortlist plus the cached radios of the
/// listener's own tracks. Pure: the callers read the files and hand the results over.
///
/// A candidate that is not in the library goes through the same filters as autoplay's (official audio, 60 to 900
/// seconds, no karaoke / cover / sped-up, live / instrumental / remix only when the seed is one), and is dropped when
/// the library already has the recording, when the listener ignored it three times, or when a constraint of 5.11
/// excludes it. A library track appears once, as itself.
public enum MixPoolBuilder {
    /// At most this many rows of one list are looked at: the head of a radio is where its quality is.
    public static let rowsPerList = 50

    public static func build(library: [LibraryTrack], seeds: [MixSeed], index: BrainLibraryIndex, constraints: MixConstraints,
                             ignoredRids: Set<Int64>, aidOfName: (String) -> Int64) -> MixPool {
        var libraryByRid: [Int64: LibraryTrack] = [:]
        libraryByRid.reserveCapacity(library.count * 2)
        var libraryOrder: [LibraryTrack] = []
        libraryOrder.reserveCapacity(library.count)
        for track in library where track.rid != 0 && libraryByRid[track.rid] == nil {
            libraryByRid[track.rid] = track
            libraryOrder.append(track)
        }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(library.count + seeds.count * 20)
        var seedLists: [Retrieval.SeedList] = []
        var novel: [Int64: NovelEntry] = [:]
        var artistNames: [Int64: String] = [:]

        for track in libraryOrder {
            candidates.append(Candidate(
                rid: track.rid, aid: track.aid,
                albumKey: AutoplayPool.albumHash(BrainLibraryIndex.albumKey(of: track.song.album)), inLibrary: true,
                liked: track.liked, boostLn: track.boostLn))
            if track.aid != 0 && artistNames[track.aid] == nil {
                artistNames[track.aid] = BrainLibraryIndex.primaryArtistName(track.song)
            }
        }

        for seed in seeds {
            if seed.aid != 0 && !BrainText.isBlank(seed.artistName) && artistNames[seed.aid] == nil {
                artistNames[seed.aid] = seed.artistName
            }
            let seedFlags = BrainText.cleanTitle(seed.title).versionFlags
            if let list = seed.list {
                let rows = Array(list.rows.prefix(rowsPerList))
                seedLists.append(Retrieval.SeedList(
                    seedRid: seed.rid, seedAid: seed.aid, rids: rows.map(\.rid),
                    edgeFactor: list.kind == RadioList.kindRelated ? Graph.related : Graph.radio))
                for rank in rows.indices {
                    addNovel(rows[rank], rank: rank + 1, seed: seed, seedFlags: seedFlags, fromArtist: false, index: index,
                             constraints: constraints, ignoredRids: ignoredRids, libraryByRid: libraryByRid, novel: &novel,
                             candidates: &candidates, artistNames: &artistNames, aidOfName: aidOfName)
                }
            }
            for stored in seed.artistRows.prefix(rowsPerList) {
                addNovel(stored, rank: 0, seed: seed, seedFlags: seedFlags, fromArtist: true, index: index,
                         constraints: constraints, ignoredRids: ignoredRids, libraryByRid: libraryByRid, novel: &novel,
                         candidates: &candidates, artistNames: &artistNames, aidOfName: aidOfName)
            }
        }
        return MixPool(candidates: candidates, seedLists: seedLists, library: libraryByRid, novel: novel,
                       artistNames: artistNames)
    }

    private static func addNovel(_ stored: StoredRadioRow, rank: Int, seed: MixSeed, seedFlags: Int32, fromArtist: Bool,
                                 index: BrainLibraryIndex, constraints: MixConstraints, ignoredRids: Set<Int64>,
                                 libraryByRid: [Int64: LibraryTrack], novel: inout [Int64: NovelEntry],
                                 candidates: inout [Candidate], artistNames: inout [Int64: String],
                                 aidOfName: (String) -> Int64) {
        let row = stored.row
        let rid = stored.rid
        if rid == 0 || row.artists.isEmpty || ignoredRids.contains(rid) || libraryByRid[rid] != nil { return }
        if let old = novel[rid] {
            // The same recording in another seed's list: keep the better rank, nothing else changes.
            if rank > 0 && (old.radioRank == 0 || rank < old.radioRank) && !fromArtist {
                novel[rid] = NovelEntry(stored: old.stored, track: old.track, radioRank: rank, seedAid: seed.aid,
                                        seedArtist: seed.artistName, fromArtistRadio: old.fromArtistRadio)
            }
            return
        }
        // Music the listener already has is not a card here: it is a library candidate.
        if index.match(row) != nil { return }
        let track = EngineTrack(row: row, rid: rid)
        let albumKey = row.album.flatMap(BrainLibraryIndex.albumKey(of:))
        let policy = AutoplayPolicy.Candidate(
            mediaId: track.songId, rid: rid, artistKey: BrainLibraryIndex.artistKey(of: row), albumKey: albumKey,
            durationMs: track.durationMs, versionFlags: BrainText.cleanTitle(row.title).versionFlags,
            officialAudio: row.isOfficialAudio, inLibrary: false, arm: fromArtist ? Arm.artist : Arm.radio,
            radioRank: Int32(rank))
        if !AutoplayPolicy.passesFilters(policy, seedFlags: seedFlags) { return }
        let song = track.song()
        if !constraints.allows(song) { return }
        let primary = row.artists[0].name
        let aid = aidOfName(primary)
        if aid != 0 && artistNames[aid] == nil { artistNames[aid] = primary }
        novel[rid] = NovelEntry(stored: stored, track: track, radioRank: rank, seedAid: seed.aid,
                                seedArtist: seed.artistName, fromArtistRadio: fromArtist)
        candidates.append(Candidate(rid: rid, aid: aid, albumKey: AutoplayPool.albumHash(albumKey), inLibrary: false,
                                    fromArtistRadio: fromArtist, boostLn: constraints.boostLn(song)))
    }
}

// MARK: - The seeds of the day

/// One track a seed may be made of, with its recording and artist.
public struct RecentTrack: Sendable, Equatable {
    public var rid: Int64
    public var aid: Int64
    public var lastMs: Int64
}

/// What the seed groups read from the event log (3.6, "Stage 2 before islands exist"). Pure: the callers hand over the
/// events of the last weeks.
public enum SeedQueries {
    /// Events with these flags set mean "the listener liked, saved or replayed it" (liked 64, saved 128, replayed 1024).
    static let chosenFlags = EventFlags.likedDuring | EventFlags.savedDuring | EventFlags.replayed
    static let likedOrSaved = EventFlags.likedDuring | EventFlags.savedDuring
    static let finishedMs: Int32 = 30_000

    /// The tracks the listener chose and finished since `sinceMs`, newest first: an event that no recommendation
    /// produced, or an engine pick the listener liked, saved or replayed (5.12 rule 10). A play that never sounded is
    /// not one.
    public static func recentChosen(_ events: [PlayEvent], sinceMs: Int64, limit: Int) -> [RecentTrack] {
        newest(events.filter {
            $0.startedAtMs >= sinceMs && $0.endReason == EndReason.trackDone && !$0.has(EventFlags.neverAudible)
                && $0.playedMs >= finishedMs && ($0.arm == Arm.none || $0.flags & chosenFlags != 0)
        }, limit: limit)
    }

    /// Tracks liked or saved while they played since `sinceMs`, newest first.
    public static func recentlySaved(_ events: [PlayEvent], sinceMs: Int64, limit: Int) -> [RecentTrack] {
        newest(events.filter { $0.startedAtMs >= sinceMs && $0.flags & likedOrSaved != 0 }, limit: limit)
    }

    /// One row per recording, with its newest play; newest first, ties by recording id.
    private static func newest(_ events: [PlayEvent], limit: Int) -> [RecentTrack] {
        var byRid: [Int64: RecentTrack] = [:]
        for e in events where e.rid != 0 {
            if let old = byRid[e.rid], old.lastMs >= e.startedAtMs { continue }
            byRid[e.rid] = RecentTrack(rid: e.rid, aid: e.primaryAid, lastMs: e.startedAtMs)
        }
        let ordered = byRid.values.sorted { $0.lastMs != $1.lastMs ? $0.lastMs > $1.lastMs : $0.rid < $1.rid }
        return Array(ordered.prefix(limit))
    }
}

/// The four groups of seeds (3.6) in the order `Seeds.select` reads them.
public enum SeedGroups {
    /// A track that may be a seed.
    public struct Source: Sendable, Equatable {
        public var rid: Int64
        public var aid: Int64

        public init(rid: Int64, aid: Int64) {
            self.rid = rid
            self.aid = aid
        }
    }

    /// `usable` says a radio can be asked for the recording.
    public static func groups(recent: [Source], top: [Source], saved: [Source], randomRids: [Int64],
                              aidOf: (Int64) -> Int64, usable: (Int64) -> Bool) -> [[Seeds.Seed]] {
        [
            recent.filter { usable($0.rid) }.map { Seeds.Seed(rid: $0.rid, aid: $0.aid, group: Seeds.recent) },
            top.filter { usable($0.rid) }.map { Seeds.Seed(rid: $0.rid, aid: $0.aid, group: Seeds.top) },
            saved.filter { usable($0.rid) }.map { Seeds.Seed(rid: $0.rid, aid: $0.aid, group: Seeds.saved) },
            randomRids.filter(usable).map { Seeds.Seed(rid: $0, aid: aidOf($0), group: Seeds.random) },
        ]
    }
}

/// A track the day's seeds are made of: a library song or a track from outside it (never both).
public struct PickedSeed: Sendable {
    public var rid: Int64
    public var aid: Int64
    public var title: String
    public var artist: String
    public var song: Song?
    public var playable: EngineTrack?

    public init(rid: Int64, aid: Int64, title: String, artist: String, song: Song? = nil, playable: EngineTrack? = nil) {
        self.rid = rid
        self.aid = aid
        self.title = title
        self.artist = artist
        self.song = song
        self.playable = playable
    }
}
