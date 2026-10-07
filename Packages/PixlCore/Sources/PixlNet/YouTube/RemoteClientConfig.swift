// Remote InnerTube client profiles (architecture §2, "client profiles also from remote/config.json"). YouTube breaks
// clients without warning; Android needed a release for every version bump. The iOS app fetches the repo's
// `remote/config.json` and applies it on top of the built-in table here — but the two invariants of
// `InnerTubeContexts` are not negotiable: the native clients never receive a cookie, and only InnerTube hosts are
// accepted as base URLs. Anything malformed is ignored and the built-in table stays.

import Foundation
import PixlFoundation

/// The parsed remote client configuration.
public struct RemoteClientConfig: Sendable, Hashable {
    /// The schema this parser understands.
    public static let schema = 1
    /// Clients that answer HTTP 400 to a cookie (yt-dlp: absent from `SUPPORTS_COOKIES`). Remote config can never
    /// make them cookie clients.
    public static let cookielessClients: Set<String> = ["VISIONOS", "ANDROID_VR", "IOS", "ANDROID_MUSIC"]
    public static let allowedBaseURLs: Set<String> = [InnerTubeContexts.baseURL, InnerTubeContexts.musicBaseURL]

    /// Profiles by name: built-ins with the remote fields applied, plus fully specified new ones.
    public var profiles: [String: InnerTubeClientProfile]
    /// Order of the pre-signed strategies (nil = built-in `playerProfiles` order).
    public var preSignedOrder: [String]?
    /// Order of the deciphered strategies (nil = TVHTML5, WEB (signed in only), WEB_REMIX).
    public var cipheredOrder: [String]?
    /// Free-form note shown in diagnostics ("bumped IOS to 21.30").
    public var note: String?
    /// Streaming speed R8: overlap the clients when one is slow. Off (nil) unless the remote file turns it on.
    public var hedging: StreamHedging?

    public init(profiles: [String: InnerTubeClientProfile] = Self.builtInProfiles, preSignedOrder: [String]? = nil,
                cipheredOrder: [String]? = nil, note: String? = nil, hedging: StreamHedging? = nil) {
        self.profiles = profiles
        self.preSignedOrder = preSignedOrder
        self.cipheredOrder = cipheredOrder
        self.note = note
        self.hedging = hedging
    }

