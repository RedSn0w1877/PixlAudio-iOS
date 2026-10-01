import Foundation
import Testing
import PixlFoundation
@testable import PixlModel

/// `LyricsDocCodec` against the real Android codec: every case in `Fixtures/lyricsdoc-android-golden.txt` was run
/// through the Android app's compiled `LyricsDocCodec.decode` and, when it decoded, re-encoded with `encode`
/// (kotlinx.serialization 1.11). Regenerate with `tools/android-reference/DocGen.java`.
@Suite("LyricsDoc codec (Android golden)")
struct LyricsDocGoldenTests {
    enum FixtureError: Error { case malformed(String) }

    static func cases() throws -> [(input: String, output: String?)] {
        let url = try #require(Bundle.module.url(forResource: "lyricsdoc-android-golden", withExtension: "txt",
                                                 subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let parser = JSONParser()
        var out: [(String, String?)] = []
        var pendingInput: String?
        for line in lines {
            if line.hasPrefix("IN ") {
                let value = try parser.parse(String(line.dropFirst(3)))
                guard case .string(let input) = value else { throw FixtureError.malformed(String(line)) }
                pendingInput = input
            } else if line.hasPrefix("OUT ") {
                let input = try #require(pendingInput)
                let rest = String(line.dropFirst(4))
                if rest == "null" {
                    out.append((input, nil))
                } else {
                    let value = try parser.parse(rest)
                    guard case .string(let output) = value else { throw FixtureError.malformed(String(line)) }
                    out.append((input, output))
                }
                pendingInput = nil
            }
        }
        return out
    }

    @Test func decodeAndReencodeMatchAndroidByteForByte() throws {
        let cases = try Self.cases()
        #expect(cases.count == 66)
        for (index, c) in cases.enumerated() {
            let decoded = LyricsDocCodec.decode(c.input)
            if let expected = c.output {
                let doc = try #require(decoded, "case \(index): Android decoded \(c.input.prefix(120))")
                let encoded = LyricsDocCodec.encode(doc)
                #expect(encoded.isIdentical(to: expected), "case \(index):\n ours    \(encoded)\n android \(expected)")
                // Android's own output is canonical: it decodes to the same document and re-encodes identically.
                #expect(LyricsDocCodec.decode(expected) == doc, "case \(index)")
                #expect(LyricsDocCodec.encode(try #require(LyricsDocCodec.decode(expected))).isIdentical(to: expected))
            } else {
                #expect(decoded == nil, "case \(index): Android rejected \(c.input.prefix(120))")
            }
        }
    }
}

/// Ported from Android `data/network/lyrics/WordSyncTranspilersTest` (the `LyricsDoc` model and codec parts;
/// the YRC/RichSync transpilers themselves are ported with the lyrics parsers in PixlLyrics).
@Suite("LyricsDoc model")
struct LyricsDocModelTests {
    /// What `WordSyncTranspilers.yrc("[12000,2500](12000,400,0)Hel(12400,600,0)lo (13500,1000,0)there")` builds.
    static let yrcDoc = LyricsDoc(lines: [
        TimedLine(startMs: 12000, endMs: 14500, text: "Hello there", syllables: [
            TimedSyllable(startMs: 12000, durationMs: 400, text: "Hel"),
            TimedSyllable(startMs: 12400, durationMs: 600, text: "lo "),
            TimedSyllable(startMs: 13500, durationMs: 1000, text: "there"),
        ]),
    ])

    // yrcUsesAbsoluteTimesAndPreservesSyllableJoinsAndGaps (model half)
    @Test func syllableGapsJoinsAndLegacyWords() throws {
        let doc = Self.yrcDoc
        #expect(LyricsDocCodec.isValid(doc))
        let line = try #require(doc.lines.first)
        #expect(line.text == "Hello there")
        #expect(line.syllables.map(\.startMs) == [12000, 12400, 13500])
        #expect(line.currentSyllable(at: 13000) == nil)
        #expect(line.currentSyllable(at: 12400)?.text == "lo ")
        #expect(doc.findActiveLine(at: 11999) == nil)
        #expect(doc.findActiveLine(at: 14500) == nil)
        let legacy = try #require(doc.toLyrics().synced?.first)
        #expect(legacy.words?.map(\.startsNewWord) == [true, false, true])
        #expect(legacy.words?.first?.endTime == 12400)
        #expect(legacy.words?.map(\.word) == ["Hel", "lo", "there"])
        #expect(legacy.endTime == 14500)
        #expect(legacy.voiceRole == "lead")
        #expect(doc.toLyrics().plain == ["Hello there"])
        #expect(doc.toLyrics().document == doc)
    }

