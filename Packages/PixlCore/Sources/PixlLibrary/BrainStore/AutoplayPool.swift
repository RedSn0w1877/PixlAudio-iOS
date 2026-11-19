// Builds the pool Autoplay picks from (docs/brain-spec.md, 7.1): the radios of the anchors, mapped onto the library
// where the listener already has the recording, filtered (6.1), in radio order; and the library-only pool for when
// there is no network, no YouTube source, or no radio with anything in it. A port of the pool half of Android's
// `AutoplayController.kt`. Runs off the main actor; the app's controller only carries out the result.

import Foundation
import PixlModel

/// One of the last tracks the listener chose: what a radio request needs to know about it.
public struct AutoplayAnchor: Sendable {
    /// The queue's own song value.
    public var song: Song
    /// The YouTube audio id known for it (a `yt:` song, a matched Spotify song); nil when it has none yet.
    public var videoId: String?
    /// A real Spotify track id; nil for a track that has none.
    public var spotifyId: String?

    public init(song: Song, videoId: String?, spotifyId: String?) {
        self.song = song
        self.videoId = videoId
        self.spotifyId = spotifyId
    }
}

/// One track the pool can play.
public struct AutoplayPoolEntry: Sendable {
    public var candidate: AutoplayPolicy.Candidate
    /// Set when the recording is a library track: it plays from the library row.
    public var librarySong: Song?
    /// Set for a track from outside the library: it must be in `playable` before it reaches the player.
    public var engineTrack: EngineTrack?
    /// The artist the pick is explained by when the planner names none: the anchor's primary artist.
    public var whyArtist: String
    /// ONE artist name: the track's own primary artist.
    public var primaryArtist: String = ""
    /// The same track as the pure core sees it; nil in the library-only pool.
    public var brain: Candidate? = nil
}

public struct BuiltAutoplayPool: Sendable {
    public var entries: [AutoplayPoolEntry]
    /// The picks come from the library alone.
    public var fromLibrary: Bool
    /// The radios the entries came from, newest anchor first; empty for a pool that is picked in its own order
    /// (the library-only pool, and a radio pool the library had to carry on behind).
    public var seeds: [Retrieval.SeedList]
    /// Artist names by aid, for the reason line.
    public var artistNames: [Int64: String]
    /// Built with no network: only tracks that play from the phone. Not kept for long (`AutoplayPolicy.poolTtlMs`).
    public var offline: Bool
    /// The network was allowed, but no radio gave anything (the request budget, a failed request, an anchor with no
    /// match): the library stands in, and the radios are tried again after a while.
    public var fellBack: Bool

    public init(entries: [AutoplayPoolEntry], fromLibrary: Bool, seeds: [Retrieval.SeedList] = [],
                artistNames: [Int64: String] = [:], offline: Bool = false, fellBack: Bool = false) {
        self.entries = entries
        self.fromLibrary = fromLibrary
        self.seeds = seeds
        self.artistNames = artistNames
        self.offline = offline
        self.fellBack = fellBack
    }
}

/// Everything a pool build reads. Plain values, captured on the main actor; the build itself runs elsewhere.
public struct AutoplayPoolRequest: Sendable {
    /// Newest first.
    public var anchors: [AutoplayAnchor]
    /// Ask for the continuation pages of the newest anchor's radio, and let the library carry on behind the radios.
    public var deepen: Bool
    public var allowNetwork: Bool
    public var library: [Song]
    /// Ids of the songs that were ever played (the arm of a library pick: a favourite or a deep cut).
    public var everPlayed: Set<String>
    public var blocked: BlockedArtistMatcher
    public var adjustments: TasteAdjustmentSet
    /// Recordings the listener ignored three times (6.1); empty until the event log records.
    public var ignoredRids: Set<Int64>
    /// The existing ranking's picks from the library, asked for only when the library pool is needed.
    public var libraryPicks: @Sendable () async -> [Song]
    /// Three skips in a row with no other anchor to turn to (7.3): seed from the listener's best-loved library
    /// artist outside the ones just skipped, when one has a known YouTube audio id.
    public var otherDirection = false
    /// The stored YouTube match of a Spotify track id (for the other-direction seed).
    public var matchedVideoId: @Sendable (String) async -> String? = { _ in nil }
    public var nowMs: Int64 = 0
    /// The station the pool is for (8.3); nil for plain autoplay. An artist station leads with the artist's own
    /// radio.
    public var station: Station? = nil
    /// The phone has no network at all (as opposed to the YouTube source being switched off): only tracks that
    /// play from the phone may be queued.
    public var offline = false
    /// Which of these library songs play with no network (a file on the phone, a finished download, a complete
    /// copy in the audio cache), by song id. Asked only when `offline`, with the songs the pool would hold.
    public var offlinePlayable: @Sendable ([Song]) async -> Set<String> = { _ in [] }

