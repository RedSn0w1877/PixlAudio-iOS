import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

/// Android `SpotifySnapshotRetentionTest` (all nine cases) plus the matcher pass (`SpotifyMatchWorker`), the import
/// helpers and the in-memory store's DAO semantics.
struct SpotifySnapshotRetentionTests {
    actor Tokens: SpotifyTokenStore {
        var tokens: SpotifyTokens? = SpotifyTokens(accessToken: "test-authorization", refreshToken: "R", expiresAtMs: Int64.max / 2)
        func load() async -> SpotifyTokens? { tokens }
        func save(_ tokens: SpotifyTokens) async throws { self.tokens = tokens }
        func clear() async { tokens = nil }
    }

    static func saved(_ id: String) -> SpotifyPlaylistRow { SpotifyPlaylistRow(id: id, name: id, coverUrl: nil, songCount: 2, lastSyncTime: 123) }

    static func make(store: InMemorySpotifyLibraryStore,
                     _ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) -> (SpotifyLibrarySync, FixtureHTTPClient) {
        let http = FixtureHTTPClient(handler)
        let session = SpotifySession(http: http, store: Tokens(), clientId: { "cid" }, sha256: { TestSHA256.hash($0) },
                                     randomBytes: { Array(repeating: 0, count: $0) }, nowMs: { 0 })
        let api = SpotifyWebAPI(http: http, session: session, nowMs: { 0 }, sleep: { _ in })
        return (SpotifyLibrarySync(api: api, store: store, sha256: { TestSHA256.hash($0) }, nowMs: { 1_000 }), http)
    }

    static func offset(_ request: HTTPRequest) -> Int {
        guard let range = request.url.range(of: "offset=") else { return 0 }
        return Int(request.url[range.upperBound...].prefix { $0.isNumber }) ?? 0
    }

    static let error503 = HTTPResponse(statusCode: 503, text: "{}")