    // documentRoundTripRetainsRolesOverlapAndExclusiveEnds
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
        #expect(restored.toLyrics().synced?[1].voiceRole == "background")
        // When no lead line is active the last active line is used.
        #expect(restored.findActiveLine(at: 3200)?.text == "Guest")
    }

    // jsonRejectsUnsupportedVersionUnknownVoiceAndExcessiveDepth
    @Test func jsonRejectsUnsupportedVersionUnknownVoiceAndExcessiveDepth() {
        let doc = LyricsDoc(lines: [TimedLine(startMs: 1, endMs: 2, text: "a")])
        var v2 = doc
        v2.version = 2
        #expect(LyricsDocCodec.decode(LyricsDocCodec.encode(v2)) == nil)
        var missingVoice = doc
        missingVoice.lines = [TimedLine(startMs: 1, endMs: 2, text: "a", voiceId: "missing")]
        #expect(!LyricsDocCodec.isValid(missingVoice))
        #expect(LyricsDocCodec.decode(String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)) == nil)
    }

    // zeroDurationSpeechIsNotInventedAndPunctuationRetainsNeighborTime (model half)
    @Test func zeroDurationSyllablesAreInvalid() {
        let doc = LyricsDoc(lines: [TimedLine(startMs: 100, endMs: 400, text: "missingword", syllables: [
            TimedSyllable(startMs: 100, durationMs: 0, text: "missing"),
            TimedSyllable(startMs: 100, durationMs: 300, text: "word"),
        ])])
        #expect(!LyricsDocCodec.isValid(doc))
    }

    @Test func validationRules() {
        let base = LyricsDoc(lines: [TimedLine(startMs: 0, endMs: 1000, text: "ab", syllables: [
            TimedSyllable(startMs: 0, durationMs: 500, text: "a"), TimedSyllable(startMs: 500, durationMs: 500, text: "b"),
        ])])
        #expect(LyricsDocCodec.isValid(base))
        var d = base
        d.lines[0].syllables[1].durationMs = 501 // runs past the line end
        #expect(!LyricsDocCodec.isValid(d))
        d = base
        d.lines[0].text = "a b" // text loss
        #expect(!LyricsDocCodec.isValid(d))
        d = base
        d.metadata.durationMs = 999 // line ends after the song
        #expect(!LyricsDocCodec.isValid(d))
        d = base
        d.voices = (0..<33).map { Voice(id: "v\($0)") }
        #expect(!LyricsDocCodec.isValid(d))
        d = base
        d.voices = [Voice(id: "lead", role: "Lead")]
        #expect(!LyricsDocCodec.isValid(d))
        d = base
        d.format = "pixelplay-lyric"
        #expect(!LyricsDocCodec.isValid(d))
        d = base
        d.lines = Array(repeating: TimedLine(startMs: 0, endMs: 1, text: "x"), count: 10_001)
        #expect(!LyricsDocCodec.isValid(d))
        d.lines = Array(repeating: TimedLine(startMs: 0, endMs: 1, text: "x"), count: 10_000)
        #expect(LyricsDocCodec.isValid(d))
        // Canonically equivalent but different code units: Android compares code units.
        d = LyricsDoc(lines: [TimedLine(startMs: 0, endMs: 10, text: "e\u{301}", syllables: [
            TimedSyllable(startMs: 0, durationMs: 10, text: "\u{E9}"),
        ])])
        #expect(!LyricsDocCodec.isValid(d))
    }

    @Test func boundedJsonPrecheck() {
        #expect(LyricsDocCodec.isBoundedJson(#"{"a":"[[[[" }"#))
        #expect(!LyricsDocCodec.isBoundedJson(#"{"a":"unterminated}"#))
        #expect(!LyricsDocCodec.isBoundedJson("}{"))
        #expect(!LyricsDocCodec.isBoundedJson(String(repeating: "{", count: 33) + String(repeating: "}", count: 33)))
        #expect(LyricsDocCodec.isBoundedJson(String(repeating: "[", count: 32) + String(repeating: "]", count: 32)))
        #expect(LyricsDocCodec.isBoundedJson(#"{"a":"\"[["}"#))
        #expect(!LyricsDocCodec.isBoundedJson(String(repeating: " ", count: LyricsDocCodec.maxInputLength + 1)))
    }

    @Test func encodeWritesEveryDefaultInDeclarationOrder() {
        let doc = LyricsDoc(lines: [TimedLine(startMs: 1, endMs: 2, text: "a")])
        #expect(LyricsDocCodec.encode(doc) ==
            #"{"format":"pixelplay-lyrics","version":1,"metadata":{"title":"","artist":"","album":"","durationMs":null,"source":null},"voices":[{"id":"lead","role":"lead","name":null}],"lines":[{"startMs":1,"endMs":2,"text":"a","voiceId":"lead","syllables":[]}]}"#)
    }

    @Test func foundationCodableRoundTrip() throws {
        let doc = Self.yrcDoc
        let data = try JSONEncoder().encode(doc)
        #expect(try JSONDecoder().decode(LyricsDoc.self, from: data) == doc)
        // Foundation decoding fills Android's defaults too.
        let minimal = try JSONDecoder().decode(LyricsDoc.self, from: Data(#"{"lines":[{"startMs":1,"endMs":2,"text":"a"}]}"#.utf8))
        #expect(minimal == LyricsDoc(lines: [TimedLine(startMs: 1, endMs: 2, text: "a")]))
        let lyrics = doc.toLyrics()
        #expect(try JSONDecoder().decode(Lyrics.self, from: JSONEncoder().encode(lyrics)) == lyrics)
        let legacy = try JSONDecoder().decode(Lyrics.self, from: Data(#"{"synced":[{"time":5,"line":"x","words":[{"time":5,"word":"x"}]}]}"#.utf8))
        #expect(legacy.synced?.first?.voiceRole == "lead")
        #expect(legacy.synced?.first?.words?.first?.startsNewWord == true)
        #expect(legacy.areFromRemote == false)
    }
}