    public init(anchors: [AutoplayAnchor], deepen: Bool, allowNetwork: Bool, library: [Song], everPlayed: Set<String>,
                blocked: BlockedArtistMatcher = .empty, adjustments: TasteAdjustmentSet = .empty,
                ignoredRids: Set<Int64> = [], libraryPicks: @escaping @Sendable () async -> [Song] = { [] }) {
        self.anchors = anchors
        self.deepen = deepen
        self.allowNetwork = allowNetwork
        self.library = library
        self.everPlayed = everPlayed
        self.blocked = blocked
        self.adjustments = adjustments
        self.ignoredRids = ignoredRids
        self.libraryPicks = libraryPicks
    }
}

/// The pool Autoplay picks from.
public enum AutoplayPool {
    static let deepenContinuations = 2
    /// Library tracks by each anchor's artist that join the radio rows as candidates (6.1 FAV and DEEP).
    static let libraryPerAnchorArtist = 30
    static let otherDirectionTries = 5

    /// One radio as it came back: its entries, and what the retrieval step needs.
    struct Fetched: Sendable {
        var entries: [AutoplayPoolEntry]
        var seedRid: Int64
        var rids: [Int64]
        var related: Bool
        var artist: String
    }

    static func albumHash(_ albumKey: String?) -> Int64 {
        guard let albumKey else { return 0 }
        return BrainHash.id(BrainHash.fnv1a64(albumKey))
    }

    /// The listener's boost / reduce for a song, as the planner adds it: `ln(product)`, 0 for none (5.11).
    static func boostLn(_ adjustments: TasteAdjustmentSet, _ song: Song) -> Double {
        if adjustments.isEmpty { return 0.0 }
        let multiplier = adjustments.factor(for: song)
        return multiplier == 1.0 || multiplier <= 0.0 ? 0.0 : BrainMath.ln(multiplier)
    }

    /// The key of a set of anchors: a pool belongs to its anchors; other anchors, another pool.
    public static func key(of mediaIds: [String]) -> String { mediaIds.joined(separator: "|") }

