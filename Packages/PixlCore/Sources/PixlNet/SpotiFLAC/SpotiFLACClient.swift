import Foundation

/// Multi-provider lossless audio resolver (SpotiFLAC) that resolves Spotify tracks to direct FLAC streams.
///
/// Resolution order:
/// 1. **Monochrome Track Streamer** (`https://tracks.monochrome.st`):
///    - Searches `/search/tracks?q=<artist> <title>&limit=6`
///    - Enriches candidate ISRCs and durations via `/releases/:releaseId` (cached)
///    - Scores with `SpotiFLACMatcher` (`exactISRCScore == 200`, `minimumAcceptScore == 85`)
///    - Returns `https://tracks.monochrome.st/track/:trackId` (supports HTTP byte-range `206 Partial Content` FLAC streaming).
/// 2. **Tidal HiFi API Instances** (`https://api.monochrome.tf`, `https://tidal.kinoplus.online`,
///    `https://wolf.qqdl.site`, `https://maus.qqdl.site`):
///    - Searches by ISRC (`/search/?i=<ISRC>`) when available, then by query (`/search/?s=<artist> <title>`)
///    - Resolves lossless manifest (`/track/?id=<id>&quality=LOSSLESS`), decoding either `OriginalTrackUrl`
///      or base64 `application/vnd.tidal.bts` `manifest` JSON `urls[0]` while rejecting `PREVIEW` responses.
/// 3. **Deezer Public API** (`https://api.deezer.com/2.0/track/isrc:<ISRC>`):
///    - Used for ISRC/duration enrichment when a track lacks duration or canonical title metadata,
///      and optional Deezer lossless stream endpoints when configured.
public actor SpotiFLACClient {
    public nonisolated static let defaultUserAgent = "PixlAudio/2.0 (SpotiFLAC; +https://monochrome.tf)"

    public nonisolated static let defaultMonochromeTrackEndpoints: [URL] = [
        URL(string: "https://tracks.monochrome.st")!
    ]

    public nonisolated static let defaultHiFiEndpoints: [URL] = [
        URL(string: "https://api.monochrome.tf")!,
        URL(string: "https://tidal.kinoplus.online")!,
        URL(string: "https://wolf.qqdl.site")!,
        URL(string: "https://maus.qqdl.site")!
    ]

    public nonisolated static let defaultDeezerAPIBaseURL = URL(string: "https://api.deezer.com")!

    /// Trusted host suffixes for lossless audio streams resolved by SpotiFLAC.
    public nonisolated static let trustedAudioHostSuffixes: Set<String> = [
        "monochrome.st",
        "monochrome.tf",
        "tidal.com",
        "kinoplus.online",
        "qqdl.site",
        "dzcdn.net",
        "deezer.com",
        "qobuz.com"
    ]

    private let http: any HTTPClient
    private let monochromeEndpoints: [URL]
    private let hifiEndpoints: [URL]
    private let deezerAPIBaseURL: URL
    private let clock: @Sendable () -> Int64

    /// Positive resolution cache (`cacheKey -> SpotiFLACResolvedStream`).
    private var resolvedCache: [String: SpotiFLACResolvedStream] = [:]
    /// Negative lookup cache (`cacheKey -> expiryEpochMs`).
    private var negativeCache: [String: Int64] = [:]
    /// Cached release tracklists (`releaseId -> [SpotiFLACCandidate]`).
    private var releaseCache: [String: [SpotiFLACCandidate]] = [:]
    /// Per-host failure cooldowns (`host -> cooldownUntilEpochMs`).
    private var hostCooldownUntilMs: [String: Int64] = [:]

    private let negativeCacheTTLMs: Int64 = 10 * 60 * 1_000
    private let hostCooldownDurationMs: Int64 = 60 * 1_000

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

    /// Resolves a lossless FLAC stream for `query`, returning `nil` if no lossless provider matches.
    public func resolve(_ query: SpotiFLACTrackQuery) async -> SpotiFLACResolvedStream? {
        let key = query.cacheKey
        if let cached = resolvedCache[key] {
            return cached
        }
        let now = clock()
        if let negUntil = negativeCache[key], now < negUntil {
            return nil
        }

        // Enrich via Deezer ISRC lookup if query has an ISRC but is missing title/artist or duration.
        let enrichedQuery = await enrichWithDeezerIfNeeded(query)

        // 1. Primary: Monochrome Track Streamer (`https://tracks.monochrome.st`)
        for baseURL in monochromeEndpoints where !isHostCoolingDown(baseURL, now: now) {
            if let stream = await resolveViaMonochrome(enrichedQuery, baseURL: baseURL) {
                resolvedCache[key] = stream
                return stream
            }
        }

        // 2. Secondary: Tidal HiFi instances (`api.monochrome.tf`, `tidal.kinoplus.online`, `wolf.qqdl.site`, `maus.qqdl.site`)
        for baseURL in hifiEndpoints where !isHostCoolingDown(baseURL, now: now) {
            if let stream = await resolveViaHiFiInstance(enrichedQuery, baseURL: baseURL) {
                resolvedCache[key] = stream
                return stream
            }
        }

        negativeCache[key] = clock() + negativeCacheTTLMs
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

    // MARK: - Provider 1: Monochrome Track Streamer

    private func resolveViaMonochrome(
        _ query: SpotiFLACTrackQuery,
        baseURL: URL
    ) async -> SpotiFLACResolvedStream? {
        let searchTerms = buildSearchQueries(for: query)
        for searchTerm in searchTerms {
            guard let searchURL = buildSearchTracksURL(baseURL: baseURL, query: searchTerm) else { continue }
            guard let searchData = await performGET(searchURL, hostForCooldown: baseURL) else { continue }

            let candidates = SpotiFLACParsing.parseMonochromeSearchTracks(searchData, baseURL: baseURL)
            guard !candidates.isEmpty else { continue }

            // Enrich top candidates via `/releases/:releaseId` so we can verify exact ISRC and durationMs.
            let enrichedCandidates = await enrichMonochromeCandidates(candidates, query: query, baseURL: baseURL)

            guard let best = SpotiFLACMatcher.selectBestCandidate(enrichedCandidates, target: query),
                  let streamURL = best.candidate.streamURL ?? SpotiFLACParsing.buildMonochromeTrackURL(baseURL: baseURL, trackId: best.candidate.id),
                  CloudStreamSecurity.isSafeRemoteStreamURL(streamURL.absoluteString) else {
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

    private func enrichMonochromeCandidates(
        _ candidates: [SpotiFLACCandidate],
        query: SpotiFLACTrackQuery,
        baseURL: URL
    ) async -> [SpotiFLACCandidate] {
        var enriched: [SpotiFLACCandidate] = []
        enriched.reserveCapacity(candidates.count)
        var fetchedReleaseCount = 0

        for candidate in candidates {
            // Only fetch release details for candidates whose title/artist plausibly match `query`
            // (and cap at 3 release lookups per search to keep latency minimal).
            let prelimScore = SpotiFLACMatcher.scoreCandidate(candidate, target: query)
            guard prelimScore >= SpotiFLACMatcher.minimumAcceptScore,
                  let releaseId = candidate.releaseId,
                  !releaseId.isEmpty else {
                enriched.append(candidate)
                continue
            }

            let releaseTracks: [SpotiFLACCandidate]?
            if let cached = releaseCache[releaseId] {
                releaseTracks = cached
            } else if fetchedReleaseCount < 3,
                      let releaseURL = buildReleaseURL(baseURL: baseURL, releaseId: releaseId),
                      let releaseData = await performGET(releaseURL, hostForCooldown: nil) {
                fetchedReleaseCount += 1
                let parsed = SpotiFLACParsing.parseMonochromeReleaseTracks(releaseData, baseURL: baseURL)
                if !parsed.isEmpty {
                    releaseCache[releaseId] = parsed
                }
                releaseTracks = parsed
            } else {
                releaseTracks = nil
            }

            if let releaseTracks {
                if let exactTrack = releaseTracks.first(where: { $0.id == candidate.id }) {
                    enriched.append(exactTrack)
                    // Short-circuit if we found an exact ISRC match!
                    if let targetISRC = SpotiFLACMatcher.normalizeISRC(query.isrc),
                       let trackISRC = SpotiFLACMatcher.normalizeISRC(exactTrack.isrc),
                       targetISRC == trackISRC,
                       exactTrack.playable {
                        return [exactTrack]
                    }
                    continue
                }
                // Also check if another track on the same release matches the target ISRC
                if let targetISRC = SpotiFLACMatcher.normalizeISRC(query.isrc),
                   let isrcTrack = releaseTracks.first(where: {
                       SpotiFLACMatcher.normalizeISRC($0.isrc) == targetISRC && $0.playable
                   }) {
                    return [isrcTrack]
                }
            }

            enriched.append(candidate)
        }

        return enriched
    }

    // MARK: - Provider 2: Tidal HiFi Instances

    private func resolveViaHiFiInstance(
        _ query: SpotiFLACTrackQuery,
        baseURL: URL
    ) async -> SpotiFLACResolvedStream? {
        var candidatePool: [SpotiFLACCandidate] = []

        // 2a. Try direct ISRC search (`/search/?i=<ISRC>`) first when ISRC is known.
        if let isrc = SpotiFLACMatcher.normalizeISRC(query.isrc),
           let isrcURL = buildHiFiSearchURL(baseURL: baseURL, paramName: "i", paramValue: isrc),
           let data = await performGET(isrcURL, hostForCooldown: baseURL) {
            candidatePool.append(contentsOf: SpotiFLACParsing.parseHiFiSearchResponse(data))
        }

        // 2b. If ISRC search didn't yield an accepted candidate, try text search (`/search/?s=<query>`).
        if SpotiFLACMatcher.selectBestCandidate(candidatePool, target: query) == nil {
            for term in buildSearchQueries(for: query) {
                guard let searchURL = buildHiFiSearchURL(baseURL: baseURL, paramName: "s", paramValue: term),
                      let data = await performGET(searchURL, hostForCooldown: baseURL) else {
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
              let streamData = await performGET(trackURL, hostForCooldown: baseURL),
              var resolved = SpotiFLACParsing.parseHiFiStreamResponse(
                  streamData,
                  trackId: best.candidate.id,
                  isrc: best.candidate.isrc ?? query.isrc
              ) else {
            return nil
        }

        if resolved.replayGain == nil {
            resolved.replayGain = best.candidate.replayGain
        }
        return resolved
    }

    // MARK: - Provider 3: Deezer ISRC Metadata Enrichment

    private func enrichWithDeezerIfNeeded(_ query: SpotiFLACTrackQuery) async -> SpotiFLACTrackQuery {
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
              let data = await performGET(url, hostForCooldown: nil),
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

    private func buildSearchQueries(for query: SpotiFLACTrackQuery) -> [String] {
        var queries: [String] = []
        let trimmedArtist = query.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryArtist = trimmedArtist
            .components(separatedBy: CharacterSet(charactersIn: ",;&/"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmedArtist

        if !primaryArtist.isEmpty && !trimmedTitle.isEmpty {
            queries.append("\(primaryArtist) \(trimmedTitle)")
        }
        if !trimmedTitle.isEmpty && !queries.contains(trimmedTitle) {
            queries.append(trimmedTitle)
        }
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

    private func buildReleaseURL(baseURL: URL, releaseId: String) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encoded = releaseId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? releaseId
        components?.path = basePath.isEmpty ? "/releases/\(encoded)" : "/\(basePath)/releases/\(encoded)"
        components?.query = nil
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

    private func isHostCoolingDown(_ baseURL: URL, now: Int64) -> Bool {
        guard let host = baseURL.host?.lowercased(),
              let until = hostCooldownUntilMs[host] else {
            return false
        }
        return now < until
    }

    private func markHostCooldown(_ baseURL: URL?) {
        guard let host = baseURL?.host?.lowercased() else { return }
        hostCooldownUntilMs[host] = clock() + hostCooldownDurationMs
    }

    private func performGET(_ url: URL, hostForCooldown: URL?) async -> Data? {
        let req = HTTPRequest(
            method: .get,
            url: url.absoluteString,
            headers: [
                HTTPHeader("Accept", "application/json"),
                HTTPHeader("User-Agent", Self.defaultUserAgent)
            ]
        )
        do {
            let resp = try await http.send(req)
            if resp.isSuccessful {
                return resp.body
            }
            if resp.statusCode == 429 || resp.statusCode >= 500 {
                markHostCooldown(hostForCooldown)
            }
            return nil
        } catch {
            markHostCooldown(hostForCooldown)
            return nil
        }
    }
}
