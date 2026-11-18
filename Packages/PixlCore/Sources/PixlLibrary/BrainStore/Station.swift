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

    public var isArtist: Bool { kind == Session.seedStationArtist }

    static let separator = "\u{1F}"

    public static func song(seedMediaId: String, title: String, primaryArtist: String, nowMs: Int64) -> Station {
        Station(id: idOf(kind: Session.seedStationSong, seedMediaId: seedMediaId), kind: Session.seedStationSong,
                seedMediaId: seedMediaId, title: title, artistName: primaryArtist, startedAtMs: nowMs)
    }

    public static func artist(seedMediaId: String, artistName: String, nowMs: Int64) -> Station {
        Station(id: idOf(kind: Session.seedStationArtist, seedMediaId: seedMediaId), kind: Session.seedStationArtist,
                seedMediaId: seedMediaId, title: artistName, artistName: artistName, startedAtMs: nowMs)
    }

    /// Lower-case hexadecimal of `fnv1a64("station|<kind>|<seedMediaId>")`, as Android writes it.
    public static func idOf(kind: Int32, seedMediaId: String) -> String {
        BrainSurfaces.hashedId("station|\(kind)|\(seedMediaId)")
    }

    /// One line of text for the preferences: the five fields, separated by U+001F.
    public func encode() -> String {
        [String(kind), seedMediaId, Self.clean(title), Self.clean(artistName), String(startedAtMs)]
            .joined(separator: Self.separator)
    }

    public static func decode(_ text: String?) -> Station? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.components(separatedBy: separator)
        guard parts.count == 5, let kind = Int32(parts[0]),
              kind == Session.seedStationSong || kind == Session.seedStationArtist, !parts[1].isEmpty,
              let startedAtMs = Int64(parts[4]) else { return nil }
        return Station(id: idOf(kind: kind, seedMediaId: parts[1]), kind: kind, seedMediaId: parts[1], title: parts[2],
                       artistName: parts[3], startedAtMs: startedAtMs)
    }

    private static func clean(_ text: String) -> String { text.replacingOccurrences(of: separator, with: " ") }

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
