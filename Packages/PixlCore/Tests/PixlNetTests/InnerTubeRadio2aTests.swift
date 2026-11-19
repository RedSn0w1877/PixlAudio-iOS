import Foundation
import Testing
import PixlFoundation
import PixlModel
@testable import PixlNet

/// The stage 2a parsers (docs/brain-spec.md, 3.3: discography, album audio, playlist pages and their continuations,
/// `music/get_queue`, a songs search) against the same saved anonymous captures Android's `InnerTubeMusicParsers2aTest`
/// reads (`Fixtures/innertube`, cut by its `tools/brain/cut_fixtures.py --2a`). The `.expected.json` files come from
/// that script's own plain extraction, not from a parser.
@Suite("YouTube Music, stage 2a: discography, album audio, playlists, get_queue, songs search")
struct InnerTubeRadio2aTests {
    private func text(_ name: String) throws -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let url = try #require(Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures/innertube"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func resource(_ name: String) throws -> JSONValue { try JSONParser().parse(try text(name)) }

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

    private func expectRows(_ expected: [JSONValue], _ actual: [RadioRow], _ what: String) {
        #expect(expected.count == actual.count, "\(what): row count")
        for (i, e) in expected.enumerated() where i < actual.count {
            let a = actual[i]
            let at: Comment = "\(what) row \(i) (\(str(e, "title") ?? ""))"
            #expect(str(e, "videoId") == a.videoId, at)
            #expect(str(e, "title") == a.title, at)
            let artists = (e["artists"]?.arrayValue ?? []).map { RadioArtistRef(name: str($0, "name") ?? "", channelId: str($0, "id")) }
            #expect(artists == a.artists, at)
            #expect(str(e, "album") == a.album, at)
            #expect(str(e, "albumId") == a.albumBrowseId, at)
            #expect(int(e, "year") == a.year, at)
            #expect(int(e, "durationSec") == a.durationSec, at)
            #expect((str(e, "explicit") == "true") == a.explicit, at)
            #expect(str(e, "type") == a.kind.rawValue, at)
            #expect(str(e, "plays").flatMap { Int64($0) } == a.playCount, at)
        }
    }

    @Test func discographyEveryCardIsAReleaseWithItsKindYearAndAudioPlaylist() throws {
        let expected = try #require(try resource("discography.expected.json")["releases"]?.arrayValue)
        let parsed = InnerTubeRadio.parseDiscography(try resource("discography.json"))
        #expect(expected.count == parsed.count)
        for (i, e) in expected.enumerated() where i < parsed.count {
            let a = parsed[i]
            #expect(str(e, "browseId") == a.browseId)
            #expect(str(e, "title") == a.title)
            #expect(int(e, "year") == a.year)
            #expect(str(e, "kind") == a.kind.rawValue)
            #expect(str(e, "audioPlaylistId") == a.audioPlaylistId)
            #expect(str(e, "thumb") == a.thumbnailUrl)
        }
        #expect(parsed.first?.kind == .album)
        #expect(parsed.allSatisfy { $0.browseId.hasPrefix("MPREb_") && ($0.audioPlaylistId ?? "").hasPrefix("OLAK5uy_") })
        #expect(parsed.contains { $0.kind == .single } && parsed.contains { $0.kind == .ep })
    }

    @Test func aDiscographyResponseWithNoGridIsNoReleasesNotAnError() throws {
        #expect(InnerTubeRadio.parseDiscography(try resource("radio_invalid_id.json")).isEmpty)
        #expect(InnerTubeRadio.parseDiscography(.object(JSONObject())).isEmpty)
    }

