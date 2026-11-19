// Track DNA on disk (docs/brain-spec.md, 3.2 and 3.8, stage 2b): what the brain knows about a recording beyond how it was
// played. A port of Android's `brain.db` version 4 tables `track_dna`, `artist_dna` and `source_miss`
// (`BrainEntitiesV4.kt`), as three keyed record files like the other brain tables:
//
//     track_dna.pbl     `<rid>`             ->  a `TrackDnaRow`
//     artist_dna.pbl    `<aid>`             ->  an `ArtistDnaRow`
//     source_miss.pbl   `<entity>|<source>` ->  {"m":misses,"r":retryAfterMs,"v":1}     (entity: `t:<rid>` or `a:<aid>`)
//
// Every record has a version `v`; a reader skips a record it cannot read or a version it does not know, so a later stage
// can add fields without a migration, and a stage 1 or 2a install (which has none of these files) is an empty store.
// A cache: every column can be fetched again, nothing here is the listener's history. Integers only, so both apps store
// and compare it identically: unknown is a value (year 0, popularity -1, energy and valence -1, tempo 0, gain -32768,
// explicit -1, an empty tag blob). Byte fields are base64 in the JSON (`Data`).

import Foundation
import PixlModel

/// The bits of `fetchedMask`: which sources have been tried for a row.
public enum DnaSource {
    public static let deezer = 1
    public static let musicbrainz = 2
    public static let listenbrainz = 4
    public static let wikidata = 8
    public static let itunes = 16
    public static let spotifyGenres = 32
    public static let youtubeChips = 64
    public static let youtubeRow = 128

    /// The number a source has in `source_miss.source` and the ledger: the bit's position.
    public static func numberOf(_ bit: Int) -> Int { bit.trailingZeroBitCount }

    /// The bit of an open-data host.
    public static func bit(of host: KnowledgeHost) -> Int {
        switch host {
        case .deezer: return deezer
        case .musicbrainz: return musicbrainz
        case .listenbrainz: return listenbrainz
        case .wikidata: return wikidata
        case .itunes: return itunes
        }
    }
}

public struct TrackDnaRow: Codable, Sendable, Equatable {
    public static let formatVersion = 1
    public var v: Int = TrackDnaRow.formatVersion
    public var rid: Int64
    public var spotifyId: String?
    public var isrc: String?
    public var deezerId: Int64?
    public var mbRecordingId: String?
    /// Known official-audio video ids, joined by ','.
    public var ytAudioIds: String
    /// Artist ids (decimal), primary first, joined by ','.
    public var artistIds: String
    public var albumKey: Int64?
    public var title: String
    public var artistDisplay: String
    public var versionFlags: Int
    public var firstYear: Int
    public var yearSource: Int
    public var durationMs: Int
    public var explicit: Int
    public var popPermille: Int
    public var tempoBpmX10: Int
    public var tempoSource: Int
    public var gainDbX10: Int
    public var scriptLang: Int
    /// `Tags.encode`: 3 bytes a tag (atlas id, weight). Empty means unknown.
    public var tags: Data
    /// Up to 4 mood ids, one byte each.
    public var moods: Data
    public var energy: Int
    public var valence: Int
    public var embVersion: Int
    public var confidence: Int
    /// One bit per source tried: see `DnaSource`.
    public var fetchedMask: Int
    public var updatedAtMs: Int64
    public var tagsAtMs: Int64
    public var popAtMs: Int64
    /// The atlas version the tag ids were written with.
    public var atlasVersion: Int
    /// What each source said, so a refresh of one source re-merges the others without asking them again: 4 bytes a claim
    /// (provider, atlas id high byte, atlas id low byte, confidence 0...255).
    public var tagInputs: Data
    /// Year claims, `source:year` joined by ','.
    public var yearClaims: String
    /// Popularity claims, `d:<permille>`, `y:` and `l:` joined by ','.
    public var popClaims: String

