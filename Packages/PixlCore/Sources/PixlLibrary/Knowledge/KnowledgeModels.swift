// The open-data hosts of the brain's knowledge layer (docs/brain-spec.md, 3.3 B and 3.7), with the spec's rate and
// daily ceiling and the owner's third-party-terms decision: each host has its own off switch (local and remote), and
// each is used at run time only. A port of Android's `KnowledgeModels.kt`.
//
// These clients live in PixlLibrary, not PixlNet: they need `BrainText` (title folding) and PixlNet cannot import
// PixlLibrary. The network itself is a `KnowledgeTransport` the app supplies, so every rule here is tested without one.

import Foundation

/// The hosts, with the polite spacing, the daily ceiling and the terms the Developer screen and the handoff list.
public enum KnowledgeHost: String, Sendable, CaseIterable {
    case deezer, musicbrainz, listenbrainz, wikidata, itunes

    public var key: String { rawValue }

    public var host: String {
        switch self {
        case .deezer: return "api.deezer.com"
        case .musicbrainz: return "musicbrainz.org"
        case .listenbrainz: return "api.listenbrainz.org"
        case .wikidata: return "query.wikidata.org"
        case .itunes: return "itunes.apple.com"
        }
    }

    /// Spacing between two requests: the polite rate of the host.
    public var minIntervalMs: Int64 {
        switch self {
        case .deezer: return 200
        case .musicbrainz: return 1_100
        case .listenbrainz: return 1_000
        case .wikidata: return 6_000
        case .itunes: return 3_500
        }
    }

    /// Requests a day, across every caller (3.7: "Daily ceiling").
    public var dailyCeiling: Int {
        switch self {
        case .deezer: return 600
        case .musicbrainz: return 200
        case .listenbrainz: return 150
        case .wikidata: return 3
        case .itunes: return 60
        }
    }

    /// The name the Developer screen shows.
    public var label: String {
        switch self {
        case .deezer: return "Deezer"
        case .musicbrainz: return "MusicBrainz"
        case .listenbrainz: return "ListenBrainz"
        case .wikidata: return "Wikidata"
        case .itunes: return "iTunes Search"
        }
    }

    /// What the handoff lists so the owner can switch a source off before charging anyone.
    public var terms: String {
        switch self {
        case .deezer:
            return "Non-commercial API terms. Album genres, popularity, release date, tempo and loudness. Used at run time only, never stored beyond the device."
        case .musicbrainz:
            return "Core data CC0; tag votes CC BY-NC-SA, so the votes are fetched at run time and never bundled. One request per 1.1 s and an app User-Agent, as MetaBrainz asks."
        case .listenbrainz:
            return "Open data, derived from MusicBrainz tags (CC BY-NC-SA votes); popularity is the listener count. Used at run time only."
        case .wikidata:
            return "CC0. One SPARQL query per 100 artists."
        case .itunes:
            return "The iTunes Search API's terms: genre and release date of a song, looked up by name, one request per 3.5 s."
        }
    }

    public static func byKey(_ key: String) -> KnowledgeHost? { KnowledgeHost(rawValue: key) }
}

// MARK: What the parsers read out of a response

/// Deezer answers errors as HTTP 200 with an `error` object: `errorCode` is 0 for a real answer, 4 quota, 800 no data.
public struct DeezerReply<T: Sendable>: Sendable {
    public var value: T?
    public var errorCode: Int
    public init(_ value: T?, _ errorCode: Int = 0) {
        self.value = value
        self.errorCode = errorCode
    }
    public var quota: Bool { errorCode == 4 }
    public var noData: Bool { errorCode == 800 || (errorCode == 0 && value == nil) }
}

public struct DeezerTrackRef: Sendable, Equatable {
    public var id: Int64
    public var title: String
    public var artistName: String
    public var artistId: Int64
    public var durationSec: Int
    public var rank: Int64
    public var albumId: Int64
    public var isrc: String?
}

public struct DeezerTrack: Sendable, Equatable {
    public var id: Int64
    public var isrc: String?
    public var title: String
    public var durationSec: Int
    public var rank: Int64
    public var releaseDate: String?
    public var bpm: Double
    /// Loudness in dB; nil when Deezer sent none.
    public var gain: Double?
    public var explicit: Bool?
    public var albumId: Int64
    public var artistId: Int64
    public var artistName: String

    public init(id: Int64, isrc: String? = nil, title: String = "", durationSec: Int = 0, rank: Int64 = 0,
                releaseDate: String? = nil, bpm: Double = 0, gain: Double? = nil, explicit: Bool? = nil, albumId: Int64 = 0,
                artistId: Int64 = 0, artistName: String = "") {
        self.id = id
        self.isrc = isrc
        self.title = title
        self.durationSec = durationSec
        self.rank = rank
        self.releaseDate = releaseDate
        self.bpm = bpm
        self.gain = gain
        self.explicit = explicit
        self.albumId = albumId
        self.artistId = artistId
        self.artistName = artistName
    }
}

