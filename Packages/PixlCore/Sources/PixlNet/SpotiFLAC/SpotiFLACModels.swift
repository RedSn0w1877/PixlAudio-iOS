import Foundation

/// Lossless stream provider tiers used by SpotiFLAC resolution.
public enum SpotiFLACProvider: String, Sendable, Codable, Hashable, CaseIterable {
    case monochrome = "monochrome"
    case tidal = "tidal"
    case qobuz = "qobuz"
    case deezer = "deezer"
}

/// Query metadata describing a track to resolve on the SpotiFLAC lossless chain.
public struct SpotiFLACTrackQuery: Sendable, Codable, Hashable {
    public var spotifyId: String
    public var title: String
    public var artist: String
    public var album: String
    public var durationMs: Int
    public var isrc: String?

    public init(
        spotifyId: String,
        title: String,
        artist: String,
        album: String = "",
        durationMs: Int,
        isrc: String? = nil
    ) {
        self.spotifyId = spotifyId
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.isrc = SpotiFLACMatcher.normalizeISRC(isrc)
    }

    /// Stable cache key combining Spotify track ID (or normalized artist + title) and ISRC when present.
    public var cacheKey: String {
        let base = spotifyId.trimmingCharacters(in: .whitespacesAndNewlines)
        let idPart = base.isEmpty
            ? "\(SpotiFLACMatcher.cleanString(artist)):\(SpotiFLACMatcher.cleanString(title)):\(durationMs)"
            : base
        if let normalizedISRC = SpotiFLACMatcher.normalizeISRC(isrc) {
            return "\(idPart)|\(normalizedISRC)"
        }
        return idPart
    }
}

extension SpotifyTrackRecord {
    /// Creates a `SpotiFLACTrackQuery` directly from a persisted or synced `SpotifyTrackRecord`.
    public var spotiFLACQuery: SpotiFLACTrackQuery {
        SpotiFLACTrackQuery(
            spotifyId: spotifyId,
            title: title,
            artist: artist,
            album: album,
            durationMs: Int(clamping: durationMs),
            isrc: isrc
        )
    }
}

/// What the first bytes of a SpotiFLAC file say about it (Android: `AudioFileFacts`). Monochrome sends everything as
/// `application/octet-stream` and mixes 16-bit/44.1 kHz FLAC, 24-bit FLAC up to 192 kHz and the odd AAC-in-MP4 file.
public struct SpotiFLACAudioFileFacts: Sendable, Hashable {
    public enum Format: String, Sendable, Hashable {
        case flac, mp4, mp3, aac, ogg, webm, unknown

        /// The MIME type the player is told, or nil for an unknown format.
        public var mimeType: String? {
            switch self {
            case .flac: "audio/flac"
            case .mp4: "audio/mp4"
            case .mp3: "audio/mpeg"
            case .aac: "audio/aac"
            case .ogg: "audio/ogg"
            case .webm: "audio/webm"
            case .unknown: nil
            }
        }
    }

    /// Enough for FLAC's STREAMINFO (bytes 8–41) and every other signature here.
    public static let headBytes = 64

    public var format: Format
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var channels: Int?

    public init(format: Format, sampleRate: Int? = nil, bitDepth: Int? = nil, channels: Int? = nil) {
        self.format = format
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
    }

    /// The FLAC sample rate, or nil for anything that isn't FLAC (or a rate the header didn't give).
    public var flacSampleRate: Int? { format == .flac ? sampleRate : nil }
}

/// ReplayGain loudness metadata returned by lossless stream providers when available.
public struct SpotiFLACReplayGain: Sendable, Codable, Hashable {
    public var trackGainDb: Double?
    public var trackPeak: Double?
    public var albumGainDb: Double?
    public var albumPeak: Double?

    public init(
        trackGainDb: Double? = nil,
        trackPeak: Double? = nil,
        albumGainDb: Double? = nil,
        albumPeak: Double? = nil
    ) {
        self.trackGainDb = trackGainDb
        self.trackPeak = trackPeak
        self.albumGainDb = albumGainDb
        self.albumPeak = albumPeak
    }
}

/// Candidate lossless track returned by a SpotiFLAC provider search or release lookup.
public struct SpotiFLACCandidate: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var provider: SpotiFLACProvider
    public var title: String
    public var artist: String
    public var artistNames: [String]
    public var album: String?
    public var releaseId: String?
    public var durationMs: Int?
    public var isrc: String?
    public var playable: Bool
    public var streamURL: URL?
    public var mimeType: String
    public var codec: String
    public var bitDepth: Int?
    public var sampleRate: Int?
    public var replayGain: SpotiFLACReplayGain?

    public init(
        id: String,
        provider: SpotiFLACProvider,
        title: String,
        artist: String,
        artistNames: [String] = [],
        album: String? = nil,
        releaseId: String? = nil,
        durationMs: Int? = nil,
        isrc: String? = nil,
        playable: Bool = true,
        streamURL: URL? = nil,
        mimeType: String = "audio/flac",
        codec: String = "flac",
        bitDepth: Int? = 16,
        sampleRate: Int? = 44_100,
        replayGain: SpotiFLACReplayGain? = nil
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.artist = artist
        self.artistNames = artistNames.isEmpty ? (artist.isEmpty ? [] : [artist]) : artistNames
        self.album = album
        self.releaseId = releaseId
        self.durationMs = durationMs
        self.isrc = SpotiFLACMatcher.normalizeISRC(isrc)
        self.playable = playable
        self.streamURL = streamURL
        self.mimeType = mimeType
        self.codec = codec
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.replayGain = replayGain
    }
}

/// Resolved direct lossless audio stream ready for byte-range streaming or offline download.
public struct SpotiFLACResolvedStream: Sendable, Codable, Hashable {
    public var url: URL
    public var provider: SpotiFLACProvider
    public var trackId: String
    public var isrc: String?
    public var mimeType: String
    public var codec: String
    public var fileExtension: String
    public var bitDepth: Int?
    public var sampleRate: Int?
    public var replayGain: SpotiFLACReplayGain?
    public var userAgent: String

    public init(
        url: URL,
        provider: SpotiFLACProvider,
        trackId: String,
        isrc: String? = nil,
        mimeType: String = "audio/flac",
        codec: String = "flac",
        fileExtension: String = "flac",
        bitDepth: Int? = 16,
        sampleRate: Int? = 44_100,
        replayGain: SpotiFLACReplayGain? = nil,
        userAgent: String = SpotiFLACClient.defaultUserAgent
    ) {
        self.url = url
        self.provider = provider
        self.trackId = trackId
        self.isrc = SpotiFLACMatcher.normalizeISRC(isrc)
        self.mimeType = mimeType
        self.codec = codec
        self.fileExtension = fileExtension
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.replayGain = replayGain
        self.userAgent = userAgent
    }
}
