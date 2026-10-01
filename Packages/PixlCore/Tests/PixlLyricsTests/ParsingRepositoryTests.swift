import Foundation
import Testing
import PixlFoundation
import PixlModel
@testable import PixlLyrics

/// Port of the pure cases of the Android `data/repository/LyricsRepositoryImplTest` (embedded-field choice and the
/// four LRCLIB ranking cases; the storage-order cases belong to the iOS LyricsService, stage 9), plus Swift checks of
/// the matching, search-strategy and repository helpers.
@Suite("Parsing — LRCLIB matching and repository logic")
struct ParsingRepositoryTests {

    static func song(id: String = "1", title: String, artist: String, path: String = "", duration: Int64) -> Song {
        Song(id: id, title: title, artist: artist, artistId: 5, album: "Album", albumId: 8, path: path, contentUriString: "",
             albumArtUriString: nil, duration: duration, mimeType: "audio/mpeg", bitrate: 320_000, sampleRate: 44_100)
    }

    static func lrcResponse(name: String, artistName: String, duration: Double) -> LrcLibResponse {
        LrcLibResponse(id: name.hashValue & 0x7FFF_FFFF, name: name, artistName: artistName, albumName: "Album", duration: duration,
                       plainLyrics: nil, syncedLyrics: "[00:01.00]First line\n[00:05.00]Second line")
    }

    /// `fetchFromRemote`: the first candidate-mode search result, else the exact `api/get` match (automatic mode).
    static func fetchFromRemote(_ song: Song, search: [LrcLibResponse], exact: LrcLibResponse?) -> LyricsSearchResult? {
        LrcLibMatching.candidateResults(song: song, responses: search).first
            ?? LrcLibMatching.exactMatchResult(song: song, response: exact)
    }

