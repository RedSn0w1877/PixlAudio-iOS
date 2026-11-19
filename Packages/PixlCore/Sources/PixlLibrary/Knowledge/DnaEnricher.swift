// The enrichment lanes 3 to 5 of docs/brain-spec.md, 3.7: for each track, ask the open-data sources in the fallback order
// of 3.3, keep what they say in `track_dna` and `artist_dna`, and never ask twice for what is fresh. A port of Android's
// `DnaEnricher.kt` and `AtlasProvider.kt`.
//
//  - Order. Deezer (by ISRC, else by name), MusicBrainz (the recording and its first year, then the artist's genres),
//    iTunes (by name), then one ListenBrainz batch for the recordings found and one Wikidata query for their artists. The
//    Spotify artist genres and the radio's genre chips need no request and are read from `DnaTarget`.
//  - Fresh is never asked again. Ids, year and tempo never expire; tags 90 days; popularity 7 days; a source that had
//    nothing is not asked again for 14 days, doubling to 120 (`source_miss`).
//  - One door. Every request goes through `KnowledgeHttp`: the source's own off switch (local and remote), its daily budget
//    and ledger, its spacing and its back-off. A source that cannot be asked is skipped for this track and tried again
//    next run.
//  - Stoppable. `gate` is asked before each track and before each batch call; false stops the run and what was gathered is
//    still saved.

import Foundation
import PixlModel

/// Where the genre atlas comes from: the bundled asset in the app, a plain object in tests.
public protocol AtlasProvider: Sendable {
    /// The parsed atlas, or nil when it cannot be read. Parsing runs off the main thread; never called at app start.
    func atlas() async -> GenreAtlas?
    /// The atlas if it is already in memory; never loads.
    func loadedOrNil() async -> GenreAtlas?
}

/// Loads the atlas with `load` (the app reads and gunzips its bundled asset) the first time something needs a genre, and
/// keeps it. Two callers at once share one load; a load that failed is tried again by the next caller.
public actor CachedAtlasProvider: AtlasProvider {
    private let load: @Sendable () async -> GenreAtlas?
    private var cached: GenreAtlas?
    private var loading: Task<GenreAtlas?, Never>?

    public init(load: @escaping @Sendable () async -> GenreAtlas?) { self.load = load }

    public func loadedOrNil() -> GenreAtlas? { cached }

    public func atlas() async -> GenreAtlas? {
        if let cached { return cached }
        if let loading { return await loading.value }
        let load = self.load
        let task = Task.detached(priority: .utility) { await load() }
        loading = task
        let result = await task.value
        loading = nil
        if let result { cached = result }
        return result
    }
}

/// The two halves of lanes 3 to 5, handed to the refresh together: who to work on, and the work.
public struct DnaLanes: Sendable {
    public let targets: DnaTargets
    public let enricher: DnaEnricher
    public init(targets: DnaTargets, enricher: DnaEnricher) {
        self.targets = targets
        self.enricher = enricher
    }
}

public struct DnaEnricher: Sendable {
    public static let popularityTtlMs: Int64 = 7 * 24 * 60 * 60 * 1000
    public static let tagsTtlMs: Int64 = 90 * 24 * 60 * 60 * 1000
    public static let missFirstMs: Int64 = 14 * 24 * 60 * 60 * 1000
    public static let missCapMs: Int64 = 120 * 24 * 60 * 60 * 1000

    public struct Report: Sendable, Equatable {
        public var tracks: Int
        public var stopped: Bool
        public var noAtlas: Bool
        public init(tracks: Int, stopped: Bool, noAtlas: Bool = false) {
            self.tracks = tracks
            self.stopped = stopped
            self.noAtlas = noAtlas
        }
    }

    private let deezer: DeezerSource
    private let musicBrainz: MusicBrainzSource
    private let listenBrainz: ListenBrainzSource
    private let wikidata: WikidataSource
    private let itunes: ITunesSource
    private let store: DnaRepository
    private let atlasProvider: any AtlasProvider
    private let clock: @Sendable () -> Int64
    private let timing: @Sendable (String, Int64) -> Void

