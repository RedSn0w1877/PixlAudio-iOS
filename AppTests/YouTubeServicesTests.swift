import Foundation
import PixlLibrary
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// Stage 11 app-side logic without the network: the Bearer and base.js transports, cookie handling, song identity,
/// URL expiry, the sparse stream cache and the playable-URL order (download → complete cache → stream).
@MainActor
final class YouTubeServicesTests: XCTestCase {
    // MARK: Transports

    func testBearerOnlyForTVHTML5PlayerRequestsWithoutCookie() {
        let body = InnerTubeRequests.playerBody(videoId: "dQw4w9WgXcQ", profile: InnerTubeContexts.tvHTML5,
                                                visitorData: "v", authenticated: false)
        let tv = InnerTubeRequests.post(path: "player", body: body, profile: InnerTubeContexts.tvHTML5)
        XCTAssertTrue(GoogleBearerHTTPClient.wantsBearer(tv))
        let vision = InnerTubeRequests.post(path: "player", body: body, profile: InnerTubeContexts.visionOS)
        XCTAssertFalse(GoogleBearerHTTPClient.wantsBearer(vision))
        var withCookie = tv
        withCookie.setHeader("cookie", "SAPISID=x")
        XCTAssertFalse(GoogleBearerHTTPClient.wantsBearer(withCookie))
        let search = InnerTubeRequests.post(path: "search", body: body, profile: InnerTubeContexts.tvHTML5)
        XCTAssertFalse(GoogleBearerHTTPClient.wantsBearer(search))
    }

    func testKeyIsRemovedForBearerRequests() {
        XCTAssertEqual(GoogleBearerHTTPClient.removingKey("https://www.youtube.com/youtubei/v1/player?key=ABC&prettyPrint=false"),
                       "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
        XCTAssertEqual(GoogleBearerHTTPClient.removingKey("https://x/y?key=ABC"), "https://x/y")
        XCTAssertEqual(GoogleBearerHTTPClient.removingKey("https://x/y"), "https://x/y")
    }

    func testBaseJsPlayerId() {
        XCTAssertEqual(BaseJsCachingHTTPClient.playerId(
            fromBaseJsURL: SignatureCipher.baseJsURL(playerId: "6450230e")), "6450230e")
        XCTAssertNil(BaseJsCachingHTTPClient.playerId(fromBaseJsURL: "https://www.youtube.com/iframe_api"))
        XCTAssertNil(BaseJsCachingHTTPClient.playerId(fromBaseJsURL: "https://www.youtube.com/s/player/ab/x/base.js"))
    }

    func testBaseJsIsServedFromDiskTheSecondTime() async throws {
        let inner = CountingHTTPClient()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = BaseJsCachingHTTPClient(inner: inner, directory: directory)
        let request = HTTPRequest(url: SignatureCipher.baseJsURL(playerId: "6450230e"))
        _ = try await client.send(request)
        let second = try await client.send(request)
        XCTAssertEqual(second.text, "var a=1;")
        XCTAssertEqual(inner.count, 1)
        _ = try await client.send(HTTPRequest(url: SignatureCipher.iframeApiURL))
        XCTAssertEqual(inner.count, 2)
    }

    // MARK: Cookies and identity

    func testCookieNormalisationAndSAPISID() {
        XCTAssertEqual(YouTubeCookieText.normalize("Cookie: SID=a;  HSID=b\nSAPISID=c/d=; junk"),
                       "SID=a; HSID=b; SAPISID=c/d=")
        XCTAssertTrue(YouTubeCookieText.hasSAPISID("SID=a; SAPISID=c"))
        XCTAssertFalse(YouTubeCookieText.hasSAPISID("SID=a; __Secure-3PAPISID=c"))
        XCTAssertFalse(YouTubeCookieText.hasSAPISID("SAPISID="))
    }

    func testCookieHeaderFromWebViewCookies() {
        let header = YouTubeCookieText.header(from: [
            (domain: ".youtube.com", name: "SAPISID", value: "s"),
            (domain: ".google.com", name: "NID", value: "n"),
            (domain: "music.youtube.com", name: "PREF", value: "p"),
            (domain: ".youtube.com", name: "SAPISID", value: "dup"),
        ])
        XCTAssertEqual(header, "SAPISID=s; PREF=p")
    }

    func testSongIdentity() {
        let yt = DemoLibrary.songs[0]
        var song = yt
        song.id = "yt:dQw4w9WgXcQ"
        song.contentUriString = ""
        XCTAssertEqual(YouTubeSongIdentity.videoId(for: song), "dQw4w9WgXcQ")
        song.id = "sp:abc"
        song.contentUriString = "pixlstream://AbC_-12345x"
        XCTAssertEqual(YouTubeSongIdentity.videoId(for: song), "AbC_-12345x")
        song.contentUriString = "file:///x.m4a"
        XCTAssertNil(YouTubeSongIdentity.videoId(for: song))
        XCTAssertEqual(YouTubeSongIdentity.videoId(from: URL(string: "pixlstream://AbC_-12345x")!), "AbC_-12345x")
        XCTAssertNil(YouTubeSongIdentity.videoId(from: URL(string: "https://AbC_-12345x")!))
        XCTAssertNil(YouTubeSongIdentity.videoId(from: URL(string: "pixlstream://short")!))
    }

    func testYouTubeMusicTrackBecomesALibrarySong() {
        let track = YouTubeMusicTrack(videoId: "dQw4w9WgXcQ", title: "Song", artist: "", album: nil,
                                      thumbnailUrl: "https://i.ytimg.com/x.jpg", durationMs: 213_000)
        let song = YouTubeSongFactory.song(track, now: 1000)
        XCTAssertEqual(song.id, "yt:dQw4w9WgXcQ")
        XCTAssertEqual(song.contentUriString, "pixlstream://dQw4w9WgXcQ")
        XCTAssertEqual(song.artist, "Unknown Artist")
        XCTAssertEqual(song.album, "Unknown Album")
        XCTAssertLessThan(song.albumId, 0)
        XCTAssertLessThan(song.artistId, 0)
        XCTAssertTrue(LibrarySorting.isOnline(song))
    }

    func testURLExpiry() {
        let expiry = InnerTubeService.expiry(of: "https://r1.googlevideo.com/videoplayback?expire=2000000000&itag=140")
        XCTAssertEqual(expiry.timeIntervalSince1970, 2_000_000_000 - 120, accuracy: 0.5)
        XCTAssertGreaterThan(InnerTubeService.expiry(of: "https://x/y").timeIntervalSinceNow, 3 * 3600)
    }

    // MARK: Stream cache

    func testSparseCacheWritesReadsAndCompletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = StreamCache(directory: directory)
        let id = "dQw4w9WgXcQ"
        await cache.setInfo(id, contentLength: 10, contentType: "audio/mp4", itag: "140")
        await cache.write(id, offset: 6, data: Data([6, 7, 8, 9]))
        let missing = await cache.read(id, 0..<4)
        XCTAssertNil(missing)
        let tail = await cache.read(id, 6..<10)
        XCTAssertEqual(tail, Data([6, 7, 8, 9]))
        let notYet = await cache.isComplete(id)
        XCTAssertFalse(notYet)
        let next = await cache.nextCachedStart(id, after: 0)
        XCTAssertEqual(next, 6)
        await cache.write(id, offset: 0, data: Data([0, 1, 2, 3, 4, 5, 99, 99])) // overlaps; capped at the length
        let complete = await cache.isComplete(id)
        XCTAssertTrue(complete)
        let all = await cache.read(id, 0..<10)
        XCTAssertEqual(all, Data([0, 1, 2, 3, 4, 5, 99, 99, 8, 9]))

        // A second cache over the same folder sees the metadata (a relaunch).
        let reopened = StreamCache(directory: directory)
        let url = await reopened.completeFileURL(id)
        XCTAssertEqual(url?.lastPathComponent, "\(id).m4a")

        // Another itag is another file: the bytes go.
        await reopened.setInfo(id, contentLength: 10, contentType: "audio/mp4", itag: "141")
        let reset = await reopened.isComplete(id)
        XCTAssertFalse(reset)
    }

