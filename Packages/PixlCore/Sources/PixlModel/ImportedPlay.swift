// Listening history brought in from outside the app (spec "deep listening-history import", section B): plays read from
// the Spotify Web API, a Spotify data export, YouTube Music's history page or a Google Takeout file, and the taste
// snapshot Spotify keeps (top tracks / artists, followed artists). Plain values: PixlNet builds them from responses,
// PixlLibrary parses files into them, weights them and feeds them to the recommendations. The same model, constants and
// wording exist on Android.

import Foundation

/// Where an imported play came from. Spotify sources weigh 1.0, YouTube Music sources 0.35
/// (`ListeningHistoryWeights`).
public enum ImportedPlaySource: String, Sendable, Hashable, Codable, CaseIterable {
    /// `GET /v1/me/player/recently-played` (automatic sync).
    case spotifyAPI = "spotify_api"
    /// A Spotify "Download your data" file (extended or basic streaming history).
    case spotifyExport = "spotify_export"
    /// YouTube Music's history page through InnerTube (automatic sync, signed in to YouTube).
    case ytmusic = "ytmusic"
    /// A Google Takeout `watch-history.json`.
    case takeout = "takeout"

    public var isSpotify: Bool { self == .spotifyAPI || self == .spotifyExport }
}

/// One play from outside the app.
public struct ImportedPlay: Sendable, Hashable, Codable {
    public var source: ImportedPlaySource
    /// When the play ended (Spotify `ts` / `played_at` / `endTime`, Takeout `time`), ms since the epoch.
    public var timestampMs: Int64
    public var title: String
    /// The (first) artist; for YouTube the channel without " - Topic".
    public var artist: String
    public var album: String?
    /// The 22-character Spotify track id, when known.
    public var spotifyTrackId: String?
    /// The YouTube video id, when known.
    public var videoId: String?
    /// How long it was listened to (0 = unknown).
    public var msPlayed: Int64
    /// The track's length (0 = unknown).
    public var durationMs: Int64
    /// Spotify extended history `skipped` (nil = unknown).
    public var skipped: Bool?
    /// Spotify extended history `reason_start` (`clickrow`, `trackdone`, `fwdbtn`, …).
    public var reasonStart: String?
    /// Spotify extended history `reason_end` (`trackdone`, `fwdbtn`, `endplay`, …).
    public var reasonEnd: String?
    public var shuffle: Bool?

    public init(source: ImportedPlaySource, timestampMs: Int64, title: String, artist: String, album: String? = nil,
                spotifyTrackId: String? = nil, videoId: String? = nil, msPlayed: Int64 = 0, durationMs: Int64 = 0,
                skipped: Bool? = nil, reasonStart: String? = nil, reasonEnd: String? = nil, shuffle: Bool? = nil) {
        self.source = source
        self.timestampMs = timestampMs
        self.title = title
        self.artist = artist
        self.album = album
        self.spotifyTrackId = spotifyTrackId
        self.videoId = videoId
        self.msPlayed = msPlayed
        self.durationMs = durationMs
        self.skipped = skipped
        self.reasonStart = reasonStart
        self.reasonEnd = reasonEnd
        self.shuffle = shuffle
    }
}

/// What Spotify says the listener likes, besides individual plays: top tracks and artists per time range and the
/// followed artists. Replaced as a whole on every sync.
public struct ExternalTasteSnapshot: Sendable, Hashable, Codable {
    /// Spotify's `time_range`.
    public enum Range: String, Sendable, Hashable, Codable, CaseIterable {
        case shortTerm = "short_term"
        case mediumTerm = "medium_term"
        case longTerm = "long_term"
    }

    public struct RankedTrack: Sendable, Hashable, Codable {
        public var range: Range
        /// 0-based position in Spotify's list.
        public var rank: Int
        public var title: String
        public var artist: String
        public var spotifyTrackId: String?

        public init(range: Range, rank: Int, title: String, artist: String, spotifyTrackId: String? = nil) {
            self.range = range
            self.rank = rank
            self.title = title
            self.artist = artist
            self.spotifyTrackId = spotifyTrackId
        }
    }

    public struct RankedArtist: Sendable, Hashable, Codable {
        public var range: Range
        public var rank: Int
        public var name: String
        public var genres: [String]

        public init(range: Range, rank: Int, name: String, genres: [String] = []) {
            self.range = range
            self.rank = rank
            self.name = name
            self.genres = genres
        }
    }

    public var topTracks: [RankedTrack]
    public var topArtists: [RankedArtist]
    public var followedArtists: [String]
    public var fetchedAtMs: Int64

    public init(topTracks: [RankedTrack] = [], topArtists: [RankedArtist] = [], followedArtists: [String] = [],
                fetchedAtMs: Int64 = 0) {
        self.topTracks = topTracks
        self.topArtists = topArtists
        self.followedArtists = followedArtists
        self.fetchedAtMs = fetchedAtMs
    }

    public var isEmpty: Bool { topTracks.isEmpty && topArtists.isEmpty && followedArtists.isEmpty }
}