    public static func build(_ request: AutoplayPoolRequest, index: BrainLibraryIndex,
                             repository: BrainRepository?, engine: BrainEngine? = nil) async -> BuiltAutoplayPool {
        var request = request
        // Recordings the listener ignored three times stay away for 60 days (6.1).
        if let engine, request.ignoredRids.isEmpty { request.ignoredRids = await engine.ignoredRids(nowMs: request.nowMs) }
        if request.otherDirection, request.station == nil, let repository, let engine,
           let anchor = await otherDirectionAnchor(request, index: index, repository: repository, engine: engine) {
            request.anchors = [anchor]
        }
        var seedFlags: Int32 = 0
        var anchorArtistKeys: [String] = []
        var seeds: [(seed: RadioSeed, whyArtist: String)] = []
        for anchor in request.anchors {
            seedFlags |= BrainText.cleanTitle(anchor.song.title).versionFlags
            let primaryArtist = BrainLibraryIndex.primaryArtistName(anchor.song)
            if !BrainText.isBlank(primaryArtist) {
                let key = BrainText.fold(primaryArtist)
                if !anchorArtistKeys.contains(where: { BrainKey.sameBytes($0, key) }) { anchorArtistKeys.append(key) }
            }
            if let videoId = anchor.videoId, !BrainText.isBlank(videoId) {
                seeds.append((RadioSeed(mediaId: anchor.song.id, videoId: videoId, title: anchor.song.title,
                                        primaryArtist: primaryArtist, durationMs: anchor.song.duration,
                                        spotifyId: anchor.spotifyId), primaryArtist))
            }
        }

        if !request.allowNetwork {
            // 7.1: offline, or with the YouTube source switched off, the pool is the library alone. A radio that is
            // still in the cache names tracks from outside the library, and those need the network to play. With
            // no network at all, a library track without a copy on the phone needs it too: such a track would fail
            // to load, one after another, where the queue used to end.
            var entries = await libraryPool(request, index: index, anchorArtistKeys: anchorArtistKeys)
            if request.offline {
                let playable = await request.offlinePlayable(entries.compactMap(\.librarySong))
                entries = entries.filter { playable.contains($0.candidate.mediaId) }
            }
            return BuiltAutoplayPool(entries: entries, fromLibrary: true, offline: request.offline)
        }

        var fetched: [Fetched] = []
        if let repository {
            // At most two radio requests run at a time (the budget's own limit); the anchors are asked together.
            // Only the newest anchor may cost a request: the older ones were the newest in their turn, and are
            // answered from the cache or not at all. Three new anchors after an album would otherwise spend three
            // requests of a small daily allowance on one top-up.
            let collected = await withTaskGroup(of: (Int, Fetched?).self) { group in
                for (i, item) in seeds.enumerated() {
                    let continuations = request.deepen && i == 0 ? deepenContinuations : 0
                    let everPlayed = request.everPlayed
                    // An album or playlist station has several seeds that all matter (6.2): each may cost a request.
                    let allowNetwork = i == 0 || request.station != nil
                    let adjustments = request.adjustments
                    group.addTask {
                        guard let radio = await repository.radioFor(seed: item.seed, allowNetwork: allowNetwork,
                                                                    continuations: continuations) else { return (i, nil) }
                        let artistRadio = radio.kind == RadioList.kindArtist
                        var list: [AutoplayPoolEntry] = []
                        list.reserveCapacity(radio.rows.count)
                        for (rank, stored) in radio.rows.enumerated() {
                            if let entry = entry(for: stored, rank: Int32(rank + 1), index: index, everPlayed: everPlayed,
                                                 anchorArtist: item.whyArtist, artistRadio: artistRadio,
                                                 adjustments: adjustments) {
                                list.append(entry)
                            }
                        }
                        return (i, Fetched(entries: list, seedRid: radio.seedRid, rids: radio.rows.map(\.rid),
                                           related: radio.kind == RadioList.kindRelated, artist: item.whyArtist))
                    }
                }
                var collected = [Fetched?](repeating: nil, count: seeds.count)
                for await (i, list) in group { collected[i] = list }
                return collected
            }
            fetched = collected.compactMap { $0 }
            if let station = request.station, station.isArtist, let first = seeds.first {
                // An artist station leads with the artist's own radio (6.2): the artist page's top songs and the
                // radio its button starts. Asked after the seed's song radio, whose rows usually name the artist's
                // channel, so the first request is not made twice. Only the artist's own tracks count as "more
                // from" them; the rest are what their listeners also play.
                let artistKey = BrainText.fold(first.whyArtist)
                if let radio = await repository.artistRadio(seed: first.seed, allowNetwork: request.allowNetwork) {
                    // Songs of artists close to this one (6.2): the top songs of three of the page's "Fans might also like".
                    let similarRows = await repository.similarArtistSongs(seed: first.seed, allowNetwork: request.allowNetwork)
                    var list: [AutoplayPoolEntry] = []
                    list.reserveCapacity(radio.rows.count + similarRows.count)
                    for (rank, stored) in radio.rows.enumerated() {
                        let own = !artistKey.isEmpty
                            && BrainKey.sameBytes(BrainLibraryIndex.artistKey(of: stored.row), artistKey)
                        if let entry = entry(for: stored, rank: Int32(rank + 1), index: index,
                                             everPlayed: request.everPlayed, anchorArtist: first.whyArtist,
                                             artistRadio: own, adjustments: request.adjustments) {
                            list.append(entry)
                        }
                    }
                    for (rank, stored) in similarRows.enumerated() {
                        if let entry = entry(for: stored, rank: Int32(radio.rows.count + rank + 1), index: index,
                                             everPlayed: request.everPlayed, anchorArtist: first.whyArtist,
                                             artistRadio: false, adjustments: request.adjustments, fromSimilar: true) {
                            list.append(entry)
                        }
                    }
                    fetched.insert(Fetched(entries: list, seedRid: radio.seedRid,
                                           rids: radio.rows.map(\.rid) + similarRows.map(\.rid),
                                           related: false, artist: first.whyArtist), at: 0)
                }
            }
        }
        let lists = fetched.map(\.entries)

        var byMediaId: [BrainKey: AutoplayPoolEntry] = [:]
        for list in lists {
            for entry in list where byMediaId[BrainKey(entry.candidate.mediaId)] == nil {
                byMediaId[BrainKey(entry.candidate.mediaId)] = entry
            }
        }
        let ordered = AutoplayPolicy.interleave(lists.map { $0.map(\.candidate) })
        var entries: [AutoplayPoolEntry] = []
        entries.reserveCapacity(ordered.count)
        for candidate in ordered {
            if !AutoplayPolicy.passesFilters(candidate, seedFlags: seedFlags) { continue }
            if request.ignoredRids.contains(candidate.rid) { continue }
            guard let entry = byMediaId[BrainKey(candidate.mediaId)], isAllowed(entry, request) else { continue }
            entries.append(entry)
        }

        if !entries.isEmpty, let repository {
            // Library tracks by the anchors' artists are candidates too (6.1 FAV and DEEP), whether or not a radio
            // names them.
            var known = Set(entries.map { BrainKey($0.candidate.mediaId) })
            let anchorIds = Set(request.anchors.map { BrainKey($0.song.id) })
            var extra: [Song] = []
            for artistKey in anchorArtistKeys {
                var taken = 0
                for song in index.byPrimaryArtist(artistKey) {
                    if taken >= libraryPerAnchorArtist { break }
                    if anchorIds.contains(BrainKey(song.id)) || !isAllowed(song, request) { continue }
                    if !known.insert(BrainKey(song.id)).inserted { continue }
                    extra.append(song)
                    taken += 1
                }
            }
            let extraFacts = extra.map(TrackCatalog.facts(of:))
            let extraRids = await repository.resolveTracks(extraFacts.map { facts in
                TrackRequest(keys: facts?.keys ?? Ids.TrackKeys(), durationMs: Int32(clamping: max(facts?.durationMs ?? 0, 0)))
            })
            for (i, song) in extra.enumerated() where extraRids[i] != 0 && !request.ignoredRids.contains(extraRids[i]) {
                let entry = libraryEntry(song, rid: extraRids[i], rank: 0, everPlayed: request.everPlayed,
                                         anchorArtist: "", adjustments: request.adjustments)
                if AutoplayPolicy.passesFilters(entry.candidate, seedFlags: seedFlags) { entries.append(entry) }
            }

            // Artists by id: stage 1 joins them by folded name (3.1), through the alias table.
            var names: [String] = []
            var seenNames: Set<BrainKey> = []
            for list in fetched where !BrainText.isBlank(list.artist) && seenNames.insert(BrainKey(list.artist)).inserted {
                names.append(list.artist)
            }
            for entry in entries where !BrainText.isBlank(entry.primaryArtist)
                && seenNames.insert(BrainKey(entry.primaryArtist)).inserted {
                names.append(entry.primaryArtist)
            }
            let aids = await repository.resolveArtistNames(names)
            var aidByName: [BrainKey: Int64] = [:]
            var nameByAid: [Int64: String] = [:]
            for (i, name) in names.enumerated() {
                aidByName[BrainKey(name)] = aids[i]
                if aids[i] != 0 && nameByAid[aids[i]] == nil { nameByAid[aids[i]] = name }
            }
            for i in entries.indices where entries[i].brain != nil {
                entries[i].brain!.aid = aidByName[BrainKey(entries[i].primaryArtist)] ?? 0
            }
            let seedLists = fetched.map { list in
                Retrieval.SeedList(seedRid: list.seedRid, seedAid: aidByName[BrainKey(list.artist)] ?? 0, rids: list.rids,
                                   edgeFactor: list.related ? Graph.related : Graph.radio)
            }
            if request.deepen && entries.count < AutoplayPolicy.poolRefillBelow {
                // The radios are running dry even with their continuation pages: the library carries on behind them,
                // so the queue does not end while there is anything left to play. That pool has no recording ids,
                // so it is picked in its own order.
                var seen = Set(entries.map { BrainKey($0.candidate.mediaId) })
                for entry in await libraryPool(request, index: index, anchorArtistKeys: anchorArtistKeys)
                where seen.insert(BrainKey(entry.candidate.mediaId)).inserted {
                    entries.append(entry)
                }
                return BuiltAutoplayPool(entries: entries, fromLibrary: false)
            }
            return BuiltAutoplayPool(entries: entries, fromLibrary: false, seeds: seedLists, artistNames: nameByAid)
        }
        return BuiltAutoplayPool(entries: await libraryPool(request, index: index, anchorArtistKeys: anchorArtistKeys),
                                 fromLibrary: true, fellBack: true)
    }

