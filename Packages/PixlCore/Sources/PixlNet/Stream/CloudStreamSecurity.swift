// Port of `data/stream/CloudStreamSecurity.kt`: the cheap checks the streaming layer runs on every request — id
// shapes, Range headers, upstream Content-Type/Length, and whether a resolved URL is safe to fetch (https, an
// allowed host suffix, never the local network or a URL with credentials). On iOS the resource loader uses them.

import Foundation

/// `CloudStreamSecurity`.
public enum CloudStreamSecurity {
    public static let maxStreamContentLengthBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maxRangeHeaderLength = 64
    static let maxRangeValueBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let forbiddenHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]
    static let localDNSSuffixes = [".local", ".lan", ".home", ".internal", ".home.arpa"]
    static let extraAllowedAudioTypes: Set<String> = ["application/octet-stream", "binary/octet-stream", "application/mp4", "video/mp4"]

    /// The hosts Spotify/YouTube audio may come from: googlevideo plus the trusted Piped hosts.
    public static func allowedHostSuffixes(pipedTrustedHosts: Set<String>) -> Set<String> {
        Set(["googlevideo.com"]).union(pipedTrustedHosts)
    }

    /// `^[A-Za-z0-9]{22}$`.
    public static func validateSpotifyTrackId(_ id: String) -> Bool {
        id.utf8.count == 22 && id.utf8.allSatisfy(isAlnum)
    }

    /// `^[A-Za-z0-9_-]{11}$`.
    public static func validateYouTubeVideoId(_ id: String) -> Bool {
        id.utf8.count == 11 && id.utf8.allSatisfy { isAlnum($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    private static func isAlnum(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    /// `RangeHeaderValidation`.
    public struct RangeValidation: Sendable, Hashable {
        public var isValid: Bool
        public var normalizedHeader: String?
        public var startInclusive: Int64?
        public var endInclusive: Int64?
        public var isSuffixRange: Bool

        public init(isValid: Bool, normalizedHeader: String? = nil, startInclusive: Int64? = nil, endInclusive: Int64? = nil, isSuffixRange: Bool = false) {
            self.isValid = isValid
            self.normalizedHeader = normalizedHeader
            self.startInclusive = startInclusive
            self.endInclusive = endInclusive
            self.isSuffixRange = isSuffixRange
        }
    }

    /// `validateRangeHeader`: a single `bytes=a-b` range (absent header is valid).
    public static func validateRangeHeader(_ raw: String?) -> RangeValidation {
        guard let raw, !NetText.isBlank(raw) else { return RangeValidation(isValid: true) }
        let header = NetText.trim(raw)
        if header.utf16.count > maxRangeHeaderLength { return RangeValidation(isValid: false) }
        if !header.hasPrefix("bytes=") || header.contains(",") { return RangeValidation(isValid: false) }
        let payload = String(header.dropFirst("bytes=".count))
        let dashes = payload.indices.filter { payload[$0] == "-" }
        guard dashes.count == 1, let dash = dashes.first else { return RangeValidation(isValid: false) }
        let startPart = NetText.trim(String(payload[..<dash]))
        let endPart = NetText.trim(String(payload[payload.index(after: dash)...]))
        if startPart.isEmpty && endPart.isEmpty { return RangeValidation(isValid: false) }
        func allDigits(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { $0.properties.generalCategory == .decimalNumber } }
        if !startPart.isEmpty && !allDigits(startPart) { return RangeValidation(isValid: false) }
        if !endPart.isEmpty && !allDigits(endPart) { return RangeValidation(isValid: false) }
        let start = startPart.isEmpty ? nil : NetText.toLong(startPart)
        let end = endPart.isEmpty ? nil : NetText.toLong(endPart)
        if (!startPart.isEmpty && start == nil) || (!endPart.isEmpty && end == nil) { return RangeValidation(isValid: false) }
        if start == nil && end == 0 { return RangeValidation(isValid: false) }
        if let start, start < 0 || start > maxRangeValueBytes { return RangeValidation(isValid: false) }
        if let end, end < 0 || end > maxRangeValueBytes { return RangeValidation(isValid: false) }
        if let start, let end, start > end { return RangeValidation(isValid: false) }
        return RangeValidation(isValid: true, normalizedHeader: "bytes=\(startPart)-\(endPart)", startInclusive: start,
                               endInclusive: end, isSuffixRange: start == nil && end != nil)
    }

    /// `isSupportedAudioContentType`: missing, `audio/*`, or one of the octet-stream/mp4 types.
    public static func isSupportedAudioContentType(_ header: String?) -> Bool {
        guard let header, !NetText.isBlank(header) else { return true }
        let normalized = NetText.lowercased(NetText.trim(NetText.substringBefore(header, ";")))
        return normalized.hasPrefix("audio/") || extraAllowedAudioTypes.contains(normalized)
    }

    /// `isAcceptableContentLength`: missing, or 0…2 GiB.
    public static func isAcceptableContentLength(_ header: String?) -> Bool {
        guard let header, !NetText.isBlank(header) else { return true }
        guard let parsed = NetText.toLong(header) else { return false }
        return parsed >= 0 && parsed <= maxStreamContentLengthBytes
    }

    /// `isSafeRemoteStreamUrl`.
    public static func isSafeRemoteStreamURL(_ url: String, allowedHostSuffixes: Set<String> = [], allowHttpForAllowedHosts: Bool = false) -> Bool {
        guard let scheme = URLCoding.scheme(url), scheme == "http" || scheme == "https",
              let rawHost = URLCoding.host(url) else { return false }
        let host = NetText.lowercased(rawHost)
        if forbiddenHosts.contains(host) { return false }
        if host.hasSuffix(".local") { return false }
        if isPrivateIPv4Literal(host) { return false }
        if let info = URLCoding.userInfo(url), !info.isEmpty { return false }
        if !hostMatchesAllowedSuffix(host, allowedHostSuffixes) { return false }
        return scheme == "https" || (allowHttpForAllowedHosts && !allowedHostSuffixes.isEmpty)
    }

    /// `mapUpstreamStatusToProxyStatus`.
    public static func proxyStatus(forUpstream code: Int) -> Int {
        switch code {
        case 401, 403, 404, 408, 416, 429: return code
        default: return 502
        }
    }

    static func hostMatchesAllowedSuffix(_ host: String, _ suffixes: Set<String>) -> Bool {
        if suffixes.isEmpty { return true }
        return suffixes.contains { suffix in
            let normalized = NetText.lowercased(suffix)
            return host == normalized || host.hasSuffix("." + normalized)
        }
    }

    /// `isLocalOrPrivateHost`.
    public static func isLocalOrPrivateHost(_ host: String) -> Bool {
        var normalized = NetText.lowercased(host)
        if normalized.hasPrefix("[") { normalized.removeFirst() }
        if normalized.hasSuffix("]") { normalized.removeLast() }
        if normalized.isEmpty { return false }
        if normalized == "localhost" { return true }
        if localDNSSuffixes.contains(where: { normalized.hasSuffix($0) }) { return true }
        if isPrivateIPv4Literal(normalized) || isCGNATIPv4Literal(normalized) { return true }
        if normalized.contains(":") { return isPrivateIPv6Literal(normalized) }
        return !normalized.contains(".")
    }

    static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard let value = NetText.toInt(String(part)), (0...255).contains(value) else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// `isPrivateIpv4Literal`: 0/8, 10/8, 127/8, 169.254/16, 172.16/12, 192.168/16.
    public static func isPrivateIPv4Literal(_ host: String) -> Bool {
        guard let o = ipv4Octets(host) else { return false }
        return o[0] == 0 || o[0] == 10 || o[0] == 127 || (o[0] == 169 && o[1] == 254) || (o[0] == 172 && (16...31).contains(o[1]))
            || (o[0] == 192 && o[1] == 168)
    }

    /// 100.64.0.0/10.
    static func isCGNATIPv4Literal(_ host: String) -> Bool {
        guard let o = ipv4Octets(host) else { return false }
        return o[0] == 100 && (64...127).contains(o[1])
    }

    /// ::1, fe80::/10, fc00::/7.
    static func isPrivateIPv6Literal(_ host: String) -> Bool {
        if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        if ["fe8", "fe9", "fea", "feb"].contains(where: { host.hasPrefix($0) }) { return true }
        return host.hasPrefix("fc") || host.hasPrefix("fd")
    }
}
