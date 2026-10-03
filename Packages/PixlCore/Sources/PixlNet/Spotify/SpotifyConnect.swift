// Spotify Connect output: PixlAudio tells a Spotify Connect device (an Echo, a TV, a speaker, the desktop app) what
// to play through the Web API's Player endpoints, and acts as its remote. The device streams from Spotify itself.
// Shared spec with Android (docs/parity.md › Spotify Connect). Every endpoint, scope and limit here was checked
// against developer.spotify.com/documentation/web-api and is recorded in docs/api-notes.md.
//
// This file: scopes, request builders, the device / playback-state DTOs, error mapping and the URI window.

import Foundation
import PixlFoundation

/// Constants and pure helpers of Spotify Connect output.
public enum SpotifyConnect {
    /// `GET /me/player`, `GET /me/player/devices`.
    public static let readPlaybackScope = "user-read-playback-state"
    /// Transfer, play, pause, next, previous, seek, volume, shuffle, repeat.
    public static let modifyPlaybackScope = "user-modify-playback-state"
    public static let requiredScopes = [readPlaybackScope, modifyPlaybackScope]

    /// The Connect scopes a granted scope string lacks. nil (the token response carried no `scope`) is unknown and
    /// reports nothing missing: a 403 "Insufficient client scope" from the player endpoints catches it instead.
    public static func missingScopes(granted: String?) -> [String] {
        guard let granted else { return [] }
        let have = Set(granted.split(separator: " ").map(String.init))
        return requiredScopes.filter { !have.contains($0) }
    }

    /// Upper bound of `uris` sent in one `PUT /me/player/play`. The reference documents no limit; 100 is the Web
    /// API's usual batch size (playlist item adds), and PixlAudio re-sends the next window when the device reaches
    /// the last of these (`SpotifyConnectWindow`), so a long queue never needs a bigger body.
    public static let maxURIsPerPlay = 100

    public static func trackURI(_ id: String) -> String { "spotify:track:\(id)" }

    /// The id of a `spotify:track:<id>` URI.
    public static func trackId(fromURI uri: String) -> String? {
        let prefix = "spotify:track:"
        guard uri.hasPrefix(prefix) else { return nil }
        let id = String(uri.dropFirst(prefix.count))
        return isTrackId(id) ? id : nil
    }

    /// A real Spotify track id: 22 base62 characters. YouTube Music rows imported into the Spotify tables carry a
    /// synthetic id of 22 lowercase hex characters (`SpotifyLibrary.youTubeMusicSyntheticId`) that Spotify doesn't
    /// know; those resolve through search like local files. (A real id is all-lowercase-hex with odds ≈ 1e-10.)
    public static func isTrackId(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard scalars.count == 22 else { return false }
        var allLowerHex = true
        for c in scalars {
            let v = c.value
            let digit = v >= 0x30 && v <= 0x39
            let upper = v >= 0x41 && v <= 0x5A
            let lower = v >= 0x61 && v <= 0x7A
            guard digit || upper || lower else { return false }
            if !(digit || (v >= 0x61 && v <= 0x66)) { allLowerHex = false }
        }
        return !allLowerHex
    }

    /// The direct URI of a song that already carries a real Spotify id.
    public static func directURI(spotifyId: String?) -> String? {
        guard let spotifyId, isTrackId(spotifyId) else { return nil }
        return trackURI(spotifyId)
    }
}

// MARK: - Requests

/// `api.spotify.com/v1/me/player…` request builders. Commands without a body still send an empty one
/// (`Content-Length: 0`) so a `PUT`/`POST` is never rejected for a missing length.
public enum SpotifyConnectAPI {
    private static func request(_ method: HTTPMethod, _ path: String, authorization: String,
                                query: [(name: String, value: String?)] = [], json: JSONValue? = nil) -> HTTPRequest {
        var headers = [HTTPHeader("Authorization", authorization)]
        var body: Data?
        if let json {
            headers.append(HTTPHeader("Content-Type", "application/json"))
            body = Data(JSONWriter.write(json).utf8)
        } else if method != .get {
            body = Data()
        }
        return HTTPRequest(method: method, url: URLCoding.url(SpotifyAuth.apiBaseURL + path, query: query),
                           headers: headers, body: body, timeout: 15)
    }