    static func isAllowed(_ entry: AutoplayPoolEntry, _ request: AutoplayPoolRequest) -> Bool {
        guard let song = entry.librarySong ?? entry.engineTrack?.song() else { return false }
        return isAllowed(song, request)
    }

    static func isAllowed(_ song: Song, _ request: AutoplayPoolRequest) -> Bool {
        !request.blocked.isBlocked(song) && !request.adjustments.isExcluded(song) && !request.adjustments.isBlocked(song)
    }

    static func entry(for stored: StoredRadioRow, rank: Int32, index: BrainLibraryIndex, everPlayed: Set<String>,
                      anchorArtist: String, artistRadio: Bool,
                      adjustments: TasteAdjustmentSet = .empty, fromSimilar: Bool = false) -> AutoplayPoolEntry? {
        let row = stored.row
        if let librarySong = index.match(row) {
            return libraryEntry(librarySong, rid: stored.rid, rank: rank, everPlayed: everPlayed,
                                anchorArtist: anchorArtist, adjustments: adjustments)
        }
        if row.artists.isEmpty { return nil }
        let track = EngineTrack(row: row, rid: stored.rid)
        let albumKey = row.album.flatMap(BrainLibraryIndex.albumKey(of:))
        return AutoplayPoolEntry(
            candidate: AutoplayPolicy.Candidate(
                mediaId: track.songId, rid: stored.rid, artistKey: BrainLibraryIndex.artistKey(of: row),
                albumKey: albumKey, durationMs: track.durationMs,
                versionFlags: BrainText.cleanTitle(row.title).versionFlags, officialAudio: row.isOfficialAudio,
                inLibrary: false, arm: fromSimilar ? Arm.sim : (artistRadio ? Arm.artist : Arm.radio), radioRank: rank),
            librarySong: nil, engineTrack: track, whyArtist: anchorArtist,
            primaryArtist: row.artists.first?.name ?? "",
            brain: Candidate(rid: stored.rid, aid: 0, albumKey: albumHash(albumKey), inLibrary: false,
                             fromArtistRadio: artistRadio && !fromSimilar,
                             boostLn: adjustments.isEmpty ? 0.0 : boostLn(adjustments, track.song()),
                             fromSimilarArtist: fromSimilar))
    }

