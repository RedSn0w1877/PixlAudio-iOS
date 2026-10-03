// Spotify Connect: turning PixlAudio's queue into Spotify track URIs. A song with a real Spotify id plays as
// `spotify:track:<id>`; any other song (a local file, a YouTube Music row) is looked up with Spotify search —
// `isrc:<ISRC>` first when the song has one, then title + artist — and only a strict match is accepted: same
// normalized title and artist, duration within ±3 s, no live/remix/cover/… mismatch (TrackMatcher's normalization
// and variant words). Results, misses included, are cached persistently; misses are retried after a week.

import Foundation
import PixlFoundation
import PixlModel

/// What resolution needs from a queue entry.
public struct SpotifyConnectSong: Sendable, Hashable {
    /// The PixlAudio song id (the cache key).
    public var key: String
    public var spotifyId: String?
    public var title: String
    public var artist: String
    public var durationMs: Int64
    /// A local file whose tags may hold an ISRC (read by the app's `ISRCLookup`, only on a cache miss).
    public var fileURL: String?

    public init(key: String, spotifyId: String?, title: String, artist: String, durationMs: Int64, fileURL: String? = nil) {
        self.key = key
        self.spotifyId = spotifyId
        self.title = title
        self.artist = artist
        self.durationMs = durationMs
        self.fileURL = fileURL
    }

    /// Changes when the tags that decide the match change (a cached answer for other tags is stale).
    public var fingerprint: String {
        "\(TrackMatcher.normalize(title))|\(TrackMatcher.normalize(artist))|\(durationMs / 1000)"
    }

    /// The URI without any lookup (a real Spotify id).
    public var directURI: String? { SpotifyConnect.directURI(spotifyId: spotifyId) }
}

/// The strict match rules.
public enum SpotifyConnectMatcher {
    public static let durationToleranceMs: Int64 = 3000

    /// Words that make a different recording (TrackMatcher's list plus "acoustic" and "demo").
    static let variantWords = TrackMatcher.variantPenaltyWords + ["acoustic", "demo"]

    /// Bracketed or dashed suffixes that name the same recording ("(feat. X)", "- Remastered 2011").
    static let sameRecordingMarkers = ["feat", "ft", "featuring", "with", "remaster", "remastered", "mono", "stereo",
                                       "single version", "album version", "original mix", "explicit", "clean"]

