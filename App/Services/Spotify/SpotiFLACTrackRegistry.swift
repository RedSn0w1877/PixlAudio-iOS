import Foundation
import PixlModel
import PixlNet

/// Thread-safe registry mapping stream `videoId`s (and `spotifyId`s) to their `SpotiFLACTrackQuery` metadata
/// so `InnerTubeService`, `StreamFetcher`, and `DownloadManager` can resolve lossless FLAC streams first
/// and fall back automatically to YouTube (`InnerTube`) if a track is unavailable or fails on SpotiFLAC.
nonisolated final class SpotiFLACTrackRegistry: @unchecked Sendable {
    static let shared = SpotiFLACTrackRegistry()

    private let lock = NSLock()
    private var byVideoId: [String: SpotiFLACTrackQuery] = [:]
    private var bySpotifyId: [String: SpotiFLACTrackQuery] = [:]

    init() {}

    /// Registers a full `SpotiFLACTrackQuery` for `videoId` (and its `spotifyId` when non-empty).
    func register(_ query: SpotiFLACTrackQuery, forVideoId videoId: String? = nil) {
        guard !query.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let trimmedSpotifyId = query.spotifyId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSpotifyId.isEmpty {
            if let existing = bySpotifyId[trimmedSpotifyId], existing.isrc != nil && query.isrc == nil {
                var merged = query
                merged.isrc = existing.isrc
                bySpotifyId[trimmedSpotifyId] = merged
            } else {
                bySpotifyId[trimmedSpotifyId] = query
            }
        }

        if let videoId, !videoId.isEmpty {
            if let existing = byVideoId[videoId], existing.isrc != nil && query.isrc == nil {
                var merged = query
                merged.isrc = existing.isrc
                byVideoId[videoId] = merged
            } else if !trimmedSpotifyId.isEmpty, let enriched = bySpotifyId[trimmedSpotifyId] {
                byVideoId[videoId] = enriched
            } else {
                byVideoId[videoId] = query
            }
        }
    }

    /// Registers metadata from a `Song` for `videoId` without overwriting an existing entry that already carries an ISRC.
    func register(song: Song, forVideoId videoId: String) {
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = song.displayArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty, artist != "Unknown Artist" else { return }

        let spotifyId = SpotifyPlayableURLResolver.spotifyId(of: song) ?? ""
        lock.lock()
        let existingSpotifyQuery = spotifyId.isEmpty ? nil : bySpotifyId[spotifyId]
        let existingVideoQuery = byVideoId[videoId]
        lock.unlock()

        if let existingVideoQuery, existingVideoQuery.isrc != nil {
            return
        }
        if let existingSpotifyQuery {
            register(existingSpotifyQuery, forVideoId: videoId)
            return
        }

        let query = SpotiFLACTrackQuery(
            spotifyId: spotifyId,
            title: title,
            artist: artist,
            album: song.album == "Unknown Album" ? "" : song.album,
            durationMs: Int(clamping: song.duration),
            isrc: nil
        )
        register(query, forVideoId: videoId)
    }

    /// Returns the registered `SpotiFLACTrackQuery` for `videoId`, if any.
    func query(forVideoId videoId: String) -> SpotiFLACTrackQuery? {
        lock.lock()
        defer { lock.unlock() }
        return byVideoId[videoId]
    }

    /// Returns the registered `SpotiFLACTrackQuery` for `spotifyId`, if any.
    func query(forSpotifyId spotifyId: String) -> SpotiFLACTrackQuery? {
        lock.lock()
        defer { lock.unlock() }
        return bySpotifyId[spotifyId]
    }

    /// Deterministic 11-character identifier (`_[A-Za-z0-9]{10}`) for an unmatched Spotify track so it can travel
    /// through `pixlstream://` and `StreamCache` when YouTube has no match.
    static func syntheticVideoId(forSpotifyId spotifyId: String) -> String {
        let filtered = spotifyId.unicodeScalars.filter { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 65 && scalar.value <= 90) ||
            (scalar.value >= 97 && scalar.value <= 122)
        }
        var suffix = String(String.UnicodeScalarView(filtered).prefix(10))
        if suffix.count < 10 {
            suffix += String(repeating: "0", count: 10 - suffix.count)
        }
        return "_" + suffix
    }

    /// True when `videoId` is a synthetic SpotiFLAC-only stream identifier rather than a real YouTube video ID.
    static func isSyntheticVideoId(_ videoId: String) -> Bool {
        videoId.count == 11 && videoId.hasPrefix("_")
    }
}
