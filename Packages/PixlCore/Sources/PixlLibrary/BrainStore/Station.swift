// A station (docs/brain-spec.md, 8.3): the listener asked for music like one song or one artist. The queue itself
// holds the tracks; this is only what the queue is about, the Familiar / Blend / Discover switch, and the rules
// around both. Plain values and pure rules: the app stores two small values and carries the answers out. A port of
// Android's `Station.kt`, the seed half of its `StationStateHolder.kt` and `BrainPlayTags.kt`.

import Foundation
import PixlModel

/// What the queue is about while it is a station.
public struct Station: Sendable, Hashable {
    /// The `surfaceId` its plays are logged under: a hash, never the seed's own id.
    public var id: String
    /// `Session.seedStationSong` or `Session.seedStationArtist`.
    public var kind: Int32
    /// The media id of the track the station starts with.
    public var seedMediaId: String
    /// What the queue's line names after "Station": the song's title, or the artist's name.
    public var title: String
    /// ONE artist name: the artist of an artist station, the seed's primary artist of a song station.
    public var artistName: String
    public var startedAtMs: Int64
    /// What the listener started it from: one of the `source...` constants.
    public var source: Int
    /// The media ids of every seed, `seedMediaId` first: one for a song or artist station, up to five for an album or
    /// playlist station (6.2). They are library tracks; the radios of all of them are merged.
    public var seedMediaIds: [String]

    public var isArtist: Bool { kind == Session.seedStationArtist }

    static let separator = "\u{1F}"
    static let idsSeparator = "\u{1E}"

    public static let sourceSong = 0
    public static let sourceArtist = 1
    public static let sourceAlbum = 2
    public static let sourcePlaylist = 3
    /// A station from a genre or a mood of the atlas (8.3, stage 2b): the listener's own songs under the node seed it.
    public static let sourceGenre = 4
    public static let sourceMood = 5

    public init(id: String, kind: Int32, seedMediaId: String, title: String, artistName: String, startedAtMs: Int64,
                source: Int? = nil, seedMediaIds: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.seedMediaId = seedMediaId
        self.title = title
        self.artistName = artistName
        self.startedAtMs = startedAtMs
        self.source = source ?? (kind == Session.seedStationArtist ? Self.sourceArtist : Self.sourceSong)
        self.seedMediaIds = seedMediaIds ?? [seedMediaId]
    }

    /// A station from an album (`sourceAlbum`) or a playlist (`sourcePlaylist`): `seedMediaIds` are its seeds, best first.
    public static func fromSource(_ source: Int, seedMediaIds: [String], title: String, nowMs: Int64) -> Station {
        let first = seedMediaIds.first ?? ""
        return Station(id: idOf(kind: Session.seedStationSong, seedMediaId: first, source: source),
                       kind: Session.seedStationSong, seedMediaId: first, title: title, artistName: "",
                       startedAtMs: nowMs, source: source, seedMediaIds: seedMediaIds)
    }

    public static func song(seedMediaId: String, title: String, primaryArtist: String, nowMs: Int64) -> Station {
        Station(id: idOf(kind: Session.seedStationSong, seedMediaId: seedMediaId), kind: Session.seedStationSong,
                seedMediaId: seedMediaId, title: title, artistName: primaryArtist, startedAtMs: nowMs)
    }

    public static func artist(seedMediaId: String, artistName: String, nowMs: Int64) -> Station {
        Station(id: idOf(kind: Session.seedStationArtist, seedMediaId: seedMediaId), kind: Session.seedStationArtist,
                seedMediaId: seedMediaId, title: artistName, artistName: artistName, startedAtMs: nowMs)
    }

    /// Lower-case hexadecimal of `fnv1a64("station|<kind>|<seedMediaId>")`, as Android writes it.
    public static func idOf(kind: Int32, seedMediaId: String, source: Int = -1) -> String {
        // A song or artist station's id is what it always was; an album or playlist one adds where it came from.
        BrainSurfaces.hashedId(source >= sourceAlbum
            ? "station|\(kind)|\(seedMediaId)|\(source)" : "station|\(kind)|\(seedMediaId)")
    }

    /// One line of text for the preferences: seven fields, separated by U+001F (the seeds by U+001E).
    public func encode() -> String {
        [String(kind), seedMediaId, Self.clean(title), Self.clean(artistName), String(startedAtMs), String(source),
         seedMediaIds.map { Self.clean($0) }.joined(separator: Self.idsSeparator)]
            .joined(separator: Self.separator)
    }