    @Test func theAlbumsAudioPlaylistIsTheCanonicalUrlsListNeverTheAlbumPagesOwnTracks() throws {
        let expected = str(try resource("album_audio.expected.json"), "audioPlaylistId")
        #expect(InnerTubeRadio.parseAlbumAudioPlaylistId(try resource("album_audio.json")) == expected)
        #expect((expected ?? "").hasPrefix("OLAK5uy_"))
        #expect(InnerTubeRadio.parseAlbumAudioPlaylistId(try resource("radio_invalid_id.json")) == nil)
        #expect(InnerTubeRadio.audioListParam("https://music.youtube.com/playlist?list=OLAK5uy_abc-D_1&x=2") == "OLAK5uy_abc-D_1")
        #expect(InnerTubeRadio.audioListParam("https://music.youtube.com/playlist?list=PLabc") == nil)
        #expect(InnerTubeRadio.audioListParam("https://music.youtube.com/playlist?list=OLAK5uy_") == nil)
    }

    @Test func anAlbumAsAPlaylistHasFourteenOfficialAudioRowsAndNoContinuation() throws {
        let expected = try resource("playlist_album.expected.json")
        let page = InnerTubeRadio.parsePlaylistPage(try resource("playlist_album.json"))
        expectRows(expected["rows"]?.arrayValue ?? [], page.rows, "album playlist")
        #expect(page.rows.count == 14)
        let allAudio = page.rows.allSatisfy { $0.isOfficialAudio }
        #expect(allAudio)
        #expect(page.continuation == nil)
    }

    @Test func aLongPlaylistHasPlayCountsAndTheContinuationToken() throws {
        let expected = try resource("playlist_top_songs.expected.json")
        let page = InnerTubeRadio.parsePlaylistPage(try resource("playlist_top_songs.json"))
        expectRows(expected["rows"]?.arrayValue ?? [], page.rows, "playlist page 1")
        #expect(str(expected, "continuation") == page.continuation)
        #expect(!(page.continuation ?? "").isEmpty)
        #expect(page.rows.first?.playCount == 3_400_000_000)
    }

    @Test func aPlaylistContinuationHasAppendedItemsAndTheLastPageHasNoToken() throws {
        let expected = try resource("playlist_cont.expected.json")
        let page = InnerTubeRadio.parsePlaylistPage(try resource("playlist_cont.json"))
        expectRows(expected["rows"]?.arrayValue ?? [], page.rows, "playlist continuation")
        #expect(page.continuation == nil)
    }

