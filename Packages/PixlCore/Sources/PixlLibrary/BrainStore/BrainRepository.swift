// The music brain's orchestration (docs/brain-spec.md, 2.1): in stage 1a, the radio cache and the `playable`
// table. It answers "what is related to this track" from the stored lists when it can and from YouTube Music when
// it may, applies the junk detector and its fallbacks (3.3, rule 6), resolves every row to a recording id and
// stores the parsed rows. A port of Android's `BrainRepository.kt`, `BrainIdentity.kt` and `PlayableStore.kt`.
//
// Nothing here runs at app start. Every call is off the main actor and bounded: at most one first page, one retry
// and the fallbacks of one seed per call, all under the YouTube budget.

import Foundation
import PixlModel

/// A track the brain can ask a radio for.
public struct RadioSeed: Sendable, Hashable {
    /// The media id the track plays under.
    public var mediaId: String
    /// The YouTube audio id to ask with.
    public var videoId: String
    public var title: String
    /// ONE artist name: the primary one, never a joined display string.
    public var primaryArtist: String
    public var durationMs: Int64
    /// A real Spotify track id; nil for a track that has none.
    public var spotifyId: String?

    public init(mediaId: String, videoId: String, title: String, primaryArtist: String, durationMs: Int64,
                spotifyId: String? = nil) {
        self.mediaId = mediaId
        self.videoId = videoId
        self.title = title
        self.primaryArtist = primaryArtist
        self.durationMs = durationMs
        self.spotifyId = spotifyId
    }
}

/// A radio out of the cache, or just fetched and stored.
public struct StoredRadio: Sendable, Hashable {
    public var seedRid: Int64
    /// One of `RadioList.kind...`: which fallback produced the rows.
    public var kind: Int
    /// Seed excluded, deduplicated by recording, in the source's own order.
    public var rows: [StoredRadioRow]
    public var fromCache: Bool
}

