// Port of `data/youtube/piped/PipedStreamResolver.kt`: public Piped instances resolve the video on their own server
// and return an already-authenticated googlevideo (or instance proxy) link. The live instance list comes from the
// official registry (cached one hour), falling back to a fixed list; after every instance fails the resolver cools
// down for 20 s. On iOS the audio pick can be limited to AAC (`aacOnly`).

import Foundation
import PixlFoundation
import PixlModel

/// Piped parsing and constants.
public enum Piped {
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    public static let registryURL = "https://piped-instances.kavin.rocks"
    public static let cooldownMs: Int64 = 20 * 1000
    public static let liveListTTLMs: Int64 = 60 * 60 * 1000
    public static let maxInstancesToTry = 8
    /// Probe timeouts (connect 4 s, read 4 s, call 6 s on Android).
    public static let requestTimeoutSeconds: Double = 6

    /// Last-resort instances (checked by hand 2026-07-24 on Android).
    public static let fallbackInstances = ["api.piped.private.coffee", "pipedapi.kavin.rocks", "pipedapi.adminforge.de"]

    /// `GET https://<instance>/streams/<videoId>`.
    public static func streamsRequest(instance: String, videoId: String) -> HTTPRequest {
        HTTPRequest(url: "https://\(instance)/streams/\(videoId)", headers: [HTTPHeader("User-Agent", userAgent)],
                    timeout: requestTimeoutSeconds)
    }

    /// The registry request.
    public static func registryRequest() -> HTTPRequest {
        HTTPRequest(url: registryURL, headers: [HTTPHeader("User-Agent", userAgent)], timeout: requestTimeoutSeconds)
    }

    /// `fetchLiveInstances`: the host of every entry's `api_url`. Empty when the body is not a JSON array.
    public static func liveInstances(registryBody: String) -> [String] {
        guard let array = OrgJSON.parse(registryBody)?.arrayValue else { return [] }
        var hosts: [String] = []
        for entry in array {
            guard let object = entry.objectValue else { continue }
            let apiUrl = OrgJSON.optString(object, "api_url")
            if NetText.isBlank(apiUrl) { continue }
            guard let host = URLCoding.host(apiUrl) else { continue }
            hosts.append(host)
        }
        return hosts
    }

    /// The registry's hosts combined with the fixed list, distinct, at most `maxInstancesToTry`.
    public static func candidateInstances(live: [String]) -> [String] {
        var seen = Set<String>()
        return Array((live + fallbackInstances).filter { seen.insert($0).inserted }.prefix(maxInstancesToTry))
    }

    /// What a `/streams` response offers.
    public enum StreamChoice: Sendable, Hashable {
        /// An audio-only stream (preferred).
        case audioOnly(String)
        /// The lowest-resolution muxed video+audio `/videoplayback` stream (when audio-only is broken).
        case muxed(String)
        /// The response had nothing usable (`audioCount`/`videoCount` for the log).
        case nothing(audioCount: Int, videoCount: Int)
        /// Not JSON, or an `error` object.
        case invalid
    }

    /// `resolveFromInstance`'s parsing. `aacOnly` limits audio-only streams to AAC in MP4 (iOS).
    public static func choose(streamsBody: String, aacOnly: Bool = false) -> StreamChoice {
        guard let json = OrgJSON.parse(streamsBody)?.objectValue else { return .invalid }
        if OrgJSON.has(json, "error") { return .invalid }
        if let url = bestAudioOnlyUrl(json, aacOnly: aacOnly) { return .audioOnly(url) }
        if let url = bestMuxedUrl(json) { return .muxed(url) }
        return .nothing(audioCount: OrgJSON.optArray(json, "audioStreams")?.count ?? 0,
                        videoCount: OrgJSON.optArray(json, "videoStreams")?.count ?? 0)
    }

    /// The highest-bitrate audio stream with a URL (first wins ties).
    public static func bestAudioOnlyUrl(_ json: JSONObject, aacOnly: Bool = false) -> String? {
        guard let streams = OrgJSON.optArray(json, "audioStreams") else { return nil }
        var bestUrl: String?
        var bestBitrate = -1
        for item in streams {
            guard let stream = item.objectValue else { continue }
            let url = OrgJSON.optString(stream, "url")
            if NetText.isBlank(url) { continue }
            if aacOnly && !isAAC(stream) { continue }
            let bitrate = OrgJSON.optInt(stream, "bitrate", 0)
            if bitrate > bestBitrate {
                bestBitrate = bitrate
                bestUrl = url
            }
        }
        return bestUrl
    }

    /// Whether a Piped audio stream is AAC in MP4 (`mimeType` audio/mp4, `codec` mp4a…, or `format` M4A).
    public static func isAAC(_ stream: JSONObject) -> Bool {
        let mime = OrgJSON.optString(stream, "mimeType").lowercased()
        let codec = OrgJSON.optString(stream, "codec").lowercased()
        let format = OrgJSON.optString(stream, "format").uppercased()
        if codec.hasPrefix("mp4a") { return true }
        if codec.isEmpty && (mime.hasPrefix("audio/mp4") || format == "M4A") { return true }
        return false
    }