    /// A library track as a pool entry: it plays from its library row.
    static func libraryEntry(_ song: Song, rid: Int64, rank: Int32, everPlayed: Set<String>, anchorArtist: String,
                             adjustments: TasteAdjustmentSet) -> AutoplayPoolEntry {
        let albumKey = BrainLibraryIndex.albumKey(of: song.album)
        return AutoplayPoolEntry(
            candidate: AutoplayPolicy.Candidate(
                mediaId: song.id, rid: rid, artistKey: BrainLibraryIndex.artistKey(of: song), albumKey: albumKey,
                durationMs: song.duration, versionFlags: BrainText.cleanTitle(song.title).versionFlags,
                officialAudio: true, inLibrary: true,
                arm: AutoplayPolicy.libraryArm(everPlayed: everPlayed.contains(song.id)), radioRank: rank),
            librarySong: song, engineTrack: nil, whyArtist: anchorArtist,
            primaryArtist: BrainLibraryIndex.primaryArtistName(song),
            brain: Candidate(rid: rid, aid: 0, albumKey: albumHash(albumKey), inLibrary: true, liked: song.isFavorite,
                             boostLn: boostLn(adjustments, song)))
    }

    /// The seed for a change of direction when the session has no other anchor: a library track with a known
    /// YouTube audio id, by the library artist the listener finishes most, outside the artists just skipped.
    static func otherDirectionAnchor(_ request: AutoplayPoolRequest, index: BrainLibraryIndex,
                                     repository: BrainRepository, engine: BrainEngine) async -> AutoplayAnchor? {
        if request.library.isEmpty { return nil }
        let keys = index.artistKeys()
        let names = keys.map { key in index.byPrimaryArtist(key).first.map(BrainLibraryIndex.primaryArtistName) ?? "" }
        let aids = await repository.resolveArtistNames(names)
        let order = await engine.otherDirectionOrder(aids: aids, nowMs: request.nowMs, limit: otherDirectionTries)
        for i in order {
            for song in index.byPrimaryArtist(keys[i]).prefix(otherDirectionTries) {
                var spotifyId = song.spotifyId
                if let id = spotifyId, BrainText.isBlank(id) || TrackCatalog.isSyntheticId(id) { spotifyId = nil }
                var videoId = TrackCatalog.videoId(ofSongId: song.id)
                if videoId == nil, let spotifyId { videoId = await request.matchedVideoId(spotifyId) }
                guard let videoId else { continue }
                return AutoplayAnchor(song: song, videoId: videoId, spotifyId: spotifyId)
            }
        }
        return nil
    }