    func testResolverPrefersDownloadsThenCompleteCacheThenStream() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = StreamCache(directory: directory)
        let resolver = StreamingPlayableURLResolver(base: DefaultPlayableURLResolver(), cache: cache)
        var song = DemoLibrary.songs[0]
        song.id = "yt:Zz9_-Zz9_-Z"
        song.contentUriString = "pixlstream://Zz9_-Zz9_-Z"
        let streamed = await resolver.playableURL(for: song)
        XCTAssertEqual(streamed?.absoluteString, "pixlstream://Zz9_-Zz9_-Z")
        await cache.setInfo("Zz9_-Zz9_-Z", contentLength: 2, contentType: "audio/mp4", itag: nil)
        await cache.write("Zz9_-Zz9_-Z", offset: 0, data: Data([1, 2]))
        let cached = await resolver.playableURL(for: song)
        XCTAssertEqual(cached?.isFileURL, true)
        XCTAssertEqual(cached?.lastPathComponent, "Zz9_-Zz9_-Z.m4a")
        // Local songs go to the base resolver.
        let local = DemoLibrary.songs[0]
        let localURL = await resolver.playableURL(for: local)
        let baseURL = DefaultPlayableURLResolver.url(for: local)
        XCTAssertEqual(localURL, baseURL)
    }
}

/// Answers every request with a small script and counts the calls.
nonisolated final class CountingHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        increment()
        return HTTPResponse(statusCode: 200, text: "var a=1;")
    }

    private func increment() {
        lock.lock()
        calls += 1
        lock.unlock()
    }
}
