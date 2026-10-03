// Artist pictures from Deezer (Android `ArtistImageRepository` + `DeezerApiService.searchArtist`): the request, the
// picture a search answer carries, and the high-resolution URL upgrade. The app runs the requests (three at a time,
// with Android's retry) and stores the URLs on the artists.

import Foundation
import PixlFoundation

public enum DeezerArtistImages {
    /// `DeezerApiService` base URL.
    public static let baseURL = "https://api.deezer.com/"
    /// `PREFETCH_CONCURRENCY`: parallel lookups while prefetching.
    public static let prefetchConcurrency = 3
    /// `NETWORK_RETRY_ATTEMPTS` and `NETWORK_RETRY_INITIAL_DELAY_MS` (the delay doubles per retry).
    public static let retryAttempts = 3
    public static let retryInitialDelayMs = 500

    /// What one lookup found.
    public enum Outcome: Sendable, Hashable {
        /// The artist's picture (already upgraded to 1000×1000).
        case picture(String)
        /// Deezer knows no such artist, or it has no picture (Android remembers it as a failed fetch).
        case noMatch
        /// An error answer (quota, server) or an unreadable body: worth retrying.
        case failed
    }

    /// `GET search/artist?q=<name>&limit=1` (Retrofit encodes the query like OkHttp).
    public static func searchRequest(artistName: String) -> HTTPRequest {
        HTTPRequest(url: baseURL + "search/artist?q=" + URLCoding.okHttpQueryComponent(artistName) + "&limit=1",
                    timeout: 15)
    }

    /// The first match's `picture_xl ?: picture_big ?: picture_medium ?: picture`, upgraded.
    public static func outcome(statusCode: Int, body: Data) -> Outcome {
        guard (200...299).contains(statusCode), let root = OrgJSON.parse(body)?.objectValue else { return .failed }
        if root["error"] != nil { return .failed }
        guard let first = root["data"]?.arrayValue?.first?.objectValue else { return .noMatch }
        for key in ["picture_xl", "picture_big", "picture_medium", "picture"] {
            if let url = first[key]?.stringValue, !url.isEmpty { return .picture(upgradeToHighRes(url)) }
        }
        return .noMatch
    }

    /// `upgradeToHighResDeezerUrl`: Deezer CDN artist pictures carry their size in the path
    /// (`/250x250-000000-80-0-0.jpg`); ask for 1000×1000. Other URLs are returned unchanged.
    public static func upgradeToHighRes(_ url: String) -> String {
        guard url.contains("dzcdn.net/images/artist"),
              let regex = try? NSRegularExpression(pattern: "/\\d{2,4}x\\d{2,4}([\\-.])") else { return url }
        let range = NSRange(url.startIndex..., in: url)
        return regex.stringByReplacingMatches(in: url, range: range, withTemplate: "/1000x1000$1")
    }

    /// The key a lookup is remembered under (`artistName.trim().lowercase()`).
    public static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