    public init(rid: Int64, spotifyId: String? = nil, isrc: String? = nil, deezerId: Int64? = nil, mbRecordingId: String? = nil,
                ytAudioIds: String = "", artistIds: String = "", albumKey: Int64? = nil, title: String = "",
                artistDisplay: String = "", versionFlags: Int = 0, firstYear: Int = 0, yearSource: Int = 0, durationMs: Int = 0,
                explicit: Int = -1, popPermille: Int = -1, tempoBpmX10: Int = 0, tempoSource: Int = 0,
                gainDbX10: Int = TrackDna.gainUnknown, scriptLang: Int = 0, tags: Data = Data(), moods: Data = Data(),
                energy: Int = -1, valence: Int = -1, embVersion: Int = 0, confidence: Int = 0, fetchedMask: Int = 0,
                updatedAtMs: Int64 = 0, tagsAtMs: Int64 = 0, popAtMs: Int64 = 0, atlasVersion: Int = 1,
                tagInputs: Data = Data(), yearClaims: String = "", popClaims: String = "") {
        self.rid = rid
        self.spotifyId = spotifyId
        self.isrc = isrc
        self.deezerId = deezerId
        self.mbRecordingId = mbRecordingId
        self.ytAudioIds = ytAudioIds
        self.artistIds = artistIds
        self.albumKey = albumKey
        self.title = title
        self.artistDisplay = artistDisplay
        self.versionFlags = versionFlags
        self.firstYear = firstYear
        self.yearSource = yearSource
        self.durationMs = durationMs
        self.explicit = explicit
        self.popPermille = popPermille
        self.tempoBpmX10 = tempoBpmX10
        self.tempoSource = tempoSource
        self.gainDbX10 = gainDbX10
        self.scriptLang = scriptLang
        self.tags = tags
        self.moods = moods
        self.energy = energy
        self.valence = valence
        self.embVersion = embVersion
        self.confidence = confidence
        self.fetchedMask = fetchedMask
        self.updatedAtMs = updatedAtMs
        self.tagsAtMs = tagsAtMs
        self.popAtMs = popAtMs
        self.atlasVersion = atlasVersion
        self.tagInputs = tagInputs
        self.yearClaims = yearClaims
        self.popClaims = popClaims
    }

    /// The tag vector the row holds; empty for unknown.
    public var tagVector: Tags.Vector { Tags.decode([UInt8](tags)) }
}

/// The artist-level facts (3.2, `ArtistDna`). A cache.
public struct ArtistDnaRow: Codable, Sendable, Equatable {
    public static let formatVersion = 1
    public var v: Int = ArtistDnaRow.formatVersion
    public var aid: Int64
    public var spotifyId: String?
    public var ytChannelId: String?
    public var deezerId: Int64?
    public var mbid: String?
    public var wikidataId: String?
    public var name: String
    /// ISO 3166 code, or empty.
    public var country: String
    public var tags: Data
    public var popPermille: Int
    /// The last seen `MPREb_` ids for the release diff (6.3), joined by ','.
    public var releaseIds: String
    public var fetchedMask: Int
    public var updatedAtMs: Int64
    public var tagsAtMs: Int64
    public var atlasVersion: Int
    /// As `TrackDnaRow.tagInputs`, for the artist-level sources only.
    public var tagInputs: Data

    public init(aid: Int64, spotifyId: String? = nil, ytChannelId: String? = nil, deezerId: Int64? = nil, mbid: String? = nil,
                wikidataId: String? = nil, name: String = "", country: String = "", tags: Data = Data(), popPermille: Int = -1,
                releaseIds: String = "", fetchedMask: Int = 0, updatedAtMs: Int64 = 0, tagsAtMs: Int64 = 0,
                atlasVersion: Int = 1, tagInputs: Data = Data()) {
        self.aid = aid
        self.spotifyId = spotifyId
        self.ytChannelId = ytChannelId
        self.deezerId = deezerId
        self.mbid = mbid
        self.wikidataId = wikidataId
        self.name = name
        self.country = country
        self.tags = tags
        self.popPermille = popPermille
        self.releaseIds = releaseIds
        self.fetchedMask = fetchedMask
        self.updatedAtMs = updatedAtMs
        self.tagsAtMs = tagsAtMs
        self.atlasVersion = atlasVersion
        self.tagInputs = tagInputs
    }
}

/// What a coverage count reports (the Developer screen and the handoff).
public struct DnaCoverage: Sendable, Equatable {
    public var tracks = 0
    public var withTags = 0
    public var withYear = 0
    public var withPopularity = 0
    public var withEnergy = 0
    public var withTempo = 0
    public init() {}
}

