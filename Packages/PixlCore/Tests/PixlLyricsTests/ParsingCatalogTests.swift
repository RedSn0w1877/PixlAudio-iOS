import Foundation
import Testing
import PixlFoundation
import PixlModel
@testable import PixlLyrics

/// Port of the Android `data/network/lyrics/NeteaseLyricsSourceTest` (3 cases, the OkHttp fixtures replaced by the
/// same JSON fed through the pure functions PixlNet will call) and Swift checks of the AMLL/HTTP helpers.
@Suite("Parsing — AMLL and NetEase catalogs")
struct ParsingCatalogTests {
    static let song = ParsingWordSyncTests.song()

    static func object(_ json: String) throws -> JSONObject {
        guard case .object(let o) = try JSONParser(mode: .kotlinx).parse(json) else { throw CancellationError() }
        return o
    }

    /// `NeteaseLyricsSource.find` driven by fixture replies (what PixlNet does around these functions).
    static func find(search: String, lyric: (String) -> String) throws -> (lyrics: Lyrics?, requested: [String]) {
        var requested: [String] = []
        guard NeteaseLyricsMatching.searchParameters(song: song) != nil,
              let searchResponse = try LyricsHTTP.decodeBody(Array(search.utf8)),
              try NeteaseLyricsMatching.isSuccess(searchResponse),
              let tracks = try NeteaseLyricsMatching.candidateTracks(searchResponse: searchResponse, song: song) else {
            return (nil, requested)
        }
        for track in tracks {
            let id = try NeteaseLyricsMatching.trackId(track)
            requested.append(id)
            guard let data = try LyricsHTTP.decodeBody(Array(lyric(id).utf8)), try NeteaseLyricsMatching.isSuccess(data) else { continue }
            if let lyrics = try NeteaseLyricsMatching.lyrics(fromLyricResponse: data, song: song) { return (lyrics, requested) }
        }
        return (nil, requested)
    }

