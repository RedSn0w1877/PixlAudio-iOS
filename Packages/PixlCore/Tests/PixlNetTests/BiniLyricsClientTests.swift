import Foundation
import Testing
import PixlFoundation
import PixlModel
import PixlLyrics
@testable import PixlNet

/// `BiniLyricsClient` over a scripted transport (no network): the ISRC lookup, the title search, redirects and the
/// host allowlist, back-off, remembered results, and its place in the catalog race. All lyrics are invented.
@Suite("BiniLyrics over HTTP")
struct BiniLyricsClientTests {
    static let isrc = "QZAA12500042"

    static func song(title: String = "Glass Harbor", artist: String = "Nova Reed", duration: Int64 = 200_000) -> Song {
        Song(id: "7", title: title, artist: artist, artistId: 1, album: "Tidal Rooms", albumId: 1, path: "",
             contentUriString: "", albumArtUriString: nil, duration: duration, mimeType: nil, bitrate: nil, sampleRate: nil)
    }

    static func result(_ title: String = "Glass Harbor", isrc: String = isrc, seconds: Int = 200, timing: String = "word",
                       url: String? = nil) -> String {
        let link = url ?? "https://lrc.red/s/\(isrc).ttml"
        return #"{"album_name":"Tidal Rooms","artist_name":"Nova Reed","duration":\#(seconds),"id":"\#(isrc)","isrc":"\#(isrc)","lyricsUrl":"\#(link)","timing_type":"\#(timing)","track_name":"\#(title)"}"#
    }

