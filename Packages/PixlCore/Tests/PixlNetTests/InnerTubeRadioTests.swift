import Foundation
import Testing
import PixlFoundation
import PixlModel
@testable import PixlNet

/// The radio parsers against saved YouTube Music responses (`Fixtures/innertube`, the files Android's
/// `InnerTubeMusicParsersTest` reads: cut by its `tools/brain/cut_fixtures.py` from anonymous captures of famous
/// public tracks). Each `<name>.expected.json` was written by that script's own plain extraction, not by a parser,
/// so a parser bug cannot hide behind its own output. Copy the files again from the Android repo when they change.
@Suite("YouTube Music radios, the Related tab and artist pages")
struct InnerTubeRadioTests {
    private func text(_ name: String) throws -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let url = try #require(Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures/innertube"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func resource(_ name: String) throws -> JSONValue {
        try JSONParser().parse(try text(name))
    }

    private func str(_ object: JSONValue, _ key: String) -> String? {
        guard let value = object[key], !value.isNull else { return nil }
        switch value {
        case .string(let s): return s
        case .number(let literal): return literal
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    private func int(_ object: JSONValue, _ key: String) -> Int { Int(object[key]?.int64Value ?? 0) }

    private func artists(_ row: JSONValue) -> [RadioArtistRef] {
        (row["artists"]?.arrayValue ?? []).map { RadioArtistRef(name: str($0, "name") ?? "", channelId: str($0, "id")) }
    }

    private func expectRows(_ expected: [JSONValue], _ actual: [RadioRow], _ what: String) {
        #expect(expected.count == actual.count, "\(what): row count")
        for (i, e) in expected.enumerated() where i < actual.count {
            let a = actual[i]
            let at: Comment = "\(what) row \(i) (\(str(e, "title") ?? ""))"
            #expect(str(e, "videoId") == a.videoId, at)
            #expect(str(e, "title") == a.title, at)
            #expect(artists(e) == a.artists, at)
            #expect(str(e, "album") == a.album, at)
            #expect(str(e, "albumId") == a.albumBrowseId, at)
            #expect(int(e, "year") == a.year, at)
            #expect(int(e, "durationSec") == a.durationSec, at)
            #expect(str(e, "thumb") == a.thumbnailUrl, at)
            #expect((str(e, "explicit") == "true") == a.explicit, at)
            #expect(str(e, "type") == a.kind.rawValue, at)
            #expect(str(e, "plays").flatMap { Int64($0) } == a.playCount, at)
        }
    }

    @discardableResult
    private func expectRadio(_ name: String) throws -> RadioPage {
        let expected = try resource("\(name).expected.json")
        let page = InnerTubeRadio.parseRadio(try resource("\(name).json"))
        expectRows(expected["rows"]?.arrayValue ?? [], page.rows, name)
        #expect(str(expected, "continuation") == page.continuation, "\(name): continuation")
        #expect(str(expected, "relatedBrowseId") == page.relatedBrowseId, "\(name): related tab")
        let chips = (expected["chips"]?.arrayValue ?? []).map {
            RadioChip(label: str($0, "label") ?? "", playlistId: str($0, "playlistId") ?? "", params: str($0, "params"))
        }
        #expect(chips == page.chips, "\(name): chips")
        return page
    }

    private func isJunk(_ rows: [RadioRow], _ seed: String?, _ ids: Set<String>) -> Bool {
        RadioRules.isJunkRadio(rows: rows, seedVideoId: seed, seedArtistIds: ids, fold: { $0.lowercased() })
    }

    @Test func songRadio() throws {
        let page = try expectRadio("radio_song")
        #expect(page.rows.count == 50)
        #expect(page.rows.first?.videoId == "J7p4bzqLvCw")
        #expect(page.rows.allSatisfy { $0.isOfficialAudio })
        #expect(page.rows.allSatisfy { (60...900).contains($0.durationSec) })
        #expect(page.rows.allSatisfy { !$0.artists.isEmpty && $0.artists[0].channelId != nil })
        #expect(page.continuation != nil)
        #expect(page.relatedBrowseId == "MPTRt_4U7yfKKFZLv-1")
        #expect(!page.chips.isEmpty)
        #expect(!isJunk(page.rows, "J7p4bzqLvCw", []))
    }

    @Test func continuationPage() throws {
        let page = try expectRadio("radio_song_cont1")
        #expect(page.rows.count == 49)
        #expect(page.continuation != nil)
        #expect(page.relatedBrowseId == nil)
    }

    @Test func pagesAreMergedByVideoId() throws {
        let first = InnerTubeRadio.parseRadio(try resource("radio_song.json"))
        let second = InnerTubeRadio.parseRadio(try resource("radio_song_cont1.json"))
        var pager = RadioPager()
        #expect(pager.accept(first) == 50)
        #expect(pager.nextToken != nil)
        let added = pager.accept(second)
        let overlap = second.rows.filter { row in first.rows.contains { $0.videoId == row.videoId } }.count
        #expect(added == second.rows.count - overlap)
        #expect(pager.rows.count == 50 + added)
        #expect(Set(pager.rows.map(\.videoId)).count == pager.rows.count)
        #expect(pager.newPerPage == [50, added])

        // The same page again brings nothing new, twice in a row: the chain stops though a token exists.
        #expect(pager.accept(second) == 0)
        #expect(pager.nextToken != nil)
        #expect(pager.accept(second) == 0)
        #expect(pager.nextToken == nil)
    }

    @Test func thePagerStopsAfterThreeContinuationsAndOnAMissingToken() {
        func page(_ prefix: String, _ token: String?) -> RadioPage {
            RadioPage(rows: (0..<10).map { RadioRow(videoId: "\(prefix)\($0)", title: "t") }, continuation: token)
        }
        var capped = RadioPager()
        capped.accept(page("a", "t1"))
        #expect(capped.nextToken == "t1")
        capped.accept(page("b", "t2"))
        capped.accept(page("c", "t3"))
        #expect(capped.nextToken == "t3")
        capped.accept(page("d", "t4"))
        #expect(capped.nextToken == nil, "three continuations is the cap")
        #expect(capped.rows.count == 40)

        var ended = RadioPager()
        ended.accept(page("a", nil))
        #expect(ended.nextToken == nil)
    }

    @Test func vietnameseRadioKeepsDiacriticsAndTheBylineYear() throws {
        let page = try expectRadio("radio_vpop")
        let row = try #require(page.rows.count > 1 ? page.rows[1] : nil)
        #expect(row.title == "Ch\u{00FA}ng Ta C\u{1EE7}a Hi\u{1EC7}n T\u{1EA1}i")
        #expect(row.artists.first?.name == "S\u{01A1}n T\u{00F9}ng M-TP")
        #expect(row.artists.first?.channelId == "UC3muIvzjhubNpJ4Pn_0kCQw")
        #expect(row.albumBrowseId == "MPREb_zxR43A84eOG")
        #expect(row.year == 2020)
        #expect(row.durationSec == 302)
        #expect(row.kind == .atv)
    }

    @Test func artistRadioIsHealthyForItsOwnArtist() throws {
        let page = try expectRadio("radio_artist")
        #expect(page.rows.count == 50)
        let weeknd = "UClYV6hHlupm_S_ObS1W-DYw"
        #expect(!isJunk(page.rows, "VtCJ_ABaHQY", [weeknd]))
        // Asked about an artist who is not in it, the same list is junk.
        #expect(isJunk(page.rows, "VtCJ_ABaHQY", ["UC_nobody"]))
    }

    @Test func aShortRadioIsJunk() throws {
        let page = try expectRadio("radio_short")
        #expect(page.rows.count == 28)
        #expect(isJunk(page.rows, page.rows.first?.videoId, []))
    }

    @Test func fortyRowsWithNothingByTheSeedArtistInTheFirst25IsJunk() {
        func row(_ i: Int, _ channel: String?) -> RadioRow {
            RadioRow(videoId: "v\(i)", title: "t\(i)",
                     artists: [RadioArtistRef(name: "Artist \(channel ?? "nil")", channelId: channel)], kind: .atv)
        }
        let seed = row(0, "UCseed")
        let strangers = (0..<45).map { row($0 + 1, "UCother\($0 % 7)") }
        #expect(isJunk([seed] + strangers, "v0", []))

        // The seed artist at row 26 is outside the window; at row 25 it is inside.
        var late = strangers
        late[25] = row(26, "UCseed")
        #expect(isJunk([seed] + late, "v0", []))
        var inTime = strangers
        inTime[24] = row(25, "UCseed")
        #expect(!isJunk([seed] + inTime, "v0", []))

        // A row without an artist id is kept but can never satisfy the test.
        var unlinked = strangers
        unlinked[3] = row(4, nil)
        #expect(isJunk([seed] + unlinked, "v0", []))
    }

    @Test func musicVideoRowsAreParsedButAreNotOfficialAudio() throws {
        let page = try expectRadio("radio_music_videos")
        #expect(!page.rows.isEmpty)
        #expect(!page.rows.contains { $0.isOfficialAudio })
        #expect(page.rows.contains { $0.kind == .omv })
    }

    @Test func aResponseWithoutTheRendererIsNoData() throws {
        let page = try expectRadio("radio_invalid_id")
        #expect(page.rows.isEmpty)
        #expect(page.continuation == nil)
        // Even without a queue panel the response names the Related tab: the first fallback.
        #expect(page.relatedBrowseId != nil)
        #expect(InnerTubeRadio.parseRadio(try JSONParser().parse("{}")).rows.isEmpty)
        #expect(InnerTubeRadio.parseRadio(try JSONParser().parse("[1,2]")).rows.isEmpty)
        #expect(InnerTubeRadio.parseRelated(try JSONParser().parse("{}")) == .empty)
        #expect(InnerTubeRadio.parseArtistPage(try JSONParser().parse("{}")) == .empty)
        #expect(InnerTubeRadio.parseRadio(text: "not json") == nil)
    }

    @Test func wrapperRowsAreUnwrappedUnplayableRowsSkippedAMissingTypeIsUnknown() throws {
        let panel = #"""
        {"contents":{"x":{"playlistPanelRenderer":{"contents":[
          {"playlistPanelVideoWrapperRenderer":{
            "primaryRenderer":{"playlistPanelVideoRenderer":{"videoId":"primary0001","title":{"runs":[{"text":"Wrapped"}]},
              "longBylineText":{"runs":[{"text":"Someone"},{"text":" \#u{2022} "},{"text":"An Album"},{"text":" \#u{2022} "},{"text":"1999"}]},
              "lengthText":{"runs":[{"text":"1:02:03"}]}}},
            "counterpart":[{"counterpartRenderer":{"playlistPanelVideoRenderer":{"videoId":"video000001","title":{"runs":[{"text":"The video"}]}}}}]}},
          {"playlistPanelVideoRenderer":{"videoId":"blocked0001","title":{"runs":[{"text":"Gone"}]},"unplayableText":{"runs":[{"text":"x"}]}}},
          {"playlistPanelVideoRenderer":{"title":{"runs":[{"text":"No id"}]}}}
        ]}}}}
        """#
        let page = InnerTubeRadio.parseRadio(try JSONParser().parse(panel))
        #expect(page.rows.map(\.videoId) == ["primary0001"])
        let row = try #require(page.rows.first)
        #expect(row.kind == .unknown)
        #expect(!row.isOfficialAudio)
        // No run links to an artist: the plain run before the first bullet is the artist, without an id.
        #expect(row.artists == [RadioArtistRef(name: "Someone", channelId: nil)])
        #expect(row.year == 1999)
        #expect(row.durationSec == 3723)
    }

    @Test func relatedTab() throws {
        let expected = try resource("related.expected.json")
        let page = InnerTubeRadio.parseRelated(try resource("related.json"))
        expectRows(expected["youMightAlsoLike"]?.arrayValue ?? [], page.youMightAlsoLike, "also like")
        expectRows(expected["otherPerformances"]?.arrayValue ?? [], page.otherPerformances, "other performances")
        let similar = (expected["similarArtists"]?.arrayValue ?? []).map {
            RadioArtistRef(name: str($0, "name") ?? "", channelId: str($0, "id"))
        }
        #expect(similar == page.similarArtists)
        #expect(page.youMightAlsoLike.count == 20)
        #expect(page.otherPerformances.count == 8)
        #expect(page.similarArtists.count == 10)
        // Related rows carry no length.
        #expect(page.youMightAlsoLike.allSatisfy { $0.durationSec == 0 })
        #expect(page.youMightAlsoLike.first?.artists.map(\.name) == ["Post Malone", "Swae Lee"])
    }

    @Test func artistPage() throws {
        let expected = try resource("artist_page.expected.json")
        let page = InnerTubeRadio.parseArtistPage(try resource("artist_page.json"))
        #expect(str(expected, "name") == page.name)
        let radio = try #require(expected["radio"])
        #expect(RadioEndpoint(videoId: str(radio, "videoId"), playlistId: str(radio, "playlistId") ?? "",
                              params: str(radio, "params")) == page.radio)
        #expect(page.radio == RadioEndpoint(videoId: "VtCJ_ABaHQY", playlistId: "RDEMHSpo_Uv9STIRtF73zMywLg", params: "wAEB"))
        expectRows(expected["topSongs"]?.arrayValue ?? [], page.topSongs, "top songs")
        #expect(page.topSongs.count == 5)
        #expect(page.topSongs.first?.playCount == 3_400_000_000)
        func releases(_ key: String) -> [ReleaseRef] {
            (expected[key]?.arrayValue ?? []).map {
                ReleaseRef(browseId: str($0, "browseId") ?? "", title: str($0, "title") ?? "", year: int($0, "year"))
            }
        }
        #expect(releases("albums") == page.albums)
        #expect(releases("singles") == page.singles)
        #expect(page.albums.count == 10)
        #expect(page.singles.count == 10)
        let fans = (expected["fansAlsoLike"]?.arrayValue ?? []).map {
            RadioArtistRef(name: str($0, "name") ?? "", channelId: str($0, "id"))
        }
        #expect(fans == page.fansAlsoLike)
        #expect(page.fansAlsoLike.count == 10)
    }

    @Test func clocksAndPlayCounts() {
        #expect(InnerTubeRadio.parseClock("5:02") == 302)
        #expect(InnerTubeRadio.parseClock("1:02:03") == 3723)
        #expect(InnerTubeRadio.parseClock("") == 0)
        #expect(InnerTubeRadio.parseClock("live") == 0)
        #expect(InnerTubeRadio.parseClock("5:123") == 0)
        #expect(InnerTubeRadio.parsePlayCount("47M plays") == 47_000_000)
        #expect(InnerTubeRadio.parsePlayCount("3.4B plays") == 3_400_000_000)
        #expect(InnerTubeRadio.parsePlayCount("812 views") == 812)
        #expect(InnerTubeRadio.parsePlayCount("1.5K plays") == 1_500)
        #expect(InnerTubeRadio.parsePlayCount("The Weeknd") == nil)
        #expect(InnerTubeRadio.parsePlayCount("1.2.3 plays") == nil)
    }

    // MARK: Requests

    private func response(_ name: String) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, text: try text(name))
    }

    @Test func theRadioRequestsAreAnonymousAndCarryOnlyTheSeed() async throws {
        let radio = try response("radio_song.json")
        let http = FixtureHTTPClient { _ in radio }
        let client = InnerTubeRadioClient(http: http, visitorData: { "VISITOR" })
        let page = try #require(await client.nextRadio(videoId: "J7p4bzqLvCw", playlistId: "RDAMVMJ7p4bzqLvCw"))
        #expect(page.rows.count == 50)
        _ = await client.nextRadioContinuation("TOKEN")
        _ = await client.related(browseId: "MPTRt_x")

        let requests = http.requests
        #expect(requests.count == 3)
        #expect(requests[0].url == InnerTubeContexts.endpoint(InnerTubeContexts.webRemix, "next"))
        #expect(requests[2].url == InnerTubeContexts.endpoint(InnerTubeContexts.webRemix, "browse"))
        for request in requests {
            #expect(request.header("cookie") == nil)
            #expect(request.header("Authorization") == nil)
            #expect(request.header("Origin") == "https://music.youtube.com")
        }
        let context = #"{"context":{"client":{"clientName":"WEB_REMIX","clientVersion":"1.20260707.12.00","userAgent":"Mozilla\/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit\/537.36 (KHTML, like Gecko) Chrome\/133.0.0.0 Safari\/537.36","hl":"en","gl":"US","visitorData":"VISITOR"}}"#
        #expect(String(decoding: requests[0].body ?? Data(), as: UTF8.self)
                == context + #","videoId":"J7p4bzqLvCw","playlistId":"RDAMVMJ7p4bzqLvCw"}"#)
        #expect(String(decoding: requests[1].body ?? Data(), as: UTF8.self) == context + #","continuation":"TOKEN"}"#)
        #expect(String(decoding: requests[2].body ?? Data(), as: UTF8.self) == context + #","browseId":"MPTRt_x"}"#)
    }

    @Test func aFailedRequestIsNilNeverAnError() async {
        let failing = FixtureHTTPClient { _ in HTTPResponse(statusCode: 404, text: "") }
        let client = InnerTubeRadioClient(http: failing, visitorData: { nil })
        #expect(await client.nextRadio(videoId: "x", playlistId: "RDAMVMx") == nil)
        #expect(await client.artistPage(channelId: "UCx") == nil)
        let throwing = FixtureHTTPClient { _ in throw InnerTubeError("offline") }
        #expect(await InnerTubeRadioClient(http: throwing, visitorData: { nil }).related(browseId: "MPTRt_x") == nil)
    }

    @Test func theSourceMergesPagesAndRetriesAnEmptyRadioOnce() async throws {
        let first = try response("radio_song.json")
        let next = try response("radio_song_cont1.json")
        let http = FixtureHTTPClient { request in
            String(decoding: request.body ?? Data(), as: UTF8.self).contains("\"continuation\"") ? next : first
        }
        let source = YouTubeRadioSource(client: InnerTubeRadioClient(http: http, visitorData: { nil }),
                                        budget: HostBudget(clock: { 0 }))
        let fetched = try #require(await source.songRadio(videoId: "J7p4bzqLvCw", continuations: 1))
        #expect(fetched.requests == 2)
        #expect(fetched.rows.count > 50)
        #expect(Set(fetched.rows.map(\.videoId)).count == fetched.rows.count)
        #expect(fetched.relatedBrowseId == "MPTRt_4U7yfKKFZLv-1")
        #expect(!fetched.chips.isEmpty)

        // An empty radio: asked twice, then returned as an empty radio (the caller treats it as junk).
        let empty = try response("radio_invalid_id.json")
        let emptyHTTP = FixtureHTTPClient { _ in empty }
        let emptySource = YouTubeRadioSource(client: InnerTubeRadioClient(http: emptyHTTP, visitorData: { nil }),
                                             budget: HostBudget(clock: { 0 }))
        let nothing = try #require(await emptySource.songRadio(videoId: "bad", continuations: 0))
        #expect(nothing.rows.isEmpty && nothing.requests == 2)
        #expect(nothing.relatedBrowseId != nil)
        #expect(emptyHTTP.requests.count == 2)
    }

    @Test func theBudgetStopsRequestsWhenItIsSpent() async throws {
        let radio = try response("radio_song.json")
        let http = FixtureHTTPClient { _ in radio }
        let budget = HostBudget(capacity: 1, clock: { 0 })
        let source = YouTubeRadioSource(client: InnerTubeRadioClient(http: http, visitorData: { nil }), budget: budget)
        #expect(await source.songRadio(videoId: "a", continuations: 0) != nil)
        #expect(await source.songRadio(videoId: "b", continuations: 0) == nil)
        #expect(http.requests.count == 1)
        #expect(await budget.available() == 0)
    }

    @Test func theBucketRefillsOneTokenPerInterval() async {
        let now = Box<Int64>(1_000)
        let budget = HostBudget(capacity: 2, refillIntervalMs: 100, clock: { now.value })
        #expect(await budget.tryAcquire())
        #expect(await budget.tryAcquire())
        #expect(await !budget.tryAcquire())
        now.value = 1_250
        #expect(await budget.available() == 2)
        // The clock went back: nothing is earned, what is left is kept.
        #expect(await budget.tryAcquire())
        now.value = 500
        #expect(await budget.available() == 1)
    }
}