    @Test func aContinuationThatNamesTheNextOneInTheNewAndTheOldShape() throws {
        let appended = try JSONParser().parse(#"""
            {"onResponseReceivedActions":[{"appendContinuationItemsAction":{"continuationItems":[
            {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"NEXT_NEW"}}}}]}}]}
            """#)
        #expect(InnerTubeRadio.parsePlaylistPage(appended).continuation == "NEXT_NEW")
        let legacy = try JSONParser().parse(#"""
            {"continuationContents":{"musicPlaylistShelfContinuation":{"contents":[],
            "continuations":[{"nextContinuationData":{"continuation":"NEXT_OLD"}}]}}}
            """#)
        #expect(InnerTubeRadio.parsePlaylistPage(legacy).continuation == "NEXT_OLD")
    }

    @Test func aPlaylistRowWithNoWatchEndpointStillHasItsVideoIdFromThePlaylistItemData() throws {
        let doc = try JSONParser().parse(#"""
            {"contents":{"musicPlaylistShelfRenderer":{"contents":[{"musicResponsiveListItemRenderer":{
            "playlistItemData":{"videoId":"abcdefghijk"},
            "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"A song"}]}}},
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"An artist"}]}}}],
            "fixedColumns":[{"musicResponsiveListItemFixedColumnRenderer":{"text":{"runs":[{"text":"3:05"}]}}}]}}]}}}
            """#)
        let row = try #require(InnerTubeRadio.parsePlaylistPage(doc).rows.first)
        #expect(row.videoId == "abcdefghijk")
        #expect(row.durationSec == 185)
    }

    @Test func anAlbumPagesOwnTrackListIsNotReadAsAPlaylist() throws {
        let doc = try JSONParser().parse(#"""
            {"contents":{"musicShelfRenderer":{"contents":[{"musicResponsiveListItemRenderer":
            {"playlistItemData":{"videoId":"xxxxxxxxxxx"}}}]}}}
            """#)
        #expect(InnerTubeRadio.parsePlaylistPage(doc).rows.isEmpty)
    }

    @Test func getQueueGivesRowsWithArtistsAlbumAndLengthAnUnplayableIdIsLeftOut() throws {
        let expected = try #require(try resource("get_queue.expected.json")["rows"]?.arrayValue)
        let rows = InnerTubeRadio.parseGetQueue(try resource("get_queue.json"))
        #expect(expected.count == rows.count)
        for (i, e) in expected.enumerated() where i < rows.count {
            #expect(str(e, "videoId") == rows[i].videoId)
            #expect(str(e, "title") == rows[i].title)
            #expect(int(e, "durationSec") == rows[i].durationSec)
            #expect(str(e, "type") == rows[i].kind.rawValue)
            #expect((e["artists"]?.arrayValue ?? []).map { str($0, "name") ?? "" } == rows[i].artists.map(\.name))
        }
        #expect(InnerTubeRadio.parseGetQueue(try JSONParser().parse(#"{"error":{"code":404}}"#)).isEmpty)
    }

    @Test func aSongsSearchKeepsTheArtistsChannelIdAndTheLengthFromTheByline() throws {
        let expected = try resource("search_songs.expected.json")
        let rows = InnerTubeRadio.parseSongSearch(try resource("search_songs.json"))
        expectRows(expected["rows"]?.arrayValue ?? [], rows, "songs search")
        #expect(rows.first?.artists.first?.channelId == "UClYV6hHlupm_S_ObS1W-DYw")
        #expect(rows.first?.durationSec == 202)
    }

    @Test func theArtistPageCardsCarryTheirKind() throws {
        let page = InnerTubeRadio.parseArtistPage(try resource("artist_page.json"))
        #expect(page.albums.allSatisfy { $0.kind == .album })
        #expect(page.singles.allSatisfy { $0.kind == .single || $0.kind == .ep })
    }

    // MARK: Requests and the source

    private func ok(_ name: String) throws -> HTTPResponse { HTTPResponse(statusCode: 200, text: try text(name)) }

    @Test func theNewCallsAreAnonymousAndNameOnlyTheirOwnInput() async throws {
        let page = try ok("playlist_cont.json")
        let http = FixtureHTTPClient { _ in page }
        let client = InnerTubeRadioClient(http: http, visitorData: { "V" })
        #expect(await client.browseContinuation("TOKEN") != nil)
        #expect(await client.getQueueText(["a", "b"]) != nil)
        #expect(await client.searchSongsText("  Some Artist  ") != nil)
        #expect(await client.getQueueText([]) == nil)
        #expect(await client.searchSongsText("   ") == nil)
        let requests = http.requests
        #expect(requests.count == 3)
        #expect(requests[0].url == InnerTubeContexts.endpoint(InnerTubeContexts.webRemix, "browse"))
        #expect(requests[1].url == InnerTubeContexts.endpoint(InnerTubeContexts.webRemix, "music/get_queue"))
        #expect(requests[2].url == InnerTubeContexts.endpoint(InnerTubeContexts.webRemix, "search"))
        for request in requests {
            #expect(request.header("cookie") == nil)
            #expect(request.header("Authorization") == nil)
        }
        let body = { (i: Int) in String(decoding: requests[i].body ?? Data(), as: UTF8.self) }
        #expect(body(0).hasSuffix(#","continuation":"TOKEN"}"#))
        #expect(body(1).hasSuffix(#","videoIds":["a","b"]}"#))
        #expect(body(2).hasSuffix(#","query":"Some Artist","params":"EgWKAQIIAWoKEAkQBRAKEAMQBA=="}"#))
    }

    @Test func aPlaylistIsReadPageByPageUpToTheLimitAndDeduplicated() async throws {
        let first = try ok("playlist_top_songs.json")
        let more = try ok("playlist_cont.json")
        let http = FixtureHTTPClient { request in
            String(decoding: request.body ?? Data(), as: UTF8.self).contains("\"continuation\"") ? more : first
        }
        let source = YouTubeRadioSource(client: InnerTubeRadioClient(http: http, visitorData: { nil }),
                                        budget: HostBudget(clock: { 0 }))
        let one = try #require(await source.playlistRows(playlistId: "PLx", maxPages: 1))
        #expect(http.requests.count == 1)
        let two = try #require(await source.playlistRows(playlistId: "PLx", maxPages: 5))
        #expect(http.requests.count == 3)
        #expect(two.count > one.count)
        #expect(Set(two.map(\.videoId)).count == two.count)
    }

    @Test func aReleaseWithItsAudioPlaylistCostsOneRequestAndOneWithoutCostsTwo() async throws {
        let album = try ok("album_audio.json")
        let tracks = try ok("playlist_album.json")
        let http = FixtureHTTPClient { request in
            String(decoding: request.body ?? Data(), as: UTF8.self).contains("\"browseId\":\"MPREb_") ? album : tracks
        }
        let source = YouTubeRadioSource(client: InnerTubeRadioClient(http: http, visitorData: { nil }),
                                        budget: HostBudget(clock: { 0 }))
        let withId = ReleaseRef(browseId: "MPREb_x", title: "A", year: 2024, kind: .album, audioPlaylistId: "OLAK5uy_a")
        #expect(try #require(await source.releaseTracks(withId)).count == 14)
        #expect(http.requests.count == 1)
        let without = ReleaseRef(browseId: "MPREb_x", title: "A", year: 2024, kind: .album)
        #expect(try #require(await source.releaseTracks(without)).count == 14)
        #expect(http.requests.count == 3)
    }

    @Test func hydrateBisectsABatchThatAnInvalidIdTurnedInto404WithASmallBound() async throws {
        let good = try ok("get_queue.json")
        // Any batch that holds the id "bad" is a 404, as YouTube Music answers.
        let http = FixtureHTTPClient { request in
            String(decoding: request.body ?? Data(), as: UTF8.self).contains("\"bad\"")
                ? HTTPResponse(statusCode: 404, text: "") : good
        }
        let source = YouTubeRadioSource(client: InnerTubeRadioClient(http: http, visitorData: { nil }),
                                        budget: HostBudget(clock: { 0 }))
        let rows = try #require(await source.hydrate(videoIds: ["a", "b", "bad", "c", "a"]))
        #expect(!rows.isEmpty)
        // One batch, then at most three splits (each split is two requests: the budget bounds the rest).
        #expect(http.requests.count >= 3 && http.requests.count <= 7)
        #expect(await source.hydrate(videoIds: []) == [])
        // A single bad id is nothing, not a crash.
        #expect(await source.hydrate(videoIds: ["bad"]) == nil)
    }

    @Test func anArtistIdComesFromTheFirstSongsSearchHitThatNamesThatArtist() async throws {
        let search = try ok("search_songs.json")
        let http = FixtureHTTPClient { _ in search }
        let source = YouTubeRadioSource(client: InnerTubeRadioClient(http: http, visitorData: { nil }),
                                        budget: HostBudget(clock: { 0 }))
        let rows = InnerTubeRadio.parseSongSearch(try resource("search_songs.json"))
        let ref = try #require(rows.first?.artists.first)
        #expect(await source.channelId(forArtist: ref.name) == ref.channelId)
        #expect(await source.channelId(forArtist: "Nobody By This Name") == nil)
        #expect(await source.channelId(forArtist: "   ") == nil)
    }

    @Test func discographyNeedsAChannelId() async throws {
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: "{}") }
        let source = YouTubeRadioSource(client: InnerTubeRadioClient(http: http, visitorData: { nil }),
                                        budget: HostBudget(clock: { 0 }))
        #expect(await source.discography(channelId: "not-a-channel") == nil)
        #expect(http.requests.isEmpty)
    }
}