    /// `GET /v1/me/player/devices`.
    public static func devices(authorization: String) -> HTTPRequest {
        request(.get, "v1/me/player/devices", authorization: authorization)
    }

    /// `GET /v1/me/player` (tracks only: an episode arrives with `item: null`). 204 = nothing is playing anywhere.
    public static func playbackState(authorization: String) -> HTTPRequest {
        request(.get, "v1/me/player", authorization: authorization)
    }

    /// `PUT /v1/me/player` — `device_ids` takes exactly one id (more answers 400). `play: false` keeps the
    /// current play state; PixlAudio follows it with its own `play`.
    public static func transfer(authorization: String, deviceId: String, play: Bool) -> HTTPRequest {
        request(.put, "v1/me/player", authorization: authorization,
                json: .object(JSONObject([("device_ids", .array([.string(deviceId)])), ("play", .bool(play))])))
    }

    /// `PUT /v1/me/player/play?device_id=` with `{uris, offset: {position}, position_ms}`.
    public static func play(authorization: String, deviceId: String, uris: [String], offset: Int = 0,
                            positionMs: Int64) -> HTTPRequest {
        let body = JSONObject([
            ("uris", .array(uris.map { .string($0) })),
            ("offset", .object(JSONObject([("position", .integer(max(offset, 0)))]))),
            ("position_ms", .integer(max(positionMs, 0))),
        ])
        return request(.put, "v1/me/player/play", authorization: authorization, query: [("device_id", deviceId)],
                       json: .object(body))
    }

    /// `PUT /v1/me/player/play?device_id=` without a body: resume.
    public static func resume(authorization: String, deviceId: String) -> HTTPRequest {
        request(.put, "v1/me/player/play", authorization: authorization, query: [("device_id", deviceId)])
    }

    /// `PUT /v1/me/player/pause?device_id=`.
    public static func pause(authorization: String, deviceId: String) -> HTTPRequest {
        request(.put, "v1/me/player/pause", authorization: authorization, query: [("device_id", deviceId)])
    }

    /// `POST /v1/me/player/next?device_id=`.
    public static func next(authorization: String, deviceId: String) -> HTTPRequest {
        request(.post, "v1/me/player/next", authorization: authorization, query: [("device_id", deviceId)])
    }

    /// `POST /v1/me/player/previous?device_id=`.
    public static func previous(authorization: String, deviceId: String) -> HTTPRequest {
        request(.post, "v1/me/player/previous", authorization: authorization, query: [("device_id", deviceId)])
    }

    /// `PUT /v1/me/player/seek?position_ms=&device_id=`.
    public static func seek(authorization: String, deviceId: String, positionMs: Int64) -> HTTPRequest {
        request(.put, "v1/me/player/seek", authorization: authorization,
                query: [("position_ms", String(max(positionMs, 0))), ("device_id", deviceId)])
    }

    /// `PUT /v1/me/player/volume?volume_percent=&device_id=` (0…100).
    public static func volume(authorization: String, deviceId: String, percent: Int) -> HTTPRequest {
        request(.put, "v1/me/player/volume", authorization: authorization,
                query: [("volume_percent", String(min(max(percent, 0), 100))), ("device_id", deviceId)])
    }

    /// `PUT /v1/me/player/shuffle?state=&device_id=`.
    public static func shuffle(authorization: String, deviceId: String, enabled: Bool) -> HTTPRequest {
        request(.put, "v1/me/player/shuffle", authorization: authorization,
                query: [("state", enabled ? "true" : "false"), ("device_id", deviceId)])
    }

    /// `PUT /v1/me/player/repeat?state=track|context|off&device_id=`.
    public static func repeatMode(authorization: String, deviceId: String, state: SpotifyRepeatState) -> HTTPRequest {
        request(.put, "v1/me/player/repeat", authorization: authorization,
                query: [("state", state.rawValue), ("device_id", deviceId)])
    }

    /// `GET /v1/search?q=isrc:<ISRC>&type=track` (no `limit`: see `SpotifyAPI.search`).
    public static func searchTracks(authorization: String, query: String) -> HTTPRequest {
        SpotifyAPI.search(authorization: authorization, query: query, type: "track")
    }
}

/// `repeat_state` / the repeat endpoint's `state`.
public enum SpotifyRepeatState: String, Sendable, Hashable {
    case track
    case context
    case off
}

// MARK: - Models