    public init(http: any KnowledgeHttp, store: DnaRepository, atlas: any AtlasProvider,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() },
                timing: @escaping @Sendable (String, Int64) -> Void = { _, _ in }) {
        deezer = DeezerSource(http: http)
        musicBrainz = MusicBrainzSource(http: http)
        listenBrainz = ListenBrainzSource(http: http)
        wikidata = WikidataSource(http: http)
        itunes = ITunesSource(http: http)
        self.store = store
        atlasProvider = atlas
        self.clock = clock
        self.timing = timing
    }

    /// One target's working state while the sources are asked.
    private final class State {
        let target: DnaTarget
        let prior: TrackDnaRow?
        let priorArtist: ArtistDnaRow?
        var tried = 0
        var deezerTrack: DeezerTrack?
        var deezerAlbum: DeezerAlbum?
        var mb: MbRecordingHit?
        var mbArtist: MbArtist?
        var lb: LbRecording?
        var lbPop: LbPopularity?
        var wd: WdArtist?
        var itunes: ITunesSong?
        let want: TrackMatch.Want
        let entity: String
        var recordingMbid: String?
        var artistMbid: String?

        init(target: DnaTarget, prior: TrackDnaRow?, priorArtist: ArtistDnaRow?) {
            self.target = target
            self.prior = prior
            self.priorArtist = priorArtist
            want = TrackMatch.Want(title: target.title, artist: target.artist, durationMs: target.durationMs)
            entity = "t:\(target.rid)"
            recordingMbid = prior?.mbRecordingId
            artistMbid = priorArtist?.mbid
        }

        func evidence() -> DnaEvidence {
            DnaEvidence(deezerTrack: deezerTrack, deezerAlbum: deezerAlbum, mb: mb, mbArtist: mbArtist, lb: lb,
                        lbPopularity: lbPop, wd: wd, itunes: itunes, tried: tried)
        }

        func priorArtistFresh(_ now: Int64, _ bit: Int) -> Bool {
            guard let a = priorArtist else { return false }
            return a.fetchedMask & bit != 0 && a.tagsAtMs > 0 && now - a.tagsAtMs <= DnaEnricher.tagsTtlMs
        }
    }

    /// True when `bit` has to be asked for this row now: never tried, or its part of the row has expired.
    private func stale(_ mask: Int, _ bit: Int, _ stampMs: Int64, _ ttlMs: Int64, _ now: Int64, hasRow: Bool) -> Bool {
        !hasRow || mask & bit == 0 || (stampMs > 0 && now - stampMs > ttlMs)
    }

    public func enrich(_ targets: [DnaTarget], gate: @Sendable () async -> Bool) async -> Report {
        if targets.isEmpty { return Report(tracks: 0, stopped: false) }
        let startedMs = clock()
        guard let atlas = await atlasProvider.atlas() else { return Report(tracks: 0, stopped: false, noAtlas: true) }
        let version = atlas.version
        let now = clock()
        var states: [State] = []
        states.reserveCapacity(targets.count)
        var priors: [Int64: TrackDnaRow] = [:]
        for row in await store.tracks(targets.map(\.rid)) { priors[row.rid] = row }
        var priorArtists: [Int64: ArtistDnaRow] = [:]
        for row in await store.artists(Array(Set(targets.map(\.aid).filter { $0 != 0 }))) { priorArtists[row.aid] = row }
        let entities = targets.map { "t:\($0.rid)" }
        var blockedBySource: [Int: Set<String>] = [:]
        func blocked(_ bit: Int, _ entity: String) async -> Bool {
            let n = DnaSource.numberOf(bit)
            if blockedBySource[n] == nil { blockedBySource[n] = await store.blocked(source: n, nowMs: now, entities: entities) }
            return blockedBySource[n]?.contains(entity) ?? false
        }

        /// Stale and not in the negative cache.
        func due(_ isStale: Bool, _ bit: Int, _ entity: String) async -> Bool {
            if !isStale { return false }
            return await !blocked(bit, entity)
        }

        var albumCache: [Int64: Lookup<DeezerAlbum>] = [:]
        var artistCache: [String: Lookup<MbArtist>] = [:]
        var stopped = false
        for t in targets {
            let prior = priors[t.rid]
            let st = State(target: t, prior: prior, priorArtist: priorArtists[t.aid])
            states.append(st)
            if await !gate() { stopped = true; break }

            // 1. Deezer.
            let needDeezer = await due(stale(prior?.fetchedMask ?? 0, DnaSource.deezer, prior?.popAtMs ?? 0, Self.popularityTtlMs, now,
                                             hasRow: prior != nil), DnaSource.deezer, st.entity)
            if needDeezer {
                let isrc = t.isrc ?? prior?.isrc
                var track: Lookup<DeezerTrack> = .notFound
                if let isrc { track = await deezer.trackByIsrc(isrc) }
                if case .notFound = track {
                    switch await deezer.search(st.want) {
                    case .found(let ref): track = await deezer.track(ref.id)
                    case .notFound: break
                    case .unavailable: track = .unavailable
                    }
                }
                switch track {
                case .found(let found):
                    st.deezerTrack = found
                    st.tried |= DnaSource.deezer
                    // The album's genres are tags (90 days), the rank is popularity (7 days): a weekly rank refresh does
                    // not ask for the album again, or the tags would never expire.
                    let tagsDue = prior == nil || prior!.fetchedMask & DnaSource.deezer == 0 || prior!.tagsAtMs == 0
                        || now - prior!.tagsAtMs > Self.tagsTtlMs
                    if found.albumId != 0 && tagsDue {
                        let album: Lookup<DeezerAlbum>
                        if let cached = albumCache[found.albumId] {
                            album = cached
                        } else {
                            album = await deezer.album(found.albumId)
                            albumCache[found.albumId] = album
                        }
                        if case .found(let a) = album { st.deezerAlbum = a }
                    }
                case .notFound:
                    st.tried |= DnaSource.deezer
                    await recordMiss(st.entity, DnaSource.deezer, now)
                case .unavailable: break
                }
            }
            if await !gate() { stopped = true; break }

            // 2. MusicBrainz: the recording (its id and first year), then its artist's genres.
            let needMb = await due(stale(prior?.fetchedMask ?? 0, DnaSource.musicbrainz, prior?.tagsAtMs ?? 0, Self.tagsTtlMs, now,
                                         hasRow: prior != nil), DnaSource.musicbrainz, st.entity)
            if needMb {
                var answered = false
                if st.recordingMbid == nil {
                    var hit: Lookup<MbRecordingHit> = .notFound
                    if let isrc = t.isrc ?? prior?.isrc ?? st.deezerTrack?.isrc { hit = await musicBrainz.recordingByIsrc(isrc, st.want) }
                    if case .notFound = hit { hit = await musicBrainz.searchRecording(st.want) }
                    switch hit {
                    case .found(let h):
                        st.mb = h
                        st.recordingMbid = h.mbid
                        st.artistMbid = h.artistMbid ?? st.artistMbid
                        answered = true
                    case .notFound: answered = true
                    case .unavailable: break
                    }
                } else {
                    answered = true
                }
                if let am = st.artistMbid {
                    if st.priorArtistFresh(now, DnaSource.musicbrainz) {
                        // The artist's genres are already stored and fresh: no request. (assemble keeps the stored claims.)
                    } else {
                        let a: Lookup<MbArtist>
                        if let cached = artistCache[am] {
                            a = cached
                        } else {
                            a = await musicBrainz.artist(am)
                            artistCache[am] = a
                        }
                        switch a {
                        case .found(let artist): st.mbArtist = artist; answered = true
                        case .notFound: answered = true
                        case .unavailable: answered = false
                        }
                    }
                }
                if answered {
                    st.tried |= DnaSource.musicbrainz
                    if st.mb == nil && st.recordingMbid == nil { await recordMiss(st.entity, DnaSource.musicbrainz, now) }
                }
            }

            // 3. iTunes: the song's genre and release date, by name.
            let needItunes = await due(stale(prior?.fetchedMask ?? 0, DnaSource.itunes, prior?.tagsAtMs ?? 0, Self.tagsTtlMs, now,
                                             hasRow: prior != nil), DnaSource.itunes, st.entity)
            if needItunes {
                if await !gate() { stopped = true; break }
                switch await itunes.search(st.want) {
                case .found(let s):
                    st.itunes = s
                    st.tried |= DnaSource.itunes
                case .notFound:
                    st.tried |= DnaSource.itunes
                    await recordMiss(st.entity, DnaSource.itunes, now)
                case .unavailable: break
                }
            }
        }

        if !stopped { stopped = await !batchPasses(states, now, gate: gate, blocked: blocked) }
        var saved = 0
        for st in states {
            if await persist(st, atlas, version) { saved += 1 }
        }
        timing("brain_dna_round", clock() - startedMs)
        return Report(tracks: saved, stopped: stopped)
    }

    /// The ListenBrainz batch (recording and artist genre tags, popularity) and the Wikidata query (artist genres).
    private func batchPasses(_ states: [State], _ now: Int64, gate: @Sendable () async -> Bool,
                             blocked: (Int, String) async -> Bool) async -> Bool {
        // ListenBrainz: 16 recordings a request.
        var lbStates: [State] = []
        for st in states where st.recordingMbid != nil
            && stale(st.prior?.fetchedMask ?? 0, DnaSource.listenbrainz, st.prior?.tagsAtMs ?? 0, Self.tagsTtlMs, now, hasRow: st.prior != nil) {
            if await !blocked(DnaSource.listenbrainz, st.entity) { lbStates.append(st) }
        }
        var start = 0
        while start < lbStates.count {
            let chunk = Array(lbStates[start..<min(start + ListenBrainzSource.batch, lbStates.count)])
            start += ListenBrainzSource.batch
            if await !gate() { return false }
            var ids: [String] = []
            var seen: Set<BrainKey> = []
            for st in chunk { if let id = st.recordingMbid, seen.insert(BrainKey(id)).inserted { ids.append(id) } }
            switch await listenBrainz.recordings(ids) {
            case .found(let map):
                for st in chunk {
                    st.lb = st.recordingMbid.flatMap { map[$0] }
                    st.tried |= DnaSource.listenbrainz
                    if st.lb == nil { await recordMiss(st.entity, DnaSource.listenbrainz, now) }
                }
            case .notFound:
                for st in chunk {
                    st.tried |= DnaSource.listenbrainz
                    await recordMiss(st.entity, DnaSource.listenbrainz, now)
                }
            case .unavailable: break
            }
            // Popularity from listeners is the last resort: only for tracks no other source ranked.
            let unranked = chunk.filter { $0.deezerTrack == nil && ($0.prior?.popPermille ?? -1) < 0 && $0.target.ytPlays <= 0 }
            if !unranked.isEmpty, await gate() {
                if case .found(let p) = await listenBrainz.popularity(unranked.compactMap(\.recordingMbid)) {
                    for st in unranked { st.lbPop = st.recordingMbid.flatMap { p[$0] } }
                }
            }
        }
        // Wikidata: one query for up to 100 artists, once a day or so.
        let wdStates = states.filter { $0.artistMbid != nil && !$0.priorArtistFresh(now, DnaSource.wikidata) }
        var wdIds: [String] = []
        var seenIds: Set<BrainKey> = []
        for st in wdStates { if let id = st.artistMbid, seenIds.insert(BrainKey(id)).inserted { wdIds.append(id) } }
        if !wdIds.isEmpty {
            if await !gate() { return false }
            switch await wikidata.artists(wdIds) {
            case .found(let rows):
                var byMbid: [String: WdArtist] = [:]
                for r in rows { byMbid[r.mbid] = r }
                for st in wdStates {
                    st.wd = st.artistMbid.flatMap { byMbid[$0] }
                    st.tried |= DnaSource.wikidata
                }
            case .notFound:
                for st in wdStates { st.tried |= DnaSource.wikidata }
            case .unavailable: break
            }
        }
        return true
    }

    /// Saves one target's row; false when nothing was learned about a track that has no row yet (no source answered and
    /// the app knew nothing), or the save failed. A track that has a row is saved again even when no source could be
    /// asked: its `updatedAtMs` moves, so lane 5 does not keep offering the same rows first while a source is off or spent.
    private func persist(_ st: State, _ atlas: GenreAtlas, _ version: Int) async -> Bool {
        let t = st.target
        let ownFacts = !t.spotifyGenres.isEmpty || !t.chipGenres.isEmpty || t.ytYear > 0 || t.ytPlays > 0
            || !(t.spotifyReleaseDate.map(BrainText.isBlank) ?? true)
        if st.tried == 0 && !ownFacts && st.prior == nil { return false }
        let now = clock()
        let r = DnaAssembler.assemble(target: t, evidence: st.evidence(), prior: st.prior, priorArtist: st.priorArtist, atlas: atlas,
                                      atlasVersion: version, nowMs: now, maxYear: Self.currentYear(now) + 1)
        return await store.upsert(track: r.track, artist: r.artist)
    }

    private func recordMiss(_ entity: String, _ bit: Int, _ now: Int64) async {
        let source = DnaSource.numberOf(bit)
        let n = await store.misses(entity: entity, source: source) + 1
        var wait = Self.missFirstMs
        if n > 1 {
            for _ in 1..<n {
                wait *= 2
                if wait >= Self.missCapMs { wait = Self.missCapMs; break }
            }
        }
        await store.putMiss(entity: entity, source: source, retryAfterMs: now + wait, misses: n)
    }

    /// The calendar year of `ms` (UTC): precise enough for "no year after next year".
    public static func currentYear(_ ms: Int64) -> Int {
        let days = BrainMath.floorDiv(ms, 86_400_000)
        // Civil-from-days (Howard Hinnant), year part only.
        let z = days + 719_468
        let era = BrainMath.floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        if mp >= 10 { y += 1 }
        return Int(y)
    }
}