    /// The built-in table by name.
    public static var builtInProfiles: [String: InnerTubeClientProfile] {
        Dictionary(InnerTubeContexts.allProfiles.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The built-in behaviour (what the app uses without a remote file).
    public static let builtIn = RemoteClientConfig()

    // MARK: Parsing

    /// Parses `remote/config.json`. nil when it is not a JSON object, has a newer schema or no `innertube` section.
    ///
    ///     {"schema": 1, "innertube": {
    ///        "note": "…",
    ///        "profiles": {"IOS": {"clientVersion": "21.30.1", "userAgent": "…"}, "NEWCLIENT": {…every field…}},
    ///        "preSignedOrder": ["VISIONOS", "IOS"],
    ///        "cipheredOrder": ["TVHTML5", "WEB", "WEB_REMIX"],
    ///        "hedge": {"enabled": false, "afterSeconds": 1.5, "strategyTimeoutSeconds": 8}}}
    public static func parse(_ text: String) -> RemoteClientConfig? {
        guard let root = OrgJSON.parse(text)?.objectValue else { return nil }
        let schema = OrgJSON.optInt(root, "schema", 1)
        guard schema <= Self.schema, let section = OrgJSON.optObject(root, "innertube") else { return nil }

        var profiles = builtInProfiles
        if let overrides = OrgJSON.optObject(section, "profiles") {
            for member in OrgJSON.members(overrides) {
                guard let fields = member.value.objectValue, isValidName(member.key) else { continue }
                if let base = profiles[member.key] {
                    profiles[member.key] = applying(fields, to: base)
                } else if let created = newProfile(name: member.key, fields) {
                    profiles[member.key] = created
                }
            }
        }
        func order(_ key: String) -> [String]? {
            guard let array = OrgJSON.optArray(section, key) else { return nil }
            var seen = Set<String>()
            let names = array.compactMap(\.stringValue).filter { profiles[$0] != nil && seen.insert($0).inserted }
            return names.isEmpty ? nil : names
        }
        let note = OrgJSON.optString(section, "note")
        return RemoteClientConfig(profiles: profiles, preSignedOrder: order("preSignedOrder"),
                                  cipheredOrder: order("cipheredOrder"), note: NetText.isBlank(note) ? nil : note,
                                  hedging: hedging(section))
    }

    /// The `hedge` object: only `"enabled": true` turns hedging on; missing or odd numbers fall back to the defaults
    /// and are clamped (start the next client after 0.5…10 s; 3…15 s per client).
    static func hedging(_ section: JSONObject) -> StreamHedging? {
        guard let hedge = OrgJSON.optObject(section, "hedge"), hedge["enabled"]?.boolValue == true else { return nil }
        return StreamHedging(afterSeconds: hedge["afterSeconds"]?.doubleValue ?? StreamHedging.defaultAfterSeconds,
                             strategyTimeoutSeconds: hedge["strategyTimeoutSeconds"]?.doubleValue
                                 ?? StreamHedging.defaultStrategyTimeoutSeconds)
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 40 && name.utf8.allSatisfy {
            ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == UInt8(ascii: "_")
        }
    }

    private static func text(_ fields: JSONObject, _ key: String) -> String? {
        guard let value = fields[key]?.stringValue, !NetText.isBlank(value), value.utf8.count <= 400 else { return nil }
        return value
    }

    private static func integer(_ fields: JSONObject, _ key: String) -> Int? {
        guard let value = fields[key], let int = OrgJSON.int(value) else { return nil }
        return int
    }

    private static func bool(_ fields: JSONObject, _ key: String) -> Bool? {
        fields[key]?.boolValue
    }

    /// Remote fields on top of a built-in profile. The cookie invariant and the base URL allow-list always hold.
    static func applying(_ fields: JSONObject, to base: InnerTubeClientProfile) -> InnerTubeClientProfile {
        var p = base
        if let v = text(fields, "clientName") { p.clientName = v }
        if let v = text(fields, "clientVersion") { p.clientVersion = v }
        if let v = text(fields, "userAgent") { p.userAgent = v }
        if let v = integer(fields, "clientNameId"), v > 0 { p.clientNameId = v }
        if let v = text(fields, "apiKey") { p.apiKey = v }
        if let v = text(fields, "baseUrl"), allowedBaseURLs.contains(v) { p.baseUrl = v }
        if let v = text(fields, "deviceMake") { p.deviceMake = v }
        if let v = text(fields, "deviceModel") { p.deviceModel = v }
        if let v = text(fields, "osName") { p.osName = v }
        if let v = text(fields, "osVersion") { p.osVersion = v }
        if let v = integer(fields, "androidSdkVersion"), v > 0 { p.androidSdkVersion = v }
        if let v = bool(fields, "expectsPreSignedUrls") { p.expectsPreSignedUrls = v }
        if let v = bool(fields, "supportsCookies") { p.supportsCookies = v }
        if let v = bool(fields, "requiresStreamingPoToken") { p.requiresStreamingPoToken = v }
        if cookielessClients.contains(p.name) || cookielessClients.contains(p.clientName) { p.supportsCookies = false }
        return p
    }

    /// A profile the app does not know yet: needs `clientName`, `clientVersion`, `userAgent`, `clientNameId` and an
    /// allowed `baseUrl` (default www.youtube.com).
    static func newProfile(name: String, _ fields: JSONObject) -> InnerTubeClientProfile? {
        guard let clientName = text(fields, "clientName"), let clientVersion = text(fields, "clientVersion"),
              let userAgent = text(fields, "userAgent"), let clientNameId = integer(fields, "clientNameId"),
              clientNameId > 0 else { return nil }
        let baseUrl = text(fields, "baseUrl") ?? InnerTubeContexts.baseURL
        guard allowedBaseURLs.contains(baseUrl) else { return nil }
        let base = InnerTubeClientProfile(name: name, clientName: clientName, clientVersion: clientVersion,
                                          userAgent: userAgent, clientNameId: clientNameId, baseUrl: baseUrl,
                                          expectsPreSignedUrls: false)
        return applying(fields, to: base)
    }

    // MARK: Strategies

    /// The pre-signed profiles in order (VISIONOS first unless the remote file says otherwise).
    public var preSignedProfiles: [InnerTubeClientProfile] {
        let names = preSignedOrder ?? InnerTubeContexts.playerProfiles.map(\.name)
        return names.compactMap { profiles[$0] }.filter(\.expectsPreSignedUrls)
    }

    /// The resolution chain, the remote version of `YouTubeStreamStrategy.chain(signedIn:)`: pre-signed clients first,
    /// then the deciphered ones; clients that need the cookie (WEB) only when signed in.
    public func chain(signedIn: Bool) -> [YouTubeStreamStrategy] {
        var strategies = preSignedProfiles.map { YouTubeStreamStrategy(kind: .preSigned, profile: $0) }
        let ciphered = cipheredOrder ?? [InnerTubeContexts.tvHTML5.name, InnerTubeContexts.web.name, InnerTubeContexts.webRemix.name]
        for name in ciphered {
            guard let profile = profiles[name] else { continue }
            if name == InnerTubeContexts.web.name && !signedIn { continue }
            strategies.append(YouTubeStreamStrategy(kind: .ciphered, profile: profile))
        }
        return strategies
    }

    /// The search profile (WEB_REMIX with any remote fields).
    public var searchProfile: InnerTubeClientProfile { profiles[InnerTubeContexts.webRemix.name] ?? InnerTubeContexts.webRemix }
}
