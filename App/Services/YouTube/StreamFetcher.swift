import AVFoundation
import Foundation
import PixlNet

/// The network half of the streaming loader: ranged GETs against the resolved googlevideo (or Piped) URL with
/// exactly the User-Agent of the client that obtained it (Origin/Referer would get a 403), written into the sparse
/// `StreamCache`. GET sizes follow PixlNet's `StreamChunkPolicy` (streaming speed R2): the first GET reads 128 KiB
/// ahead of AVFoundation's 2-byte request, and each loading request's fetches grow 128 KiB → 512 KiB → 2 MiB.
/// Failures follow `StreamRetryPolicy` (R5a, Android oct3's rules): a 401/403/404/410 drops the URL and resolves
/// again with the same client first (the IP may have changed), then past it (only while nothing of the file is
/// cached); 429/5xx back off 250 ms × attempt; four attempts at most (Piped is the last strategy). Every response is
/// checked like Android's `CloudStreamSecurity` (safe host, audio content type, sane length).
nonisolated struct StreamFetcher: Sendable {
    nonisolated enum Failure: Error, LocalizedError, Equatable {
        case unresolvable
        case unsafeURL
        case http(Int)
        case badResponse(String)
        /// The re-resolved URL serves a different file (another itag) than the cached bytes.
        case formatChanged

        var errorDescription: String? {
            switch self {
            case .unresolvable: "No YouTube client could provide this song's audio."
            case .unsafeURL: "The stream address was refused."
            case .http(let code): "The audio server answered HTTP \(code)."
            case .badResponse(let why): why
            case .formatChanged: "The audio changed on the server; try again."
            }
        }
    }

    /// Size and type of a stream.
    nonisolated struct Info: Sendable, Equatable {
        var contentLength: Int64
        var contentType: String

        /// The UTI the resource loader reports (`AVFileType`): muxed itag 18 is MPEG-4 video, the rest M4A audio.
        var uniformTypeIdentifier: String {
            contentType.lowercased().hasPrefix("video/") ? AVFileType.mp4.rawValue : AVFileType.m4a.rawValue
        }
    }


    let service: InnerTubeService
    let cache: StreamCache
    let session: URLSession

    // MARK: Info

    /// `allowsConstrained: false` keeps a speculative fetch off Low Data Mode paths (the prefetcher's head bytes).
    func info(videoId: String, allowsConstrained: Bool = true) async throws -> Info {
        if let meta = await cache.meta(videoId), meta.contentLength > 0 {
            return Info(contentLength: meta.contentLength, contentType: meta.contentType)
        }
        // AVFoundation's first request wants the content information and bytes 0-1: one GET of the first 128 KiB
        // answers both, and the following request's first bytes come from disk (the size is Content-Range's total).
        _ = try await fetch(videoId: videoId, range: 0..<2, readAhead: StreamChunkPolicy.startFetchBytes,
                            allowsConstrained: allowsConstrained)
        guard let meta = await cache.meta(videoId) else { throw Failure.badResponse("No size for the stream.") }
        return Info(contentLength: meta.contentLength, contentType: meta.contentType)
    }

    // MARK: Data

    /// The next bytes from `offset` (before `end`): cached bytes when there are some there (up to 2 MiB at once),
    /// else one network fetch of at most `fetchSize`, stopping where cached bytes resume. `fromNetwork` tells the
    /// loader's ramp that a GET was made.
    func read(videoId: String, from offset: Int64, upTo end: Int64, fetchSize: Int64 = StreamChunkPolicy.maxFetchBytes,
              allowsConstrained: Bool = true) async throws -> (data: Data, fromNetwork: Bool) {
        guard end > offset else { return (Data(), false) }
        let cacheLimit = min(max(fetchSize, StreamChunkPolicy.maxFetchBytes), end - offset)
        let cached = await cache.contiguousLength(videoId, from: offset, limit: cacheLimit)
        if cached > 0, let data = await cache.read(videoId, offset..<(offset + cached)) { return (data, false) }
        let next = await cache.nextCachedStart(videoId, after: offset)
        let stop = StreamChunkPolicy.fetchEnd(offset: offset, end: end, fetchSize: fetchSize, nextCachedStart: next)
        return (try await fetch(videoId: videoId, range: offset..<stop, allowsConstrained: allowsConstrained), true)
    }

    /// Fetches the first `bytes` into the cache (prefetch before the track starts). Never on the caller's actor
    /// (`@concurrent`: the prefetcher calls it from the main actor). `allowsConstrained: false` for speculative
    /// prefetches, which then fail fast in Low Data Mode.
    @concurrent
    func prefetch(videoId: String, bytes: Int64 = 1 << 20, allowsConstrained: Bool = true) async {
        guard let info = try? await info(videoId: videoId, allowsConstrained: allowsConstrained) else { return }
        var offset: Int64 = 0
        let end = min(bytes, info.contentLength)
        while offset < end, !Task.isCancelled {
            guard let data = try? await read(videoId: videoId, from: offset, upTo: end,
                                             allowsConstrained: allowsConstrained).data,
                  !data.isEmpty else { return }
            offset += Int64(data.count)
        }
    }

    /// Downloads every missing byte (the download fallback when a background transfer is refused).
    func fillCache(videoId: String, progress: (@Sendable (Int64, Int64) async -> Void)? = nil) async throws {
        let info = try await info(videoId: videoId)
        var offset: Int64 = 0
        while offset < info.contentLength {
            try Task.checkCancellation()
            let data = try await read(videoId: videoId, from: offset, upTo: info.contentLength).data
            guard !data.isEmpty else { throw Failure.badResponse("The stream ended early.") }
            offset += Int64(data.count)
            await progress?(offset, info.contentLength)
        }
    }

    // MARK: Network

    /// One ranged GET (with re-resolution on 403) whose bytes go into the cache. Returns the bytes of `range`; the GET
    /// itself reads up to `readAhead` bytes from `range.lowerBound` (never into cached bytes or past the end).
    @discardableResult
    func fetch(videoId: String, range: Range<Int64>, readAhead: Int64 = 0, allowsConstrained: Bool = true) async throws -> Data {
        let requested = StreamChunkPolicy.requestRange(
            for: range, readAhead: readAhead,
            nextCachedStart: await cache.nextCachedStart(videoId, after: range.lowerBound),
            contentLength: await cache.meta(videoId)?.contentLength)
        var excluded: Set<String> = []
        for attempt in 0..<StreamRetryPolicy.maxAttempts {
            try Task.checkCancellation()
            guard let stream = await service.resolve(videoId: videoId, excluding: excluded) else { throw Failure.unresolvable }
            let allowed = await service.allowedHosts()
            guard CloudStreamSecurity.isSafeRemoteStreamURL(stream.url, allowedHostSuffixes: allowed),
                  let url = URL(string: stream.url) else { throw Failure.unsafeURL }
            var request = URLRequest(url: url)
            request.allowsConstrainedNetworkAccess = allowsConstrained
            request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(ContentRange.requestHeader(requested), forHTTPHeaderField: "Range")
            let (body, response) = try await session.data(for: request)
            PlaybackStartTimings.shared.networkFetched(key: YouTubeSongIdentity.timingKey(videoId: videoId), bytes: body.count)
            guard let http = response as? HTTPURLResponse else { throw Failure.badResponse("No HTTP response.") }
            if http.statusCode == 206 || http.statusCode == 200 {
                return try await store(videoId: videoId, range: range, body: body, response: http, streamURL: stream.url)
            }
            let hasCachedBytes = await cache.meta(videoId) != nil
            switch StreamRetryPolicy.decide(status: http.statusCode, attempt: attempt, hasCachedBytes: hasCachedBytes) {
            case .fail:
                throw Failure.http(http.statusCode)
            case .retry(let switchClient, let delayMs):
                await service.invalidate(videoId: videoId)
                if switchClient { excluded.insert(stream.strategyName ?? InnerTubeService.pipedStrategyName) }
                if delayMs > 0 { try await Task.sleep(for: .milliseconds(delayMs)) }
            }
        }
        throw Failure.http(403)
    }

    private func store(videoId: String, range: Range<Int64>, body: Data, response: HTTPURLResponse,
                       streamURL: String) async throws -> Data {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        guard CloudStreamSecurity.isSupportedAudioContentType(contentType) else {
            throw Failure.badResponse("The server sent \(contentType ?? "?"), not audio.")
        }
        let type = contentType.map { String($0.split(separator: ";").first ?? "") } ?? "audio/mp4"
        let itag = URLCoding.androidQueryParameter(streamURL, "itag")
        let start: Int64
        let total: Int64
        if response.statusCode == 206 {
            guard let contentRange = ContentRange.parse(response.value(forHTTPHeaderField: "Content-Range")),
                  let length = contentRange.total else { throw Failure.badResponse("No Content-Range.") }
            start = contentRange.start
            total = length
        } else {
            // A 200 to a range request: the whole file.
            start = 0
            total = Int64(body.count)
        }
        guard total > 0, total <= CloudStreamSecurity.maxStreamContentLengthBytes else {
            throw Failure.badResponse("Unexpected stream size.")
        }
        if let meta = await cache.meta(videoId), meta.contentLength > 0,
           meta.contentLength != total || (meta.itag != nil && itag != nil && meta.itag != itag) {
            // Another file than the cached one: start over (the player gets an error and reloads).
            await cache.remove(videoId)
            throw Failure.formatChanged
        }
        await cache.setInfo(videoId, contentLength: total, contentType: type, itag: itag)
        await cache.write(videoId, offset: start, data: body)
        // The part of the body that covers `range`.
        let bodyEnd = start + Int64(body.count)
        let lower = max(range.lowerBound, start)
        let upper = min(range.upperBound, bodyEnd)
        guard upper > lower else { throw Failure.badResponse("The server sent the wrong range.") }
        return body.subdata(in: Int(lower - start)..<Int(upper - start))
    }

    /// The playback test's last step: the loader's own first request (the same resolution, headers and checks).
    func probe(videoId: String) async -> StreamProbe {
        do {
            let data = try await fetch(videoId: videoId, range: 0..<2)
            let meta = await cache.meta(videoId)
            return StreamProbe(ok: !data.isEmpty, httpStatus: 206, contentType: meta?.contentType)
        } catch Failure.http(let code) {
            return StreamProbe(ok: false, httpStatus: code)
        } catch {
            return StreamProbe(ok: false, error: error.localizedDescription)
        }
    }
}