    /// The ISRC query (`isrc` field filter), or nil for something that isn't an ISRC (12 alphanumerics).
    public static func isrcQuery(_ isrc: String?) -> String? {
        guard let isrc else { return nil }
        let code = String(String.UnicodeScalarView(isrc.unicodeScalars.filter {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A)
        })).uppercased()
        guard code.unicodeScalars.count == 12 else { return nil }
        return "isrc:\(code)"
    }

    /// The text query: "title primaryArtist", stripped of quotes and colons so it can't become a field filter.
    public static func textQuery(_ song: SpotifyConnectSong) -> String? {
        let title = clean(song.title)
        let artist = clean(primaryArtist(song.artist))
        if NetText.isBlank(title) { return nil }
        return NetText.isBlank(artist) ? title : "\(title) \(artist)"
    }

    private static func clean(_ s: String) -> String {
        NetText.trim(String(String.UnicodeScalarView(s.unicodeScalars.map { $0 == "\"" || $0 == ":" ? " " : $0 })))
    }

    /// The first artist of a local tag ("A feat. B", "A & B", "A, B", "A; B", "A / B", "A x B").
    static func primaryArtist(_ artist: String) -> String {
        var best = artist
        for separator in [",", ";", " & ", " / ", " feat. ", " feat ", " ft. ", " ft ", " featuring ", " x ", " with "] {
            if let range = best.range(of: separator, options: .caseInsensitive) {
                best = String(best[best.startIndex..<range.lowerBound])
            }
        }
        return NetText.trim(best)
    }

    /// The title with same-recording suffixes removed, normalized.
    static func coreTitle(_ title: String) -> String {
        var s = Array(title.unicodeScalars)
        // Bracketed segments that only add "feat." / "Remastered" / …
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < s.count {
            if s[i] == "(" || s[i] == "[", let close = s[(i + 1)...].firstIndex(where: { $0 == ")" || $0 == "]" }) {
                let inner = TrackMatcher.normalize(String(String.UnicodeScalarView(s[(i + 1)..<close])))
                if sameRecordingMarkers.contains(where: { TrackMatcher.containsPhrase(inner, $0) }) {
                    out.append(" ")
                    i = close + 1
                    continue
                }
            }
            out.append(s[i])
            i += 1
        }
        s = out
        // " - Remastered 2011" / " - Single Version".
        let text = String(String.UnicodeScalarView(s))
        if let dash = text.range(of: " - ") {
            let tail = TrackMatcher.normalize(String(text[dash.upperBound...]))
            if sameRecordingMarkers.contains(where: { TrackMatcher.containsPhrase(tail, $0) }) {
                return TrackMatcher.normalize(String(text[text.startIndex..<dash.lowerBound]))
            }
        }
        return TrackMatcher.normalize(text)
    }

    static func titlesMatch(_ local: String, _ remote: String) -> Bool {
        let a = TrackMatcher.normalize(local), b = TrackMatcher.normalize(remote)
        if !a.isEmpty, a == b { return true }
        let coreA = coreTitle(local), coreB = coreTitle(remote)
        return !coreA.isEmpty && coreA == coreB
    }

    static func variantsMatch(_ local: String, _ remote: String) -> Bool {
        let a = TrackMatcher.normalize(local), b = TrackMatcher.normalize(remote)
        return variantWords.allSatisfy { TrackMatcher.containsPhrase(a, $0) == TrackMatcher.containsPhrase(b, $0) }
    }

    static func artistsMatch(_ local: String, _ remote: [SpotifyArtistRef]) -> Bool {
        let whole = TrackMatcher.normalize(local)
        let primary = TrackMatcher.normalize(primaryArtist(local))
        if whole.isEmpty { return false }
        for artist in remote {
            let name = TrackMatcher.normalize(artist.name ?? "")
            if name.isEmpty { continue }
            if name == primary || name == whole { return true }
            if TrackMatcher.containsPhrase(whole, name) || TrackMatcher.containsPhrase(name, primary) { return true }
            if TrackMatcher.artistSimilarity(primary, name) >= 0.9 { return true }
        }
        return false
    }

    static func durationsMatch(_ localMs: Int64, _ remoteMs: Int64?) -> Bool {
        guard localMs > 0 else { return true } // unknown locally: title + artist decide
        guard let remoteMs, remoteMs > 0 else { return false }
        return abs(localMs - remoteMs) <= durationToleranceMs
    }

    static func isPlayableTrack(_ candidate: SpotifyTrack) -> Bool {
        guard let id = candidate.id, SpotifyConnect.isTrackId(id) else { return false }
        if candidate.isLocal == true { return false }
        if let type = candidate.type, type != "track" { return false }
        return true
    }

    /// A text-search candidate is the same recording.
    public static func isStrictMatch(_ song: SpotifyConnectSong, _ candidate: SpotifyTrack) -> Bool {
        guard isPlayableTrack(candidate), let name = candidate.name else { return false }
        return titlesMatch(song.title, name) && variantsMatch(song.title, name)
            && artistsMatch(song.artist, candidate.artists ?? []) && durationsMatch(song.durationMs, candidate.durationMs)
    }

    /// An ISRC hit is the recording by definition; the duration still has to agree (a re-release can reuse it).
    public static func isISRCMatch(_ song: SpotifyConnectSong, _ candidate: SpotifyTrack) -> Bool {
        isPlayableTrack(candidate) && durationsMatch(song.durationMs, candidate.durationMs)
    }

    /// The accepted candidate closest in duration, if any.
    public static func best(_ song: SpotifyConnectSong, _ candidates: [SpotifyTrack], isrc: Bool) -> SpotifyTrack? {
        candidates.filter { isrc ? isISRCMatch(song, $0) : isStrictMatch(song, $0) }
            .min { abs(($0.durationMs ?? 0) - song.durationMs) < abs(($1.durationMs ?? 0) - song.durationMs) }
    }
}

// MARK: - Cache

/// A cached answer: the URI, or nil for "not on Spotify".
public struct SpotifyConnectResolution: Sendable, Hashable, Codable {
    public var uri: String?
    public var fingerprint: String
    public var resolvedAtMs: Int64

    public init(uri: String?, fingerprint: String, resolvedAtMs: Int64) {
        self.uri = uri
        self.fingerprint = fingerprint
        self.resolvedAtMs = resolvedAtMs
    }
}

