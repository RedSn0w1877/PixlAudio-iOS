// BiniLyrics (https://lyrics.binimum.org) over an `HTTPClient`: the ISRC lookup, then a title + artist search,
// then the chosen TTML document. Matching and parsing are PixlLyrics' (`BiniLyricsMatching`, `TtmlDocumentParser`).
//
// Safety: every request — the API call, each redirect hop and the document — must be HTTPS to an allowlisted host
// (`BiniLyricsMatching.allowedHosts`). Redirects are followed here, one hop at a time, so the app hands this client a
// transport that does not follow them by itself. Bodies are capped (1 MB of JSON, 4 MB of TTML), each request has a
// short timeout, the lookup makes one request at a time with no retries, and a 429/5xx pauses the source (Retry-After
// honoured, doubling up to 15 minutes). Results (misses included) are remembered for 15 minutes per song, so one song
// costs one lookup. Cancellation ends a lookup quietly; nothing here throws to the caller.

import Foundation
import PixlFoundation
import PixlModel
import PixlLyrics

public actor BiniLyricsClient {
    public static let requestTimeoutSeconds: Double = 6
    public static let maxRedirects = 3
    public static let minBackoffMs: Int64 = 30_000
    public static let maxBackoffMs: Int64 = 15 * 60_000
    public static let maxRetryAfterMs: Int64 = 60 * 60_000
    public static let rememberMs: Int64 = 15 * 60_000
    public static let rememberLimit = 64

    /// A found document: the lyrics, the TTML they came from, and the search result that pointed to it.
    public struct Match: Sendable, Hashable {
        public let lyrics: Lyrics
        public let document: String
        public let candidate: BiniLyricsCandidate
    }

    private enum Failure: Error {
        /// HTTP 429 or 5xx: the source is paused.
        case throttled
    }

    private let http: any HTTPClient
    private let romanization: any CJKRomanizationProvider
    private let preferredLanguages: [String]
    private let nowMs: @Sendable () -> Int64
    private var blockedUntilMs: Int64 = 0
    private var backoffMs: Int64 = 0
    private var remembered: [String: (expiresMs: Int64, match: Match?)] = [:]
    private var rememberedOrder: [String] = []

    public init(http: any HTTPClient, romanization: any CJKRomanizationProvider = NoCJKRomanization(),
                preferredLanguages: [String] = [], nowMs: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.http = http
        self.romanization = romanization
        self.preferredLanguages = preferredLanguages
        self.nowMs = nowMs
    }

    /// Whether a 429/5xx has paused the source.
    public var isPaused: Bool { nowMs() < blockedUntilMs }

    /// The song's lyrics, or nil (no confident match, paused, offline, cancelled…).
    public func find(song: Song, isrc: String?) async -> Match? {
        let isrc = BiniLyricsMatching.normalizedISRC(isrc)
        let key = Self.rememberKey(song, isrc)
        let now = nowMs()
        if let entry = remembered[key], entry.expiresMs > now { return entry.match }
        if now < blockedUntilMs { return nil }
        do {
            let match = try await lookup(song: song, isrc: isrc)
            try Task.checkCancellation()
            remember(match, key: key)
            return match
        } catch {
            return nil // cancelled, paused or a transport error: not remembered, the next lookup tries again
        }
    }

    private func lookup(song: Song, isrc: String?) async throws -> Match? {
        var tried: String?
        if let isrc {
            let results = try await search(BiniLyricsMatching.isrcQuery(isrc))
            if let candidate = BiniLyricsMatching.choose(results, song: song, isrc: isrc, romanization: romanization) {
                if let match = try await document(for: candidate, song: song) { return match }
                tried = candidate.lyricsURL
            }
        }
        guard let query = BiniLyricsMatching.searchQuery(song: song) else { return nil }
        let results = try await search(query)
        guard let candidate = BiniLyricsMatching.choose(results, song: song, romanization: romanization),
              candidate.lyricsURL != tried else { return nil }
        return try await document(for: candidate, song: song)
    }

    private func search(_ query: [(name: String, value: String)]) async throws -> [BiniLyricsCandidate] {
        let url = URLCoding.url(BiniLyricsMatching.apiURL, query: query.map { ($0.name, Optional($0.value)) })
        guard let response = try await get(url, accept: "application/json", maxBytes: BiniLyricsMatching.maxSearchBytes)
        else { return [] }
        return BiniLyricsMatching.candidates(fromBody: Array(response.body)) ?? []
    }

    private func document(for candidate: BiniLyricsCandidate, song: Song) async throws -> Match? {
        guard let url = BiniLyricsMatching.documentURL(candidate),
              let response = try await get(url, accept: "application/ttml+xml, application/xml;q=0.9",
                                           maxBytes: BiniLyricsMatching.maxDocumentBytes) else { return nil }
        let text = String(decoding: response.body, as: UTF8.self)
        let metadata = LyricsMetadata(title: song.title, artist: song.displayArtist, album: song.album,
                                      source: BiniLyricsMatching.sourceName)
        guard let lyrics = TtmlDocumentParser.parse(text, metadata: metadata, preferredLanguages: preferredLanguages,
                                                    romanization: romanization),
              BiniLyricsMatching.isPlausible(lyrics, song: song) else { return nil }
        return Match(lyrics: lyrics, document: text, candidate: candidate)
    }

    /// One GET, following up to three redirects that stay on allowlisted HTTPS hosts. nil for a refused hop, a
    /// non-success status or an oversized body; throws `Failure.throttled` on 429/5xx and transport errors as they are.
    private func get(_ url: String, accept: String, maxBytes: Int) async throws -> HTTPResponse? {
        var current = url
        for _ in 0...Self.maxRedirects {
            guard BiniLyricsMatching.isAllowedURL(current) else { return nil }
            try Task.checkCancellation()
            let request = HTTPRequest(url: current, headers: [HTTPHeader("User-Agent", LyricsHTTP.userAgent),
                                                              HTTPHeader("Accept", accept)],
                                      timeout: Self.requestTimeoutSeconds)
            let response = try await http.send(request)
            try Task.checkCancellation()
            switch response.statusCode {
            case 301, 302, 303, 307, 308:
                guard let location = response.header("Location"),
                      let next = BiniLyricsMatching.redirectTarget(location: location, from: current) else { return nil }
                current = next
            case 429, 500...599:
                pause(retryAfter: response.header("Retry-After"))
                throw Failure.throttled
            case 200...299:
                backoffMs = 0
                if let declared = response.header("Content-Length").flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }),
                   declared > Int64(maxBytes) { return nil }
                return response.body.count > maxBytes ? nil : response
            default:
                return nil
            }
        }
        return nil
    }

    private func pause(retryAfter: String?) {
        backoffMs = min(max(backoffMs * 2, Self.minBackoffMs), Self.maxBackoffMs)
        var wait = backoffMs
        if let seconds = retryAfter.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }), seconds > 0 {
            wait = max(wait, min(seconds * 1000, Self.maxRetryAfterMs))
        }
        blockedUntilMs = nowMs() + wait
    }

    private func remember(_ match: Match?, key: String) {
        if remembered[key] == nil { rememberedOrder.append(key) }
        remembered[key] = (nowMs() + Self.rememberMs, match)
        while rememberedOrder.count > Self.rememberLimit {
            remembered[rememberedOrder.removeFirst()] = nil
        }
    }

    private static func rememberKey(_ song: Song, _ isrc: String?) -> String {
        [song.id, song.title, song.artist, song.album, String(song.duration), isrc ?? ""].joined(separator: "\u{1F}")
    }
}
