import Foundation
import Testing
import PixlFoundation
import PixlModel
import PixlLyrics
@testable import PixlNet

@Suite("Lyrics providers over HTTP")
struct LyricsProviderTests {
    func song(title: String = "Northern Lights", artist: String = "Nova", album: String = "First Light", duration: Int64 = 180_000,
              spotifyId: String? = nil) -> Song {
        Song(id: "1", title: title, artist: artist, artistId: 1, album: album, albumId: 1, path: "", contentUriString: "",
             albumArtUriString: nil, duration: duration, mimeType: nil, bitrate: nil, sampleRate: nil, spotifyId: spotifyId)
    }

    static let synced = "[00:01.00]First line\n[00:05.00]Second line"

    func lrclibRecord(id: Int, name: String = "Northern Lights", artist: String = "Nova", duration: Double = 180, synced: String? = Self.synced) -> String {
        let syncedJSON = synced.map { "\"" + $0.replacingOccurrences(of: "\n", with: "\\n") + "\"" } ?? "null"
        return #"{"id":\#(id),"name":"\#(name)","artistName":"\#(artist)","albumName":"First Light","duration":\#(duration),"plainLyrics":"First line\nSecond line","syncedLyrics":\#(syncedJSON)}"#
    }

    @Test func requestBuilders() {
        let get = LyricsRequests.lrclibGet(song: song(title: "A & B", duration: 180_999))
        #expect(get.url == "https://lrclib.net/api/get?track_name=A%20%26%20B&artist_name=Nova&album_name=First%20Light&duration=180")
        #expect(get.header("User-Agent") == "PixlAudio/1.0 (iOS; Music Player)")
        let search = LyricsRequests.lrclibSearch(LrcLibSearchRequest(name: "x", query: "q", trackName: nil, artistName: "Nova"))
        #expect(search.url == "https://lrclib.net/api/search?q=q&artist_name=Nova")
        let amll = LyricsRequests.amll("lyrics/search", [("musicName", "夜"), ("pageSize", "10")])
        #expect(amll.url == "https://api.amll.dev/v1/lyrics/search?musicName=%E5%A4%9C&pageSize=10" && amll.timeout == 8)
        #expect(amll.header("User-Agent") == LyricsHTTP.userAgent)
        #expect(LyricsRequests.netease("search/get", [("s", "a b")]).url == "https://music.163.com/api/search/get?s=a%20b")
    }

    @Test func boundedCatalogBodies() throws {
        #expect(try LyricsRequests.catalogJSON(HTTPResponse(statusCode: 500, text: "{}")) == nil)
        #expect(try LyricsRequests.catalogJSON(HTTPResponse(statusCode: 200, headers: [HTTPHeader("Content-Length", "2000000")], text: "{}")) == nil)
        #expect(try LyricsRequests.catalogJSON(HTTPResponse(statusCode: 200, text: #"{"code":200}"#))?["code"] != nil)
        #expect(throws: LyricsCatalogError.self) { try LyricsRequests.catalogJSON(HTTPResponse(statusCode: 200, text: "[1]")) }
    }

