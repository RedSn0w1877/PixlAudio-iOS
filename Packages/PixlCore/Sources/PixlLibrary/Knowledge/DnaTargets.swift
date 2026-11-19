// Who the DNA lanes work on (docs/brain-spec.md, 3.7): lane 3 the tracks the listener plays most, lane 4 the rest of the
// library, lane 5 the rows whose tags or popularity have expired. A port of Android's `DnaTargets.kt`. Only the library
// is enriched in this milestone: the graph nodes outside it wait for the milestone that shows them.
//
// A target carries what the app already knows, so a source is only asked what it can add: the ISRC (from the Spotify
// sync), the Spotify artist genres already synced with the top artists, the genre chips of the track's own radio. With
// "Use my Spotify music to shape picks" off, no Spotify fact or genre is used.

import Foundation
import PixlModel

/// What `DnaTargets` reads from the rest of the app (set by `AppEnvironment`; nothing is read until a lane asks).
public struct DnaSources: Sendable {
    /// The library as it is now.
    public var library: @Sendable () async -> [Song]
    /// "Use my Spotify music to shape picks" (13.1).
    public var spotifyShapesPicks: @Sendable () -> Bool
    /// The listener's top artists the Spotify sync saved, with the genres Spotify sent for each (the sync keeps names, not ids).
    public var spotifyTopArtists: @Sendable () async -> [ExternalTasteSnapshot.RankedArtist]
    /// The facts the Spotify sync kept for these Spotify ids.
    public var spotifyFacts: @Sendable ([String]) async -> [SpotifyFactStore.Row]

    public init(library: @escaping @Sendable () async -> [Song], spotifyShapesPicks: @escaping @Sendable () -> Bool = { true },
                spotifyTopArtists: @escaping @Sendable () async -> [ExternalTasteSnapshot.RankedArtist] = { [] },
                spotifyFacts: @escaping @Sendable ([String]) async -> [SpotifyFactStore.Row] = { _ in [] }) {
        self.library = library
        self.spotifyShapesPicks = spotifyShapesPicks
        self.spotifyTopArtists = spotifyTopArtists
        self.spotifyFacts = spotifyFacts
    }
}

public extension DnaSources {
    /// Spotify's genres by the folded name of the artist: the first range that sent any wins.
    static func genresByName(_ artists: [ExternalTasteSnapshot.RankedArtist]) -> [BrainKey: [String]] {
        var out: [BrainKey: [String]] = [:]
        for a in artists where !a.genres.isEmpty {
            let key = BrainKey(BrainText.fold(a.name))
            if out[key] == nil { out[key] = a.genres }
        }
        return out
    }

    /// How many distinct top artists the sync saved, and how many of them came with genres (the check of spec 14.6, S1).
    static func genreCounts(_ artists: [ExternalTasteSnapshot.RankedArtist]) -> (total: Int, withGenres: Int) {
        var seen: Set<BrainKey> = []
        var withGenres = 0
        for a in artists where seen.insert(BrainKey(BrainText.fold(a.name))).inserted {
            if !a.genres.isEmpty { withGenres += 1 }
        }
        return (seen.count, withGenres)
    }
}

