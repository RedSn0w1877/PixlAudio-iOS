// Value types of `data/youtube/InnerTubeClient.kt` and `YouTubeStreamResolver.kt`.

import Foundation

/// A song (or music video) found on YouTube Music.
public struct YouTubeSearchResult: Sendable, Hashable, Codable {
    public var videoId: String
    public var title: String
    public var artist: String
    public var album: String?
    public var durationSeconds: Int?
    public var thumbnailUrl: String?
    public var isMusicVideo: Bool

    public init(videoId: String, title: String, artist: String, album: String?, durationSeconds: Int?,
                thumbnailUrl: String? = nil, isMusicVideo: Bool = false) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.thumbnailUrl = thumbnailUrl
        self.isMusicVideo = isMusicVideo
    }
}

/// One audio format of a video.
public struct YouTubeAudioFormat: Sendable, Hashable, Codable {
    public var itag: Int
    public var mimeType: String?
    public var bitrate: Int
    /// Direct, playable URL (nil when it came ciphered).
    public var url: String?
    /// Unresolved `signatureCipher` query string (needs base.js).
    public var signatureCipher: String?
    public var contentLength: Int64?
    public var approxDurationMs: Int64?
    /// itag 18 (360p mp4 with audio and video): PoToken-exempt in yt-dlp, so it always arrives complete. Ranked last.
    public var isMuxedFallback: Bool

    public init(itag: Int, mimeType: String?, bitrate: Int, url: String?, signatureCipher: String?,
                contentLength: Int64?, approxDurationMs: Int64?, isMuxedFallback: Bool = false) {
        self.itag = itag
        self.mimeType = mimeType
        self.bitrate = bitrate
        self.url = url
        self.signatureCipher = signatureCipher
        self.contentLength = contentLength
        self.approxDurationMs = approxDurationMs
        self.isMuxedFallback = isMuxedFallback
    }
}

/// The parsed `player` response.
public struct YouTubePlayerResponse: Sendable, Hashable {
    /// `playabilityStatus.status` ("UNKNOWN" when missing or blank).
    public var status: String
    public var reason: String?
    public var formats: [YouTubeAudioFormat]
    /// The `pot` to append to the final audio URL when the response was requested with a PoToken.
    public var streamingPoToken: String?
    /// Diagnostics: true when the status was OK but no format survived parsing (the SABR signature).
    public var hadOnlyUnusableFormats: Bool
    /// Diagnostics: every `mimeType` of the raw format arrays when nothing was usable.
    public var rawMimeTypes: [String]
    /// Diagnostics: whether the response carried `streamingData.hlsManifestUrl`.
    public var hasHlsManifest: Bool

    public init(status: String, reason: String?, formats: [YouTubeAudioFormat], streamingPoToken: String? = nil,
                hadOnlyUnusableFormats: Bool = false, rawMimeTypes: [String] = [], hasHlsManifest: Bool = false) {
        self.status = status
        self.reason = reason
        self.formats = formats
        self.streamingPoToken = streamingPoToken
        self.hadOnlyUnusableFormats = hadOnlyUnusableFormats
        self.rawMimeTypes = rawMimeTypes
        self.hasHlsManifest = hasHlsManifest
    }

    /// `status.equals("OK", ignoreCase = true)`.
    public var isPlayable: Bool { status.lowercased() == "ok" }

    /// The diagnostics line `"<status> — <reason>"` used when a video is not playable.
    public var statusDetail: String { status + (reason.map { " — \($0)" } ?? "") }
}

/// A playable audio URL and the User-Agent it must be fetched with (googlevideo binds URLs to the client).
public struct ResolvedStream: Sendable, Hashable {
    public var url: String
    public var userAgent: String
    public var strategyName: String?

    public init(url: String, userAgent: String, strategyName: String? = nil) {
        self.url = url
        self.userAgent = userAgent
        self.strategyName = strategyName
    }
}

/// The result of the PoToken provider for an authenticated WEB_REMIX request (`PoTokenResult`).
public struct PoTokenResult: Sendable, Hashable {
    public var visitorData: String
    public var playerRequestPoToken: String
    public var streamingDataPoToken: String?

    public init(visitorData: String, playerRequestPoToken: String, streamingDataPoToken: String?) {
        self.visitorData = visitorData
        self.playerRequestPoToken = playerRequestPoToken
        self.streamingDataPoToken = streamingDataPoToken
    }
}