    @Test func retryPolicy() async throws {
        let attempts = Box(0)
        let sleeps = Box<[Int64]>([])
        let value = try await LyricsRetry.run(sleep: { ms in sleeps.mutate { $0.append(ms) } }) { () async throws -> Int in
            attempts.mutate { $0 += 1 }
            if attempts.value < 3 { throw LyricsHTTPError(statusCode: 503) }
            return 9
        }
        #expect(value == 9 && sleeps.value == [500, 1000])
        await #expect(throws: LyricsHTTPError.self) {
            try await LyricsRetry.run(sleep: { _ in }) { () async throws -> Int in throw LyricsHTTPError(statusCode: 404) }
        }
        #expect(LyricsRetry.isRetryable(HTTPTransportError(message: "x")) && LyricsRetry.isRetryable(LyricsHTTPError(statusCode: 429)))
        #expect(!LyricsRetry.isRetryable(LyricsHTTPError(statusCode: 400)))
    }

    @Test func fastStrategiesTakeTheFirstNonEmptyBatch() async throws {
        let record = lrclibRecord(id: 7)
        let http = FixtureHTTPClient { request in
            if request.url.contains("q=") { return HTTPResponse(statusCode: 200, text: "[\(record),\(record)]") }
            try await Task.sleep(nanoseconds: 20_000_000)
            return HTTPResponse(statusCode: 200, text: "[]")
        }
        let client = LrcLibClient(http: http, sleep: { _ in })
        let results = await client.runStrategiesFast([LrcLibSearchRequest(name: "a", trackName: "t"), LrcLibSearchRequest(name: "b", query: "q")])
        #expect(results.map(\.id) == [7])
        #expect(await client.runStrategiesFast([]).isEmpty)
    }

    @Test func automaticFetchRanksAndParses() async throws {
        let http = FixtureHTTPClient { request in
            HTTPResponse(statusCode: 200, text: "[\(lrclibRecord(id: 1, duration: 400)),\(lrclibRecord(id: 2))]")
        }
        let client = LrcLibClient(http: http, nowMs: { 1_000_000 }, sleep: { _ in })
        let result = try #require(try await client.fetchAutomatic(song: song()))
        #expect(result.record.id == 2 && result.lyrics.areFromRemote)
        #expect(result.lyrics.synced?.map(\.line) == ["First line", "Second line"])
        #expect(http.requests.allSatisfy { $0.url.hasPrefix("https://lrclib.net/api/search?") })
    }

    @Test func automaticFetchUsesTheTitleOnlyFallback() async throws {
        let http = FixtureHTTPClient { request in
            if request.url == "https://lrclib.net/api/search?track_name=Northern%20Lights" {
                return HTTPResponse(statusCode: 200, text: "[\(lrclibRecord(id: 3))]")
            }
            return HTTPResponse(statusCode: 200, text: "[]")
        }
        let client = LrcLibClient(http: http, sleep: { _ in })
        let result = try await client.fetchAutomatic(song: song(title: "Northern Lights - Remastered"))
        #expect(http.requests.contains { $0.url == "https://lrclib.net/api/search?track_name=Northern%20Lights" })
        _ = result
    }

    @Test func rateLimitDelaysBackToBackCalls() async throws {
        let sleeps = Box<[Int64]>([])
        let client = LrcLibClient(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: "[]") }, nowMs: { 5_000 },
                                  sleep: { ms in sleeps.mutate { $0.append(ms) } })
        _ = try await client.fetchAutomatic(song: song())
        _ = try await client.fetchAutomatic(song: song())
        #expect(sleeps.value.contains(100))
    }

    @Test func remoteFetchFallsBackToTheExactMatch() async throws {
        let http = FixtureHTTPClient { request in
            if request.url.hasPrefix("https://lrclib.net/api/get?") { return HTTPResponse(statusCode: 200, text: lrclibRecord(id: 11)) }
            return HTTPResponse(statusCode: 200, text: "[]")
        }
        let client = LrcLibClient(http: http, sleep: { _ in })
        #expect(try await client.fetchFromRemote(song: song())?.record.id == 11)
        let notFound = LrcLibClient(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 404, text: "") }, sleep: { _ in })
        #expect(try await notFound.fetchFromRemote(song: song()) == nil)
        let candidates = await client.searchCandidates(song: song())
        #expect(candidates.query == "Northern Lights Nova" && candidates.results.isEmpty)
        let manual = await client.searchManual(title: " Northern Lights ", artist: " ")
        #expect(manual.query == "Northern Lights")
    }

    @Test func amllLooksUpBySpotifyIdThenByMetadata() async throws {
        let ttml = #"<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div><p begin=\"00:01.000\" end=\"00:03.000\"><span begin=\"00:01.000\" end=\"00:02.000\">Hel</span><span begin=\"00:02.000\" end=\"00:03.000\">lo</span></p></div></body></tt>"#
        let spotifyId = "4uLU6hMCjMI75M1A2tKUQC"
        let http = FixtureHTTPClient { request in
            if request.url.contains("spotifyId=") {
                return HTTPResponse(statusCode: 200, text: #"{"data":{"spotifyIds":["\#(spotifyId)"],"format":"ttml","lyrics":"\#(ttml)"}}"#)
            }
            return HTTPResponse(statusCode: 404)
        }
        let lyrics = await AmllLyricsClient(http: http).find(song: song(spotifyId: spotifyId))
        #expect(lyrics?.areFromRemote == true && (lyrics?.synced?.first?.words?.count ?? 0) == 2)
        #expect(http.requests.first?.url == "https://api.amll.dev/v1/lyrics/get?spotifyId=\(spotifyId)")

        let byMetadata = FixtureHTTPClient { request in
            if request.url.contains("lyrics/search") {
                return HTTPResponse(statusCode: 200, text: #"{"data":{"items":[{"id":"42","musicNames":["Northern Lights"],"artistNames":["Nova"],"albumNames":["First Light"]}]}}"#)
            }
            if request.url.hasSuffix("lyrics/get?id=42") {
                return HTTPResponse(statusCode: 200, text: #"{"data":{"format":"ttml","lyrics":"\#(ttml)"}}"#)
            }
            return HTTPResponse(statusCode: 404)
        }
        #expect(await AmllLyricsClient(http: byMetadata).find(song: song())?.synced?.isEmpty == false)
        #expect(byMetadata.requests.map(\.url) == ["https://api.amll.dev/v1/lyrics/search?musicName=Northern%20Lights&artistName=Nova&pageSize=10",
                                                   "https://api.amll.dev/v1/lyrics/get?id=42"])
        #expect(await AmllLyricsClient(http: byMetadata).find(song: song(album: "")) == nil)
        #expect(await AmllLyricsClient(http: FixtureHTTPClient { _ in throw HTTPTransportError(message: "down") }).find(song: song()) == nil)
    }

    @Test func neteaseMatchesTheRecordingAndReadsYRC() async throws {
        let yrc = #"[1000,2000](1000,1000,0)Hel(2000,1000,0)lo\n"#
        let http = FixtureHTTPClient { request in
            if request.url.contains("search/get") {
                return HTTPResponse(statusCode: 200, text: #"{"code":200,"result":{"songs":[{"id":99,"name":"Northern Lights","duration":180500,"artists":[{"name":"Nova"}],"album":{"name":"First Light"}},{"id":5,"name":"Other","duration":1,"artists":[{"name":"X"}],"album":{"name":"Y"}}]}}"#)
            }
            if request.url.contains("song/lyric/v1?id=99") {
                return HTTPResponse(statusCode: 200, text: #"{"code":200,"yrc":{"lyric":"\#(yrc)"}}"#)
            }
            return HTTPResponse(statusCode: 404)
        }
        let lyrics = await NeteaseLyricsClient(http: http).find(song: song())
        #expect(lyrics?.areFromRemote == true && lyrics?.synced?.first?.line == "Hello")
        #expect(http.requests.first?.url == "https://music.163.com/api/search/get?type=1&offset=0&limit=10&s=Northern%20Lights%20Nova")
        #expect(http.requests.last?.url == "https://music.163.com/api/song/lyric/v1?id=99&kv=0&yv=0&rv=0&tv=0")
        #expect(await NeteaseLyricsClient(http: http).find(song: song(duration: 0)) == nil)
        let opaque = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: #"{"code":200,"result":"opaque"}"#) }
        #expect(await NeteaseLyricsClient(http: opaque).find(song: song()) == nil)
        let rejected = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: #"{"code":403,"result":{"songs":[]}}"#) }
        #expect(await NeteaseLyricsClient(http: rejected).find(song: song()) == nil)
    }

    @Test func catalogSearchPrefersWordSyncedResults() async throws {
        let ttmlHTTP = FixtureHTTPClient { _ in HTTPResponse(statusCode: 404) }
        let lrclibHTTP = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: "[\(lrclibRecord(id: 4))]") }
        let neteaseHTTP = FixtureHTTPClient { request in
            if request.url.contains("search/get") {
                return HTTPResponse(statusCode: 200, text: #"{"code":200,"result":{"songs":[{"id":99,"name":"Northern Lights","duration":180000,"artists":[{"name":"Nova"}],"album":{"name":"First Light"}}]}}"#)
            }
            return HTTPResponse(statusCode: 200, text: #"{"code":200,"yrc":{"lyric":"[1000,2000](1000,1000,0)Hel(2000,1000,0)lo\n"}}"#)
        }
        let search = LyricsCatalogSearch(amll: AmllLyricsClient(http: ttmlHTTP), netease: NeteaseLyricsClient(http: neteaseHTTP),
                                         lrclib: LrcLibClient(http: lrclibHTTP, sleep: { _ in }))
        let result = try #require(await search.find(song: song(), syncedOnly: true))
        #expect(result.source == "NetEase YRC")
        let lineOnly = LyricsCatalogSearch(amll: AmllLyricsClient(http: ttmlHTTP), netease: NeteaseLyricsClient(http: ttmlHTTP),
                                           lrclib: LrcLibClient(http: lrclibHTTP, sleep: { _ in }))
        #expect(await lineOnly.find(song: song(), syncedOnly: true)?.source == "LRCLIB")
        let nothing = LyricsCatalogSearch(amll: AmllLyricsClient(http: ttmlHTTP), netease: NeteaseLyricsClient(http: ttmlHTTP),
                                          lrclib: LrcLibClient(http: ttmlHTTP, sleep: { _ in }))
        #expect(await nothing.find(song: song(), syncedOnly: false) == nil)
    }
}