/// The radio cache, identity and the `playable` table.
public actor BrainRepository {
    /// A radio is good for two weeks: related music does not change faster than that.
    public static let cacheTtlMs: Int64 = 14 * 24 * 60 * 60 * 1000
    public static let junkRetryMs: Int64 = 24 * 60 * 60 * 1000
    public static let minFallbackRows = 5
    /// A song radio with fewer official-audio rows than this is treated as junk.
    public static let minOfficialAudioRows = 10
    /// The `chip` of a song radio stored with its continuation pages.
    public static let deepChip = "+pages"
    /// The `chip` of an artist station's list (the artist page's top songs, then the artist radio).
    public static let artistStationChip = "+artist"

    static let kinds = [RadioList.kindSong, RadioList.kindRelated, RadioList.kindArtist]

    private let tables: BrainTables
    private let radioSource: (any RadioSource)?
    private let clock: @Sendable () -> Int64
    /// One seed is fetched once: a second caller for the same seed waits and then reads the cache.
    private var inFlight: [Int64: Task<StoredRadio?, Never>] = [:]

    public init(directory: URL, radioSource: (any RadioSource)?,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        tables = BrainTables(directory: directory)
        self.radioSource = radioSource
        self.clock = clock
    }

    // MARK: Radios

    /// Related music for `seed`. With `allowNetwork` false (offline, the YouTube source switched off) only the
    /// cache answers, however old. Nil means "nothing known": the caller falls back to the library.
    public func radioFor(seed: RadioSeed, allowNetwork: Bool, continuations: Int = 0) async -> StoredRadio? {
        let duration = Int32(clamping: max(seed.durationMs, 0))
        let seedRid = tables.resolveTrack(
            Ids.TrackKeys(spotifyId: seed.spotifyId, videoId: seed.videoId,
                          nameKey: Ids.nameKey(primaryArtist: seed.primaryArtist, rawTitle: seed.title)),
            durationMs: duration)
        if seedRid == 0 { return nil }
        while let running = inFlight[seedRid] { _ = await running.value }
        // The task clears its own entry before it ends, so a caller that waited for it never finds it again.
        let task = Task { () -> StoredRadio? in
            let result = await self.radioForLocked(seed: seed, seedRid: seedRid, allowNetwork: allowNetwork,
                                                   continuations: continuations)
            self.inFlight[seedRid] = nil
            return result
        }
        inFlight[seedRid] = task
        return await task.value
    }

    private func radioForLocked(seed: RadioSeed, seedRid: Int64, allowNetwork: Bool, continuations: Int) async -> StoredRadio? {
        let now = clock()
        // A request for continuation pages is stored beside the first-page list, under its own chip key, so it is
        // fetched once and then answered from the cache like any other list.
        let songChip = continuations > 0 ? Self.deepChip : ""
        var stale: RadioListFacts?
        let songMarker = tables.radioFacts(seedRid: seedRid, kind: RadioList.kindSong, chip: "")
        for kind in Self.kinds {
            let chip = kind == RadioList.kindSong ? songChip : ""
            guard let cached = tables.radioFacts(seedRid: seedRid, kind: kind, chip: chip), cached.healthy else { continue }
            let age = now - cached.fetchedAt
            if age >= 0 && age < Self.cacheTtlMs {
                tables.touchRadio(seedRid: seedRid, kind: kind, chip: chip, nowMs: now)
                return StoredRadio(seedRid: seedRid, kind: kind,
                                   rows: tables.radioRows(seedRid: seedRid, kind: kind, chip: chip), fromCache: true)
            }
            if stale == nil { stale = cached }
        }
        // Offline or over budget, a first-page list still answers a request for more.
        if stale == nil, !songChip.isEmpty, let songMarker, songMarker.healthy { stale = songMarker }
        let staleFacts = stale
        func staleOrNil() -> StoredRadio? {
            guard let facts = staleFacts else { return nil }
            return StoredRadio(seedRid: seedRid, kind: facts.kind,
                               rows: tables.radioRows(seedRid: seedRid, kind: facts.kind, chip: facts.chip),
                               fromCache: true)
        }

        guard allowNetwork, let radioSource else { return staleOrNil() }
        // A seed whose radio was junk is not asked again for a day.
        if let songMarker, !songMarker.healthy {
            let age = now - songMarker.fetchedAt
            if age >= 0 && age < Self.junkRetryMs { return staleOrNil() }
        }
        if tables.radiosFetchedSince(now - HostBudget.dayMs) >= HostBudget.dailyLimit { return staleOrNil() }

        let fetched = await radioSource.songRadio(videoId: seed.videoId, continuations: continuations)
        if let fetched, !isJunk(fetched, seed) {
            return store(seedRid: seedRid, kind: RadioList.kindSong, rows: withoutSeed(fetched.rows, seed),
                         chips: fetched.chips, now: now, chip: songChip)
        }
        guard let fetched else { return staleOrNil() } // transport failure or no budget: nothing learned

        // Junk (3.3, rule 6): remember it, then the Related tab, another audio id, the artist radio.
        tables.upsertRadio(RadioList(seedRid: seedRid, kind: RadioList.kindSong, chip: "", fetchedAt: now,
                                     lastUsedAt: now, healthy: false, rows: [], chips: []))

        if let browseId = fetched.relatedBrowseId, let related = await radioSource.related(browseId: browseId) {
            let same = Set(related.otherPerformances.map { BrainKey($0.videoId) })
            let rows = related.youMightAlsoLike.filter { !same.contains(BrainKey($0.videoId)) }
            if rows.count >= Self.minFallbackRows {
                return store(seedRid: seedRid, kind: RadioList.kindRelated, rows: withoutSeed(rows, seed), chips: [],
                             now: now)
            }
        }

        if let otherId = tables.otherVideoIds(rid: seedRid, exceptVideoId: seed.videoId).first {
            var otherSeed = seed
            otherSeed.videoId = otherId
            if let other = await radioSource.songRadio(videoId: otherId, continuations: continuations),
               !isJunk(other, otherSeed) {
                return store(seedRid: seedRid, kind: RadioList.kindSong, rows: withoutSeed(other.rows, seed),
                             chips: other.chips, now: now, chip: songChip)
            }
        }

        let seedRow = fetched.rows.first { BrainKey.sameBytes($0.videoId, seed.videoId) } ?? fetched.rows.first
        if let channelId = seedRow?.artists.first(where: { $0.channelId != nil })?.channelId,
           let endpoint = await radioSource.artistPage(channelId: channelId)?.radio,
           let artistRadio = await radioSource.artistRadio(endpoint: endpoint),
           !RadioRules.isJunkRadio(rows: artistRadio.rows, seedVideoId: endpoint.videoId, seedArtistIds: [channelId],
                                   fold: BrainText.fold) {
            return store(seedRid: seedRid, kind: RadioList.kindArtist, rows: withoutSeed(artistRadio.rows, seed),
                         chips: [], now: now)
        }
        return staleOrNil()
    }

    // MARK: Artist stations (8.3, 6.2)

    /// The radio of the artist of `seed`: the artist page's top songs followed by the artist radio the page's own
    /// button starts. Nil when nothing is known and the network may not be asked, or the artist has no channel the
    /// brain can find.
    ///
    /// Costs, the first time: at most one `next` to learn the channel id (only when no cached radio row names the
    /// artist), one `browse` and one `next`. After that it is the cache, for two weeks.
    public func artistRadio(seed: RadioSeed, allowNetwork: Bool) async -> StoredRadio? {
        let seedRid = tables.resolveTrack(
            Ids.TrackKeys(spotifyId: seed.spotifyId, videoId: seed.videoId,
                          nameKey: Ids.nameKey(primaryArtist: seed.primaryArtist, rawTitle: seed.title)),
            durationMs: Int32(clamping: max(seed.durationMs, 0)))
        if seedRid == 0 { return nil }
        // Its own slot beside the seed's song radio: a second caller waits and then reads the cache.
        let slot = ~seedRid
        while let running = inFlight[slot] { _ = await running.value }
        let task = Task { () -> StoredRadio? in
            let result = await self.artistRadioLocked(seed: seed, seedRid: seedRid, allowNetwork: allowNetwork)
            self.inFlight[slot] = nil
            return result
        }
        inFlight[slot] = task
        return await task.value
    }

    private func artistRadioLocked(seed: RadioSeed, seedRid: Int64, allowNetwork: Bool) async -> StoredRadio? {
        let now = clock()
        let kind = RadioList.kindArtist
        let chip = Self.artistStationChip
        let cached = tables.radioFacts(seedRid: seedRid, kind: kind, chip: chip)
        func cachedOrNil() -> StoredRadio? {
            guard let cached, cached.healthy else { return nil }
            return StoredRadio(seedRid: seedRid, kind: kind, rows: tables.radioRows(seedRid: seedRid, kind: kind, chip: chip),
                               fromCache: true)
        }
        if let cached, cached.healthy {
            let age = now - cached.fetchedAt
            if age >= 0 && age < Self.cacheTtlMs {
                tables.touchRadio(seedRid: seedRid, kind: kind, chip: chip, nowMs: now)
                return cachedOrNil()
            }
        }
        guard allowNetwork, let radioSource else { return cachedOrNil() }
        // An artist with no radio is not asked again for a day.
        if let cached, !cached.healthy {
            let age = now - cached.fetchedAt
            if age >= 0 && age < Self.junkRetryMs { return nil }
        }
        if tables.radiosFetchedSince(now - HostBudget.dayMs) >= HostBudget.dailyLimit { return cachedOrNil() }

        guard let channelId = await channelId(for: seed, seedRid: seedRid, radioSource: radioSource),
              let page = await radioSource.artistPage(channelId: channelId) else { return cachedOrNil() }
        var rows: [RadioRow] = []
        var seen: Set<BrainKey> = []
        for row in page.topSongs where seen.insert(BrainKey(row.videoId)).inserted { rows.append(row) }
        if let endpoint = page.radio, let radio = await radioSource.artistRadio(endpoint: endpoint),
           !RadioRules.isJunkRadio(rows: radio.rows, seedVideoId: endpoint.videoId, seedArtistIds: [channelId],
                                   fold: BrainText.fold) {
            for row in radio.rows where seen.insert(BrainKey(row.videoId)).inserted { rows.append(row) }
        }
        if rows.count < Self.minFallbackRows {
            tables.upsertRadio(RadioList(seedRid: seedRid, kind: kind, chip: chip, fetchedAt: now, lastUsedAt: now,
                                         healthy: false, rows: [], chips: []))
            return nil
        }
        return store(seedRid: seedRid, kind: kind, rows: withoutSeed(rows, seed), chips: [], now: now, chip: chip)
    }

    /// The `UC...` id of `seed`'s primary artist: from a cached radio row by that artist, else from the seed's own
    /// row of its radio (one `next`).
    private func channelId(for seed: RadioSeed, seedRid: Int64, radioSource: any RadioSource) async -> String? {
        let artistKey = BrainText.fold(seed.primaryArtist)
        if artistKey.isEmpty { return nil }
        func channel(in rows: [RadioRow]) -> String? {
            for row in rows {
                guard let first = row.artists.first, let channelId = first.channelId else { continue }
                if BrainKey.sameBytes(BrainText.fold(first.name), artistKey) { return channelId }
            }
            return nil
        }
        for kind in Self.kinds {
            guard let cached = tables.radioFacts(seedRid: seedRid, kind: kind, chip: ""), cached.healthy else { continue }
            if let found = channel(in: tables.radioRows(seedRid: seedRid, kind: kind, chip: "").map(\.row)) { return found }
        }
        guard let fetched = await radioSource.songRadio(videoId: seed.videoId, continuations: 0) else { return nil }
        if let found = channel(in: fetched.rows) { return found }
        return fetched.rows.first { BrainKey.sameBytes($0.videoId, seed.videoId) }?
            .artists.first { $0.channelId != nil }?.channelId
    }

    private func isJunk(_ fetched: FetchedRadio, _ seed: RadioSeed) -> Bool {
        // A library track can be matched to a music video, and the radio of a music video is music videos. Stage 1
        // only plays official audio, so such a radio has nothing to offer: it takes the junk path, whose first stop
        // (the Related tab) lists official-audio songs.
        var officialAudio = 0
        for row in fetched.rows where row.isOfficialAudio { officialAudio += 1 }
        if officialAudio < Self.minOfficialAudioRows { return true }
        return RadioRules.isJunkRadio(rows: fetched.rows, seedVideoId: seed.videoId, seedArtistIds: [],
                                      seedArtistNames: [seed.primaryArtist], fold: BrainText.fold)
    }

    /// The seed itself is the first row of its own radio; it is not a candidate.
    private func withoutSeed(_ rows: [RadioRow], _ seed: RadioSeed) -> [RadioRow] {
        let seedKey = Ids.nameKey(primaryArtist: seed.primaryArtist, rawTitle: seed.title)
        return rows.filter { row in
            if BrainKey.sameBytes(row.videoId, seed.videoId) { return false }
            guard let seedKey, let artist = row.artists.first,
                  let rowKey = Ids.nameKey(primaryArtist: artist.name, rawTitle: row.title) else { return true }
            return !BrainKey.sameBytes(seedKey, rowKey)
        }
    }

    private func store(seedRid: Int64, kind: Int, rows: [RadioRow], chips: [RadioChip], now: Int64,
                       chip: String = "") -> StoredRadio {
        let rids = tables.resolveTracks(rows.map { row in
            TrackRequest(keys: Ids.TrackKeys(videoId: row.videoId,
                                             nameKey: row.artists.first.flatMap {
                                                 Ids.nameKey(primaryArtist: $0.name, rawTitle: row.title)
                                             }),
                         durationMs: Int32(clamping: Int64(row.durationSec) * 1000))
        })
        // Pages are merged by video id by the pager; here by recording, because one recording shows up under several
        // audio ids and a radio mixes them.
        var seen: Set<Int64> = [seedRid]
        var stored: [StoredRadioRow] = []
        stored.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() {
            let rid = rids[i]
            if rid == 0 || !seen.insert(rid).inserted { continue }
            stored.append(StoredRadioRow(row: row, rid: rid))
        }
        tables.upsertRadio(RadioList(seedRid: seedRid, kind: kind, chip: chip, fetchedAt: now, lastUsedAt: now,
                                     healthy: true, rows: stored, chips: chips))
        return StoredRadio(seedRid: seedRid, kind: kind, rows: stored, fromCache: false)
    }

    // MARK: Playable (7.2)

    /// Stores `tracks` so they can be shown, played and saved after a restart.
    public func registerPlayable(_ tracks: [EngineTrack], nowMs: Int64? = nil) {
        if tracks.isEmpty { return }
        let now = nowMs ?? clock()
        tables.registerPlayable(tracks.map { $0.record(nowMs: now) })
    }

    /// The track that plays under `songId`, when the engine played or queued it.
    public func engineTrack(songId: String) -> EngineTrack? {
        tables.playable(songId: songId).map(EngineTrack.init(record:))
    }

    /// Every track from outside the library the engine queued and that is still kept (Recently Played resolves ids
    /// the library does not have through this).
    public func engineTracks() -> [EngineTrack] {
        tables.allPlayable().map(EngineTrack.init(record:))
    }

    /// Deletes `playable` rows nobody used for 60 days, except the ones in `keepSongIds`.
    @discardableResult
    public func prunePlayable(keepSongIds: Set<String>, nowMs: Int64? = nil) -> Int {
        tables.prunePlayable(keepSongIds: keepSongIds, nowMs: nowMs ?? clock())
    }

    // MARK: Identity (3.1), for the event recorder and the migration

    /// Rids for `requests`, in order; 0 for a request with no usable key.
    public func resolveTracks(_ requests: [TrackRequest]) -> [Int64] { tables.resolveTracks(requests) }

    /// Aids for `names` (ONE artist name each), in order; 0 for a name that folds to nothing.
    public func resolveArtistNames(_ names: [String]) -> [Int64] { tables.resolveArtistNames(names) }

    /// Every merged recording and the one it was merged into.
    public func trackMerges() -> [Int64: Int64] { tables.trackMerges() }

    /// One track resolved together with its artists: one hop for the recorder.
    public func resolve(keys: Ids.TrackKeys, durationMs: Int32, artistNames: [String]) -> (rid: Int64, aids: [Int64]) {
        let rid = tables.resolveTrack(keys, durationMs: durationMs)
        return (rid, tables.resolveArtistNames(artistNames))
    }

    /// The stored `playable` row of `songId`, when the engine queued it.
    public func playable(songId: String) -> PlayableRecord? { tables.playable(songId: songId) }

    // MARK: Tests and diagnostics

    public func radioListCount() -> Int { tables.radioCount }
    public func playableCount() -> Int { tables.playableCount }
    public func resolveTrack(_ keys: Ids.TrackKeys, durationMs: Int32) -> Int64 {
        tables.resolveTrack(keys, durationMs: durationMs)
    }
}