/// A `DeviceObject` from `GET /me/player/devices` (or the `device` of `GET /me/player`).
public struct SpotifyConnectDevice: Sendable, Hashable, Identifiable {
    /// Nullable in the reference; a device without one can't be targeted.
    public var deviceId: String?
    public var name: String
    /// "Computer", "Smartphone", "Speaker", "TV", "AVR", "CastAudio", …
    public var type: String
    public var isActive: Bool
    public var isPrivateSession: Bool
    /// "No Web API commands will be accepted by this device."
    public var isRestricted: Bool
    public var volumePercent: Int?
    public var supportsVolume: Bool

    public init(deviceId: String?, name: String, type: String, isActive: Bool = false, isPrivateSession: Bool = false,
                isRestricted: Bool = false, volumePercent: Int? = nil, supportsVolume: Bool = false) {
        self.deviceId = deviceId
        self.name = name
        self.type = type
        self.isActive = isActive
        self.isPrivateSession = isPrivateSession
        self.isRestricted = isRestricted
        self.volumePercent = volumePercent
        self.supportsVolume = supportsVolume
    }

    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        let name = LenientJSON.string(o["name"]) ?? ""
        let id = LenientJSON.string(o["id"]).flatMap { NetText.isBlank($0) ? nil : $0 }
        self.init(deviceId: id, name: NetText.isBlank(name) ? "Spotify device" : name,
                  type: LenientJSON.string(o["type"]) ?? "Unknown", isActive: LenientJSON.bool(o["is_active"]) ?? false,
                  isPrivateSession: LenientJSON.bool(o["is_private_session"]) ?? false,
                  isRestricted: LenientJSON.bool(o["is_restricted"]) ?? false,
                  volumePercent: LenientJSON.int(o["volume_percent"]),
                  supportsVolume: LenientJSON.bool(o["supports_volume"]) ?? false)
    }

    public var id: String { deviceId ?? "name:\(name)" }

    /// Whether PixlAudio can start a session on it.
    public var isControllable: Bool { deviceId != nil && !isRestricted }

    /// The SF Symbol for `type` (case-insensitive; unknown types get a speaker).
    public var symbolName: String { Self.symbolName(forType: type) }

    public static func symbolName(forType type: String) -> String {
        switch NetText.lowercased(type) {
        case "computer": "laptopcomputer"
        case "tablet": "ipad"
        case "smartphone": "iphone"
        case "speaker": "hifispeaker.fill"
        case "tv": "tv"
        case "avr": "hifireceiver"
        case "stb": "tv.and.mediabox"
        case "audiodongle": "cable.connector"
        case "gameconsole": "gamecontroller"
        case "castvideo": "tv.badge.wifi"
        case "castaudio": "hifispeaker.2"
        case "automobile": "car"
        case "smartwatch": "applewatch"
        default: "speaker.wave.2"
        }
    }

    /// `{"devices": [...]}`.
    public static func list(json: JSONValue) -> [SpotifyConnectDevice]? {
        guard let o = json.objectValue, let items = LenientJSON.array(o["devices"]) else { return nil }
        return items.compactMap(SpotifyConnectDevice.init(json:))
    }

    /// The order the sheet lists them: the active device first, then controllable ones, each by name.
    public static func sortedForDisplay(_ devices: [SpotifyConnectDevice]) -> [SpotifyConnectDevice] {
        devices.enumerated().sorted { a, b in
            if a.element.isActive != b.element.isActive { return a.element.isActive }
            if a.element.isControllable != b.element.isControllable { return a.element.isControllable }
            let nameA = NetText.lowercased(a.element.name), nameB = NetText.lowercased(b.element.name)
            if nameA != nameB { return nameA < nameB }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// `GET /me/player`: what plays where.
public struct SpotifyPlaybackState: Sendable, Hashable {
    public var device: SpotifyConnectDevice?
    public var isPlaying: Bool
    public var progressMs: Int64?
    /// Unix ms when the state last changed (play, pause, skip, scrub, new song).
    public var timestamp: Int64?
    /// `item.uri` (`spotify:track:<id>`); nil for nothing, an episode or an ad.
    public var itemURI: String?
    public var itemDurationMs: Int64?
    public var itemName: String?
    public var shuffleState: Bool?
    public var repeatState: SpotifyRepeatState?
    /// `track`, `episode`, `ad`, `unknown`.
    public var currentlyPlayingType: String?

    public init(device: SpotifyConnectDevice?, isPlaying: Bool, progressMs: Int64?, timestamp: Int64? = nil,
                itemURI: String?, itemDurationMs: Int64? = nil, itemName: String? = nil, shuffleState: Bool? = nil,
                repeatState: SpotifyRepeatState? = nil, currentlyPlayingType: String? = "track") {
        self.device = device
        self.isPlaying = isPlaying
        self.progressMs = progressMs
        self.timestamp = timestamp
        self.itemURI = itemURI
        self.itemDurationMs = itemDurationMs
        self.itemName = itemName
        self.shuffleState = shuffleState
        self.repeatState = repeatState
        self.currentlyPlayingType = currentlyPlayingType
    }

    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        let item = LenientJSON.object(o["item"])
        self.init(device: o["device"].flatMap(SpotifyConnectDevice.init(json:)),
                  isPlaying: LenientJSON.bool(o["is_playing"]) ?? false,
                  progressMs: LenientJSON.long(o["progress_ms"]), timestamp: LenientJSON.long(o["timestamp"]),
                  itemURI: LenientJSON.string(item?["uri"]), itemDurationMs: LenientJSON.long(item?["duration_ms"]),
                  itemName: LenientJSON.string(item?["name"]), shuffleState: LenientJSON.bool(o["shuffle_state"]),
                  repeatState: LenientJSON.string(o["repeat_state"]).flatMap(SpotifyRepeatState.init(rawValue:)),
                  currentlyPlayingType: LenientJSON.string(o["currently_playing_type"]))
    }
}

// MARK: - Errors

/// The regular error object `{"error": {"status", "message", "reason"}}`.
public struct SpotifyErrorBody: Sendable, Hashable {
    public var status: Int?
    public var message: String?
    /// e.g. `QUOTA_EXCEEDED` (documented today); the player reasons `PREMIUM_REQUIRED`, `NO_ACTIVE_DEVICE`, … were
    /// documented in the older reference ("Player Error Reasons") and are still matched.
    public var reason: String?

    public init?(data: Data) {
        guard let error = OrgJSON.parse(data)?.objectValue.flatMap({ LenientJSON.object($0["error"]) }) else { return nil }
        status = LenientJSON.int(error["status"])
        message = LenientJSON.string(error["message"])
        reason = LenientJSON.string(error["reason"])
    }
}

/// Why a Connect call failed, and what the user is told.
public enum SpotifyConnectError: Error, Sendable, Hashable {
    /// No session, or the refresh token is dead.
    case notSignedIn
    /// The token predates `user-read-playback-state` / `user-modify-playback-state`.
    case missingScope
    case premiumRequired
    /// 404 `NO_ACTIVE_DEVICE`: transfer first.
    case noActiveDevice
    /// The device refuses Web API commands (`is_restricted`, `DEVICE_NOT_CONTROLLABLE`, `REMOTE_CONTROL_DISALLOW`).
    case deviceRestricted
    case volumeNotSupported
    /// 429: wait this long (Retry-After, clamped to 1…60 s, 5 s when absent).
    case rateLimited(retryAfterMs: Int64)
    /// 5xx.
    case unavailable(status: Int)
    /// No HTTP response.
    case network(String)
    case failed(status: Int, message: String?)

    /// Maps a non-2xx answer.
    public static func from(statusCode: Int, body: Data, retryAfter: String?) -> SpotifyConnectError {
        let parsed = SpotifyErrorBody(data: body)
        let reason = parsed?.reason ?? ""
        let message = parsed?.message ?? ""
        let lowerMessage = NetText.lowercased(message)
        if statusCode == 429 {
            if case .waitAndRetry(let ms) = SpotifyCallPolicy.decision(statusCode: 429, retryAfter: retryAfter) {
                return .rateLimited(retryAfterMs: ms)
            }
            return .rateLimited(retryAfterMs: 5000)
        }
        if reason == "PREMIUM_REQUIRED" || lowerMessage.contains("premium") { return .premiumRequired }
        if reason == "NO_ACTIVE_DEVICE" || (statusCode == 404 && (lowerMessage.contains("device") || message.isEmpty)) {
            return .noActiveDevice
        }
        if lowerMessage.contains("scope") || lowerMessage.contains("permissions missing") { return .missingScope }
        if reason == "VOLUME_CONTROL_DISALLOW" { return .volumeNotSupported }
        if reason == "DEVICE_NOT_CONTROLLABLE" || reason == "REMOTE_CONTROL_DISALLOW" || lowerMessage.contains("restricted") {
            return .deviceRestricted
        }
        if statusCode == 401 { return .notSignedIn }
        if statusCode >= 500 { return .unavailable(status: statusCode) }
        return .failed(status: statusCode, message: message.isEmpty ? nil : message)
    }

    /// The toast (English, like the rest of the Spotify screens).
    public var userMessage: String {
        switch self {
        case .notSignedIn: "Sign in to Spotify again to use Connect"
        case .missingScope: "Reconnect Spotify to use Connect"
        case .premiumRequired: "Spotify Connect needs Spotify Premium"
        case .noActiveDevice: "That device isn't available. Open Spotify on it and try again"
        case .deviceRestricted: "This device can't be controlled from other apps"
        case .volumeNotSupported: "This device's volume can't be changed from here"
        case .rateLimited(let ms): "Spotify is busy. Try again in \(max(1, (ms + 999) / 1000)) s"
        case .unavailable: "Spotify isn't responding. Try again in a moment"
        case .network: "Couldn't reach Spotify"
        case .failed(let status, _): "Spotify Connect failed (HTTP \(status))"
        }
    }
}

// MARK: - The URI window

/// What one queue entry resolved to.
public enum SpotifyConnectSlot: Sendable, Hashable {
    case uri(String)
    /// Not on Spotify (or not resolvable): skipped.
    case skipped
    /// Not looked up yet.
    case pending
}

/// The `uris` of one `PUT /me/player/play`, each with the PixlAudio queue index it plays: from a start entry
/// onwards, skipping entries that aren't on Spotify, stopping at the first one not resolved yet (order must hold)
/// or at `maxCount`.
public struct SpotifyConnectWindow: Sendable, Hashable {
    public var uris: [String]
    public var queueIndices: [Int]

    public init(uris: [String] = [], queueIndices: [Int] = []) {
        self.uris = uris
        self.queueIndices = queueIndices
    }

    public var isEmpty: Bool { uris.isEmpty }
    public var count: Int { uris.count }

    public static func make(slots: [SpotifyConnectSlot], from start: Int,
                            maxCount: Int = SpotifyConnect.maxURIsPerPlay) -> SpotifyConnectWindow {
        var window = SpotifyConnectWindow()
        guard start >= 0, maxCount > 0 else { return window }
        var index = start
        while index < slots.count, window.count < maxCount {
            switch slots[index] {
            case .uri(let uri):
                window.uris.append(uri)
                window.queueIndices.append(index)
            case .skipped:
                break
            case .pending:
                return window
            }
            index += 1
        }
        return window
    }

    /// Whether the queue holds anything playable (or still unknown) after the window's last entry.
    public static func hasMore(after window: SpotifyConnectWindow, slots: [SpotifyConnectSlot]) -> Bool {
        guard let last = window.queueIndices.last else { return false }
        var index = last + 1
        while index < slots.count {
            if slots[index] != .skipped { return true }
            index += 1
        }
        return false
    }

    /// Entries in `range` that turned out not to be on Spotify (the "N songs … were skipped" toast).
    public static func skippedCount(slots: [SpotifyConnectSlot], in range: Range<Int>) -> Int {
        let clamped = range.clamped(to: 0..<slots.count)
        return slots[clamped].reduce(0) { $0 + ($1 == .skipped ? 1 : 0) }
    }

    /// The window position of `uri`: the occurrence nearest at or after `hint` (a song can be queued twice), else
    /// the first one; nil when the window doesn't hold it.
    public func position(of uri: String, near hint: Int) -> Int? {
        if hint >= 0, hint < uris.count {
            for i in hint..<uris.count where uris[i] == uri { return i }
        }
        return uris.firstIndex(of: uri)
    }

    /// The window position that plays queue entry `queueIndex`.
    public func position(ofQueueIndex queueIndex: Int) -> Int? { queueIndices.firstIndex(of: queueIndex) }

    /// The toast for skipped songs (nil for none).
    public static func skippedMessage(_ count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 song isn't on Spotify and was skipped"
        default: "\(count) songs aren't on Spotify and were skipped"
        }
    }
}
