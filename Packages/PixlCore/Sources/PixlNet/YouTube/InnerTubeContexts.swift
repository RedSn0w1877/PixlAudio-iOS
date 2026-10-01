// Port of `data/youtube/InnerTubeContexts.kt`: the YouTube client identities (checked against yt-dlp's _base.py on
// 2026-09-07 on Android), the request context, headers and endpoints. VISIONOS leads PLAYER_PROFILES: it is the
// only client declaring neither a GVS PoToken policy (so its audio is never truncated) nor REQUIRE_JS_PLAYER (so it
// returns direct URLs). Version/policy changes belong here (or in the app's remote client config).

import Foundation
import PixlFoundation

/// One InnerTube client identity.
public struct InnerTubeClientProfile: Sendable, Hashable, Codable {
    /// Short name used in logs and strategy names.
    public var name: String
    public var clientName: String
    public var clientVersion: String
    public var userAgent: String
    /// `X-YouTube-Client-Name` header value.
    public var clientNameId: Int
    /// Public InnerTube key (goes in the URL; not a secret). nil when the client works without one.
    public var apiKey: String?
    public var baseUrl: String
    public var deviceMake: String?
    public var deviceModel: String?
    public var osName: String?
    public var osVersion: String?
    /// Required by Android clients (otherwise the player has no formats).
    public var androidSdkVersion: Int?
    /// true when this client usually returns pre-signed URLs.
    public var expectsPreSignedUrls: Bool
    /// yt-dlp `SUPPORTS_COOKIES`. Native clients (VISIONOS, ANDROID_VR, IOS, ANDROID_MUSIC) answer HTTP 400 when a
    /// cookie is attached and must be spoken to anonymously.
    public var supportsCookies: Bool
    /// Native clients whose audio requires GVS attestation must not expose tokenless audio.
    public var requiresStreamingPoToken: Bool

    public init(name: String, clientName: String, clientVersion: String, userAgent: String, clientNameId: Int,
                apiKey: String? = nil, baseUrl: String, deviceMake: String? = nil, deviceModel: String? = nil,
                osName: String? = nil, osVersion: String? = nil, androidSdkVersion: Int? = nil,
                expectsPreSignedUrls: Bool, supportsCookies: Bool = false, requiresStreamingPoToken: Bool = false) {
        self.name = name
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.userAgent = userAgent
        self.clientNameId = clientNameId
        self.apiKey = apiKey
        self.baseUrl = baseUrl
        self.deviceMake = deviceMake
        self.deviceModel = deviceModel
        self.osName = osName
        self.osVersion = osVersion
        self.androidSdkVersion = androidSdkVersion
        self.expectsPreSignedUrls = expectsPreSignedUrls
        self.supportsCookies = supportsCookies
        self.requiresStreamingPoToken = requiresStreamingPoToken
    }
}

/// `InnerTubeContexts`.
public enum InnerTubeContexts {
    public static let baseURL = "https://www.youtube.com/youtubei/v1/"
    public static let musicBaseURL = "https://music.youtube.com/youtubei/v1/"

    /// YouTube Music "songs only" search filter.
    public static let songsSearchParams = "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
    /// YouTube Music "videos only" search filter.
    public static let videosSearchParams = "EgWKAQIQAWoKEAkQChAFEAMQBA=="

    /// The Apple Vision Pro client — no PoToken policy, no JS player, no cookies.
    public static let visionOS = InnerTubeClientProfile(
        name: "VISIONOS", clientName: "VISIONOS", clientVersion: "1.02",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        clientNameId: 101, baseUrl: baseURL, deviceMake: "Apple", deviceModel: "RealityDevice17,1",
        osName: "visionOS", osVersion: "26.5.23O471", expectsPreSignedUrls: true)

    /// The Quest app: no signature cipher, but its audio requires a PoToken (truncated without one). No cookie.
    public static let androidVR = InnerTubeClientProfile(
        name: "ANDROID_VR", clientName: "ANDROID_VR", clientVersion: "1.65.10",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        clientNameId: 28, apiKey: "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w", baseUrl: baseURL,
        deviceMake: "Oculus", deviceModel: "Quest 3", osName: "Android", osVersion: "12L", androidSdkVersion: 32,
        expectsPreSignedUrls: true, requiresStreamingPoToken: true)

    /// The iPhone app: direct URLs, but its audio is cut off around 47-53 s without a GVS PoToken. No cookie.
    public static let iOS = InnerTubeClientProfile(
        name: "IOS", clientName: "IOS", clientVersion: "21.26.4",
        userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        clientNameId: 5, apiKey: "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc", baseUrl: baseURL,
        deviceMake: "Apple", deviceModel: "iPhone16,2", osName: "iPhone", osVersion: "18.3.2.22D82",
        expectsPreSignedUrls: true, requiresStreamingPoToken: true)

