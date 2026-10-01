import Foundation
import Testing
import PixlFoundation
import PixlModel
@testable import PixlLyrics

/// Port of the Android `data/network/lyrics/WordSyncTranspilersTest` (all 12 cases; the two pure `LyricsDoc` cases
/// were also ported model-side in stage 2a), plus Swift checks.
@Suite("Parsing — WordSyncTranspilers")
struct ParsingWordSyncTests {
    static let yrc = "[12000,2500](12000,400,0)Hel(12400,600,0)lo (13500,1000,0)there"

    static func fixture(_ name: String) throws -> String {
        let parts = name.split(separator: ".")
        let url = try #require(Bundle.module.url(forResource: String(parts[0]), withExtension: String(parts[1]),
                                                 subdirectory: "Fixtures/parsing"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func song(title: String = "Example", artist: String = "Singer", album: String = "Album", duration: Int64 = 180_000) -> Song {
        Song(id: "-1", title: title, artist: artist, artistId: -1, album: album, albumId: -1, path: "", contentUriString: "",
             albumArtUriString: nil, duration: duration, mimeType: nil, bitrate: nil, sampleRate: nil)
    }

    static func track(_ json: String) throws -> JSONObject {
        guard case .object(let o) = try JSONParser().parse(json) else { throw CancellationError() }
        return o
    }

    @Test func yrcUsesAbsoluteTimesAndPreservesSyllableJoinsAndGaps() throws {
        let doc = try #require(WordSyncTranspilers.yrc(Self.yrc))
        let line = try #require(doc.lines.first)
        #expect(doc.lines.count == 1)
        #expect(line.text == "Hello there")
        #expect(line.syllables.map(\.startMs) == [12000, 12400, 13500])
        #expect(line.currentSyllable(at: 13000) == nil)
        #expect(doc.findActiveLine(at: 11999) == nil)
        #expect(doc.findActiveLine(at: 14500) == nil)
        let legacy = try #require(doc.toLyrics().synced?.first)
        #expect(legacy.words?.map(\.startsNewWord) == [true, false, true])
        #expect(legacy.words?.first?.endTime == 12400)
    }

    @Test func richsyncOffsetsBecomeAbsoluteAndLastFragmentEndsAtLineEnd() throws {
        let doc = try #require(WordSyncTranspilers.richSync(#"[{"ts":12.5,"te":14.0,"x":"Hi there","l":[{"c":"Hi ","o":0.0},{"c":"there","o":0.5}]}]"#))
        #expect(doc.lines.first?.syllables.map(\.startMs) == [12500, 13000])
        #expect(doc.lines.first?.syllables.last?.durationMs == 1000)
    }

    @Test func richsyncAllowsLineOnlyAndRejectsInvalidOffsetsAndTextLoss() throws {
        #expect(try #require(WordSyncTranspilers.richSync(#"[{"ts":1,"te":2,"x":"hello"}]"#)).lines.first?.syllables.isEmpty == true)
        #expect(WordSyncTranspilers.richSync(#"[{"ts":1,"te":2,"x":"hello","l":[{"c":"hello","o":-1}]}]"#) == nil)
        #expect(WordSyncTranspilers.richSync(#"[{"ts":1,"te":2,"x":"full line","l":[{"c":"half","o":0}]}]"#) == nil)
    }

    @Test(arguments: ["[100,300](50,100,0)early", "[100,300](100,999,0)long", "[100,300](100,-1,0)bad", "[100,300](<100,200,0>)wrong"])
    func invalidYrcNeverBecomesGuessedTiming(_ raw: String) {
        #expect(WordSyncTranspilers.yrc(raw) == nil)
    }

    @Test func documentRoundTripRetainsRolesOverlapAndExclusiveEnds() throws {
        let doc = LyricsDoc(voices: [Voice(), Voice(id: "back", role: "background"), Voice(id: "guest", role: "duet")],
                            lines: [TimedLine(startMs: 1000, endMs: 3000, text: "Lead"),
                                    TimedLine(startMs: 1500, endMs: 2200, text: "Echo", voiceId: "back"),
                                    TimedLine(startMs: 2000, endMs: 3500, text: "Guest", voiceId: "guest")])
        let restored = try #require(LyricsDocCodec.decode(LyricsDocCodec.encode(doc)))
        #expect(restored == doc)
        #expect(restored.activeLines(at: 2100).count == 3)
        #expect(restored.findActiveLine(at: 2100)?.text == "Lead")
        #expect(restored.activeLines(at: 2200).count == 2)
        #expect(restored.findActiveLine(at: 3500) == nil)
        #expect(LyricsUtils.parseLyrics(LyricsDocCodec.encode(doc)).synced?[1].voiceRole == "background")
    }

    @Test func jsonRejectsUnsupportedVersionUnknownVoiceAndExcessiveDepth() {
        let doc = LyricsDoc(lines: [TimedLine(startMs: 1, endMs: 2, text: "a")])
        var v2 = doc
        v2.version = 2
        #expect(LyricsDocCodec.decode(LyricsDocCodec.encode(v2)) == nil)
        #expect(!LyricsDocCodec.isValid(LyricsDoc(lines: [TimedLine(startMs: 1, endMs: 2, text: "a", voiceId: "missing")])))
        #expect(LyricsDocCodec.decode(String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)) == nil)
    }

    @Test func parserDispatchesYrcWithoutTreatingItAsKugouRelativeOffsets() {
        #expect(LyricsUtils.parseLyrics(Self.yrc).synced?.first?.words?.first?.time == 12000)
        #expect(LyricsUtils.parseLyrics(Self.yrc).document != nil)
    }

    @Test func neteaseRejectsWrongRecordingEvenWhenSearchReturnsItFirst() throws {
        func track(title: String = "Example", artist: String = "Singer", album: String = "Album", duration: Int = 180000) throws -> JSONObject {
            try Self.track(#"{"name":"\#(title)","artists":[{"name":"\#(artist)"}],"album":{"name":"\#(album)"},"duration":\#(duration)}"#)
        }
        let song = Self.song()
        #expect(NeteaseLyricsMatching.matchesRecording(song: song, track: try track()))
        #expect(!NeteaseLyricsMatching.matchesRecording(song: song, track: try track(title: "Example (Live)")))
        #expect(!NeteaseLyricsMatching.matchesRecording(song: song, track: try track(artist: "Cover Artist")))
        #expect(!NeteaseLyricsMatching.matchesRecording(song: song, track: try track(album: "Other Recording")))
        #expect(!NeteaseLyricsMatching.matchesRecording(song: song, track: try track(duration: 195000)))
    }

    @Test func realYrcStructureRetainsEveryTimedFragment() throws {
        let doc = try #require(WordSyncTranspilers.yrc(try Self.fixture("netease-yrc-structure.yrc")))
        #expect(doc.lines.reduce(0) { $0 + $1.syllables.count } == 458)
    }

    @Test func documentImportUsesTheExistingValidatedImportPath() throws {
        let raw = LyricsDocCodec.encode(try #require(WordSyncTranspilers.yrc(Self.yrc)))
        let result = LyricsImportSecurity.validateImportedLyricsFile(fileName: "song.json", mimeType: "application/json",
                                                                     bytes: Array(raw.utf8))
        guard case .valid(let value) = result else {
            Issue.record("Expected valid, got \(result)")
            return
        }
        #expect(value.parsedLyrics.synced?.first?.endTime == 14500)
    }

    @Test(arguments: ["netease-featured-punctuation.yrc", "netease-punctuation.yrc"])
    func realCatalogPunctuationPreservesTextAndPositiveOnsets(_ name: String) throws {
        let raw = try Self.fixture(name)
        let doc = try #require(WordSyncTranspilers.yrc(raw))
        let sourceLines = ParseKit.lines(raw).filter { !$0.isKotlinBlank }
        #expect(sourceLines.count == doc.lines.count)
        for (source, line) in zip(sourceLines, doc.lines) {
            // source.substringAfter(']') with every `(\d+,\d+,0)` removed.
            let body = ParseKit.substringAfter(source, "]", missing: source)
            var expectedText = ""
            var onsets: [Int64] = []
            let scalars = Array(body.unicodeScalars)
            var i = 0
            while i < scalars.count {
                if scalars[i] == "(", let close = scalars[i...].firstIndex(of: ")") {
                    let inner = String(String.UnicodeScalarView(scalars[(i + 1)..<close]))
                    let parts = inner.split(separator: ",", omittingEmptySubsequences: false)
                    if parts.count == 3, parts[2] == "0", let start = Int64(parts[0]), let duration = Int64(parts[1]) {
                        if duration > 0 { onsets.append(start) }
                        i = close + 1
                        continue
                    }
                }
                expectedText.unicodeScalars.append(scalars[i])
                i += 1
            }
            #expect(line.text == expectedText)
            #expect(line.syllables.map(\.startMs) == onsets)
        }
    }

    @Test func zeroDurationSpeechIsNotInventedAndPunctuationRetainsNeighborTime() throws {
        #expect(WordSyncTranspilers.yrc("[100,300](100,0,0)missing(100,300,0)word") == nil)
        let line = try #require(WordSyncTranspilers.yrc("[100,300](100,0,0), (100,300,0)word")?.lines.first)
        #expect(line.text == ", word")
        #expect(line.syllables == [TimedSyllable(startMs: 100, durationMs: 300, text: ", word")])
    }

    // MARK: Swift-only

    @Test func yrcSkipsJsonMetadataAndBlankLinesAndKeepsMetadataSource() throws {
        let doc = try #require(WordSyncTranspilers.yrc("{\"t\":0,\"c\":[]}\n\n[100,300](100,300,0)a\r\n[500,200](500,200,0)b"))
        #expect(doc.lines.map(\.text) == ["a", "b"])
        #expect(doc.metadata.source == "NetEase")
        #expect(WordSyncTranspilers.yrc("[100,300]plain")?.lines.first?.syllables.isEmpty == true)
        #expect(WordSyncTranspilers.yrc("[100,300]bad (12, marker") == nil)
        #expect(WordSyncTranspilers.yrc("[99999999999999999999,1](1,1,0)x") == nil)
        #expect(WordSyncTranspilers.yrc(String(repeating: "x", count: 1_048_577)) == nil)
    }

    @Test func richSyncRoundsWithJavaMathRoundAndAcceptsNumericStrings() throws {
        let doc = try #require(WordSyncTranspilers.richSync(#"[{"ts":"1.5","te":"2","x":"ab","l":[{"c":"a","o":"0"},{"c":"b","o":0.0006}]}]"#))
        #expect(doc.lines.first?.startMs == 1500)
        #expect(doc.lines.first?.syllables.map(\.startMs) == [1500, 1501])
        #expect(WordSyncTranspilers.richSync(#"[{"ts":1,"te":2,"x":"a","l":null}]"#) == nil)
        #expect(WordSyncTranspilers.richSync(#"[{"ts":true,"te":2,"x":"a"}]"#) == nil)
        #expect(WordSyncTranspilers.richSync("[]") == nil)
    }
}