    /// The lowest-resolution muxed `video/*` stream served through `/videoplayback` (not HLS/LBRY).
    public static func bestMuxedUrl(_ json: JSONObject) -> String? {
        guard let streams = OrgJSON.optArray(json, "videoStreams") else { return nil }
        var bestUrl: String?
        var bestHeight = Int(Int32.max)
        for item in streams {
            guard let stream = item.objectValue else { continue }
            if OrgJSON.optBoolean(stream, "videoOnly", true) { continue }
            if !OrgJSON.optString(stream, "mimeType").hasPrefix("video/") { continue }
            let url = OrgJSON.optString(stream, "url")
            if NetText.isBlank(url) { continue }
            if !url.contains("/videoplayback") { continue }
            let height = qualityHeight(OrgJSON.optString(stream, "quality")) ?? Int(Int32.max)
            if height < bestHeight {
                bestHeight = height
                bestUrl = url
            }
        }
        return bestUrl
    }

    /// `Regex("""(\d+)p""").find(quality)?.groupValues?.get(1)?.toIntOrNull()`.
    static func qualityHeight(_ quality: String) -> Int? {
        let s = Array(quality.unicodeScalars)
        var i = 0
        while i < s.count {
            if NetText.isAsciiDigit(s[i]) {
                var j = i
                while j < s.count, NetText.isAsciiDigit(s[j]) { j += 1 }
                if j < s.count, s[j] == "p" {
                    var digits = String.UnicodeScalarView()
                    digits.append(contentsOf: s[i..<j])
                    return NetText.toInt(String(digits))
                }
                // Backtracking: a shorter digit run starting here cannot be followed by "p" either.
                i = j
                continue
            }
            i += 1
        }
        return nil
    }
}

/// `PipedStreamResolver`: tries the candidate instances in order.
public actor PipedStreamResolver {
    private let http: any HTTPClient
    private let nowMs: @Sendable () -> Int64
    private let aacOnly: Bool
    private var cachedLiveInstances: [String]?
    private var liveInstancesFetchedAtMs: Int64 = 0
    private var unavailableUntilMs: Int64 = 0
    private var discoveredInstances: [String] = []

    /// Why the last attempt failed or which instance answered.
    public private(set) var lastDetail: String?

    public init(http: any HTTPClient, aacOnly: Bool = true, nowMs: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.http = http
        self.aacOnly = aacOnly
        self.nowMs = nowMs
    }

    /// Hosts the streaming layer may accept for Piped audio: the fixed list plus every instance (and instance proxy
    /// host) this resolver decided to trust — never hosts taken blindly from a streams response.
    public var trustedHosts: Set<String> { Set(Piped.fallbackInstances).union(discoveredInstances) }

    public func resolve(videoId: String) async -> ResolvedStream? {
        let now = nowMs()
        if now < unavailableUntilMs {
            lastDetail = "cooling down after recent failures, \((unavailableUntilMs - now) / 1000)s left"
            return nil
        }
        for instance in await candidateInstances() {
            if let result = await resolve(instance: instance, videoId: videoId) {
                lastDetail = "\(instance) (\(videoId))"
                return result
            }
        }
        lastDetail = "no Piped instance resolved \(videoId)"
        unavailableUntilMs = nowMs() + Piped.cooldownMs
        return nil
    }

    private func candidateInstances() async -> [String] {
        let now = nowMs()
        if let cached = cachedLiveInstances, now - liveInstancesFetchedAtMs < Piped.liveListTTLMs { return cached }
        var fetched: [String] = []
        if let response = try? await http.send(Piped.registryRequest()), response.isSuccessful {
            fetched = Piped.liveInstances(registryBody: response.text)
        }
        if fetched.isEmpty { return Piped.fallbackInstances }
        for host in fetched where !discoveredInstances.contains(host) { discoveredInstances.append(host) }
        let combined = Piped.candidateInstances(live: fetched)
        cachedLiveInstances = combined
        liveInstancesFetchedAtMs = now
        return combined
    }

    private func resolve(instance: String, videoId: String) async -> ResolvedStream? {
        guard let response = try? await http.send(Piped.streamsRequest(instance: instance, videoId: videoId)),
              response.isSuccessful else { return nil }
        switch Piped.choose(streamsBody: response.text, aacOnly: aacOnly) {
        case .audioOnly(let url), .muxed(let url):
            trustResolvedUrlHost(url)
            return ResolvedStream(url: url, userAgent: Piped.userAgent)
        case .nothing, .invalid:
            return nil
        }
    }

    /// Instances often serve media through their own `proxy.*` host: trust it (it came from a trusted instance),
    /// but never add googlevideo hosts.
    private func trustResolvedUrlHost(_ url: String) {
        guard let host = URLCoding.host(url), !host.hasSuffix("googlevideo.com") else { return }
        if !discoveredInstances.contains(host) { discoveredInstances.append(host) }
    }
}