public struct DeezerAlbum: Sendable, Equatable {
    public var id: Int64
    public var genres: [String]
    public var releaseDate: String?
    public init(id: Int64, genres: [String], releaseDate: String? = nil) {
        self.id = id
        self.genres = genres
        self.releaseDate = releaseDate
    }
}

public struct MbGenreVote: Sendable, Equatable {
    public var name: String
    public var mbid: String
    public var count: Int
    public init(name: String, mbid: String = "", count: Int = 0) {
        self.name = name
        self.mbid = mbid
        self.count = count
    }
}

public struct MbRecordingHit: Sendable, Equatable {
    public var mbid: String
    public var score: Int
    public var title: String
    public var disambiguation: String
    public var lengthMs: Int
    public var artistNames: [String]
    public var artistMbid: String?
    public var firstReleaseDate: String?
    public var isrcs: [String]

    public init(mbid: String, score: Int = 0, title: String = "", disambiguation: String = "", lengthMs: Int = 0,
                artistNames: [String] = [], artistMbid: String? = nil, firstReleaseDate: String? = nil, isrcs: [String] = []) {
        self.mbid = mbid
        self.score = score
        self.title = title
        self.disambiguation = disambiguation
        self.lengthMs = lengthMs
        self.artistNames = artistNames
        self.artistMbid = artistMbid
        self.firstReleaseDate = firstReleaseDate
        self.isrcs = isrcs
    }
}

public struct MbRecording: Sendable, Equatable {
    public var mbid: String
    public var title: String
    public var firstReleaseDate: String?
    public var genres: [MbGenreVote]
    public var tags: [MbGenreVote]
}

public struct MbArtist: Sendable, Equatable {
    public var mbid: String
    public var name: String
    public var country: String
    public var genres: [MbGenreVote]
    public var tags: [MbGenreVote]

    public init(mbid: String, name: String = "", country: String = "", genres: [MbGenreVote] = [], tags: [MbGenreVote] = []) {
        self.mbid = mbid
        self.name = name
        self.country = country
        self.genres = genres
        self.tags = tags
    }
}

/// A ListenBrainz tag: `scope` is `recording`, `artist` or `release_group`; `genreMbid` is empty when the tag is not a genre.
public struct LbTag: Sendable, Equatable {
    public var tag: String
    public var count: Int
    public var genreMbid: String
    public var scope: String
    public init(tag: String, count: Int = 0, genreMbid: String = "", scope: String) {
        self.tag = tag
        self.count = count
        self.genreMbid = genreMbid
        self.scope = scope
    }
}

public struct LbRecording: Sendable, Equatable {
    public var mbid: String
    public var tags: [LbTag]
    public var artistMbid: String?
    public var firstReleaseDate: String?
    public var year: Int
    public init(mbid: String, tags: [LbTag] = [], artistMbid: String? = nil, firstReleaseDate: String? = nil, year: Int = 0) {
        self.mbid = mbid
        self.tags = tags
        self.artistMbid = artistMbid
        self.firstReleaseDate = firstReleaseDate
        self.year = year
    }
}

public struct LbPopularity: Sendable, Equatable {
    public var mbid: String
    public var listens: Int64
    public var users: Int64
    public init(mbid: String, listens: Int64 = 0, users: Int64 = 0) {
        self.mbid = mbid
        self.listens = listens
        self.users = users
    }
}

public struct WdArtist: Sendable, Equatable {
    public var mbid: String
    public var wikidataId: String
    public var genreMbids: [String]
    public var genreLabels: [String]
    public init(mbid: String, wikidataId: String = "", genreMbids: [String] = [], genreLabels: [String] = []) {
        self.mbid = mbid
        self.wikidataId = wikidataId
        self.genreMbids = genreMbids
        self.genreLabels = genreLabels
    }
}

public struct ITunesSong: Sendable, Equatable {
    public var trackName: String
    public var artistName: String
    public var durationMs: Int
    public var genre: String
    public var releaseDate: String?
    public var explicit: Bool?
    public init(trackName: String, artistName: String = "", durationMs: Int = 0, genre: String = "", releaseDate: String? = nil,
                explicit: Bool? = nil) {
        self.trackName = trackName
        self.artistName = artistName
        self.durationMs = durationMs
        self.genre = genre
        self.releaseDate = releaseDate
        self.explicit = explicit
    }
}

// MARK: What a source call returns

/// `found`: the source knows it. `notFound`: the source answered and has nothing (the negative cache keeps the enricher
/// away for 14 days, doubling to 120). `unavailable`: not asked or not answered (switched off, budget spent, offline,
/// an error, a quota): nothing is recorded and the next run tries again.
public enum Lookup<T: Sendable>: Sendable {
    case found(T)
    case notFound
    case unavailable

    public var value: T? { if case .found(let v) = self { return v } else { return nil } }
}
