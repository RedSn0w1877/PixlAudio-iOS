// The request-building half of `InnerTubeClient.kt` (player, search) plus the `visitor_id` call NewPipe uses for a
// fresh visitorData, and Swift-only `next`/`browse` builders on the same context. Bodies are serialised with
// org.json's writer so they match Android byte for byte.

import Foundation
import PixlFoundation

/// InnerTube request builders.
public enum InnerTubeRequests {
    /// OkHttp sends the body's media type as the Content-Type (it overrides an explicit header).
    public static let jsonMediaType = "application/json; charset=utf-8"

    /// The `player` body: context, `videoId`, `contentCheckOk`, `racyCheckOk` (anonymous requests only — the
    /// authenticated body replicates InnerTune's exactly) and `serviceIntegrityDimensions.poToken` when a PoToken
    /// was generated.
    public static func playerBody(videoId: String, profile: InnerTubeClientProfile, visitorData: String?,
                                  authenticated: Bool, playerRequestPoToken: String? = nil) -> JSONObject {
        var body = InnerTubeContexts.buildContext(profile, visitorData: visitorData)
        body.append("videoId", .string(videoId))
        body.append("contentCheckOk", .bool(true))
        if !authenticated { body.append("racyCheckOk", .bool(true)) }
        if let playerRequestPoToken {
            var dims = JSONObject()
            dims.append("poToken", .string(playerRequestPoToken))
            body.append("serviceIntegrityDimensions", .object(dims))
        }
        return body
    }

    /// The `search` body (`query` trimmed, `params` filter).
    public static func searchBody(query: String, params: String, visitorData: String?,
                                  profile: InnerTubeClientProfile = InnerTubeContexts.searchProfile) -> JSONObject {
        var body = InnerTubeContexts.buildContext(profile, visitorData: visitorData)
        body.append("query", .string(NetText.trim(query)))
        body.append("params", .string(params))
        return body
    }

    /// A `next` body (watch-next / radio queue). Swift-only: Android never called `next`.
    public static func nextBody(videoId: String?, playlistId: String? = nil, params: String? = nil, visitorData: String?,
                                profile: InnerTubeClientProfile = InnerTubeContexts.searchProfile) -> JSONObject {
        var body = InnerTubeContexts.buildContext(profile, visitorData: visitorData)
        if let videoId { body.append("videoId", .string(videoId)) }
        if let playlistId { body.append("playlistId", .string(playlistId)) }
        if let params { body.append("params", .string(params)) }
        body.append("isAudioOnly", .bool(true))
        return body
    }

    /// A `browse` body (album/playlist/artist pages, continuation). Swift-only: Android never called `browse`.
    public static func browseBody(browseId: String?, params: String? = nil, continuation: String? = nil,
                                  visitorData: String?,
                                  profile: InnerTubeClientProfile = InnerTubeContexts.searchProfile) -> JSONObject {
        var body = InnerTubeContexts.buildContext(profile, visitorData: visitorData)
        if let browseId { body.append("browseId", .string(browseId)) }
        if let params { body.append("params", .string(params)) }
        if let continuation { body.append("continuation", .string(continuation)) }
        return body
    }

    /// The `visitor_id` body (WEB client, as NewPipe's `getVisitorDataFromInnertube`).
    public static func visitorIdBody(profile: InnerTubeClientProfile = InnerTubeContexts.web) -> JSONObject {
        InnerTubeContexts.buildContext(profile, visitorData: nil)
    }

    /// A POST to `endpoint(profile, path)` with anonymous headers, or the authenticated header set when both a
    /// cookie and a SAPISIDHASH authorization are given.
    public static func post(path: String, body: JSONObject, profile: InnerTubeClientProfile,
                            cookie: String? = nil, sapisidAuthorization: String? = nil, origin: String? = nil,
                            timeout: Double? = nil) -> HTTPRequest {
        var request = HTTPRequest(method: .post, url: InnerTubeContexts.endpoint(profile, path),
                                  body: Data(OrgJSONWriter.write(.object(body)).utf8), timeout: timeout)
        if let cookie, let sapisidAuthorization {
            let origin = origin ?? InnerTubeContexts.originFor(profile)
            request.setHeader("Content-Type", "application/json")
            request.setHeader("X-Goog-Api-Format-Version", "1")
            request.setHeader("X-YouTube-Client-Name", String(profile.clientNameId))
            request.setHeader("X-YouTube-Client-Version", profile.clientVersion)
            request.setHeader("x-origin", origin)
            request.setHeader("User-Agent", profile.userAgent)
            request.setHeader("cookie", cookie)
            request.setHeader("Authorization", sapisidAuthorization)
        } else {
            for header in InnerTubeContexts.headers(profile) { request.setHeader(header.name, header.value) }
        }
        request.setHeader("Content-Type", jsonMediaType)
        return request
    }
}

/// The cookie session of `YouTubeAuthManager` (a real music.youtube.com sign-in).
public enum YouTubeCookieAuth {
    /// The placeholder visitorData InnerTune starts with before a sign-in captures the real one.
    public static let defaultVisitorData = "CgtsZG1ySnZiQWtSbyiMjuGSBg%3D%3D"

    /// `parseCookieString`: `name=value` pairs split on `"; "` (later duplicates win).
    public static func parseCookieString(_ cookie: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in cookie.components(separatedBy: "; ") where !part.isEmpty && part.contains("=") {
            let eq = part.firstIndex(of: "=")!
            out[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        return out
    }

    /// `Authorization: SAPISIDHASH <ts>_<sha1("<ts> <SAPISID> <origin>")>`; nil without a SAPISID cookie.
    public static func sapisidHashAuthorization(cookie: String?, origin: String = "https://music.youtube.com",
                                                timestampSeconds: Int64) -> String? {
        guard let cookie, let sapisid = parseCookieString(cookie)["SAPISID"] else { return nil }
        let hash = NetText.hex(SHA1.hash(Array("\(timestampSeconds) \(sapisid) \(origin)".utf8)))
        return "SAPISIDHASH \(timestampSeconds)_\(hash)"
    }
}