    @Test func parseBestEmbeddedLyricsFieldPrefersSyncedLyricsWhenLyricsFieldIsPlain() throws {
        let result = try #require(LyricsRepositoryLogic.parseBestEmbeddedLyricsField(
            ["LYRICS": ["plain lyrics only"], "SYNCEDLYRICS": ["[00:01.00]Synced lyrics"]]))
        #expect(result.synced?.count == 1)
        #expect(result.synced?.first?.line == "Synced lyrics")
        #expect(!result.areFromRemote)
    }

    @Test func fetchFromRemoteRejectsDurationOnlySearchMatch() {
        let song = Self.song(id: "101", title: "Actual Song", artist: "Actual Artist", duration: 180_000)
        let result = Self.fetchFromRemote(song, search: [Self.lrcResponse(name: "Completely Different Song",
                                                                          artistName: "Different Artist", duration: 180.0)],
                                          exact: nil)
        #expect(result == nil)
    }

    @Test func fetchFromRemoteRejectsOriginalLyricsForRemix() {
        let original = Self.lrcResponse(name: "Midnight City", artistName: "M83", duration: 242.0)
        let song = Self.song(id: "102", title: "Midnight City (Remix)", artist: "M83", path: "/music/Midnight City (Remix).mp3",
                             duration: 242_000)
        #expect(Self.fetchFromRemote(song, search: [original], exact: original) == nil)
    }

    @Test func fetchFromRemoteAcceptsMatchingRemixVariant() throws {
        let remix = Self.lrcResponse(name: "Midnight City (Eric Prydz Remix)", artistName: "M83", duration: 242.0)
        let song = Self.song(id: "103", title: "Midnight City (Eric Prydz Remix)", artist: "M83",
                             path: "/music/Midnight City (Eric Prydz Remix).mp3", duration: 242_000)
        let result = try #require(Self.fetchFromRemote(song, search: [remix], exact: nil))
        #expect(result.lyrics.areFromRemote)
        #expect(result.rawLyrics == "[00:01.00]First line\n[00:05.00]Second line")
    }

    @Test func fetchFromRemoteDoesNotTreatArtistNameInFilePathAsVariant() {
        let lyrics = Self.lrcResponse(name: "Black Magic", artistName: "Little Mix", duration: 211.0)
        let song = Self.song(id: "104", title: "Black Magic", artist: "Little Mix", path: "/music/Little Mix - Black Magic.mp3",
                             duration: 211_000)
        #expect(Self.fetchFromRemote(song, search: [lyrics], exact: nil) != nil)
    }

    /// The storage-path cases' parsing halves: stored plain and synced text parse as local lyrics.
    @Test func storedSongLyricsParseAsLocalLyrics() throws {
        let plain = LyricsUtils.parseLyrics("Saved words")
        #expect(plain.plain == ["Saved words"])
        #expect(LyricsRepositoryLogic.isUsable(plain))
        let synced = LyricsUtils.parseLyrics("[00:01.00]Hello again")
        #expect(synced.synced?.first?.line == "Hello again")
        #expect(!synced.areFromRemote)
    }

    // MARK: Swift-only: ranking details

    @Test func rankingOrderAndTolerances() {
        let song = Self.song(title: "Song", artist: "Artist", duration: 200_000)
        func r(_ id: Int, _ duration: Double, synced: String? = "[00:01.00]x", plain: String? = nil, file: String? = nil,
               name: String = "Song") -> LrcLibResponse {
            LrcLibResponse(id: id, name: name, artistName: "Artist", albumName: "A", duration: duration, plainLyrics: plain,
                           syncedLyrics: synced, lyricsFile: file)
        }
        // Automatic: synced lyrics within 2 s (1 % of 200 s, at least 2), plain within 8 s.
        let automatic = LrcLibMatching.rankRemoteLyricsMatches(song: song, responses: [
            r(1, 202), r(2, 202.5), r(3, 208, synced: nil, plain: "p"), r(4, 208.5, synced: nil, plain: "p"),
        ], mode: .automatic)
        #expect(automatic.map(\.response.id) == [1, 3])
        #expect(automatic.map(\.score) == [110, 100])
        // Candidate: 15 s, Lyricsfile first among equal scores.
        let candidate = LrcLibMatching.rankRemoteLyricsMatches(song: song, responses: [
            r(5, 201), r(6, 200.5, file: "version: '1.0'"), r(7, 215), r(8, 215.5),
        ], mode: .candidate)
        #expect(candidate.map(\.response.id) == [6, 5, 7])
        var noDuration = song
        noDuration.duration = 0
        #expect(LrcLibMatching.rankRemoteLyricsMatches(song: noDuration, responses: [r(9, 200)], mode: .candidate).isEmpty)
    }

    @Test func titleAndArtistScores() {
        #expect(LrcLibMatching.titleMatchScore("Song (feat. X) [Explicit]", "song", mode: .automatic) == 70)
        #expect(LrcLibMatching.titleMatchScore("01. Song", "Song", mode: .automatic) == 70)
        #expect(LrcLibMatching.titleMatchScore("Hello World Again", "Hello World", mode: .automatic) == 58)
        #expect(LrcLibMatching.titleMatchScore("Hello World Again", "Hello World", mode: .candidate) == 54)
        // Android quirk kept: NFD splits Hangul syllables into conjoining jamo, which the romanisation check does not
        // recognise, so a Korean base title never takes the romanised path.
        #expect(LrcLibMatching.titleMatchScore("사랑해", "Saranghae", mode: .automatic) == nil)
        #expect(LrcLibMatching.titleMatchScore("Different", "Song", mode: .automatic) == nil)
        #expect(LrcLibMatching.artistMatchScore("Unknown Artist", "Anyone") == 0)
        #expect(LrcLibMatching.artistMatchScore("Beyoncé & Jay-Z", "Beyonce and Jay Z") == 30)
        #expect(LrcLibMatching.artistMatchScore("Daft Punk feat. Pharrell Williams", "Daft Punk") == 22)
        #expect(LrcLibMatching.artistMatchScore("A x B", "B and C") == 12)
    }

    @Test func normalisationHelpers() {
        #expect(LrcLibMatching.normalizeForMatch("  Café & Don’t-Stop!! ") == "cafe and dont stop")
        // Java's lower-casing applies the final-sigma rule: ΣΟΦΟΣ → σοφος with a final ς.
        #expect(LrcLibMatching.normalizeForMatch("\u{03A3}\u{039F}\u{03A6}\u{039F}\u{03A3}").unicodeScalars.map(\.value)
                == [0x03C3, 0x03BF, 0x03C6, 0x03BF, 0x03C2])
        #expect(LrcLibMatching.baseTitleForMatching("Song - Radio Edit") == "song")
        #expect(LrcLibMatching.baseTitleForMatching("Song (Live) - Remastered 2011") == "song remastered 2011")
        #expect(LrcLibMatching.timingVariantTokens("Mash Up (Club Mix)") == ["mashup", "club", "mix"])
        #expect(LrcLibMatching.timingVariantTokens("A vs B") == ["mashup"])
        #expect(LrcLibMatching.cleanTitleSmart("01 - Taare Ginn - Envy") == "Taare Ginn")
        #expect(LrcLibMatching.songFileName(Self.song(title: "x", artist: "y", path: "/music/a.b.mp3/", duration: 1)) == "a.b")
        #expect(LrcLibMatching.isUnknownArtist("<unknown>"))
    }

    @Test func searchStrategies() {
        var song = Self.song(title: "Song (Live) feat. X", artist: "Artist & Friend", duration: 200_000)
        let automatic = LrcLibMatching.automaticSearchRequests(song: song)
        #expect(automatic.map(\.name) == ["track+artist", "combined_query", "simplified_track+artist"])
        #expect(automatic[0].trackName == "Song  feat. X")
        #expect(automatic[1].query == "Artist & Friend Song  feat. X")
        #expect(automatic[2].trackName == "Song" && automatic[2].artistName == "Artist")
        #expect(automatic[0].parameters.map(\.name) == ["track_name", "artist_name"])

        song.title = "01 - Song: Part 2"
        let names = LrcLibMatching.automaticSearchRequests(song: song).map(\.name)
        #expect(names.contains("smart_track_only"))
        #expect(LrcLibMatching.automaticFallbackRequest(song: song)?.trackName == "01")

        song.title = "사랑해"
        #expect(LrcLibMatching.automaticSearchRequests(song: song).first { $0.name == "romanized_track" }?.trackName == "saranghae")

        let candidate = LrcLibMatching.candidateSearchRequests(song: Self.song(title: "  Song ", artist: "Artist", duration: 1))
        #expect(candidate.query == "  Song  Artist")
        #expect(candidate.requests.map(\.name) == ["query+artist", "track+artist", "track_only", "query_title_only"])

        let manual = LrcLibMatching.manualSearchRequests(title: " Title ", artist: "  ")
        #expect(manual.query == "Title")
        #expect(manual.requests.map(\.name) == ["manual_query"])
        #expect(LrcLibMatching.manualSearchRequests(title: "T", artist: "A").requests.count == 2)
    }

    @Test func responseDecodingAndResults() throws {
        let json = try JSONParser().parse("""
            [{"id":1,"name":"Song","artistName":"Artist","albumName":"A","duration":200,"plainLyrics":null,
              "syncedLyrics":"[00:01.00]Hi","lyricsfile":null},
             {"id":"2","name":"Song","artistName":"Artist","albumName":"A","duration":"201.5","plainLyrics":"Hi"}]
            """)
        let responses = try #require(LrcLibResponse.decodeList(json))
        #expect(responses.map(\.id) == [1, 2])
        #expect(responses[1].duration == 201.5)
        #expect(LrcLibResponse.decodeList(try JSONParser().parse(#"[{"id":1.5,"name":"a","artistName":"b","albumName":"c","duration":1}]"#)) == nil)
        #expect(LrcLibResponse.decodeList(try JSONParser().parse(#"[{"id":1,"artistName":"b","albumName":"c","duration":1}]"#)) == nil)
        #expect(LrcLibMatching.distinctById(responses + [responses[0]]).count == 2)

        let song = Self.song(title: "Song", artist: "Artist", duration: 200_000)
        #expect(LrcLibMatching.automaticResult(song: song, responses: responses)?.record.id == 1)
        #expect(LrcLibMatching.manualResults(responses: responses.reversed()).map(\.record.id) == [1, 2])

        let withFile = LrcLibResponse(id: 3, name: "Song", artistName: "Artist", albumName: "A", duration: 200,
                                      syncedLyrics: "[00:01.00]x",
                                      lyricsFile: "version: '1.0'\nlines:\n  - text: Word\n    start_ms: 1000\n    words:\n      - text: Word\n        start_ms: 1000")
        #expect(withFile.rawLyrics == "[00:01.00]<00:01.00>Word")
    }

    // MARK: Swift-only: repository helpers

    @Test func sourceOrderAndCatalogChoice() {
        #expect(LyricsRepositoryLogic.sourceOrder(for: .apiFirst) == [.api, .embedded, .local])
        #expect(LyricsRepositoryLogic.sourceOrder(for: .embeddedFirst) == [.embedded, .api, .local])
        #expect(LyricsRepositoryLogic.sourceOrder(for: .localFirst) == [.local, .embedded, .api])

        let lineSynced = OnlineSyncedLyrics(lyrics: LyricsUtils.parseLyrics("[00:01.00]line"), source: "LRCLIB")
        let wordSynced = OnlineSyncedLyrics(lyrics: LyricsUtils.parseLyrics("[00:01.00]<00:01.00>word"), source: "NetEase YRC")
        let plain = OnlineSyncedLyrics(lyrics: LyricsUtils.parseLyrics("plain"), source: "AMLL TTML")
        let zero = OnlineSyncedLyrics(lyrics: LyricsUtils.parseLyrics("[00:00.00]zero"), source: "AMLL TTML")
        #expect(LyricsRepositoryLogic.chooseCatalogResult([plain, lineSynced, wordSynced], syncedOnly: true)?.source == "NetEase YRC")
        #expect(LyricsRepositoryLogic.chooseCatalogResult([plain, lineSynced], syncedOnly: true)?.source == "LRCLIB")
        #expect(LyricsRepositoryLogic.chooseCatalogResult([plain, zero], syncedOnly: true) == nil)
        #expect(LyricsRepositoryLogic.chooseCatalogResult([plain], syncedOnly: false)?.source == "AMLL TTML")
    }

    @Test func rawContentCacheRecordAndUserSync() throws {
        let words = LyricsUtils.parseLyrics("[00:01.00]<00:01.00>Hel<00:01.20>lo <00:01.50>world")
        #expect(LyricsRepositoryLogic.lyricsToRawContent(words) == "[00:01.00]<00:01.00>Hel<00:01.20>lo <00:01.50>world")
        #expect(LyricsRepositoryLogic.lyricsToRawContent(Lyrics(plain: [" "])) == nil)
        #expect(LyricsRepositoryLogic.looksLikeFlattenedWordByWordCache(
            LyricsUtils.parseLyrics("[00:01.00]Supercalifragilistic\n[00:02.00]Antidisestablishment")))

        let record = LyricsCacheData(lyrics: words)
        #expect(record.wordByWordLyrics == "[00:01.00]<00:01.00>Hel<00:01.20>lo <00:01.50>world")
        #expect(record.syncedLyrics == "[00:01.00]Hello world")
        let lt = "\\" + "u003c", gt = "\\" + "u003e" // Gson escapes < and > (HTML-safe)
        #expect(record.encodedJSON() == #"{"plainLyrics":"Hello world","syncedLyrics":"[00:01.00]Hello world","wordByWordLyrics":"[00:01.00]"# + lt + "00:01.00" + gt + "Hel" + lt + "00:01.20" + gt + "lo " + lt + "00:01.50" + gt + #"world"}"#)
        #expect(LyricsCacheData.decode(record.encodedJSON()) == record)
        #expect(LyricsCacheData.decode("{\"wordByWordLyrics\":") == nil)
        #expect(record.preferredRawLyrics == record.wordByWordLyrics)
        #expect(record.hasLyrics && !LyricsCacheData().hasLyrics)

        var doc = LyricsDoc(lines: [TimedLine(startMs: 1, endMs: 2, text: "a")])
        doc.metadata.source = "user"
        #expect(LyricsRepositoryLogic.documentIsUserSynced(LyricsDocCodec.encode(doc)))
        doc.metadata.source = "NetEase"
        #expect(!LyricsRepositoryLogic.documentIsUserSynced(LyricsDocCodec.encode(doc)))
    }

    @Test func rateLimiter() {
        var limiter = LyricsRateLimiter()
        #expect(limiter.delayBeforeCall("lrclib", nowMs: 1_000_000) == 0)
        limiter.recordCall("lrclib", timestampMs: 1_000_000)
        #expect(limiter.delayBeforeCall("lrclib", nowMs: 1_000_040) == 60)
        #expect(limiter.delayBeforeCall("other", nowMs: 1_000_040) == 0)
        for i in 1..<30 { limiter.recordCall("lrclib", timestampMs: 1_000_000 + Int64(i) * 200) }
        #expect(limiter.delayBeforeCall("lrclib", nowMs: 1_010_000) == 200)
        #expect(limiter.delayBeforeCall("lrclib", nowMs: 1_070_000) == 0)
    }
}
