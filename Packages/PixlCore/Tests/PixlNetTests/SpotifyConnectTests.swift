import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

/// Spotify Connect output (Swift-only: the Android port is built from the same spec in parallel).
@Suite("Spotify Connect: scopes, requests, models, errors")
struct SpotifyConnectBasicsTests {
    @Test func scopesIncludeConnectAndDetectOldLogins() {
        #expect(SpotifyAuth.scopes.contains("user-read-playback-state"))
        #expect(SpotifyAuth.scopes.contains("user-modify-playback-state"))
        #expect(SpotifyAuth.scopes.contains("user-top-read"))
        #expect(SpotifyConnect.missingScopes(granted: nil).isEmpty)
        #expect(SpotifyConnect.missingScopes(granted: "user-library-read user-top-read")
            == ["user-read-playback-state", "user-modify-playback-state"])
        #expect(SpotifyConnect.missingScopes(granted: "user-modify-playback-state user-read-playback-state").isEmpty)
        // A refresh answer without `scope` keeps the grant; one with a scope replaces it.
        let kept = SpotifyAuth.tokens(from: SpotifyTokenResponse(accessToken: "A"), previousRefreshToken: "R", nowMs: 0,
                                      previousScope: "user-top-read")
        #expect(kept?.scope == "user-top-read")
        let replaced = SpotifyAuth.tokens(from: SpotifyTokenResponse(accessToken: "A", scope: "x y"), previousRefreshToken: "R",
                                          nowMs: 0, previousScope: "user-top-read")
        #expect(replaced?.scope == "x y")
    }

    @Test func playerRequestsMatchTheReference() {
        let auth = "Bearer T"
        let devices = SpotifyConnectAPI.devices(authorization: auth)
        #expect(devices.method == .get && devices.url == "https://api.spotify.com/v1/me/player/devices" && devices.body == nil)
        #expect(devices.header("Authorization") == "Bearer T")
        #expect(SpotifyConnectAPI.playbackState(authorization: auth).url == "https://api.spotify.com/v1/me/player")

        let transfer = SpotifyConnectAPI.transfer(authorization: auth, deviceId: "dev1", play: false)
        #expect(transfer.method == .put && transfer.url == "https://api.spotify.com/v1/me/player")
        #expect(transfer.bodyText == #"{"device_ids":["dev1"],"play":false}"#)
        #expect(transfer.header("Content-Type") == "application/json")

        let play = SpotifyConnectAPI.play(authorization: auth, deviceId: "dev 1", uris: ["spotify:track:a", "spotify:track:b"], positionMs: 61_500)
        #expect(play.method == .put && play.url == "https://api.spotify.com/v1/me/player/play?device_id=dev%201")
        #expect(play.bodyText == #"{"uris":["spotify:track:a","spotify:track:b"],"offset":{"position":0},"position_ms":61500}"#)

        let pause = SpotifyConnectAPI.pause(authorization: auth, deviceId: "d")
        #expect(pause.method == .put && pause.url == "https://api.spotify.com/v1/me/player/pause?device_id=d")
        #expect(pause.body == Data() && pause.header("Content-Type") == nil)
        #expect(SpotifyConnectAPI.resume(authorization: auth, deviceId: "d").url == "https://api.spotify.com/v1/me/player/play?device_id=d")
        let next = SpotifyConnectAPI.next(authorization: auth, deviceId: "d")
        #expect(next.method == .post && next.url == "https://api.spotify.com/v1/me/player/next?device_id=d")
        #expect(SpotifyConnectAPI.previous(authorization: auth, deviceId: "d").method == .post)
        #expect(SpotifyConnectAPI.seek(authorization: auth, deviceId: "d", positionMs: -5).url
            == "https://api.spotify.com/v1/me/player/seek?position_ms=0&device_id=d")
        #expect(SpotifyConnectAPI.volume(authorization: auth, deviceId: "d", percent: 140).url
            == "https://api.spotify.com/v1/me/player/volume?volume_percent=100&device_id=d")
        #expect(SpotifyConnectAPI.shuffle(authorization: auth, deviceId: "d", enabled: false).url
            == "https://api.spotify.com/v1/me/player/shuffle?state=false&device_id=d")
        #expect(SpotifyConnectAPI.repeatMode(authorization: auth, deviceId: "d", state: .track).url
            == "https://api.spotify.com/v1/me/player/repeat?state=track&device_id=d")
        #expect(SpotifyConnectAPI.searchTracks(authorization: auth, query: "isrc:USUM71703861").url
            == "https://api.spotify.com/v1/search?q=isrc%3AUSUM71703861&type=track")
    }

    @Test func devicesDecodeSortAndMapToSymbols() throws {
        let json = try #require(OrgJSON.parse(#"""
        {"devices":[
          {"id":"b","is_active":false,"is_private_session":false,"is_restricted":false,"name":"Kitchen Echo","type":"Speaker","volume_percent":40,"supports_volume":true},
          {"id":null,"is_active":false,"is_restricted":false,"name":"Old TV","type":"TV","volume_percent":null,"supports_volume":false},
          {"id":"c","is_active":false,"is_restricted":true,"name":"Car","type":"Automobile","supports_volume":false},
          {"id":"a","is_active":true,"is_restricted":false,"name":"Desk","type":"Computer","volume_percent":"70","supports_volume":true}
        ]}
        """#))
        let devices = try #require(SpotifyConnectDevice.list(json: json))
        #expect(devices.count == 4)
        #expect(devices[0] == SpotifyConnectDevice(deviceId: "b", name: "Kitchen Echo", type: "Speaker", volumePercent: 40, supportsVolume: true))
        #expect(devices[1].deviceId == nil && !devices[1].isControllable && devices[1].volumePercent == nil)
        #expect(!devices[2].isControllable)
        #expect(devices[3].volumePercent == 70 && devices[3].isActive)
        #expect(SpotifyConnectDevice.sortedForDisplay(devices).map(\.name) == ["Desk", "Kitchen Echo", "Car", "Old TV"])
        #expect(devices.map(\.symbolName) == ["hifispeaker.fill", "tv", "car", "laptopcomputer"])
        #expect(SpotifyConnectDevice.symbolName(forType: "CastAudio") == "hifispeaker.2")
        #expect(SpotifyConnectDevice.symbolName(forType: "AVR") == "hifireceiver")
        #expect(SpotifyConnectDevice.symbolName(forType: "Smartphone") == "iphone")
        #expect(SpotifyConnectDevice.symbolName(forType: "Toaster") == "speaker.wave.2")
        #expect(SpotifyConnectDevice.list(json: .object(JSONObject())) == nil)
    }

    @Test func playbackStateDecodes() throws {
        let json = try #require(OrgJSON.parse(#"""
        {"device":{"id":"b","is_active":true,"name":"Kitchen Echo","type":"Speaker","volume_percent":35,"supports_volume":true},
         "repeat_state":"off","shuffle_state":false,"timestamp":1700000000000,"progress_ms":12345,"is_playing":true,
         "item":{"uri":"spotify:track:4iV5W9uYEdYUVa79Axb7Rh","duration_ms":200000,"name":"Song"},"currently_playing_type":"track"}
        """#))
        let state = try #require(SpotifyPlaybackState(json: json))
        #expect(state.device?.deviceId == "b" && state.device?.volumePercent == 35)
        #expect(state.isPlaying && state.progressMs == 12345 && state.itemDurationMs == 200000)
        #expect(state.itemURI == "spotify:track:4iV5W9uYEdYUVa79Axb7Rh" && state.repeatState == .off && state.shuffleState == false)
        let episodeJSON = try #require(OrgJSON.parse(#"{"is_playing":true,"item":null,"currently_playing_type":"episode"}"#))
        let episode = try #require(SpotifyPlaybackState(json: episodeJSON))
        #expect(episode.itemURI == nil && episode.device == nil && episode.currentlyPlayingType == "episode")
    }

    @Test func errorsMapToTheSpecMessages() {
        func map(_ status: Int, _ body: String, _ retryAfter: String? = nil) -> SpotifyConnectError {
            SpotifyConnectError.from(statusCode: status, body: Data(body.utf8), retryAfter: retryAfter)
        }
        let premium = map(403, #"{"error":{"status":403,"message":"Player command failed: Premium required","reason":"PREMIUM_REQUIRED"}}"#)
        #expect(premium == .premiumRequired)
        #expect(premium.userMessage == "Spotify Connect needs Spotify Premium")
        #expect(map(403, #"{"error":{"status":403,"message":"Premium required"}}"#) == .premiumRequired)
        #expect(map(404, #"{"error":{"status":404,"message":"Player command failed: No active device found","reason":"NO_ACTIVE_DEVICE"}}"#) == .noActiveDevice)
        #expect(map(404, "") == .noActiveDevice)
        let scope = map(403, #"{"error":{"status":403,"message":"Insufficient client scope"}}"#)
        #expect(scope == .missingScope && scope.userMessage == "Reconnect Spotify to use Connect")
        #expect(map(401, #"{"error":{"status":401,"message":"Permissions missing"}}"#) == .missingScope)
        #expect(map(403, #"{"error":{"status":403,"message":"Player command failed: Restriction violated","reason":"UNKNOWN"}}"#) == .failed(status: 403, message: "Player command failed: Restriction violated"))
        #expect(map(403, #"{"error":{"status":403,"message":"x","reason":"VOLUME_CONTROL_DISALLOW"}}"#) == .volumeNotSupported)
        #expect(map(403, #"{"error":{"status":403,"message":"Device is restricted"}}"#) == .deviceRestricted)
        #expect(map(429, "", "7") == .rateLimited(retryAfterMs: 7000))
        #expect(map(429, #"{"error":{"status":429,"message":"Too many requests","reason":"QUOTA_EXCEEDED"}}"#) == .rateLimited(retryAfterMs: 5000))
        #expect(map(429, "", "600") == .rateLimited(retryAfterMs: 60_000))
        #expect(SpotifyConnectError.rateLimited(retryAfterMs: 1200).userMessage == "Spotify is busy. Try again in 2 s")
        #expect(map(503, "") == .unavailable(status: 503))
        #expect(map(400, #"{"error":{"status":400,"message":"Malformed json"}}"#) == .failed(status: 400, message: "Malformed json"))
        #expect(map(401, "{}") == .notSignedIn)
    }
}

@Suite("Spotify Connect: URIs and windows")
struct SpotifyConnectWindowTests {
    @Test func trackIdsAndSyntheticYouTubeIds() {
        #expect(SpotifyConnect.isTrackId("4iV5W9uYEdYUVa79Axb7Rh"))
        #expect(!SpotifyConnect.isTrackId("0123456789abcdef012345")) // SHA-256 hex prefix (YouTube Music row)
        #expect(!SpotifyConnect.isTrackId("short"))
        #expect(!SpotifyConnect.isTrackId("4iV5W9uYEdYUVa79Axb7R!"))
        #expect(SpotifyConnect.directURI(spotifyId: "4iV5W9uYEdYUVa79Axb7Rh") == "spotify:track:4iV5W9uYEdYUVa79Axb7Rh")
        #expect(SpotifyConnect.directURI(spotifyId: nil) == nil)
        #expect(SpotifyConnect.trackId(fromURI: "spotify:track:4iV5W9uYEdYUVa79Axb7Rh") == "4iV5W9uYEdYUVa79Axb7Rh")
        #expect(SpotifyConnect.trackId(fromURI: "spotify:episode:4iV5W9uYEdYUVa79Axb7Rh") == nil)
        let synthetic = SpotifyLibrary.youTubeMusicSyntheticId("dQw4w9WgXcQ", sha256: TestSHA256.hash)
        #expect(!SpotifyConnect.isTrackId(synthetic))
    }

    @Test func windowsSkipStopAtPendingAndCap() {
        let slots: [SpotifyConnectSlot] = [.uri("u0"), .skipped, .uri("u2"), .uri("u3"), .skipped, .pending, .uri("u6")]
        let fromStart = SpotifyConnectWindow.make(slots: slots, from: 0)
        #expect(fromStart.uris == ["u0", "u2", "u3"] && fromStart.queueIndices == [0, 2, 3])
        #expect(SpotifyConnectWindow.hasMore(after: fromStart, slots: slots))
        #expect(SpotifyConnectWindow.make(slots: slots, from: 1).queueIndices == [2, 3])
        #expect(SpotifyConnectWindow.make(slots: slots, from: 0, maxCount: 2).uris == ["u0", "u2"])
        #expect(SpotifyConnectWindow.make(slots: slots, from: 6).uris == ["u6"])
        #expect(!SpotifyConnectWindow.hasMore(after: SpotifyConnectWindow.make(slots: slots, from: 6), slots: slots))
        #expect(SpotifyConnectWindow.make(slots: slots, from: 9).isEmpty)
        #expect(SpotifyConnectWindow.skippedCount(slots: slots, in: 0..<7) == 2)
        #expect(SpotifyConnectWindow.skippedCount(slots: slots, in: 3..<99) == 1)
        let tail: [SpotifyConnectSlot] = [.uri("a"), .skipped, .skipped]
        #expect(!SpotifyConnectWindow.hasMore(after: SpotifyConnectWindow.make(slots: tail, from: 0), slots: tail))

        let long = (0..<250).map { SpotifyConnectSlot.uri("u\($0)") }
        let chunk = SpotifyConnectWindow.make(slots: long, from: 120)
        #expect(chunk.count == SpotifyConnect.maxURIsPerPlay && chunk.queueIndices.first == 120 && chunk.queueIndices.last == 219)
    }

    @Test func positionsHandleDuplicates() {
        let window = SpotifyConnectWindow(uris: ["a", "b", "a", "c"], queueIndices: [4, 5, 6, 7])
        #expect(window.position(of: "a", near: 0) == 0)
        #expect(window.position(of: "a", near: 1) == 2)
        #expect(window.position(of: "a", near: 3) == 0)
        #expect(window.position(of: "z", near: 0) == nil)
        #expect(window.position(ofQueueIndex: 6) == 2)
        #expect(SpotifyConnectWindow.skippedMessage(0) == nil)
        #expect(SpotifyConnectWindow.skippedMessage(1) == "1 song isn't on Spotify and was skipped")
        #expect(SpotifyConnectWindow.skippedMessage(4) == "4 songs aren't on Spotify and were skipped")
    }
}

@Suite("Spotify Connect: strict search match and resolution cache")
struct SpotifyConnectResolverTests {
    static func song(_ title: String, _ artist: String, _ seconds: Int64, key: String = "f:1", spotifyId: String? = nil) -> SpotifyConnectSong {
        SpotifyConnectSong(key: key, spotifyId: spotifyId, title: title, artist: artist, durationMs: seconds * 1000)
    }

    static func track(_ id: String, _ name: String, _ artists: [String], _ seconds: Int64) -> SpotifyTrack {
        SpotifyTrack(id: id, name: name, durationMs: seconds * 1000, artists: artists.map { SpotifyArtistRef(id: nil, name: $0) }, type: "track")
    }

    static let idA = "4iV5W9uYEdYUVa79Axb7Rh"
    static let idB = "1301WleyT98MSxVHPZCA6M"

    @Test func strictMatchRules() {
        let local = Self.song("Here Comes the Sun", "The Beatles", 185)
        #expect(SpotifyConnectMatcher.isStrictMatch(local, Self.track(Self.idA, "Here Comes The Sun - Remastered 2009", ["The Beatles"], 186)))
        #expect(SpotifyConnectMatcher.isStrictMatch(local, Self.track(Self.idA, "Here Comes the Sun", ["The Beatles"], 188)))
        // Duration more than 3 s away.
        #expect(!SpotifyConnectMatcher.isStrictMatch(local, Self.track(Self.idA, "Here Comes the Sun", ["The Beatles"], 189)))
        // Live / remix / cover mismatch, either way.
        #expect(!SpotifyConnectMatcher.isStrictMatch(local, Self.track(Self.idA, "Here Comes the Sun - Live", ["The Beatles"], 185)))
        #expect(!SpotifyConnectMatcher.isStrictMatch(Self.song("Song (Remix)", "A", 200), Self.track(Self.idA, "Song", ["A"], 200)))
        #expect(SpotifyConnectMatcher.isStrictMatch(Self.song("Song (Remix)", "A", 200), Self.track(Self.idA, "Song - Remix", ["A"], 201)))
        // Another artist, another title.
        #expect(!SpotifyConnectMatcher.isStrictMatch(local, Self.track(Self.idA, "Here Comes the Sun", ["Nina Simone"], 185)))
        #expect(!SpotifyConnectMatcher.isStrictMatch(local, Self.track(Self.idA, "Here Comes the Rain", ["The Beatles"], 185)))
        // Featured artists on either side, multi-artist tags.
        #expect(SpotifyConnectMatcher.isStrictMatch(Self.song("Stay (feat. Justin Bieber)", "The Kid LAROI & Justin Bieber", 141),
                                                    Self.track(Self.idA, "STAY (with Justin Bieber)", ["The Kid LAROI", "Justin Bieber"], 141)))
        #expect(SpotifyConnectMatcher.isStrictMatch(Self.song("Café", "Zoé", 210), Self.track(Self.idA, "Cafe", ["Zoe"], 211)))
        // Only real catalogue tracks.
        #expect(!SpotifyConnectMatcher.isStrictMatch(local, Self.track("0123456789abcdef012345", "Here Comes the Sun", ["The Beatles"], 185)))
        var localFile = Self.track(Self.idA, "Here Comes the Sun", ["The Beatles"], 185)
        localFile.isLocal = true
        #expect(!SpotifyConnectMatcher.isStrictMatch(local, localFile))
        // ISRC hits only need the duration to agree.
        #expect(SpotifyConnectMatcher.isISRCMatch(local, Self.track(Self.idA, "Something else", ["Someone"], 184)))
        #expect(!SpotifyConnectMatcher.isISRCMatch(local, Self.track(Self.idA, "Here Comes the Sun", ["The Beatles"], 240)))
    }

    @Test func queries() {
        #expect(SpotifyConnectMatcher.isrcQuery("us-um7-17-03861") == "isrc:USUM71703861")
        #expect(SpotifyConnectMatcher.isrcQuery("nope") == nil)
        #expect(SpotifyConnectMatcher.isrcQuery(nil) == nil)
        #expect(SpotifyConnectMatcher.textQuery(Self.song("Track: \"One\"", "A feat. B", 1)) == "Track   One A")
        #expect(SpotifyConnectMatcher.primaryArtist("Simon & Garfunkel") == "Simon")
        #expect(SpotifyConnectMatcher.textQuery(Self.song(" ", "A", 1)) == nil)
    }

    actor MemoryStorage: SpotifyConnectResolutionStorage {
        var data: Data?
        func load() async -> Data? { data }
        func save(_ data: Data) async { self.data = data }
    }

    @Test func resolverUsesIdsThenISRCThenTextAndCachesMisses() async throws {
        let queries = Box<[String]>([])
        let now = Box<Int64>(1_000)
        let failing = Box(false)
        let storage = MemoryStorage()
        let search: SpotifyConnectResolver.Search = { query in
            queries.mutate { $0.append(query) }
            if failing.value { return nil }
            if query == "isrc:GBAYE0601690" { return [Self.track(Self.idB, "Whatever", ["X"], 185)] }
            if query.hasPrefix("Here Comes the Sun") { return [Self.track(Self.idA, "Here Comes the Sun", ["The Beatles"], 186)] }
            return []
        }
        let resolver = SpotifyConnectResolver(storage: storage, search: search,
                                              isrc: { $0.key == "f:isrc" ? "GBAYE0601690" : nil }, nowMs: { now.value })

        // A real Spotify id: no lookup.
        #expect(try await resolver.resolve(Self.song("x", "y", 1, key: "sp:1", spotifyId: Self.idA)) == .uri("spotify:track:\(Self.idA)"))
        #expect(queries.value.isEmpty)
        // ISRC first.
        #expect(try await resolver.resolve(Self.song("Here Comes the Sun", "The Beatles", 185, key: "f:isrc")) == .uri("spotify:track:\(Self.idB)"))
        #expect(queries.value == ["isrc:GBAYE0601690"])
        // Then title + artist.
        #expect(try await resolver.resolve(Self.song("Here Comes the Sun", "The Beatles", 185, key: "f:2")) == .uri("spotify:track:\(Self.idA)"))
        #expect(queries.value.last == "Here Comes the Sun The Beatles")
        // A miss is cached and not asked again until the retry age.
        let unknown = Self.song("Bedroom Demo 3", "Me", 100, key: "f:3")
        #expect(try await resolver.resolve(unknown) == .skipped)
        let asked = queries.value.count
        #expect(try await resolver.resolve(unknown) == .skipped)
        #expect(queries.value.count == asked)
        now.value += SpotifyConnectResolver.missRetryMs
        #expect(await resolver.cached(unknown) == .pending)
        // A failed search caches nothing.
        failing.value = true
        let other = Self.song("Other", "Me", 100, key: "f:4")
        #expect(try await resolver.resolve(other) == .pending)
        #expect(await resolver.cached(other) == .pending)
        // New tags invalidate the cached answer.
        var retagged = Self.song("Here Comes the Sun", "The Beatles", 185, key: "f:2")
        #expect(await resolver.cached(retagged) == .uri("spotify:track:\(Self.idA)"))
        retagged.title = "Something"
        #expect(await resolver.cached(retagged) == .pending)

        // Persisted and reloaded.
        await resolver.flush()
        let reloaded = SpotifyConnectResolver(storage: storage, search: { _ in [] }, nowMs: { now.value })
        #expect(await reloaded.cached(Self.song("Here Comes the Sun", "The Beatles", 185, key: "f:2")) == .uri("spotify:track:\(Self.idA)"))
        await reloaded.clear()
        #expect(await SpotifyConnectResolver(storage: storage, search: { _ in [] }).cached(Self.song("Here Comes the Sun", "The Beatles", 185, key: "f:2")) == .pending)
    }
}

@Suite("Spotify Connect: session reducer")
struct SpotifyConnectReducerTests {
    static let window = SpotifyConnectWindow(uris: ["spotify:track:a", "spotify:track:b", "spotify:track:c"], queueIndices: [3, 5, 6])

    static func state(position: Int = 0, playing: Bool = true, progress: Int64 = 10_000, anchor: Int64 = 100_000,
                      hasMore: Bool = false) -> SpotifyConnectSessionState {
        SpotifyConnectSessionState(deviceId: "echo", deviceName: "Kitchen Echo", deviceType: "Speaker", window: window,
                                   windowPosition: position, isPlaying: playing, progressMs: progress, anchorMs: anchor,
                                   durationMs: 200_000, volumePercent: 40, supportsVolume: true, hasMoreAfterWindow: hasMore)
    }

    static func poll(_ uri: String?, device: String = "echo", playing: Bool = true, progress: Int64 = 0,
                     duration: Int64 = 200_000, volume: Int = 40) -> SpotifyPlaybackState {
        SpotifyPlaybackState(device: SpotifyConnectDevice(deviceId: device, name: device == "echo" ? "Kitchen Echo" : "Desk",
                                                          type: "Speaker", isActive: true, volumePercent: volume, supportsVolume: true),
                             isPlaying: playing, progressMs: progress, itemURI: uri, itemDurationMs: duration)
    }

    @Test func interpolatesAndWritesNothingWhenNothingChanged() {
        var s = Self.state()
        #expect(s.positionMs(at: 101_500) == 11_500)
        #expect(s.positionMs(at: 999_999) == 200_000)
        let before = s
        // 1.2 s later the device reports 11.1 s: within the tolerance of the interpolated 11.2 s.
        let outcome = SpotifyConnectReducer.apply(Self.poll("spotify:track:a", progress: 11_100), to: &s, nowMs: 101_200)
        #expect(outcome == SpotifyConnectPollOutcome(.none))
        #expect(s == before)
        // A scrub on the device itself is a change.
        #expect(SpotifyConnectReducer.apply(Self.poll("spotify:track:a", progress: 90_000), to: &s, nowMs: 101_300).change == .updated)
        #expect(s.progressMs == 90_000 && s.anchorMs == 101_300)
        #expect(SpotifyConnectReducer.apply(Self.poll("spotify:track:a", playing: false, progress: 90_000), to: &s, nowMs: 101_400).change == .updated)
        #expect(!s.isPlaying && s.positionMs(at: 200_000) == 90_000)
        #expect(SpotifyConnectReducer.apply(Self.poll("spotify:track:a", playing: false, progress: 90_000, volume: 55), to: &s, nowMs: 101_500).change == .updated)
        #expect(s.volumePercent == 55)
    }

    @Test func followsTrackChangesToQueueIndices() {
        var s = Self.state()
        let outcome = SpotifyConnectReducer.apply(Self.poll("spotify:track:b", progress: 400, duration: 150_000), to: &s, nowMs: 200_000)
        #expect(outcome.change == .trackChanged(queueIndex: 5))
        #expect(s.windowPosition == 1 && s.durationMs == 150_000 && s.progressMs == 400)
    }

    @Test func takeoversEndTheSession() {
        var s = Self.state()
        #expect(SpotifyConnectReducer.apply(Self.poll("spotify:track:a", device: "desk"), to: &s, nowMs: 200_000).change
            == .takenOver(.otherDevice(name: "Desk")))
        #expect(SpotifyConnectReducer.apply(Self.poll("spotify:track:zzz"), to: &s, nowMs: 200_000).change == .takenOver(.otherContent))
        #expect(SpotifyConnectReducer.apply(nil, to: &s, nowMs: 200_000).change == .takenOver(.stopped))
        #expect(SpotifyConnectTakeover.otherDevice(name: "Desk").message(deviceName: "Kitchen Echo") == "Playback moved to Desk")
        #expect(SpotifyConnectTakeover.stopped.message(deviceName: "Kitchen Echo") == "Playback stopped on Kitchen Echo")
    }

    @Test func graceIgnoresStalePolls() {
        var s = Self.state()
        SpotifyConnectReducer.sent(SpotifyConnectWindow(uris: ["spotify:track:b", "spotify:track:c"], queueIndices: [5, 6]),
                                   positionMs: 0, durationMs: 150_000, hasMore: false, to: &s, nowMs: 300_000)
        // The device still shows the old track, another device, or nothing: all ignored during the grace period.
        #expect(SpotifyConnectReducer.apply(Self.poll("spotify:track:a"), to: &s, nowMs: 300_500).change == .none)
        #expect(SpotifyConnectReducer.apply(Self.poll("spotify:track:c"), to: &s, nowMs: 300_600).change == .none)
        #expect(SpotifyConnectReducer.apply(nil, to: &s, nowMs: 300_700).change == .none)
        #expect(s.windowPosition == 0 && s.queueIndex == 5)
        // After it, the same stale poll is a takeover.
        #expect(SpotifyConnectReducer.apply(Self.poll("spotify:track:a"), to: &s, nowMs: 300_000 + SpotifyConnectReducer.commandGraceMs)
            .change == .takenOver(.otherContent))
    }

    @Test func endOfQueueAndNextWindow() {
        // Autoplay after the last entry is the end, not a takeover.
        var s = Self.state(position: 2)
        #expect(SpotifyConnectReducer.apply(Self.poll("spotify:track:other"), to: &s, nowMs: 200_000).change == .reachedEnd)
        // The device paused itself at the last entry's start.
        var t = Self.state(position: 2)
        #expect(SpotifyConnectReducer.apply(Self.poll("spotify:track:c", playing: false, progress: 0), to: &t, nowMs: 200_000).change == .reachedEnd)
        // More queue after the window: ask for the next window once, when the last entry starts.
        var u = Self.state(position: 1, hasMore: true)
        let first = SpotifyConnectReducer.apply(Self.poll("spotify:track:c", progress: 300), to: &u, nowMs: 200_000)
        #expect(first.change == .trackChanged(queueIndex: 6) && first.needsNextWindow)
        let again = SpotifyConnectReducer.apply(Self.poll("spotify:track:c", progress: 1_300), to: &u, nowMs: 201_000)
        #expect(!again.needsNextWindow)
    }

    @Test func transportDecisions() {
        let slots: [SpotifyConnectSlot] = [.uri("x"), .skipped, .skipped, .uri("spotify:track:a"), .skipped,
                                           .uri("spotify:track:b"), .uri("spotify:track:c"), .skipped, .uri("spotify:track:d")]
        #expect(SpotifyConnectReducer.next(state: Self.state(position: 0), slots: slots, repeatAll: false) == .next)
        #expect(SpotifyConnectReducer.next(state: Self.state(position: 2), slots: slots, repeatAll: false) == .play(fromQueueIndex: 8))
        let end: [SpotifyConnectSlot] = Array(slots.prefix(7))
        #expect(SpotifyConnectReducer.next(state: Self.state(position: 2), slots: end, repeatAll: false) == .none)
        #expect(SpotifyConnectReducer.next(state: Self.state(position: 2), slots: end, repeatAll: true) == .play(fromQueueIndex: 0))

        #expect(SpotifyConnectReducer.previous(state: Self.state(position: 1, progress: 5_000), slots: slots, nowMs: 100_000) == .restart)
        #expect(SpotifyConnectReducer.previous(state: Self.state(position: 1, progress: 1_000), slots: slots, nowMs: 100_000) == .play(fromQueueIndex: 3))
        #expect(SpotifyConnectReducer.previous(state: Self.state(position: 0, progress: 1_000), slots: slots, nowMs: 100_000) == .play(fromQueueIndex: 0))
        #expect(SpotifyConnectReducer.remoteRepeat(repeatOne: true) == .track)
        #expect(SpotifyConnectReducer.remoteRepeat(repeatOne: false) == .off)
    }

    @Test func optimisticCommands() {
        var s = Self.state()
        SpotifyConnectReducer.setPlaying(false, &s, nowMs: 102_000)
        #expect(!s.isPlaying && s.progressMs == 12_000 && s.graceUntilMs == 102_000 + SpotifyConnectReducer.commandGraceMs)
        SpotifyConnectReducer.seek(to: 50_000, &s, nowMs: 103_000)
        #expect(s.positionMs(at: 110_000) == 50_000)
        SpotifyConnectReducer.advance(&s, durationMs: 150_000, nowMs: 104_000)
        #expect(s.windowPosition == 1 && s.queueIndex == 5 && s.isPlaying && s.progressMs == 0)
    }
}

@Suite("Spotify Connect: client")
struct SpotifyConnectClientTests {
    actor Store: SpotifyTokenStore {
        var tokens: SpotifyTokens? = SpotifyTokens(accessToken: "A1", refreshToken: "R1", expiresAtMs: Int64.max / 2)
        func load() async -> SpotifyTokens? { tokens }
        func save(_ tokens: SpotifyTokens) async throws { self.tokens = tokens }
        func clear() async { tokens = nil }
    }

    func make(now: Box<Int64> = Box(0), _ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse)
        -> (SpotifyConnectClient, FixtureHTTPClient, Store, Box<[Int64]>) {
        let http = FixtureHTTPClient(handler)
        let store = Store()
        let session = SpotifySession(http: http, store: store, clientId: { "cid" }, sha256: { TestSHA256.hash($0) },
                                     randomBytes: { Array(repeating: 0, count: $0) }, nowMs: { 0 })
        let sleeps = Box<[Int64]>([])
        return (SpotifyConnectClient(http: http, session: session, nowMs: { now.value }, sleep: { ms in sleeps.mutate { $0.append(ms) } }),
                http, store, sleeps)
    }

    @Test func refreshesOnceOn401AndSavesTheRotatedToken() async throws {
        let calls = Box(0)
        let (client, http, store, _) = make { request in
            if request.url.hasPrefix("https://accounts.spotify.com") {
                return HTTPResponse(statusCode: 200, text: #"{"access_token":"A2","refresh_token":"R2","expires_in":3600}"#)
            }
            calls.mutate { $0 += 1 }
            if calls.value == 1 { return HTTPResponse(statusCode: 401, text: #"{"error":{"status":401,"message":"The access token expired"}}"#) }
            return HTTPResponse(statusCode: 200, text: #"{"devices":[{"id":"d","name":"Echo","type":"Speaker","is_active":false}]}"#)
        }
        let devices = try await client.devices()
        #expect(devices.map(\.name) == ["Echo"])
        let api = http.requests.filter { $0.url.hasPrefix("https://api.spotify.com") }
        #expect(api.map { $0.header("Authorization")! } == ["Bearer A1", "Bearer A2"])
        #expect(await store.tokens?.refreshToken == "R2")
    }

    @Test func rateLimitGatesLaterCalls() async throws {
        let now = Box<Int64>(1_000)
        let (client, http, _, _) = make(now: now) { _ in HTTPResponse(statusCode: 429, headers: [HTTPHeader("Retry-After", "4")], text: "") }
        await #expect(throws: SpotifyConnectError.rateLimited(retryAfterMs: 4000)) { try await client.pause(deviceId: "d") }
        now.value = 2_000
        await #expect(throws: SpotifyConnectError.rateLimited(retryAfterMs: 3000)) { try await client.next(deviceId: "d") }
        #expect(http.requests.count == 1)
        #expect(await client.retryAfterRemainingMs == 3000)
        #expect(try await client.searchTracks("q") == nil)
    }

    @Test func startTransfersInactiveDevicesAndRetriesNoActiveDevice() async throws {
        let plays = Box(0)
        let (client, http, _, sleeps) = make { request in
            if request.url.hasPrefix("https://api.spotify.com/v1/me/player/play") {
                plays.mutate { $0 += 1 }
                if plays.value == 1 {
                    return HTTPResponse(statusCode: 404, text: #"{"error":{"status":404,"message":"Player command failed: No active device found","reason":"NO_ACTIVE_DEVICE"}}"#)
                }
            }
            return HTTPResponse(statusCode: 204, text: "")
        }
        try await client.start(deviceId: "echo", isActive: false, uris: ["spotify:track:a"], positionMs: 5_000)
        let urls = http.requests.map { "\($0.method.rawValue) \($0.url)" }
        #expect(urls == ["PUT https://api.spotify.com/v1/me/player",
                         "PUT https://api.spotify.com/v1/me/player/play?device_id=echo",
                         "PUT https://api.spotify.com/v1/me/player/play?device_id=echo"])
        #expect(sleeps.value == [SpotifyConnectClient.wakeRetryDelayMs])

        // An active device plays straight away; a 403 Premium answer surfaces as is.
        let (client2, http2, _, _) = make { _ in
            HTTPResponse(statusCode: 403, text: #"{"error":{"status":403,"message":"Player command failed: Premium required","reason":"PREMIUM_REQUIRED"}}"#)
        }
        await #expect(throws: SpotifyConnectError.premiumRequired) {
            try await client2.start(deviceId: "echo", isActive: true, uris: ["spotify:track:a"], positionMs: 0)
        }
        #expect(http2.requests.count == 1)
    }

    @Test func playbackStateHandlesNoContentAndTransportErrors() async throws {
        let (client, _, _, _) = make { _ in HTTPResponse(statusCode: 204, text: "") }
        #expect(try await client.playbackState() == nil)
        let (client2, _, _, _) = make { _ in throw HTTPTransportError(message: "offline") }
        await #expect(throws: SpotifyConnectError.network("IOException: offline")) { try await client2.playbackState() }
        let (client3, _, _, _) = make { _ in
            HTTPResponse(statusCode: 200, text: #"{"tracks":{"items":[{"id":"4iV5W9uYEdYUVa79Axb7Rh","name":"S","type":"track"}]}}"#)
        }
        #expect(try await client3.searchTracks("q")?.first?.id == "4iV5W9uYEdYUVa79Axb7Rh")
    }
}