    /// Offline, the YouTube source switched off, or no radio had anything: tracks by the anchors' primary artists
    /// first, then the existing ranking's picks. The hard constraints still apply on the way out.
    static func libraryPool(_ request: AutoplayPoolRequest, index: BrainLibraryIndex,
                            anchorArtistKeys: [String]) async -> [AutoplayPoolEntry] {
        if request.library.isEmpty { return [] }
        let anchorIds = Set(request.anchors.map { BrainKey($0.song.id) })
        var seen = Set<BrainKey>()
        var songs: [Song] = []
        // A fixed order per set of anchors, different between sets: SplitMix64 keyed by the anchors.
        let seed = BrainHash.fnv1a64(key(of: request.anchors.map(\.song.id)))
        for artistKey in anchorArtistKeys {
            let keyed = index.byPrimaryArtist(artistKey).map { song in
                (order: BrainHash.splitmix64(BrainHash.fnv1a64(song.id) ^ seed), song: song)
            }
            // Unsigned order; equal hashes keep library order (the sort is given a total order by position).
            let sorted = keyed.enumerated().sorted { a, b in
                a.element.order != b.element.order ? a.element.order < b.element.order : a.offset < b.offset
            }
            for item in sorted where seen.insert(BrainKey(item.element.song.id)).inserted {
                songs.append(item.element.song)
            }
        }
        for pick in await request.libraryPicks() where seen.insert(BrainKey(pick.id)).inserted { songs.append(pick) }

        var out: [AutoplayPoolEntry] = []
        out.reserveCapacity(songs.count)
        for song in songs {
            if anchorIds.contains(BrainKey(song.id)) || !isAllowed(song, request) { continue }
            let candidate = AutoplayPolicy.Candidate(
                mediaId: song.id, rid: 0, artistKey: BrainLibraryIndex.artistKey(of: song),
                albumKey: BrainLibraryIndex.albumKey(of: song.album), durationMs: song.duration, versionFlags: 0,
                officialAudio: true, inLibrary: true,
                arm: AutoplayPolicy.libraryArm(everPlayed: request.everPlayed.contains(song.id)), radioRank: 0)
            if AutoplayPolicy.passesFilters(candidate, seedFlags: 0) {
                out.append(AutoplayPoolEntry(candidate: candidate, librarySong: song, engineTrack: nil, whyArtist: ""))
            }
        }
        return out
    }
}