    public static let androidMusic = InnerTubeClientProfile(
        name: "ANDROID_MUSIC", clientName: "ANDROID_MUSIC", clientVersion: "7.27.52",
        userAgent: "com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 14) gzip",
        clientNameId: 21, apiKey: "AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI", baseUrl: baseURL,
        osName: "Android", osVersion: "14", androidSdkVersion: 34,
        expectsPreSignedUrls: true, requiresStreamingPoToken: true)

    /// yt-dlp's "tv_downgraded": one of the two clients yt-dlp uses with a cookie.
    public static let tvHTML5 = InnerTubeClientProfile(
        name: "TVHTML5", clientName: "TVHTML5", clientVersion: "5.20260707",
        userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
        clientNameId: 7, apiKey: "AIzaSyDCU8hByM-4DrUqRUYnGn-3llEO78bcxq8", baseUrl: baseURL,
        expectsPreSignedUrls: false, supportsCookies: true)

    /// Plain WEB (www.youtube.com): the other authenticated yt-dlp client; serves SABR-only audio today.
    public static let web = InnerTubeClientProfile(
        name: "WEB", clientName: "WEB", clientVersion: "2.20260708.00.00",
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36",
        clientNameId: 1, apiKey: "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX3", baseUrl: baseURL,
        expectsPreSignedUrls: false, supportsCookies: true, requiresStreamingPoToken: true)

    /// YouTube Music web (music.youtube.com): the search client.
    public static let webRemix = InnerTubeClientProfile(
        name: "WEB_REMIX", clientName: "WEB_REMIX", clientVersion: "1.20260707.12.00",
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36",
        clientNameId: 67, apiKey: "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30", baseUrl: musicBaseURL,
        expectsPreSignedUrls: false, supportsCookies: true, requiresStreamingPoToken: true)

    /// The order audio is resolved in (VR 1.65.10 returns 403 for all formats since 17 August, so it is kept for
    /// diagnostics only).
    public static let playerProfiles: [InnerTubeClientProfile] = [visionOS, iOS, tvHTML5, webRemix]

    /// Every defined profile (diagnostics, remote-config lookups).
    public static let allProfiles: [InnerTubeClientProfile] = [visionOS, androidVR, iOS, androidMusic, tvHTML5, web, webRemix]

    /// Search always goes through YouTube Music.
    public static let searchProfile = webRemix

    /// `buildContext(profile, visitorData)`: `{"context":{"client":{…}}}` in Android's key order.
    public static func buildContext(_ profile: InnerTubeClientProfile, visitorData: String? = nil) -> JSONObject {
        var client = JSONObject()
        client.append("clientName", .string(profile.clientName))
        client.append("clientVersion", .string(profile.clientVersion))
        client.append("userAgent", .string(profile.userAgent))
        client.append("hl", .string("en"))
        client.append("gl", .string("US"))
        if let v = profile.deviceMake { client.append("deviceMake", .string(v)) }
        if let v = profile.deviceModel { client.append("deviceModel", .string(v)) }
        if let v = profile.osName { client.append("osName", .string(v)) }
        if let v = profile.osVersion { client.append("osVersion", .string(v)) }
        if let v = profile.androidSdkVersion { client.append("androidSdkVersion", .integer(v)) }
        if let visitorData { client.append("visitorData", .string(visitorData)) }
        var context = JSONObject()
        context.append("client", .object(client))
        var root = JSONObject()
        root.append("context", .object(context))
        return root
    }

    /// The origin YouTube sees for this client (also the SAPISIDHASH origin).
    public static func originFor(_ profile: InnerTubeClientProfile) -> String {
        profile.baseUrl == musicBaseURL ? "https://music.youtube.com" : "https://www.youtube.com"
    }

    /// Anonymous request headers, in Android's order.
    public static func headers(_ profile: InnerTubeClientProfile) -> [HTTPHeader] {
        [
            HTTPHeader("User-Agent", profile.userAgent),
            HTTPHeader("Content-Type", "application/json"),
            HTTPHeader("Accept-Language", "en-US,en;q=0.9"),
            HTTPHeader("X-YouTube-Client-Name", String(profile.clientNameId)),
            HTTPHeader("X-YouTube-Client-Version", profile.clientVersion),
            HTTPHeader("Origin", originFor(profile)),
        ]
    }

    /// `endpoint(profile, path, includeKey)`: `includeKey = false` for OAuth requests (YouTube rejects a key plus
    /// an `Authorization` header).
    public static func endpoint(_ profile: InnerTubeClientProfile, _ path: String, includeKey: Bool = true) -> String {
        if includeKey, let key = profile.apiKey {
            return "\(profile.baseUrl)\(path)?key=\(key)&prettyPrint=false"
        }
        return "\(profile.baseUrl)\(path)?prettyPrint=false"
    }

    /// Headers for downloading googlevideo audio: only the User-Agent of the client that obtained the URL. Adding
    /// Origin/Referer makes googlevideo answer 403.
    public static func streamHeaders(userAgent: String) -> [HTTPHeader] { [HTTPHeader("User-Agent", userAgent)] }
}