    @Test func catalogDiscoveriesSurviveSuccessfulPlaylistPruning() async throws {
        let store = InMemorySpotifyLibraryStore(playlists: [Self.saved("remote"), Self.saved("deleted"), Self.saved(SpotifyLibrary.browsePlaylistId),
                                                            Self.saved(SpotifyLibrary.likedSongsPlaylistId)])
        let (sync, _) = Self.make(store: store) { _ in
            HTTPResponse(statusCode: 200, text: #"{"items":[{"id":"remote","name":"Remote"}],"total":1}"#)
        }
        _ = try await sync.syncUserPlaylists()
        let log = await store.log
        #expect(log.filter { $0 == "deleteSongs:deleted" }.count == 1)
        #expect(!log.contains("deleteSongs:\(SpotifyLibrary.browsePlaylistId)"))
        #expect(!log.contains("deletePlaylist:\(SpotifyLibrary.browsePlaylistId)"))
        #expect(!log.contains("deleteSongs:\(SpotifyLibrary.likedSongsPlaylistId)"))
        let ids = await store.playlists.map { $0.id }
        #expect(ids.sorted() == ["remote", SpotifyLibrary.browsePlaylistId, SpotifyLibrary.likedSongsPlaylistId].sorted())
        // `lastSyncTime` is kept from the saved row (resumable passes).
        #expect(await store.playlists.first { $0.id == "remote" }?.lastSyncTime == 123)
    }

    @Test func failedFirstPlaylistPageNeverPrunesTheSavedLibrary() async throws {
        let store = InMemorySpotifyLibraryStore(playlists: [Self.saved("a")])
        let (sync, _) = Self.make(store: store) { _ in Self.error503 }
        await #expect(throws: SpotifySyncError.self) { try await sync.syncUserPlaylists() }
        #expect(await store.log.isEmpty)
    }

    @Test func failedLaterPlaylistPageCannotReplaceACompleteSnapshotWithItsPrefix() async throws {
        let store = InMemorySpotifyLibraryStore(playlists: [Self.saved("a")])
        let (sync, http) = Self.make(store: store) { request in
            Self.offset(request) == 0
                ? HTTPResponse(statusCode: 200, text: #"{"items":[{"id":"first","name":"First"}],"total":2,"offset":0,"limit":1,"next":"https://api.spotify.com/v1/me/playlists?offset=1"}"#)
                : Self.error503
        }
        await #expect(throws: SpotifySyncError.self) { try await sync.syncUserPlaylists() }
        #expect(http.requests.filter { Self.offset($0) == 1 }.count == 1)
        #expect(await store.log.isEmpty)
    }

    @Test func shortPageWithANextCursorStillFetchesTheRemainingPlaylists() async throws {
        let store = InMemorySpotifyLibraryStore()
        let (sync, _) = Self.make(store: store) { request in
            Self.offset(request) == 0
                ? HTTPResponse(statusCode: 200, text: #"{"items":[{"id":"first","name":"First"}],"total":2,"offset":0,"limit":1,"next":"https://api.spotify.com/v1/me/playlists?offset=1"}"#)
                : HTTPResponse(statusCode: 200, text: #"{"items":[{"id":"second","name":"Second"}],"total":2,"offset":1}"#)
        }
        #expect(try await sync.syncUserPlaylists().map(\.id) == ["first", "second"])
    }

    @Test func failedLikedSongsFetchPreservesExistingMembership() async throws {
        let store = InMemorySpotifyLibraryStore()
        let (sync, _) = Self.make(store: store) { _ in Self.error503 }
        await #expect(throws: SpotifySyncError.self) { try await sync.syncLikedSongs(known: [:]) }
        #expect(await store.log.isEmpty)
    }

    @Test func playlistAccessDeniedPreservesAlreadyDownloadedSongs() async throws {
        let store = InMemorySpotifyLibraryStore()
        let (sync, _) = Self.make(store: store) { _ in HTTPResponse(statusCode: 403, text: "{}") }
        await #expect(throws: SpotifySyncError.self) { try await sync.syncPlaylistSongs("saved", known: [:]) }
        #expect(await sync.playlistAccessDenied)
        #expect(await store.log.isEmpty)
    }

    @Test func partialLikedSongsSnapshotIsNotPublishedAfterALaterFailure() async throws {
        let store = InMemorySpotifyLibraryStore()
        let (sync, http) = Self.make(store: store) { request in
            Self.offset(request) == 0
                ? HTTPResponse(statusCode: 200, text: #"{"items":[{}],"total":2,"limit":1,"offset":0,"next":"https://api.spotify.com/v1/me/tracks?offset=1"}"#)
                : Self.error503
        }
        await #expect(throws: SpotifySyncError.self) { try await sync.syncLikedSongs(known: [:]) }
        #expect(http.requests.filter { $0.url.contains("/v1/me/tracks") && Self.offset($0) == 1 }.count == 1)
        #expect(await store.log.isEmpty)
    }

    @Test func partialPlaylistContentsSurviveBothFilteredAndFallbackFailures() async throws {
        let store = InMemorySpotifyLibraryStore()
        let (sync, http) = Self.make(store: store) { request in
            Self.offset(request) == 0
                ? HTTPResponse(statusCode: 200, text: #"{"items":[{}],"total":2,"limit":1,"offset":0,"next":"https://api.spotify.com/v1/playlists/saved/items?offset=1"}"#)
                : Self.error503
        }
        await #expect(throws: SpotifySyncError.self) { try await sync.syncPlaylistSongs("saved", known: [:]) }
        let second = http.requests.filter { $0.url.contains("/v1/playlists/saved/items") && Self.offset($0) == 1 }
        #expect(second.count == 2)
        #expect(second[0].url.contains("fields=") && !second[1].url.contains("fields="))
        #expect(await store.log.isEmpty)
    }

    @Test func successfulExplicitlyEmptyLikedSnapshotCanClearMembership() async throws {
        let store = InMemorySpotifyLibraryStore()
        let (sync, _) = Self.make(store: store) { _ in HTTPResponse(statusCode: 200, text: #"{"items":[],"total":0}"#) }
        #expect(try await sync.syncLikedSongs(known: [:]) == 0)
        #expect(await store.log.filter { $0 == "replaceSongs:\(SpotifyLibrary.likedSongsPlaylistId):0" }.count == 1)
    }
}

struct SpotifyLibrarySyncTests {
    static func record(_ spotifyId: String, playlist: String = "p", state: SpotifyMatchState = .pending, video: String? = nil) -> SpotifyTrackRecord {
        SpotifyTrackRecord(id: "\(playlist)_\(spotifyId)", spotifyId: spotifyId, playlistId: playlist, title: "T \(spotifyId)",
                           artist: "A", album: "Al", albumId: nil, durationMs: 200_000, albumArtUrl: nil, isrc: nil, dateAdded: 0,
                           matchedVideoId: video, matchScore: video == nil ? nil : 0.9, matchState: state)
    }

    @Test func resyncCarriesKnownMatchesAndFetchesGenresOnce() async throws {
        let store = InMemorySpotifyLibraryStore(songs: [Self.record("t1", playlist: "pl", state: .matched, video: "vid1")])
        let (sync, http) = SpotifySnapshotRetentionTests.make(store: store) { request in
            if request.url.contains("/v1/artists?") {
                return HTTPResponse(statusCode: 200, text: #"{"artists":[{"id":"a1","name":"A","genres":["indie pop","pop"]},null]}"#)
            }
            return HTTPResponse(statusCode: 200, text: """
            {"items":[{"added_at":"2024-05-01T10:00:00Z","item":{"id":"t1","name":"One","duration_ms":1000,"type":"track","artists":[{"id":"a1","name":"A"}],"album":{"id":"al","name":"Al","images":[{"url":"https://i/1"}]}}},
                      {"item":{"id":"t2","name":"Two","type":"episode"}},
                      {"item":{"id":"t3","name":"Three","type":"track","is_local":false,"artists":[{"id":"a2","name":"B"}]}}],
             "total":3,"offset":0}
            """)
        }
        #expect(try await sync.syncPlaylistSongs("pl") == 2)
        let rows = await store.songs
        #expect(rows.map(\.id) == ["pl_t1", "pl_t3"])
        #expect(rows[0].matchedVideoId == "vid1" && rows[0].matchState == .matched)
        #expect(rows[0].genre == "indie pop" && rows[1].genre == nil)
        #expect(rows[0].dateAdded == 1_714_557_600_000 && rows[1].dateAdded == 1_000)
        #expect(http.requests.filter { $0.url.contains("/v1/artists?") }.count == 1)
    }

    @Test func syncAllFlushesAndResumes() async throws {
        let flushes = Box(0)
        let store = InMemorySpotifyLibraryStore(playlists: [SpotifyPlaylistRow(id: "done", name: "Done", coverUrl: nil, songCount: 1, lastSyncTime: 900)])
        let http = FixtureHTTPClient { request in
            if request.url.contains("/v1/me/playlists") {
                return HTTPResponse(statusCode: 200, text: #"{"items":[{"id":"done","name":"Done"},{"id":"new","name":"New","tracks":{"total":1}}],"total":2}"#)
            }
            if request.url.contains("/v1/me/tracks") { return HTTPResponse(statusCode: 200, text: #"{"items":[],"total":0}"#) }
            if request.url.hasSuffix("/v1/me") { return HTTPResponse(statusCode: 200, text: #"{"id":"me","display_name":"Hoa"}"#) }
            return HTTPResponse(statusCode: 200, text: #"{"items":[{"item":{"id":"x","name":"X"}}],"total":1}"#)
        }
        let session = SpotifySession(http: http, store: SpotifySnapshotRetentionTests.Tokens(), clientId: { "cid" }, sha256: { TestSHA256.hash($0) },
                                     randomBytes: { Array(repeating: 0, count: $0) }, nowMs: { 0 })
        let api = SpotifyWebAPI(http: http, session: session, nowMs: { 0 }, sleep: { _ in })
        let sync = SpotifyLibrarySync(api: api, store: store, sha256: { TestSHA256.hash($0) }, nowMs: { 1_000 },
                                      flush: { flushes.mutate { $0 += 1 } })
        let profile = Box<String?>(nil)
        let result = try await sync.syncAll(resumeInterrupted: true, onProfile: { profile.value = $0.displayName })
        #expect(profile.value == "Hoa")
        #expect(result == SpotifySyncResult(playlistCount: 3, syncedSongCount: 1, failedPlaylistCount: 0, isComplete: true))
        // "done" was fetched 100 ms ago in this pass: skipped. Liked Songs (never synced) flushed, then the final flush.
        #expect(!http.requests.contains { $0.url.contains("/v1/playlists/done/") })
        #expect(flushes.value == 2)

        let stopped = try await sync.syncAll(shouldContinue: { false })
        #expect(!stopped.isComplete)
    }

    @Test func importAndRemoveFromTheExploredCatalogue() async throws {
        let store = InMemorySpotifyLibraryStore(songs: [Self.record("liked1", playlist: SpotifyLibrary.likedSongsPlaylistId)])
        let (sync, _) = SpotifySnapshotRetentionTests.make(store: store) { _ in HTTPResponse(statusCode: 200, text: #"{"artists":[]}"#) }
        let tracks = [SpotifyTrack(id: "liked1", name: "L"), SpotifyTrack(id: "new1", name: "N"), SpotifyTrack(id: nil, name: "?")]
        #expect(try await sync.importTracks(tracks) == 1)
        let browse = await store.playlists.first { $0.id == SpotifyLibrary.browsePlaylistId }
        #expect(browse?.name == "Saved from Spotify" && browse?.songCount == 2)

        #expect(try await sync.removeFromExploredCatalog(spotifyId: "liked1") == false)
        #expect(try await sync.removeFromExploredCatalog(spotifyId: "new1") == true)
        #expect(await store.songs.map(\.id).sorted() == ["\(SpotifyLibrary.browsePlaylistId)_liked1", "\(SpotifyLibrary.likedSongsPlaylistId)_liked1"].sorted())

        let yt = YouTubeSearchResult(videoId: "dQw4w9WgXcQ", title: "Song", artist: "", album: nil, durationSeconds: 210)
        #expect(try await sync.importYouTubeMusicTracks([yt]) == 1)
        let row = await store.songs.last!
        #expect(row.matchState == .matched && row.matchedVideoId == "dQw4w9WgXcQ" && row.spotifyId.count == 22)
    }

    @Test func artistAlbumsAreDistinctAndNewestFirst() {
        let albums = [
            SpotifyAlbumFull(id: "1", name: "Same", releaseDate: "2020", totalTracks: 10),
            SpotifyAlbumFull(id: "2", name: "same", releaseDate: "2021", totalTracks: 10),
            SpotifyAlbumFull(id: "3", name: "Other", releaseDate: "2022-01-01", totalTracks: 3),
            SpotifyAlbumFull(id: nil, name: "No id", releaseDate: "2030"),
            SpotifyAlbumFull(id: "4", name: "Undated"),
            SpotifyAlbumFull(id: "5", name: "Tie", releaseDate: "2020", totalTracks: 1),
        ]
        #expect(SpotifyLibrarySync.distinctAlbums(albums).compactMap(\.id) == ["3", "1", "5", "4"])
    }

    @Test func freshnessWindow() {
        #expect(!SpotifyLibrarySync.isFreshlySynced(nil, passStartedAt: 10))
        #expect(!SpotifyLibrarySync.isFreshlySynced(0, passStartedAt: 10))
        #expect(SpotifyLibrarySync.isFreshlySynced(10, passStartedAt: 10 + SpotifyLibrarySync.resumeWindowMs - 1))
        #expect(!SpotifyLibrarySync.isFreshlySynced(10, passStartedAt: 10 + SpotifyLibrarySync.resumeWindowMs))
    }
}

struct SpotifyMatchRunnerTests {
    struct Flaky: Error {}

    @Test func passMatchesMarksUnmatchedAndKeepsErroredPending() async throws {
        let store = InMemorySpotifyLibraryStore(songs: [
            SpotifyLibrarySyncTests.record("a"), SpotifyLibrarySyncTests.record("a", playlist: "q"),
            SpotifyLibrarySyncTests.record("b"), SpotifyLibrarySyncTests.record("c"),
            SpotifyLibrarySyncTests.record("d", state: .manual, video: "mine"),
        ])
        let runner = SpotifyMatchRunner(store: store, matcher: { track in
            switch track.title {
            case "T a": return TrackMatch(videoId: "va", score: 0.9, candidateTitle: "A")
            case "T b": return nil
            default: throw Flaky()
            }
        }, nowMs: { 0 }, sleep: { _ in })
        let result = try await runner.run()
        #expect(result.totalPending == 3 && result.matched == 1 && result.failed == 1 && result.errored == 1)
        #expect(result.retryLater && !result.moreWork)
        let rows = await store.songs
        #expect(rows.filter { $0.spotifyId == "a" }.allSatisfy { $0.matchedVideoId == "va" && $0.matchState == .matched })
        #expect(rows.first { $0.spotifyId == "b" }?.matchState == .unmatched)
        #expect(rows.first { $0.spotifyId == "c" }?.matchState == .pending)
        #expect(rows.first { $0.spotifyId == "d" }?.matchedVideoId == "mine")

        // A user's "Find audio" re-queues the unmatched ones first.
        let again = SpotifyMatchRunner(store: store, matcher: { _ in TrackMatch(videoId: "v", score: 0.7, candidateTitle: "") },
                                       nowMs: { 0 }, sleep: { _ in })
        let second = try await again.run(retryFailed: true)
        #expect(second.totalPending == 2 && second.matched == 2 && !second.retryLater)
    }

    @Test func fullyFailedBatchStopsThePass() async throws {
        var songs: [SpotifyTrackRecord] = []
        for i in 0..<100 { songs.append(SpotifyLibrarySyncTests.record(String(format: "s%03d", i))) }
        let store = InMemorySpotifyLibraryStore(songs: songs)
        let calls = Box(0)
        let runner = SpotifyMatchRunner(store: store, matcher: { _ in
            calls.mutate { $0 += 1 }
            throw Flaky()
        }, nowMs: { 0 }, sleep: { _ in })
        let result = try await runner.run()
        #expect(result.retryLater && result.done == SpotifyMatchRunner.batchSize && calls.value == SpotifyMatchRunner.batchSize)
    }

    @Test func budgetAndConcurrency() async throws {
        var songs: [SpotifyTrackRecord] = []
        for i in 0..<60 { songs.append(SpotifyLibrarySyncTests.record(String(format: "s%03d", i))) }
        let store = InMemorySpotifyLibraryStore(songs: songs)
        let clock = Box<Int64>(0)
        let inFlight = Box(0), peak = Box(0)
        let runner = SpotifyMatchRunner(store: store, matcher: { _ in
            inFlight.mutate { $0 += 1 }
            peak.mutate { $0 = max($0, inFlight.value) }
            try await Task.sleep(nanoseconds: 2_000_000)
            inFlight.mutate { $0 -= 1 }
            return nil
        }, nowMs: { clock.value }, sleep: { _ in clock.mutate { $0 += SpotifyMatchRunner.runBudgetMs } })
        let result = try await runner.run(isPlaybackActive: { true })
        #expect(result.done == SpotifyMatchRunner.batchSize && result.moreWork)
        #expect(peak.value <= SpotifyMatchRunner.concurrencyPlaying)
    }
}