    static func results(_ items: [String]) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [HTTPHeader("Content-Type", "application/json")],
                     text: #"{"results":[\#(items.joined(separator: ","))],"source":"HIT-LRC-RED","total":\#(items.count)}"#)
    }

    static let empty = HTTPResponse(statusCode: 200, text: #"{"results":[],"source":"MISS-LRC-RED","total":0}"#)

    static let ttml = #"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:lrc="http://lrc.red/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" lrc:timing="Word" xml:lang="en"><head><metadata><ttm:agent type="person" xml:id="v1"/></metadata></head><body dur="0:30.000"><div><p begin="1.000" end="3.000" lrc:key="L1" ttm:agent="v1"><span begin="1.000" end="1.500">Salt</span> <span begin="1.500" end="2.000">on</span> <span begin="2.000" end="2.400">the</span> <span begin="2.400" end="3.000">glass</span></p><p begin="4.000" end="6.000" lrc:key="L2" ttm:agent="v1"><span begin="4.000" end="4.600">Har</span><span begin="4.600" end="5.200">bor</span> <span begin="5.200" end="6.000">lights</span></p></div></body></tt>"#
    static let lineTTML = #"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:lrc="http://lrc.red/lyric-ttml-internal" lrc:timing="Line"><body><div><p begin="1.000" end="3.000">Salt on the glass</p></div></body></tt>"#

    static func redirect(to location: String) -> HTTPResponse {
        HTTPResponse(statusCode: 307, headers: [HTTPHeader("Location", location)], text: "<html>307</html>")
    }

    /// The real flow: the documented endpoint answers 307 to lrc.red, which returns the results.
    static func service(isrcResults: [String], searchResults: [String], document: String = ttml) -> FixtureHTTPClient {
        FixtureHTTPClient { request in
            let url = request.url
            if url.hasPrefix("https://lyrics-api.binimum.org/?") {
                return redirect(to: "https://lrc.red/api/v1?" + url.dropFirst("https://lyrics-api.binimum.org/?".count))
            }
            if url.hasPrefix("https://lrc.red/api/v1?isrc=") { return isrcResults.isEmpty ? empty : results(isrcResults) }
            if url.hasPrefix("https://lrc.red/api/v1?track=") { return searchResults.isEmpty ? empty : results(searchResults) }
            if url.hasPrefix("https://lrc.red/s/") {
                return HTTPResponse(statusCode: 200, headers: [HTTPHeader("Content-Type", "application/ttml+xml")], text: document)
            }
            return HTTPResponse(statusCode: 404)
        }
    }

    @Test func isrcHitFollowsTheRedirectAndParsesTheDocument() async throws {
        let http = Self.service(isrcResults: [Self.result()], searchResults: [])
        let client = BiniLyricsClient(http: http)
        let match = try #require(await client.find(song: Self.song(), isrc: "qz-aa1-25-00042"))
        #expect(match.candidate.isrc == Self.isrc && match.document == Self.ttml)
        let doc = try #require(match.lyrics.document)
        #expect(doc.metadata.source == "BiniLyrics" && doc.lines.map(\.text) == ["Salt on the glass", "Harbor lights"])
        #expect(match.lyrics.synced?[1].words?.map(\.startsNewWord) == [true, false, true])
        #expect(http.requests.map(\.url) == ["https://lyrics-api.binimum.org/?isrc=QZAA12500042",
                                              "https://lrc.red/api/v1?isrc=QZAA12500042",
                                              "https://lrc.red/s/QZAA12500042.ttml"])
        #expect(http.requests.allSatisfy { $0.timeout == BiniLyricsClient.requestTimeoutSeconds })
        #expect(http.requests.last?.header("Accept")?.hasPrefix("application/ttml+xml") == true)
        // Remembered: the same song costs no second lookup.
        #expect(await client.find(song: Self.song(), isrc: Self.isrc) == match)
        #expect(http.requests.count == 3)
    }

    @Test func missingIsrcHitFallsBackToTheTitleSearch() async throws {
        let decoy = Self.result("Glass Harbor (Night Remix)", isrc: "QZAA12500099", seconds: 201)
        let original = Self.result(isrc: "QZAA12500001", seconds: 201, timing: "line")
        let http = Self.service(isrcResults: [], searchResults: [decoy, original], document: Self.lineTTML)
        let match = try #require(await BiniLyricsClient(http: http).find(song: Self.song(), isrc: Self.isrc))
        #expect(match.candidate.isrc == "QZAA12500001" && match.lyrics.synced?.first?.words == nil)
        #expect(http.requests.map(\.url).contains("https://lrc.red/api/v1?track=Glass%20Harbor&artist=Nova%20Reed"))
        #expect(http.requests.last?.url == "https://lrc.red/s/QZAA12500001.ttml")

        // No ISRC at all: straight to the search.
        let searchOnly = Self.service(isrcResults: [], searchResults: [original], document: Self.lineTTML)
        #expect(await BiniLyricsClient(http: searchOnly).find(song: Self.song(), isrc: nil) != nil)
        #expect(searchOnly.requests.first?.url == "https://lyrics-api.binimum.org/?track=Glass%20Harbor&artist=Nova%20Reed")
    }

    @Test func noConfidentMatchFetchesNoDocument() async throws {
        let http = Self.service(isrcResults: [], searchResults: [Self.result(seconds: 230)])
        #expect(await BiniLyricsClient(http: http).find(song: Self.song(), isrc: nil) == nil)
        #expect(!http.requests.contains { $0.url.hasPrefix("https://lrc.red/s/") })
        // A document that runs far past the song is the wrong recording.
        let short = Self.service(isrcResults: [Self.result(seconds: 3)], searchResults: [])
        #expect(await BiniLyricsClient(http: short).find(song: Self.song(duration: 3_000), isrc: Self.isrc) == nil)
    }

    @Test func refusesHopsOffTheAllowlist() async throws {
        let offList = FixtureHTTPClient { request in
            if request.url.hasPrefix("https://lyrics-api.binimum.org/") { return Self.redirect(to: "https://example.com/api/v1?isrc=x") }
            return Self.results([Self.result()])
        }
        #expect(await BiniLyricsClient(http: offList).find(song: Self.song(), isrc: Self.isrc) == nil)
        #expect(offList.requests.allSatisfy { BiniLyricsMatching.isAllowedURL($0.url) })

        let downgrade = FixtureHTTPClient { _ in Self.redirect(to: "http://lrc.red/api/v1?isrc=x") }
        #expect(await BiniLyricsClient(http: downgrade).find(song: Self.song(), isrc: Self.isrc) == nil)
        #expect(downgrade.requests.allSatisfy { $0.url.hasPrefix("https://") })

        let loop = FixtureHTTPClient { _ in Self.redirect(to: "https://lrc.red/again") }
        #expect(await BiniLyricsClient(http: loop).find(song: Self.song(), isrc: nil) == nil)
        #expect(loop.requests.count == BiniLyricsClient.maxRedirects + 1)

        let offListDocument = Self.service(isrcResults: [Self.result(url: "https://example.com/s/x.ttml")], searchResults: [])
        #expect(await BiniLyricsClient(http: offListDocument).find(song: Self.song(), isrc: Self.isrc) == nil)
        #expect(!offListDocument.requests.contains { $0.url.contains("example.com") })
    }

    @Test func oversizedBodiesAreDropped() async throws {
        let big = String(repeating: "x", count: BiniLyricsMatching.maxDocumentBytes + 1)
        let http = Self.service(isrcResults: [Self.result()], searchResults: [], document: big)
        #expect(await BiniLyricsClient(http: http).find(song: Self.song(), isrc: Self.isrc) == nil)
        let declared = FixtureHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [HTTPHeader("Content-Length", "99999999")], text: "{}")
        }
        #expect(await BiniLyricsClient(http: declared).find(song: Self.song(), isrc: Self.isrc) == nil)
    }

    @Test func throttlingPausesTheSource() async throws {
        let clock = Box<Int64>(1_000_000)
        let status = Box(429)
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: status.value, headers: [HTTPHeader("Retry-After", "120")]) }
        let client = BiniLyricsClient(http: http, nowMs: { clock.value })
        #expect(await client.find(song: Self.song(), isrc: Self.isrc) == nil)
        #expect(await client.isPaused && http.requests.count == 1)
        // Paused: no request at all, and the miss is not remembered.
        #expect(await client.find(song: Self.song(title: "Other"), isrc: nil) == nil)
        #expect(http.requests.count == 1)
        clock.value += 121_000
        #expect(await !client.isPaused)
        status.value = 503
        #expect(await client.find(song: Self.song(), isrc: Self.isrc) == nil)
        #expect(http.requests.count == 2)
        // Back-off doubles from 30 s, but Retry-After (120 s) is longer here.
        clock.value += 60_000
        #expect(await client.isPaused)
        clock.value += 61_000
        #expect(await !client.isPaused)
        // Transport errors do not pause and are not remembered.
        let failing = FixtureHTTPClient { _ in throw HTTPTransportError(message: "offline") }
        let offline = BiniLyricsClient(http: failing)
        #expect(await offline.find(song: Self.song(), isrc: Self.isrc) == nil)
        #expect(await offline.find(song: Self.song(), isrc: Self.isrc) == nil)
        #expect(await !offline.isPaused && failing.requests.count == 2)
    }

    @Test func cancellationEndsTheLookupQuietly() async throws {
        let http = FixtureHTTPClient { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return Self.empty
        }
        let client = BiniLyricsClient(http: http)
        let task = Task { await client.find(song: Self.song(), isrc: Self.isrc) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test func catalogRacePutsBiniLyricsFirst() async throws {
        let nothing = FixtureHTTPClient { _ in HTTPResponse(statusCode: 404) }
        let slowLrclib = FixtureHTTPClient { _ in
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return HTTPResponse(statusCode: 200, text: #"[{"id":4,"name":"Glass Harbor","artistName":"Nova Reed","albumName":"Tidal Rooms","duration":200,"plainLyrics":"a","syncedLyrics":"[00:01.00]Salt on the glass"}]"#)
        }
        let words = Self.service(isrcResults: [Self.result()], searchResults: [])
        let race = LyricsCatalogSearch(bini: BiniLyricsClient(http: words), amll: AmllLyricsClient(http: nothing),
                                       netease: NeteaseLyricsClient(http: nothing), lrclib: LrcLibClient(http: slowLrclib, sleep: { _ in }))
        let started = Date()
        let result = try #require(await race.find(song: Self.song(), isrc: Self.isrc, syncedOnly: false))
        #expect(result.source == "BiniLyrics" && result.rawContent == Self.ttml)
        // Word-synced BiniLyrics ends the race without waiting for the slow catalog.
        #expect(Date().timeIntervalSince(started) < 2.5)

        // A line-synced BiniLyrics result loses to word timing elsewhere and beats line timing elsewhere.
        let lineBini = Self.service(isrcResults: [Self.result(timing: "line")], searchResults: [], document: Self.lineTTML)
        let neteaseWords = FixtureHTTPClient { request in
            if request.url.contains("search/get") {
                return HTTPResponse(statusCode: 200, text: #"{"code":200,"result":{"songs":[{"id":99,"name":"Glass Harbor","duration":200000,"artists":[{"name":"Nova Reed"}],"album":{"name":"Tidal Rooms"}}]}}"#)
            }
            return HTTPResponse(statusCode: 200, text: #"{"code":200,"yrc":{"lyric":"[1000,2000](1000,1000,0)Salt (2000,1000,0)glass\n"}}"#)
        }
        let lrclib = FixtureHTTPClient { _ in
            HTTPResponse(statusCode: 200, text: #"[{"id":4,"name":"Glass Harbor","artistName":"Nova Reed","albumName":"Tidal Rooms","duration":200,"plainLyrics":"a","syncedLyrics":"[00:01.00]Salt on the glass"}]"#)
        }
        let wordElsewhere = LyricsCatalogSearch(bini: BiniLyricsClient(http: lineBini), amll: AmllLyricsClient(http: nothing),
                                                netease: NeteaseLyricsClient(http: neteaseWords), lrclib: LrcLibClient(http: lrclib, sleep: { _ in }))
        #expect(await wordElsewhere.find(song: Self.song(), isrc: Self.isrc, syncedOnly: false)?.source == "NetEase YRC")
        let lineEverywhere = LyricsCatalogSearch(bini: BiniLyricsClient(http: lineBini), amll: AmllLyricsClient(http: nothing),
                                                 netease: NeteaseLyricsClient(http: nothing), lrclib: LrcLibClient(http: lrclib, sleep: { _ in }))
        #expect(await lineEverywhere.find(song: Self.song(), isrc: Self.isrc, syncedOnly: false)?.source == "BiniLyrics")
        // Without BiniLyrics the race is the old one.
        let withoutBini = LyricsCatalogSearch(amll: AmllLyricsClient(http: nothing), netease: NeteaseLyricsClient(http: nothing),
                                              lrclib: LrcLibClient(http: lrclib, sleep: { _ in }))
        #expect(await withoutBini.find(song: Self.song(), syncedOnly: true)?.source == "LRCLIB")
    }
}