/// The three files, behind one actor. Nothing is read until the first call, and nothing here runs at app start.
public actor DnaRepository {
    public static let missFormatVersion = 1

    struct Miss: Codable {
        var v: Int
        var m: Int
        var r: Int64
    }

    private let trackFile: KeyedLogStore
    private let artistFile: KeyedLogStore
    private let missFile: KeyedLogStore
    private var loaded = false
    private var tracks: [Int64: TrackDnaRow] = [:]
    private var artists: [Int64: ArtistDnaRow] = [:]
    private var misses: [BrainKey: Miss] = [:]
    private var writes = 0

    public init(directory: URL, compactionFloorBytes: Int = 64 * 1024) {
        trackFile = KeyedLogStore(url: directory.appendingPathComponent("track_dna.pbl", isDirectory: false),
                                  compactionFloorBytes: compactionFloorBytes)
        artistFile = KeyedLogStore(url: directory.appendingPathComponent("artist_dna.pbl", isDirectory: false),
                                   compactionFloorBytes: compactionFloorBytes)
        missFile = KeyedLogStore(url: directory.appendingPathComponent("source_miss.pbl", isDirectory: false),
                                 compactionFloorBytes: compactionFloorBytes)
    }

    private func load() {
        if loaded { return }
        loaded = true
        let decoder = JSONDecoder()
        trackFile.open { _, payload in
            guard let row = try? decoder.decode(TrackDnaRow.self, from: Data(payload)),
                  row.v >= 1, row.v <= TrackDnaRow.formatVersion else { return }
            self.tracks[row.rid] = row
        }
        artistFile.open { _, payload in
            guard let row = try? decoder.decode(ArtistDnaRow.self, from: Data(payload)),
                  row.v >= 1, row.v <= ArtistDnaRow.formatVersion else { return }
            self.artists[row.aid] = row
        }
        missFile.open { key, payload in
            guard let miss = try? decoder.decode(Miss.self, from: Data(payload)),
                  miss.v >= 1, miss.v <= Self.missFormatVersion else { return }
            self.misses[BrainKey(key)] = miss
        }
    }

    private static func payload<T: Encodable>(_ value: T) -> [UInt8]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { [UInt8]($0) }
    }

    // MARK: Tracks

    public func track(_ rid: Int64) -> TrackDnaRow? {
        load()
        return tracks[rid]
    }

    public func tracks(_ rids: [Int64]) -> [TrackDnaRow] {
        load()
        return rids.compactMap { tracks[$0] }
    }

    /// Saves the rows; false when the file could not be written (the rows in memory are then unchanged). The artist row goes
    /// down FIRST: a process killed between the two writes then leaves a track row that still says an artist lookup is
    /// owed, never a track row that claims MusicBrainz answered and an artist row that was lost.
    @discardableResult
    public func upsert(track: TrackDnaRow, artist: ArtistDnaRow?) -> Bool {
        load()
        guard let trackPayload = Self.payload(track) else { return false }
        if let artist {
            if let p = Self.payload(artist), artistFile.put(String(artist.aid), p) { artists[artist.aid] = artist; writes += 1 }
        }
        guard trackFile.put(String(track.rid), trackPayload) else { return false }
        tracks[track.rid] = track
        writes += 1
        return true
    }

    /// Writes one artist row alone (the Spotify purge of artists no track row led to).
    @discardableResult
    public func upsert(artist: ArtistDnaRow) -> Bool {
        load()
        guard let p = Self.payload(artist), artistFile.put(String(artist.aid), p) else { return false }
        artists[artist.aid] = artist
        writes += 1
        return true
    }

    /// Rows that still carry something Spotify said, for the purge (3.5, owner decision on the Spotify switch).
    public func spotifyCarriers() -> (tracks: [TrackDnaRow], artists: [ArtistDnaRow]) {
        load()
        let t = tracks.values.filter { DnaAssembler.carriesSpotify($0) }.sorted { $0.rid < $1.rid }
        let a = artists.values.filter { DnaAssembler.carriesSpotify($0) }.sorted { $0.aid < $1.aid }
        return (t, a)
    }

    /// Moves on every write of a row (in this process): a cache keyed on it never serves DNA older than the rows. It loads
    /// nothing; a cache built before the first write simply has the value 0.
    public func revision() -> Int { writes }

    public func artists(_ aids: [Int64]) -> [ArtistDnaRow] {
        load()
        return aids.compactMap { artists[$0] }
    }

    /// Spotify ids that already have a row, so the library scan can leave them alone.
    public func knownSpotifyIds(_ ids: [String]) -> Set<String> {
        load()
        let wanted = Set(ids)
        var out: Set<String> = []
        for row in tracks.values { if let s = row.spotifyId, wanted.contains(s) { out.insert(s) } }
        return out
    }

    /// Rows lane 5 should look at again (3.7), the stalest first: tags older than 90 days, popularity older than 7, or a
    /// row that has not yet been answered by all three of Deezer, MusicBrainz and iTunes (a source that was off, over its
    /// budget for the day or offline when the row was made) and was last looked at before `retryBefore`. A source that
    /// answered "nothing" has its bit set and is left to the negative cache.
    public func expired(tagsBefore: Int64, popBefore: Int64, retryBefore: Int64, limit: Int) -> [TrackDnaRow] {
        load()
        let need = DnaSource.deezer | DnaSource.musicbrainz | DnaSource.itunes
        let due = tracks.values.filter {
            ($0.tagsAtMs > 0 && $0.tagsAtMs < tagsBefore) || ($0.popAtMs > 0 && $0.popAtMs < popBefore)
                || (($0.fetchedMask & need) != need && $0.updatedAtMs < retryBefore)
        }
        let ordered = due.sorted { $0.updatedAtMs != $1.updatedAtMs ? $0.updatedAtMs < $1.updatedAtMs : $0.rid < $1.rid }
        return Array(ordered.prefix(limit))
    }

    public func count() -> Int {
        load()
        return tracks.count
    }

    public func artistCount() -> Int {
        load()
        return artists.count
    }

    public func artistCountWithTags() -> Int {
        load()
        return artists.values.filter { !$0.tags.isEmpty }.count
    }

    public func coverage() -> DnaCoverage {
        load()
        var c = DnaCoverage()
        c.tracks = tracks.count
        for r in tracks.values {
            if !r.tags.isEmpty { c.withTags += 1 }
            if r.firstYear > 0 { c.withYear += 1 }
            if r.popPermille >= 0 { c.withPopularity += 1 }
            if r.energy >= 0 { c.withEnergy += 1 }
            if r.tempoBpmX10 > 0 { c.withTempo += 1 }
        }
        return c
    }

    /// How many rows have each source's bit in `fetchedMask`, for the Developer screen.
    public func countFetchedBy(_ bit: Int) -> Int {
        load()
        return tracks.values.filter { ($0.fetchedMask & bit) != 0 }.count
    }

    // MARK: The negative cache

    private static func missKey(_ entity: String, _ source: Int) -> String { "\(entity)|\(source)" }

    public func misses(entity: String, source: Int) -> Int {
        load()
        return misses[BrainKey(Self.missKey(entity, source))]?.m ?? 0
    }

    public func putMiss(entity: String, source: Int, retryAfterMs: Int64, misses count: Int) {
        load()
        let key = Self.missKey(entity, source)
        let miss = Miss(v: Self.missFormatVersion, m: count, r: retryAfterMs)
        if let payload = Self.payload(miss), missFile.put(key, payload) { misses[BrainKey(key)] = miss }
    }

    /// Entities of `entities` that `source` must not be asked about yet.
    public func blocked(source: Int, nowMs: Int64, entities: [String]) -> Set<String> {
        load()
        var out: Set<String> = []
        for entity in entities {
            if let miss = misses[BrainKey(Self.missKey(entity, source))], miss.r > nowMs { out.insert(entity) }
        }
        return out
    }

    public func activeMissCount(nowMs: Int64) -> Int {
        load()
        return misses.values.filter { $0.r > nowMs }.count
    }

    /// Drops negative-cache entries that ended more than 180 days ago.
    @discardableResult
    public func pruneMisses(nowMs: Int64) -> Int {
        load()
        let doomed = misses.filter { $0.value.r < nowMs - 15_552_000_000 }.map(\.key)
        if doomed.isEmpty { return 0 }
        guard missFile.remove(doomed.map(\.text)) else { return 0 }
        for key in doomed { misses.removeValue(forKey: key) }
        return doomed.count
    }

    /// Forgets everything (the Developer screen's reset, tests).
    public func clear() {
        load()
        _ = trackFile.remove(trackFile.keys)
        _ = artistFile.remove(artistFile.keys)
        _ = missFile.remove(missFile.keys)
        tracks.removeAll()
        artists.removeAll()
        misses.removeAll()
    }
}