    public static func decode(_ text: String?) -> Station? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.components(separatedBy: separator)
        // Five parts: a station saved before album and playlist stations existed.
        guard parts.count == 5 || parts.count == 7, let kind = Int32(parts[0]),
              kind == Session.seedStationSong || kind == Session.seedStationArtist, !parts[1].isEmpty,
              let startedAtMs = Int64(parts[4]) else { return nil }
        if parts.count == 5 {
            return Station(id: idOf(kind: kind, seedMediaId: parts[1]), kind: kind, seedMediaId: parts[1], title: parts[2],
                           artistName: parts[3], startedAtMs: startedAtMs)
        }
        guard let source = Int(parts[5]), source >= sourceSong, source <= sourceMood else { return nil }
        var ids = parts[6].components(separatedBy: idsSeparator).filter { !$0.isEmpty }
        if ids.isEmpty { ids = [parts[1]] }
        return Station(id: idOf(kind: kind, seedMediaId: parts[1], source: source), kind: kind, seedMediaId: parts[1],
                       title: parts[2], artistName: parts[3], startedAtMs: startedAtMs, source: source, seedMediaIds: ids)
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: separator, with: " ").replacingOccurrences(of: idsSeparator, with: " ")
    }

    // MARK: The station's own queue entries

    /// The tag the seed's queue entry carries: where its play is logged from, and what marks the queue as this
    /// station's.
    public var seedTag: BrainItemTag {
        BrainItemTag(surface: Surface.nameOf(Surface.station), surfaceId: id)
    }

    /// True when a queue entry is this station's seed: the seed's media id, tagged by this station. A queue the
    /// listener started any other way never holds such an entry, so a new play ends the station by itself.
    public func isSeed(mediaId: String, tag: BrainItemTag?) -> Bool {
        guard BrainKey.sameBytes(mediaId, seedMediaId), let tag, !tag.isEngineOwned,
              let surface = tag.surface, BrainKey.sameBytes(surface, Surface.nameOf(Surface.station)),
              let surfaceId = tag.surfaceId else { return false }
        return BrainKey.sameBytes(surfaceId, id)
    }
}

/// The listener's Familiar / Blend / Discover switch (8.3, 5.10): how much of the engine's picks is new music.
public enum Novelty {
    public static let familiar = 0
    public static let blend = 1
    public static let discover = 2

    public static func clamp(_ level: Int) -> Int { level < familiar || level > discover ? blend : level }

    /// What the switch multiplies the surface's novelty share by.
    public static func factor(_ level: Int) -> Double {
        switch level {
        case familiar: 0.4
        case discover: 2.0
        default: 1.0
        }
    }
}

/// The rules around a station that the app's controller only carries out.
public enum StationRules {
    /// 6.2: a station's first batch, and its novelty share against autoplay's.
    public static let firstBatch = 20
    public static let nuFactor: Double = 1.2

    /// A station started from the track that is current keeps that track where it is. When it is paused, the
    /// listener still asked for music: it plays on. (A track that is playing is left alone.)
    public static func inPlaceStartMustPlay(isPlaying: Bool) -> Bool { !isPlaying }

    public enum QueueState: Sendable, Equatable {
        /// The queue holds the station's seed: it is the station's.
        case running
        /// The queue is something else: the station is over and is forgotten.
        case ended
        /// Nothing can be said yet (no queue, or a saved queue is still being restored).
        case unknown
    }

    /// Reads off the queue whether it is still the station the listener started. `holdsSeed` is whether any entry
    /// is the station's seed (`Station.isSeed`).
    public static func state(holdsSeed: Bool, queueIsEmpty: Bool, isRestoring: Bool) -> QueueState {
        if holdsSeed { return .running }
        return queueIsEmpty || isRestoring ? .unknown : .ended
    }

    /// How many picks a plan asks for: a station opens with a long batch, then five at a time like autoplay.
    public static func batchSize(isStation: Bool, batchesSoFar: Int) -> Int {
        isStation && batchesSoFar == 0 ? firstBatch : AutoplayPolicy.batchSize
    }

    /// What the surface multiplies the novelty share by, before the listener's switch (6.2): a station leans
    /// further out; after a single track the listener asked for "more like this"; after an album or a playlist
    /// autoplay stays closer to home.
    public static func surfaceNu(isStation: Bool, listenerItems: Int) -> Double {
        if isStation { return nuFactor }
        return listenerItems <= 1 ? 1.0 : 0.8
    }