/// Where the cache lives (the app: a JSON file in Application Support).
public protocol SpotifyConnectResolutionStorage: Sendable {
    func load() async -> Data?
    func save(_ data: Data) async
}

/// Resolves queue entries, one search at a time (the Web API paces them), caching every answer.
public actor SpotifyConnectResolver {
    /// A miss is asked again after this long (the catalogue grows).
    public static let missRetryMs: Int64 = 7 * 24 * 3600 * 1000
    /// Entries kept (oldest dropped beyond it).
    public static let maxEntries = 20_000

    /// Runs one track search; nil when the request failed (nothing is cached then).
    public typealias Search = @Sendable (_ query: String) async throws -> [SpotifyTrack]?
    /// The song's ISRC, read on demand (local tags); nil when it has none.
    public typealias ISRCLookup = @Sendable (_ song: SpotifyConnectSong) async -> String?

    private let storage: (any SpotifyConnectResolutionStorage)?
    private let search: Search
    private let isrc: ISRCLookup
    private let nowMs: @Sendable () -> Int64
    private var entries: [String: SpotifyConnectResolution] = [:]
    private var loaded = false
    private var dirty = false

    public init(storage: (any SpotifyConnectResolutionStorage)?, search: @escaping Search,
                isrc: @escaping ISRCLookup = { _ in nil }, nowMs: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.storage = storage
        self.search = search
        self.isrc = isrc
        self.nowMs = nowMs
    }

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        guard let data = await storage?.load(),
              let decoded = try? JSONDecoder().decode([String: SpotifyConnectResolution].self, from: data) else { return }
        entries = decoded
    }

    /// The answer without a network call: `.uri` / `.skipped` when known (direct id, fresh cache entry), else
    /// `.pending`.
    public func cached(_ song: SpotifyConnectSong) async -> SpotifyConnectSlot {
        if let direct = song.directURI { return .uri(direct) }
        await ensureLoaded()
        guard let entry = entries[song.key], entry.fingerprint == song.fingerprint else { return .pending }
        if let uri = entry.uri { return .uri(uri) }
        return nowMs() - entry.resolvedAtMs < Self.missRetryMs ? .skipped : .pending
    }

    /// Resolves one song (cache first). A failed search answers `.pending` and caches nothing.
    public func resolve(_ song: SpotifyConnectSong) async throws -> SpotifyConnectSlot {
        let known = await cached(song)
        if known != .pending { return known }
        var searchFailed = false
        if let query = SpotifyConnectMatcher.isrcQuery(await isrc(song)) {
            if let tracks = try await search(query) {
                if let hit = SpotifyConnectMatcher.best(song, tracks, isrc: true), let id = hit.id {
                    return store(song, uri: SpotifyConnect.trackURI(id))
                }
            } else {
                searchFailed = true
            }
        }
        try Task.checkCancellation()
        if let query = SpotifyConnectMatcher.textQuery(song) {
            if let tracks = try await search(query) {
                if let hit = SpotifyConnectMatcher.best(song, tracks, isrc: false), let id = hit.id {
                    return store(song, uri: SpotifyConnect.trackURI(id))
                }
            } else {
                searchFailed = true
            }
        }
        if searchFailed { return .pending }
        return store(song, uri: nil)
    }

    private func store(_ song: SpotifyConnectSong, uri: String?) -> SpotifyConnectSlot {
        entries[song.key] = SpotifyConnectResolution(uri: uri, fingerprint: song.fingerprint, resolvedAtMs: nowMs())
        dirty = true
        if entries.count > Self.maxEntries {
            let overflow = entries.count - Self.maxEntries
            for key in entries.sorted(by: { $0.value.resolvedAtMs < $1.value.resolvedAtMs }).prefix(overflow).map(\.key) {
                entries[key] = nil
            }
        }
        return uri.map { .uri($0) } ?? .skipped
    }

    /// Writes the cache if anything changed.
    public func flush() async {
        guard dirty, let storage else { return }
        dirty = false
        guard let data = try? JSONEncoder().encode(entries) else { return }
        await storage.save(data)
    }

    /// Forgets the cache (logout).
    public func clear() async {
        entries = [:]
        loaded = true
        dirty = true
        await flush()
    }
}
