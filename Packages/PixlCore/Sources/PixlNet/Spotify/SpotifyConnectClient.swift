// Spotify Connect: the Player endpoints over the existing session. `SpotifySession` hands out the access token and
// refreshes it (saving the rotated refresh token first); a 401 forces one refresh and one retry. A 429 sets a
// Retry-After gate: every call before it ends fails fast with `.rateLimited` (the poller sleeps it out).

import Foundation
import PixlFoundation
import PixlModel

public actor SpotifyConnectClient {
    private let http: any HTTPClient
    private let session: SpotifySession
    private let nowMs: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private var notBeforeMs: Int64 = 0

    /// A device that was just woken by a transfer may still answer `NO_ACTIVE_DEVICE`: one retry after this.
    public static let wakeRetryDelayMs: Int64 = 800

    public init(http: any HTTPClient, session: SpotifySession, nowMs: @escaping @Sendable () -> Int64 = { currentTimeMillis() },
                sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) }) {
        self.http = http
        self.session = session
        self.nowMs = nowMs
        self.sleep = sleep
    }

    /// How long the Retry-After gate still holds (0 = open).
    public var retryAfterRemainingMs: Int64 { max(notBeforeMs - nowMs(), 0) }

    /// Sends a request; returns the 2xx response or throws `SpotifyConnectError` (or `CancellationError`).
    func send(_ build: @Sendable (String) -> HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let wait = notBeforeMs - nowMs()
        if wait > 0 { throw SpotifyConnectError.rateLimited(retryAfterMs: wait) }
        var refreshed = false
        while true {
            guard let authorization = await session.authorizationHeader() else { throw SpotifyConnectError.notSignedIn }
            let response: HTTPResponse
            do {
                response = try await http.send(build(authorization))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                throw SpotifyConnectError.network(String(describing: error))
            }
            if response.isSuccessful { return response }
            if response.statusCode == 401, !refreshed {
                refreshed = true
                if case .success = await session.forceRefresh() { continue }
                throw SpotifyConnectError.notSignedIn
            }
            let error = SpotifyConnectError.from(statusCode: response.statusCode, body: response.body,
                                                 retryAfter: response.header("Retry-After"))
            if case .rateLimited(let ms) = error { notBeforeMs = nowMs() + ms }
            throw error
        }
    }

    // MARK: Reads

    /// `GET /me/player/devices`.
    public func devices() async throws -> [SpotifyConnectDevice] {
        let response = try await send { SpotifyConnectAPI.devices(authorization: $0) }
        guard let json = OrgJSON.parse(response.body), let devices = SpotifyConnectDevice.list(json: json) else {
            throw SpotifyConnectError.failed(status: response.statusCode, message: "Unreadable device list")
        }
        return devices
    }

    /// `GET /me/player`; nil for 204 (nothing playing on any device).
    public func playbackState() async throws -> SpotifyPlaybackState? {
        let response = try await send { SpotifyConnectAPI.playbackState(authorization: $0) }
        if response.statusCode == 204 || response.body.isEmpty { return nil }
        return OrgJSON.parse(response.body).flatMap(SpotifyPlaybackState.init(json:))
    }

    // MARK: Commands

    public func transfer(deviceId: String, play: Bool) async throws {
        _ = try await send { SpotifyConnectAPI.transfer(authorization: $0, deviceId: deviceId, play: play) }
    }

    public func play(deviceId: String, uris: [String], positionMs: Int64) async throws {
        _ = try await send { SpotifyConnectAPI.play(authorization: $0, deviceId: deviceId, uris: uris, positionMs: positionMs) }
    }

    /// Starts `uris` on the device: transfers first when it isn't the active device, and once more when `play`
    /// answers 404 `NO_ACTIVE_DEVICE` (then one more `play` after a short wake-up pause).
    public func start(deviceId: String, isActive: Bool, uris: [String], positionMs: Int64) async throws {
        if !isActive { try await transfer(deviceId: deviceId, play: false) }
        do {
            try await play(deviceId: deviceId, uris: uris, positionMs: positionMs)
        } catch SpotifyConnectError.noActiveDevice {
            if isActive { try await transfer(deviceId: deviceId, play: false) }
            try await sleep(Self.wakeRetryDelayMs)
            try await play(deviceId: deviceId, uris: uris, positionMs: positionMs)
        }
    }

    public func resume(deviceId: String) async throws {
        _ = try await send { SpotifyConnectAPI.resume(authorization: $0, deviceId: deviceId) }
    }

    public func pause(deviceId: String) async throws {
        _ = try await send { SpotifyConnectAPI.pause(authorization: $0, deviceId: deviceId) }
    }

    public func next(deviceId: String) async throws {
        _ = try await send { SpotifyConnectAPI.next(authorization: $0, deviceId: deviceId) }
    }

    public func previous(deviceId: String) async throws {
        _ = try await send { SpotifyConnectAPI.previous(authorization: $0, deviceId: deviceId) }
    }

    public func seek(deviceId: String, positionMs: Int64) async throws {
        _ = try await send { SpotifyConnectAPI.seek(authorization: $0, deviceId: deviceId, positionMs: positionMs) }
    }

    public func setVolume(deviceId: String, percent: Int) async throws {
        _ = try await send { SpotifyConnectAPI.volume(authorization: $0, deviceId: deviceId, percent: percent) }
    }

    public func setShuffle(deviceId: String, enabled: Bool) async throws {
        _ = try await send { SpotifyConnectAPI.shuffle(authorization: $0, deviceId: deviceId, enabled: enabled) }
    }

    public func setRepeat(deviceId: String, state: SpotifyRepeatState) async throws {
        _ = try await send { SpotifyConnectAPI.repeatMode(authorization: $0, deviceId: deviceId, state: state) }
    }

    /// One track search for the resolver; nil when the request failed (a 429 included — it is retried later).
    public func searchTracks(_ query: String) async throws -> [SpotifyTrack]? {
        do {
            let response = try await send { SpotifyConnectAPI.searchTracks(authorization: $0, query: query) }
            return OrgJSON.parse(response.body).flatMap(SpotifySearchResponse.init(json:))?.tracks?.items ?? []
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }
}
