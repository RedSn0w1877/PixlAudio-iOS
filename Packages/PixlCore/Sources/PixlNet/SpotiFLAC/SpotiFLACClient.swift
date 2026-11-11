import Foundation

/// Multi-provider lossless audio resolver (SpotiFLAC) that resolves Spotify tracks to direct FLAC streams.
/// Same order and rules as Android (`data/spotiflac/SpotiFLACClient.kt`).
///
/// Resolution order:
/// 1. **Monochrome Track Streamer** (`https://tracks.monochrome.st`):
///    - `/search/tracks?q=isrc:<ISRC>` finds the exact recording in one request (`isrc:` is Monochrome's own
///      syntax; a bare ISRC is searched as text and matches nothing useful);
///    - otherwise `/search/tracks?q=<main artist> <title>`, then the title alone, scored by `SpotiFLACMatcher`
///      (search rows already carry `isrc` and `duration`, so no release lookups);
///    - the audio is `https://tracks.monochrome.st/track/:trackId`: raw FLAC with byte ranges.
/// 2. **Tidal HiFi API instances**: `/search/?i=<ISRC>` then `?s=<query>`, then `/track/?id=<id>&quality=LOSSLESS`
///    (`OriginalTrackUrl` or the base64 `application/vnd.tidal.bts` manifest, `PREVIEW` rejected). None is built in
///    any more (see `defaultHiFiEndpoints`).
/// 3. **Deezer public API** (`/2.0/track/isrc:<ISRC>`): fills a missing title, artist or duration (rare).
///
/// A lookup that is cancelled, or that met network errors, is never remembered as a miss and never cools a host
/// down; every request has a short timeout and a host that failed is skipped for a minute, so a dead provider costs
/// one timeout at most before the caller falls back to YouTube.
public actor SpotiFLACClient {
    public nonisolated static let defaultUserAgent = "PixlAudio/1.0"

    public nonisolated static let defaultMonochromeTrackEndpoints: [URL] = [
        URL(string: "https://tracks.monochrome.st")!
    ]

    /// Tidal HiFi API instances tried after Monochrome. Empty: the four this shipped with were all gone on 2026-11-11
    /// (`api.monochrome.tf` and `tidal.kinoplus.online` no longer resolve; `wolf.qqdl.site` and `maus.qqdl.site` are
    /// parked domains). Add a live instance here and its host to `trustedAudioHostSuffixes` (Tidal's own CDN,
    /// `tidal.com`, already is).
    public nonisolated static let defaultHiFiEndpoints: [URL] = []

    public nonisolated static let defaultDeezerAPIBaseURL = URL(string: "https://api.deezer.com")!

    /// Trusted host suffixes for SpotiFLAC audio: only hosts a resolver can actually return. An unused or lapsed
    /// domain here would let whoever owns it feed audio to the player.
    public nonisolated static let trustedAudioHostSuffixes: Set<String> = [
        "monochrome.st",
        "tidal.com"
    ]

    /// Seconds each provider request may take.
    public nonisolated static let requestTimeoutSeconds: Double = 5

    private let http: any HTTPClient
    private let monochromeEndpoints: [URL]
    private let hifiEndpoints: [URL]
    private let deezerAPIBaseURL: URL
    private let clock: @Sendable () -> Int64

    /// Positive resolution cache (`cacheKey -> SpotiFLACResolvedStream`).
    private var resolvedCache: [String: SpotiFLACResolvedStream] = [:]
    /// Negative lookup cache (`cacheKey -> expiryEpochMs`): clean misses only.
    private var negativeCache: [String: Int64] = [:]
    /// Per-host failure cooldowns (`host -> cooldownUntilEpochMs`).
    private var hostCooldownUntilMs: [String: Int64] = [:]

    private let negativeCacheTTLMs: Int64 = 10 * 60 * 1_000
    private let hostCooldownDurationMs: Int64 = 60 * 1_000

    /// Whether any request of the lookup in flight failed (network, 429, 5xx, a cooling-down host).
    private final class Lookup: @unchecked Sendable {
        var hadErrors = false
    }

    public init(
        http: any HTTPClient,
        monochromeEndpoints: [URL] = SpotiFLACClient.defaultMonochromeTrackEndpoints,
        hifiEndpoints: [URL] = SpotiFLACClient.defaultHiFiEndpoints,
        deezerAPIBaseURL: URL = SpotiFLACClient.defaultDeezerAPIBaseURL,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.http = http
        self.monochromeEndpoints = monochromeEndpoints
        self.hifiEndpoints = hifiEndpoints
        self.deezerAPIBaseURL = deezerAPIBaseURL
        self.clock = clock
    }

    /// Resolves a lossless FLAC stream for `query`, returning `nil` if no lossless provider matches (the caller then
    /// plays YouTube).
    public func resolve(_ query: SpotiFLACTrackQuery) async -> SpotiFLACResolvedStream? {
        let key = query.cacheKey
        if let cached = resolvedCache[key] {
            return cached
        }
        if let negUntil = negativeCache[key] {
            if clock() < negUntil { return nil }
            negativeCache[key] = nil
        }

        let lookup = Lookup()
        let enrichedQuery = await enrichWithDeezerIfNeeded(query, lookup: lookup)

        // 1. Primary: Monochrome Track Streamer (`https://tracks.monochrome.st`)
        for baseURL in monochromeEndpoints {
            if let stream = await resolveViaMonochrome(enrichedQuery, baseURL: baseURL, lookup: lookup) {
                return remember(stream, for: key)
            }
        }

        // 2. Secondary: Tidal HiFi instances (none built in; see `defaultHiFiEndpoints`)
        for baseURL in hifiEndpoints {
            if let stream = await resolveViaHiFiInstance(enrichedQuery, baseURL: baseURL, lookup: lookup) {
                return remember(stream, for: key)
            }
        }

        // Only a clean "no such track" is remembered: a cancelled lookup, or one that met errors or a cooling-down
        // host, may well succeed on the next play.
        if !lookup.hadErrors && !Task.isCancelled {
            if negativeCache.count >= 512 { negativeCache.removeAll() }
            negativeCache[key] = clock() + negativeCacheTTLMs
        }
        return nil
    }

    /// Evicts any cached resolution for `query` (e.g., if playback of the resolved URL fails mid-stream).
    public func invalidate(_ query: SpotiFLACTrackQuery) {
        let key = query.cacheKey
        resolvedCache.removeValue(forKey: key)
        negativeCache.removeValue(forKey: key)
    }

    /// Evicts any cached resolution matching `spotifyId`.
    public func invalidate(spotifyId: String) {
        let trimmed = spotifyId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        resolvedCache = resolvedCache.filter { key, _ in
            key != trimmed && !key.hasPrefix("\(trimmed)|")
        }
        negativeCache = negativeCache.filter { key, _ in
            key != trimmed && !key.hasPrefix("\(trimmed)|")
        }
    }

    private func remember(_ stream: SpotiFLACResolvedStream, for key: String) -> SpotiFLACResolvedStream {
        if resolvedCache.count >= 256 { resolvedCache.removeAll() }
        resolvedCache[key] = stream
        negativeCache[key] = nil
        return stream
    }

    // MARK: - Provider 1: Monochrome Track Streamer

    private func resolveViaMonochrome(
        _ query: SpotiFLACTrackQuery,
        baseURL: URL,
        lookup: Lookup
    ) async -> SpotiFLACResolvedStream? {
        var searchTerms: [String] = []
        // 1a. The exact recording.
        if let isrc = SpotiFLACMatcher.normalizeISRC(query.isrc) {
            searchTerms.append("isrc:\(isrc)")
        }
        // 1b. Text search: main artist + title, then the title alone.
        searchTerms.append(contentsOf: buildSearchQueries(for: query))

        for searchTerm in searchTerms {
            if Task.isCancelled { return nil }
            guard let searchURL = buildSearchTracksURL(baseURL: baseURL, query: searchTerm),
                  let searchData = await performGET(searchURL, hostForCooldown: baseURL, lookup: lookup) else {
                continue
            }

            let candidates = SpotiFLACParsing.parseMonochromeSearchTracks(searchData, baseURL: baseURL)
            guard let best = SpotiFLACMatcher.selectBestCandidate(candidates, target: query),
                  let streamURL = best.candidate.streamURL
                      ?? SpotiFLACParsing.buildMonochromeTrackURL(baseURL: baseURL, trackId: best.candidate.id),
                  CloudStreamSecurity.isSafeRemoteStreamURL(streamURL.absoluteString,
                                                            allowedHostSuffixes: Self.trustedAudioHostSuffixes) else {
                continue
            }

            return SpotiFLACResolvedStream(
                url: streamURL,
                provider: .monochrome,
                trackId: best.candidate.id,
                isrc: best.candidate.isrc ?? query.isrc,
                mimeType: "audio/flac",
                codec: "flac",
                fileExtension: "flac",
                bitDepth: best.candidate.bitDepth ?? 16,
                sampleRate: best.candidate.sampleRate ?? 44_100,
                replayGain: best.candidate.replayGain,
                userAgent: Self.defaultUserAgent
            )
        }
        return nil
    }

    // MARK: - Provider 2: Tidal HiFi Instances

    private func resolveViaHiFiInstance(
        _ query: SpotiFLACTrackQuery,
        baseURL: URL,
        lookup: Lookup
    ) async -> SpotiFLACResolvedStream? {
        var candidatePool: [SpotiFLACCandidate] = []

        // 2a. Try direct ISRC search (`/search/?i=<ISRC>`) first when ISRC is known.
        if let isrc = SpotiFLACMatcher.normalizeISRC(query.isrc),
           let isrcURL = buildHiFiSearchURL(baseURL: baseURL, paramName: "i", paramValue: isrc),
           let data = await performGET(isrcURL, hostForCooldown: baseURL, lookup: lookup) {
            candidatePool.append(contentsOf: SpotiFLACParsing.parseHiFiSearchResponse(data))
        }

        // 2b. If ISRC search didn't yield an accepted candidate, try text search (`/search/?s=<query>`).
        if SpotiFLACMatcher.selectBestCandidate(candidatePool, target: query) == nil {
            for term in buildSearchQueries(for: query) {
                if Task.isCancelled { return nil }
                guard let searchURL = buildHiFiSearchURL(baseURL: baseURL, paramName: "s", paramValue: term),
                      let data = await performGET(searchURL, hostForCooldown: baseURL, lookup: lookup) else {
                    continue
                }
                let parsed = SpotiFLACParsing.parseHiFiSearchResponse(data)
                if !parsed.isEmpty {
                    candidatePool.append(contentsOf: parsed)
                    if SpotiFLACMatcher.selectBestCandidate(candidatePool, target: query) != nil {
                        break
                    }
                }
            }
        }

        guard let best = SpotiFLACMatcher.selectBestCandidate(candidatePool, target: query) else {
            return nil
        }

        guard let trackURL = buildHiFiTrackStreamURL(baseURL: baseURL, trackId: best.candidate.id),
              let streamData = await performGET(trackURL, hostForCooldown: baseURL, lookup: lookup),
              var resolved = SpotiFLACParsing.parseHiFiStreamResponse(
                  streamData,
                  trackId: best.candidate.id,
                  isrc: best.candidate.isrc ?? query.isrc
              ),
              CloudStreamSecurity.isSafeRemoteStreamURL(resolved.url.absoluteString,
                                                        allowedHostSuffixes: Self.trustedAudioHostSuffixes) else {
            return nil
        }

        if resolved.replayGain == nil {
            resolved.replayGain = best.candidate.replayGain
        }
        return resolved
    }

    // MARK: - Provider 3: Deezer ISRC Metadata Enrichment

    private func enrichWithDeezerIfNeeded(_ query: SpotiFLACTrackQuery, lookup: Lookup) async -> SpotiFLACTrackQuery {
        guard let isrc = SpotiFLACMatcher.normalizeISRC(query.isrc),
              (query.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
               query.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
               query.durationMs <= 0) else {
            return query
        }

        var components = URLComponents(url: deezerAPIBaseURL, resolvingAgainstBaseURL: false)
        let basePath = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = basePath.isEmpty ? "/2.0/track/isrc:\(isrc)" : "/\(basePath)/2.0/track/isrc:\(isrc)"
        guard let url = components?.url,
              let data = await performGET(url, hostForCooldown: deezerAPIBaseURL, lookup: lookup),
              let deezerTrack = SpotiFLACParsing.parseDeezerTrack(data) else {
            return query
        }

        return SpotiFLACTrackQuery(
            spotifyId: query.spotifyId,
            title: query.title.isEmpty ? deezerTrack.title : query.title,
            artist: query.artist.isEmpty ? deezerTrack.artist : query.artist,
            album: query.album.isEmpty ? (deezerTrack.album ?? "") : query.album,
            durationMs: query.durationMs > 0 ? query.durationMs : (deezerTrack.durationMs ?? 0),
            isrc: isrc
        )
    }

    // MARK: - URL Builders & Transport Helpers

    /// `<main artist> <title>`, then the title alone (same as Android).
    private func buildSearchQueries(for query: SpotiFLACTrackQuery) -> [String] {
        var queries: [String] = []
        let trimmedArtist = query.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return [] }
        let primaryArtist = trimmedArtist
            .components(separatedBy: CharacterSet(charactersIn: ",;&/"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmedArtist

        if !primaryArtist.isEmpty {
            queries.append("\(primaryArtist) \(trimmedTitle)")
        }
        queries.append(trimmedTitle)
        return queries
    }

    private func buildSearchTracksURL(baseURL: URL, query: String) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = basePath.isEmpty ? "/search/tracks" : "/\(basePath)/search/tracks"
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "6")
        ]
        return components?.url
    }

    private func buildHiFiSearchURL(baseURL: URL, paramName: String, paramValue: String) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = basePath.isEmpty ? "/search/" : "/\(basePath)/search/"
        components?.queryItems = [URLQueryItem(name: paramName, value: paramValue)]
        return components?.url
    }

    private func buildHiFiTrackStreamURL(baseURL: URL, trackId: String) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = basePath.isEmpty ? "/track/" : "/\(basePath)/track/"
        components?.queryItems = [
            URLQueryItem(name: "id", value: trackId),
            URLQueryItem(name: "quality", value: "LOSSLESS")
        ]
        return components?.url
    }

    private func isHostCoolingDown(_ baseURL: URL) -> Bool {
        guard let host = baseURL.host?.lowercased(),
              let until = hostCooldownUntilMs[host] else {
            return false
        }
        return clock() < until
    }

    private func markHostCooldown(_ baseURL: URL) {
        guard let host = baseURL.host?.lowercased() else { return }
        hostCooldownUntilMs[host] = clock() + hostCooldownDurationMs
    }

    /// One GET. A host cooling down is skipped; network trouble, 429 and 5xx cool it down for a minute. A cancelled
    /// request (URLSession reports it as a transport error) is nobody's fault: no cooldown, no error noted.
    private func performGET(_ url: URL, hostForCooldown: URL, lookup: Lookup) async -> Data? {
        if Task.isCancelled { return nil }
        if isHostCoolingDown(hostForCooldown) {
            lookup.hadErrors = true
            return nil
        }
        let req = HTTPRequest(
            method: .get,
            url: url.absoluteString,
            headers: [
                HTTPHeader("Accept", "application/json"),
                HTTPHeader("User-Agent", Self.defaultUserAgent)
            ],
            timeout: Self.requestTimeoutSeconds
        )
        do {
            let resp = try await http.send(req)
            if resp.isSuccessful {
                return resp.body
            }
            if resp.statusCode == 429 || resp.statusCode >= 500 {
                markHostCooldown(hostForCooldown)
                lookup.hadErrors = true
            }
            return nil
        } catch {
            if Task.isCancelled { return nil }
            markHostCooldown(hostForCooldown)
            lookup.hadErrors = true
            return nil
        }
    }
}