public actor DnaTargets {
    /// A row some of whose sources have not answered is looked at again after a day.
    static let retryUnaskedMs: Int64 = 24 * 60 * 60 * 1000
    /// How far down the most played list lane 3 reads for tracks without DNA.
    static let rankedWindow = 1_000

    private let sources: DnaSources
    private let repository: BrainRepository
    private let engine: BrainEngine
    private let store: DnaRepository
    private let clock: @Sendable () -> Int64
    /// The library resolved to recording ids for this run of lane 3 (the whole library is resolved once, not per round).
    private var resolved: (count: Int, byRid: [Int64: Song])?

    public init(sources: DnaSources, repository: BrainRepository, engine: BrainEngine, store: DnaRepository,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.sources = sources
        self.repository = repository
        self.engine = engine
        self.store = store
        self.clock = clock
    }

    /// Lane 3: the tracks played most (decayed engagement), without DNA yet.
    public func mostPlayed(limit: Int) async -> [DnaTarget] {
        let now = clock()
        let ranked: [Int64] = await engine.readAffinity { state in
            let keys = state.sortedKeys(Family.track)
            var weights: [Int64: Double] = [:]
            weights.reserveCapacity(keys.count * 2)
            for k in keys { weights[k] = Affinity.weight(state, family: Family.track, key: k, nowMs: now) }
            let order = keys.sorted { a, b in
                let wa = weights[a] ?? 0.0, wb = weights[b] ?? 0.0
                return wa != wb ? wa > wb : a < b
            }
            return Array(order.prefix(Self.rankedWindow))
        }
        if ranked.isEmpty { return [] }
        let haveRow = Set(await store.tracks(ranked).map(\.rid))
        let byRid = await libraryByRid()
        var rids: [Int64] = []
        var songs: [Song] = []
        for rid in ranked {
            if rids.count >= limit { break }
            if haveRow.contains(rid) { continue }
            guard let song = byRid[rid] else { continue }
            rids.append(rid)
            songs.append(song)
        }
        return await build(songs, rids)
    }

    /// Lane 4: the rest of the library, in the library's own order, without DNA yet.
    public func restOfLibrary(limit: Int) async -> [DnaTarget] {
        let library = await realSpotifyLibrary()
        if library.isEmpty { return [] }
        let known = await store.knownSpotifyIds(library.compactMap(\.spotifyId))
        let missing = library.filter { !known.contains($0.spotifyId ?? "") }.prefix(limit)
        if missing.isEmpty { return [] }
        var requests: [TrackRequest] = []
        var kept: [Song] = []
        for song in missing {
            guard let f = TrackCatalog.facts(of: song) else { continue }
            requests.append(TrackRequest(keys: f.keys, durationMs: Int32(clamping: max(song.duration, 0))))
            kept.append(song)
        }
        let rids = await repository.resolveTracks(requests)
        return await build(kept, rids)
    }

    /// Lane 5: rows whose tags (90 days) or popularity (7 days) have expired, the stalest first.
    public func expired(limit: Int) async -> [DnaTarget] {
        let now = clock()
        let rows = await store.expired(tagsBefore: now - DnaEnricher.tagsTtlMs, popBefore: now - DnaEnricher.popularityTtlMs,
                                       retryBefore: now - Self.retryUnaskedMs, limit: limit)
        if rows.isEmpty { return [] }
        let aids = rows.compactMap { Int64($0.artistIds.split(separator: ",").first ?? "") }
        var names: [Int64: String] = [:]
        for a in await store.artists(Array(Set(aids))) { names[a.aid] = a.name }
        let shapes = sources.spotifyShapesPicks()
        let genres = shapes ? DnaSources.genresByName(await sources.spotifyTopArtists()) : [:]
        var facts: [String: SpotifyFactStore.Row] = [:]
        if shapes {
            for f in await sources.spotifyFacts(rows.compactMap(\.spotifyId)) { facts[f.spotifyId] = f }
        }
        var out: [DnaTarget] = []
        for r in rows {
            let aid = Int64(r.artistIds.split(separator: ",").first ?? "") ?? 0
            let fact = r.spotifyId.flatMap { facts[$0] }
            let artist = names[aid] ?? r.artistDisplay.components(separatedBy: ", ").first ?? r.artistDisplay
            out.append(await target(rid: r.rid, aid: aid, spotifyId: r.spotifyId, isrc: r.isrc, title: r.title, artist: artist,
                              artistDisplay: r.artistDisplay, durationMs: r.durationMs, albumName: nil, fact: fact,
                              spotifyGenres: genres[BrainKey(BrainText.fold(artist))] ?? [], songYear: 0))
        }
        return out
    }

    // MARK: Shared

    /// The library's songs that have a real Spotify id, in the library's own order, one per id.
    private func realSpotifyLibrary() async -> [Song] {
        var seen: Set<BrainKey> = []
        var out: [Song] = []
        for song in await sources.library() {
            guard let id = song.spotifyId, !BrainText.isBlank(id), !TrackCatalog.isSyntheticId(id) else { continue }
            if seen.insert(BrainKey(id)).inserted { out.append(song) }
        }
        return out
    }

    private func libraryByRid() async -> [Int64: Song] {
        let library = await realSpotifyLibrary()
        if let resolved, resolved.count == library.count { return resolved.byRid }
        var requests: [TrackRequest] = []
        var kept: [Song] = []
        requests.reserveCapacity(library.count)
        for song in library {
            guard let f = TrackCatalog.facts(of: song) else { continue }
            requests.append(TrackRequest(keys: f.keys, durationMs: Int32(clamping: max(song.duration, 0))))
            kept.append(song)
        }
        let rids = await repository.resolveTracks(requests)
        var byRid: [Int64: Song] = [:]
        byRid.reserveCapacity(kept.count)
        for i in kept.indices where i < rids.count && rids[i] != 0 && byRid[rids[i]] == nil { byRid[rids[i]] = kept[i] }
        resolved = (library.count, byRid)
        return byRid
    }

    private func build(_ songs: [Song], _ rids: [Int64]) async -> [DnaTarget] {
        if songs.isEmpty { return [] }
        let shapes = sources.spotifyShapesPicks()
        var facts: [String: SpotifyFactStore.Row] = [:]
        if shapes {
            for f in await sources.spotifyFacts(songs.compactMap(\.spotifyId)) { facts[f.spotifyId] = f }
        }
        let genres = shapes ? DnaSources.genresByName(await sources.spotifyTopArtists()) : [:]
        let names = songs.map { BrainLibraryIndex.primaryArtistName($0) }
        let aids = await repository.resolveArtistNames(names)
        var out: [DnaTarget] = []
        out.reserveCapacity(songs.count)
        for i in songs.indices {
            let song = songs[i]
            let rid = i < rids.count ? rids[i] : 0
            if rid == 0 { continue }
            let fact = song.spotifyId.flatMap { facts[$0] }
            var g: [String] = []
            g.append(contentsOf: genres[BrainKey(BrainText.fold(names[i]))] ?? [])
            if shapes, let own = song.genre, !BrainText.isBlank(own) { g.append(own) }
            var distinct: [String] = []
            for x in g where !distinct.contains(where: { BrainKey.sameBytes($0, x) }) { distinct.append(x) }
            out.append(await target(rid: rid, aid: i < aids.count ? aids[i] : 0, spotifyId: song.spotifyId, isrc: fact?.isrc, title: song.title,
                              artist: names[i], artistDisplay: song.displayArtist,
                              durationMs: Int(clamping: max(0, min(song.duration, Int64(Int32.max)))), albumName: song.album,
                              fact: fact, spotifyGenres: distinct, songYear: shapes ? song.year : 0))
        }
        return out
    }

    private func target(rid: Int64, aid: Int64, spotifyId: String?, isrc: String?, title: String, artist: String,
                        artistDisplay: String, durationMs: Int, albumName: String?, fact: SpotifyFactStore.Row?,
                        spotifyGenres: [String], songYear: Int) async -> DnaTarget {
        let chips = await repository.chipTagsOf(seedRid: rid).filter { $0.kind == .genre }.map(\.key)
        return DnaTarget(
            rid: rid, aid: aid, spotifyId: spotifyId, isrc: isrc, title: title, artist: artist, artistDisplay: artistDisplay,
            durationMs: durationMs, albumName: albumName, spotifyArtistIds: fact?.artistIds ?? [],
            spotifyReleaseDate: fact?.releaseDate ?? ((songYear >= 1900 && songYear <= 2200) ? String(songYear) : nil),
            spotifyExplicit: fact?.explicit, spotifyGenres: spotifyGenres, chipGenres: chips,
            spotifyOff: !sources.spotifyShapesPicks())
    }
}
