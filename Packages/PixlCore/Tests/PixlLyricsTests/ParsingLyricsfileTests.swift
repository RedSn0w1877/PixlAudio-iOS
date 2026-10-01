import Foundation
import Testing
import PixlModel
@testable import PixlLyrics

/// Port of the Android `data/network/lyrics/LyricsfileParserTest` (all 7 cases, including the AMLL metadata one),
/// plus checks of the YAML subset reader.
@Suite("Parsing — Lyricsfile")
struct ParsingLyricsfileTests {
    static let yaml = """
        version: "1.0"
        lines:
          - text: No surprises
            start_ms: 13440
            end_ms: 16000
            words:
              - text: "No "
                start_ms: 13440
              - text: surprises
                start_ms: 14000
          - text: On
            start_ms: 18000
            words:
              - text: On
                start_ms: 18000
        """

    @Test func readsAbsoluteWordTimingsAndKeepsIntroAndSpaces() throws {
        let synced = try #require(LyricsfileParser.parse(Self.yaml)?.synced)
        #expect(synced[0].time == 13440)
        #expect(synced[0].words?.map(\.time) == [13440, 14000])
        #expect(synced[0].line == "No surprises")
        #expect(synced[0].words?[1].startsNewWord == true)
    }

    @Test func yamlBooleanLookingLyricWordsStayText() {
        #expect(LyricsfileParser.parse(Self.yaml)?.synced?[1].words?[0].word == "On")
    }

    @Test func unsupportedVersionsAndAmbiguousOffsetsAreRejected() {
        #expect(LyricsfileParser.parse(Self.yaml.replacingOccurrences(of: "1.0", with: "2.0")) == nil)
        #expect(LyricsfileParser.parse("offset_ms: 200\n" + Self.yaml) == nil)
    }

    @Test func invalidAndReversedTimestampsCannotReplaceGoodLyrics() {
        #expect(LyricsfileParser.parse(Self.yaml.replacingOccurrences(of: "14000", with: "12000")) == nil)
        #expect(LyricsfileParser.parse(Self.yaml.replacingOccurrences(of: "13440", with: "-1")) == nil)
        #expect(LyricsfileParser.parse(Self.yaml.replacingOccurrences(of: "13440", with: ".nan")) == nil)
    }

    @Test func yamlObjectTagsAndDuplicateKeysAreRejected() {
        #expect(LyricsfileParser.parse("!!java.lang.ProcessBuilder {}") == nil)
        #expect(LyricsfileParser.parse("version: 2.0\n" + Self.yaml) == nil)
    }

    @Test func amllMetadataMatchingRejectsAlternateEditionsAndMissingAlbums() {
        let song = Song(id: "-1", title: "Song", artist: "Artist", artistId: -1, album: "Album", albumId: -1, path: "",
                        contentUriString: "", albumArtUriString: nil, duration: 0, mimeType: nil, bitrate: nil, sampleRate: nil)
        #expect(AmllLyricsMatching.matchesMetadata(song: song, titles: ["SONG"], artists: ["Artist"], albums: ["Album"]))
        #expect(!AmllLyricsMatching.matchesMetadata(song: song, titles: ["Song (Live)"], artists: ["Artist"], albums: ["Album"]))
        #expect(!AmllLyricsMatching.matchesMetadata(song: song, titles: ["Song"], artists: ["Another artist"], albums: ["Album"]))
        var noAlbum = song
        noAlbum.album = ""
        #expect(!AmllLyricsMatching.matchesMetadata(song: noAlbum, titles: ["Song"], artists: ["Artist"], albums: [""]))
    }

    @Test func realLrclibResponseStructureRetainsEveryTimedFragment() throws {
        let raw = try ParsingWordSyncTests.fixture("lrclib-lyricsfile-structure.yaml")
        let synced = try #require(LyricsfileParser.parse(raw)?.synced)
        let wordLines = synced.filter { !($0.words ?? []).isEmpty }
        let words = wordLines.flatMap { $0.words ?? [] }
        #expect(wordLines.count == 34)
        #expect(words.count == 190)
        #expect(words[0].time == 16742)
        #expect(words[1].time == 17179)
    }

    // MARK: YAML subset (Swift-only)

    @Test func yamlScalarsStayStrings() throws {
        let doc = try #require(try LyricsfileYAML.load("a: yes\nb: 1.50\nc: ~\nd:\ne: 'It''s'\nf: \"tab\\tx\""))
        #expect(doc["a"] == .scalar("yes"))
        #expect(doc["b"] == .scalar("1.50"))
        #expect(doc["c"] == .scalar("~"))
        #expect(doc["d"] == .scalar(""))
        #expect(doc["e"] == .scalar("It's"))
        #expect(doc["f"] == .scalar("tab\tx"))
    }

    @Test func yamlBlockScalarsAndFolding() throws {
        let doc = try #require(try LyricsfileYAML.load("lit: |\n  a\n  b\n\nfold: >-\n  c\n  d\n\n  e\nplain: one\n  two\n"))
        #expect(doc["lit"] == .scalar("a\nb\n"))
        #expect(doc["fold"] == .scalar("c d\ne"))
        #expect(doc["plain"] == .scalar("one two"))
    }

    @Test func yamlCollectionsAnchorsAndLimits() throws {
        let doc = try #require(try LyricsfileYAML.load("x: &a v\ny: *a\nz: [1, {k: w}]\n"))
        #expect(doc["y"] == .scalar("v"))
        #expect(doc["z"] == .sequence([.scalar("1"), .mapping([(key: "k", value: .scalar("w"))])]))
        #expect(throws: LyricsfileYAMLError.self) { try LyricsfileYAML.load("x: &a [1]\ny: *a\n") }
        #expect(throws: LyricsfileYAMLError.self) { try LyricsfileYAML.load("a: 1\na: 2\n") }
        #expect(throws: LyricsfileYAMLError.self) { try LyricsfileYAML.load("a: b: c\n") }
        #expect(throws: LyricsfileYAMLError.self) { try LyricsfileYAML.load("a: 1\n---\nb: 2\n") }
        #expect(throws: LyricsfileYAMLError.self) { try LyricsfileYAML.load("a: !!int 1\n") }
        let deep = String(repeating: "[", count: 21) + String(repeating: "]", count: 21)
        #expect(throws: LyricsfileYAMLError.self) { try LyricsfileYAML.load(deep) }
        #expect(try LyricsfileYAML.load(String(repeating: "[", count: 20) + String(repeating: "]", count: 20)) != nil)
        #expect(try LyricsfileYAML.load("# only a comment\n") == nil)
    }

    @Test func lyricsfileEdgeRules() throws {
        #expect(LyricsfileParser.parse("version: '1.0'\noffset_ms: 0\nlines:\n  - text: a\n    start_ms: 1") != nil)
        #expect(LyricsfileParser.parse("version: '1.0'\nlines:\n  - text: a\n    start_ms: 12.5") == nil)
        #expect(LyricsfileParser.parse("version: '1.0'\nlines:\n  - text: a\n    start_ms: 1e3")?.synced?.first?.time == 1000)
        #expect(LyricsfileParser.parse("version: '1.0'\nlines: []") == nil)
        #expect(LyricsfileParser.parse(String(repeating: " ", count: 10)) == nil)
        let lyrics = try #require(LyricsfileParser.parse("version: '1.0'\nlines:\n  - text: x\n    start_ms: 5"))
        #expect(lyrics.areFromRemote)
        #expect(lyrics.plain == ["x"])
    }
}