    /// The seed of an artist station: the listener's most-played library track whose primary artist is
    /// `artistName`; failing that, one that credits them. Nil when the library has nothing by them. Ties keep the
    /// first in `songs`.
    public static func artistSeed(artistName: String, songs: [Song], playCount: (String) -> Int) -> Song? {
        let key = BrainText.fold(artistName)
        if key.isEmpty { return nil }
        var primary: [Song] = []
        var credited: [Song] = []
        for song in songs {
            if BrainKey.sameBytes(BrainLibraryIndex.artistKey(of: song), key) {
                primary.append(song)
            } else if song.artists.contains(where: { BrainKey.sameBytes(BrainText.fold($0.name), key) }) {
                credited.append(song)
            }
        }
        let candidates = primary.isEmpty ? credited : primary
        guard var best = candidates.first else { return nil }
        var bestPlays = playCount(best.id)
        for song in candidates.dropFirst() {
            let plays = playCount(song.id)
            if plays > bestPlays {
                best = song
                bestPlays = plays
            }
        }
        return best
    }

    /// ONE artist name for a station from `song`: its primary credit; "" when it names nobody.
    public static func primaryArtist(of song: Song) -> String {
        let name = BrainLibraryIndex.primaryArtistName(song)
        return BrainText.isBlank(name) || BrainKey.sameBytes(name, EngineTrack.unknownArtist) ? "" : name
    }
}


/// Which songs seed a station from an album or a playlist (docs/brain-spec.md, 6.2): up to 3 for an album and 5 for a
/// playlist, "most played, else the first", at most 2 per artist. The first of them plays.
public enum StationSeeds {
    public static let albumSeeds = 3
    public static let playlistSeeds = 5
    /// A genre or mood station: up to five of the listener's own songs under the node (6.2).
    public static let genreSeeds = 5
    public static let perArtist = 2

    /// `songs` are in the source's own order; `plays` is the play count of each song id the listener has played. Songs
    /// with plays come first, most played first (ties by the source's order), then the unplayed ones in the source's
    /// order.
    public static func pick(songs: [Song], plays: [String: Int], max: Int) -> [Song] {
        let order = songs.indices.sorted { a, b in
            let pa = plays[songs[a].id] ?? 0
            let pb = plays[songs[b].id] ?? 0
            if (pa > 0) != (pb > 0) { return pa > 0 }
            if pa != pb { return pa > pb }
            return a < b
        }
        var used: [String: Int] = [:]
        var out: [Song] = []
        for i in order {
            if out.count >= max { break }
            let song = songs[i]
            let artist = BrainLibraryIndex.artistKey(of: song)
            let count = used[artist] ?? 0
            if !artist.isEmpty && count >= perArtist { continue }
            used[artist] = count + 1
            out.append(song)
        }
        return out
    }
}

/// The rules of a long station (6.2): when it is re-seeded and from what, and what leads its first batch.
public enum StationReseed {
    /// A station whose pool runs under this is re-seeded from its best-received track, at most twice.
    public static let below = 15
    public static let maxReseeds = 2
    /// An album or playlist station has up to five seeds, and two re-seeds may join them.
    public static let maxSeeds = 7

    /// True when the station's pool ran low and `best` (the latest track it finished or the listener liked, never its
    /// own seed) can join the seeds.
    public static func shouldReseed(poolFromLibrary: Bool, poolSize: Int, reseedIds: [String], bestMediaId: String?,
                                    seedMediaIds: [String]) -> Bool {
        guard let bestMediaId, !poolFromLibrary, poolSize < below, reseedIds.count < maxReseeds else { return false }
        return !seedMediaIds.contains(bestMediaId) && !reseedIds.contains(bestMediaId)
    }

    /// The media ids a station's pool is seeded from: its primary seed, the others it was started with, then the
    /// re-seeds, `maxSeeds` at most, each once.
    public static func seedIds(primary: String, station: Station, reseedIds: [String]) -> [String] {
        var out = [primary]
        for id in station.seedMediaIds + reseedIds where out.count < maxSeeds && !out.contains(id) { out.append(id) }
        return out
    }

    /// Whether a station track counts as "the one it did best with": the listener finished it or liked it.
    public static func isBest(finished: Bool, liked: Bool, mediaId: String, station: Station) -> Bool {
        (finished || liked) && !BrainKey.sameBytes(mediaId, station.seedMediaId)
    }
}