    @Test func skipsWrongFirstSearchHitAndPersistsRealWordEnds() throws {
        let search = """
            {"code":200,"result":{"songs":[
            {"id":1,"name":"Example (Live)","artists":[{"name":"Singer"}],"album":{"name":"Album"},"duration":180000},
            {"id":2,"name":"Example","artists":[{"name":"Singer"}],"album":{"name":"Album"},"duration":180000}]}}
            """
        let result = try Self.find(search: search) { _ in #"{"code":200,"yrc":{"lyric":"[12000,1500](12000,500,0)Hi (13000,500,0)there"}}"# }
        #expect(result.requested == ["2"])
        let lyrics = try #require(result.lyrics)
        #expect(lyrics.synced?.first?.words?.first?.endTime == 12500)
        #expect(lyrics.document?.metadata.source == "NetEase")
        #expect(lyrics.areFromRemote)
    }

    @Test func opaqueRegionalSearchAndHttpFailuresAreCleanMisses() throws {
        // Opaque `result` string: a clean miss.
        #expect(try Self.find(search: #"{"code":200,"result":"opaque"}"#) { _ in "" }.lyrics == nil)
        // HTTP 403: PixlNet never hands the body over (no decode) — nothing to parse, no lyrics.
        // A body that is not JSON: the Android source's catch-all ends the lookup.
        #expect(throws: LyricsCatalogError.self) { try LyricsHTTP.decodeBody(Array("not json".utf8)) }
    }

    @Test func featuredCreditsMatchAcrossCatalogFieldsButVersionsStillDoNot() throws {
        var featured = Self.song
        featured.title = "Example (feat. Guest)"
        featured.artist = "Singer, Guest"
        func track(title: String = "Example", artists: String = #"{"name":"Singer"},{"name":"Guest"}"#) throws -> JSONObject {
            try Self.object(#"{"name":"\#(title)","artists":[\#(artists)],"album":{"name":"Album"},"duration":180000}"#)
        }
        #expect(NeteaseLyricsMatching.matchesRecording(song: featured, track: try track()))
        #expect(!NeteaseLyricsMatching.matchesRecording(song: featured, track: try track(title: "Example (Live)")))
        #expect(!NeteaseLyricsMatching.matchesRecording(song: featured, track: try track(artists: #"{"name":"Singer"}"#)))
        var earth = Self.song
        earth.artist = "Earth, Wind & Fire"
        #expect(NeteaseLyricsMatching.matchesRecording(song: earth, track: try track(artists: #"{"name":"Earth, Wind & Fire"}"#)))
    }

    // MARK: Swift-only

    @Test func neteaseRequestsAndResponseChecks() throws {
        var featured = Self.song
        featured.title = "Example [with Friend]"
        #expect(NeteaseLyricsMatching.searchParameters(song: featured)?.last?.value == "Example Singer")
        var noDuration = Self.song
        noDuration.duration = 0
        #expect(NeteaseLyricsMatching.searchParameters(song: noDuration) == nil)
        #expect(NeteaseLyricsMatching.lyricParameters(trackId: "7").map(\.name) == ["id", "kv", "yv", "rv", "tv"])
        #expect(try NeteaseLyricsMatching.isSuccess(try Self.object(#"{"code":"200"}"#)))
        #expect(try !NeteaseLyricsMatching.isSuccess(try Self.object(#"{"msg":"x"}"#)))
        #expect(throws: LyricsCatalogError.self) { try NeteaseLyricsMatching.isSuccess(try Self.object(#"{"code":{}}"#)) }
        // Lines ending after the song (+1.5 s) are rejected; so is line-only YRC.
        let late = try Self.object(#"{"code":200,"yrc":{"lyric":"[179000,3000](179000,3000,0)late"}}"#)
        #expect(try NeteaseLyricsMatching.lyrics(fromLyricResponse: late, song: Self.song) == nil)
        let plain = try Self.object(#"{"code":200,"yrc":{"lyric":"[1000,3000]no tags"}}"#)
        #expect(try NeteaseLyricsMatching.lyrics(fromLyricResponse: plain, song: Self.song) == nil)
        #expect(throws: LyricsCatalogError.self) {
            try NeteaseLyricsMatching.lyrics(fromLyricResponse: try Self.object(#"{"yrc":[]}"#), song: Self.song)
        }
        // Closest duration first, at most two.
        let search = try Self.object("""
            {"code":200,"result":{"songs":[
            {"id":10,"name":"Example","artists":[{"name":"Singer"}],"album":{"name":"Album"},"duration":181000},
            {"id":11,"name":"Example","artists":[{"name":"Singer"}],"album":{"name":"Album"},"duration":180100},
            {"id":12,"name":"Example","artists":[{"name":"Singer"}],"album":{"name":"Album"},"duration":180900}]}}
            """)
        let tracks = try #require(try NeteaseLyricsMatching.candidateTracks(searchResponse: search, song: Self.song))
        #expect(try tracks.map(NeteaseLyricsMatching.trackId) == ["11", "12"])
        #expect(NeteaseLyricsMatching.recordingTitle("Song (feat. A) [ft. B] (Live)") == "Song (Live)")
    }

    @Test func amllLookupsAndParse() throws {
        var song = Self.song
        song.spotifyId = "4uLU6hMCjMI75M1A2tKUQC"
        #expect(AmllLyricsMatching.spotifyLookupId(song) == "4uLU6hMCjMI75M1A2tKUQC")
        song.spotifyId = "short"
        #expect(AmllLyricsMatching.spotifyLookupId(song) == nil)
        var noAlbum = Self.song
        noAlbum.album = " "
        #expect(AmllLyricsMatching.searchParameters(song: noAlbum) == nil)
        #expect(AmllLyricsMatching.searchParameters(song: Self.song)?.map(\.name) == ["musicName", "artistName", "pageSize"])

        let ttml = #"<tt><body><p begin=\"1.0\"><span begin=\"1.0\">Hi</span> <span begin=\"1.5\">there</span></p></body></tt>"#
        let data = try Self.object(#"{"format":"ttml","lyrics":"\#(ttml)","spotifyIds":["4uLU6hMCjMI75M1A2tKUQC"]}"#)
        let lyrics = try #require(try AmllLyricsMatching.lyrics(fromSpotifyLookup: data, song: Self.song, spotifyId: "4uLU6hMCjMI75M1A2tKUQC"))
        #expect(lyrics.areFromRemote)
        #expect(lyrics.synced?.first?.words?.map(\.time) == [1000, 1500])
        #expect(try AmllLyricsMatching.lyrics(fromSpotifyLookup: data, song: Self.song, spotifyId: "other") == nil)
        let lrc = try Self.object(#"{"format":"lrc","lyrics":"[00:01.00]x"}"#)
        #expect(try AmllLyricsMatching.lyrics(from: lrc, song: Self.song) == nil)
        let lineOnly = try Self.object(#"{"format":"ttml","lyrics":"<tt><body><p begin=\"1.0\">line</p></body></tt>"}"#)
        #expect(try AmllLyricsMatching.lyrics(from: lineOnly, song: Self.song) == nil)

        let search = try Self.object("""
            {"items":[{"id":"a1","musicNames":["Example"],"artistNames":["Singer"],"albumNames":["Album"]},
            {"id":"a2","musicNames":["Example (Live)"],"artistNames":["Singer"],"albumNames":["Album"]}, 7]}
            """)
        #expect(try AmllLyricsMatching.matchingId(searchData: search, song: Self.song) == "a1")
        let ambiguous = try Self.object("""
            {"items":[{"id":"a1","musicNames":["Example"],"artistNames":["Singer"],"albumNames":["Album"]},
            {"id":"a2","musicNames":["EXAMPLE"],"artistNames":["singer"],"albumNames":["album"]}]}
            """)
        #expect(try AmllLyricsMatching.matchingId(searchData: ambiguous, song: Self.song) == nil)
        #expect(try AmllLyricsMatching.data(from: try Self.object(#"{"data":{"x":1}}"#))?["x"] != nil)
    }

    @Test func boundedBodies() throws {
        #expect(try LyricsHTTP.decodeBody(Array("{}".utf8), declaredContentLength: 2_000_000) == nil)
        #expect(throws: LyricsCatalogError.self) { try LyricsHTTP.decodeBody([UInt8](repeating: 0x20, count: 1_048_577)) }
        #expect(try LyricsHTTP.decodeBody(Array((String(repeating: "[", count: 33) + String(repeating: "]", count: 33)).utf8)) == nil)
        #expect(throws: LyricsCatalogError.self) { try LyricsHTTP.decodeBody(Array("[1]".utf8)) }
        #expect(try LyricsHTTP.decodeBody(Array(#"{"a":1}"#.utf8))?["a"] == .number("1"))
    }
}
