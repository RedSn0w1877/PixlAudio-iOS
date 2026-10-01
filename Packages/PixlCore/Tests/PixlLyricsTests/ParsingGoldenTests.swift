import Foundation
import Testing
import PixlFoundation
import PixlModel
@testable import PixlLyrics

/// Compares every parser with the compiled Android implementation: `Fixtures/parsing/lyrics-android-golden.txt`
/// is produced by `tools/android-reference/LyricsGen.java` from `lyrics-cases.txt` (see that README).
@Suite("Parsing — Android golden vectors")
struct ParsingGoldenTests {

    struct GoldenCase {
        let kind: String
        let args: [String?]
        let expected: String
    }

    /// pinyin4j's readings for the Han characters the cases use, so Chinese romanisation is comparable.
    struct GoldenPinyin: CJKRomanizationProvider {
        let table: [String: String?]
        func romanizeJapanese(_ text: String) -> String? { nil } // kuromoji+ICU unavailable on the generator JVM too
        func pinyinReading(for hanzi: Character) -> String? { table[String(hanzi)] ?? nil }
    }

    static func load() throws -> (pinyin: GoldenPinyin, cases: [GoldenCase]) {
        let url = try #require(Bundle.module.url(forResource: "lyrics-android-golden", withExtension: "txt",
                                                 subdirectory: "Fixtures/parsing"))
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let pinyinLine = lines.removeFirst()
        #expect(pinyinLine.hasPrefix("PINYIN "))
        var table: [String: String?] = [:]
        if case .object(let o) = try JSONParser().parse(String(pinyinLine.dropFirst(7))) {
            for (k, v) in o { table[k] = v.stringValue }
        }
        var cases: [GoldenCase] = []
        var index = 0
        while index + 1 < lines.count {
            let input = lines[index], output = lines[index + 1]
            index += 2
            #expect(input.hasPrefix("IN ") && output.hasPrefix("OUT "))
            let rest = input.dropFirst(3)
            let space = rest.firstIndex(of: " ")!
            let kind = String(rest[..<space])
            let argsJSON = String(rest[rest.index(after: space)...])
            guard case .array(let items) = try JSONParser().parse(argsJSON) else { continue }
            cases.append(GoldenCase(kind: kind, args: items.map { $0.stringValue }, expected: String(output.dropFirst(4))))
        }
        return (GoldenPinyin(table: table), cases)
    }

    // MARK: Canonical JSON (same shape LyricsGen prints)

    static func q(_ s: String?) -> String {
        guard let s else { return "null" }
        var out = ""
        JSONWriter.writeString(s, into: &out)
        return out
    }

    static func lyricsJSON(_ l: Lyrics?) -> String {
        guard let l else { return "null" }
        var s = "{\"plain\":"
        s += l.plain.map { "[" + $0.map(q).joined(separator: ",") + "]" } ?? "null"
        s += ",\"synced\":"
        if let synced = l.synced {
            s += "[" + synced.map { line in
                var o = "{\"time\":\(line.time),\"line\":\(q(line.line)),\"words\":"
                o += line.words.map { words in
                    "[" + words.map { w in
                        "{\"time\":\(w.time),\"word\":\(q(w.word)),\"startsNewWord\":\(w.startsNewWord),\"endTime\":\(w.endTime.map(String.init) ?? "null")}"
                    }.joined(separator: ",") + "]"
                } ?? "null"
                o += ",\"translation\":\(q(line.translation)),\"romanization\":\(q(line.romanization))"
                o += ",\"endTime\":\(line.endTime.map(String.init) ?? "null"),\"voiceRole\":\(q(line.voiceRole))}"
                return o
            }.joined(separator: ",") + "]"
        } else {
            s += "null"
        }
        s += ",\"areFromRemote\":\(l.areFromRemote),\"document\":\(q(l.document.map(LyricsDocCodec.encode)))}"
        return s
    }

    static func importJSON(_ r: LyricsImportValidationResult) -> String {
        switch r {
        case .valid(let v): return "{\"valid\":true,\"sanitized\":\(q(v.sanitizedContent)),\"lyrics\":\(lyricsJSON(v.parsedLyrics))}"
        case .invalid(let reason): return "{\"valid\":false,\"reason\":\(q(reason.rawValue))}"
        }
    }

    static func setJSON(_ set: Set<String>) -> String {
        "[" + set.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.map(q).joined(separator: ",") + "]"
    }

    static func song(_ title: String, _ artist: String, _ album: String, _ path: String, _ duration: Int64) -> Song {
        Song(id: "1", title: title, artist: artist, artistId: 1, album: album, albumId: 1, path: path, contentUriString: "",
             albumArtUriString: nil, duration: duration, mimeType: nil, bitrate: nil, sampleRate: nil)
    }

    static func strings(_ json: String) throws -> [String] {
        guard case .array(let items) = try JSONParser().parse(json) else { return [] }
        return items.compactMap { $0.stringValue }
    }

    static func mode(_ s: String?) -> RemoteLyricsMatchMode { s == "CANDIDATE" ? .candidate : .automatic }

    static func run(_ c: GoldenCase, _ p: GoldenPinyin) throws -> String {
        let a = c.args
        func arg(_ i: Int) -> String { a[i] ?? "" }
        switch c.kind {
        case "P":
            return lyricsJSON(LyricsUtils.parseLyrics(a[0], romanization: p))
        case "Z":
            let l = LyricsUtils.parseLyrics(a[0], romanization: p)
            return "[" + q(LyricsUtils.toLrcString(l, preferSynced: true)) + "," + q(LyricsUtils.toLrcString(l, preferSynced: false)) + "]"
        case "T":
            return q(TtmlLyricsParser.parseToEnhancedLrc(arg(0)))
        case "Y":
            return q(WordSyncTranspilers.yrc(arg(0)).map(LyricsDocCodec.encode))
        case "R":
            return q(WordSyncTranspilers.richSync(arg(0)).map(LyricsDocCodec.encode))
        case "L":
            return lyricsJSON(LyricsfileParser.parse(a[0]))
        case "I":
            let reported = a.count > 3 ? a[3].flatMap { Int64($0) } : nil
            return importJSON(LyricsImportSecurity.validateImportedLyricsFile(fileName: a[0], mimeType: a[1],
                                                                              bytes: Array(arg(2).utf8), reportedSizeBytes: reported))
        case "IH":
            let hex = Array(arg(2).utf8)
            var bytes: [UInt8] = []
            var i = 0
            while i + 1 < hex.count {
                bytes.append(UInt8(String(decoding: hex[i...(i + 1)], as: UTF8.self), radix: 16)!)
                i += 2
            }
            return importJSON(LyricsImportSecurity.validateImportedLyricsFile(fileName: a[0], mimeType: a[1], bytes: bytes))
        case "IC":
            return importJSON(LyricsImportSecurity.validateImportedLrcContent(arg(0)))
        case "RO":
            let t = arg(0)
            return "{\"zh\":\(q(MultiLangRomanizer.romanizeChinese(t, provider: p))),\"ko\":\(q(MultiLangRomanizer.romanizeKorean(t)))"
                + ",\"hi\":\(q(MultiLangRomanizer.romanizeHindi(t))),\"pa\":\(q(MultiLangRomanizer.romanizePunjabi(t)))"
                + ",\"cyr\":\(q(MultiLangRomanizer.romanizeCyrillic(t))),\"needs\":\(MultiLangRomanizer.isScriptThatNeedsRomanization(t))}"
        case "NM":
            let v = arg(0)
            return "{\"normalize\":\(q(LrcLibMatching.normalizeForMatch(v))),\"base\":\(q(LrcLibMatching.baseTitleForMatching(v)))"
                + ",\"variants\":\(setJSON(LrcLibMatching.timingVariantTokens(v))),\"smart\":\(q(LrcLibMatching.cleanTitleSmart(v)))"
                + ",\"roman\":\(q(LrcLibMatching.romanizeForMatch(v, romanization: p)))}"
        case "TS":
            let t = LrcLibMatching.titleMatchScore(arg(1), arg(2), mode: mode(a[0]), romanization: p)
            let r = LrcLibMatching.artistMatchScore(arg(1), arg(2), romanization: p)
            return "{\"title\":\(t.map(String.init) ?? "null"),\"artist\":\(r.map(String.init) ?? "null")}"
        case "M":
            let s = song(arg(1), arg(2), "Album", arg(3), Int64(arg(4))!)
            let responses = try #require(LrcLibResponse.decodeList(try JSONParser(mode: .kotlinx).parse(arg(5))))
            let ranked = LrcLibMatching.rankRemoteLyricsMatches(song: s, responses: responses, mode: mode(a[0]), romanization: p)
            return "[" + ranked.map { "{\"id\":\($0.response.id),\"score\":\($0.score),\"raw\":\(q($0.response.rawLyrics))}" }
                .joined(separator: ",") + "]"
        case "A":
            let s = song(arg(0), arg(1), arg(2), "", 0)
            return String(AmllLyricsMatching.matchesMetadata(song: s, titles: try strings(arg(3)), artists: try strings(arg(4)),
                                                             albums: try strings(arg(5))))
        case "N":
            let s = song(arg(0), arg(1), arg(2), "", Int64(arg(3))!)
            guard case .object(let track) = try JSONParser().parse(arg(4)) else { return "?" }
            return String(NeteaseLyricsMatching.matchesRecording(song: s, track: track))
        case "E":
            guard case .object(let o) = try JSONParser().parse(arg(0)) else { return "?" }
            var map: [String: [String]] = [:]
            for (k, v) in o { map[k] = (v.arrayValue ?? []).compactMap { $0.stringValue } }
            return lyricsJSON(LyricsRepositoryLogic.parseBestEmbeddedLyricsField(map, romanization: p))
        case "RAW":
            let l = LyricsUtils.parseLyrics(arg(0), romanization: p)
            return "{\"raw\":\(q(LyricsRepositoryLogic.lyricsToRawContent(l))),\"flattened\":\(LyricsRepositoryLogic.looksLikeFlattenedWordByWordCache(l))}"
        default:
            Issue.record("Unknown golden kind \(c.kind)")
            return ""
        }
    }

    static let goldenData: (pinyin: GoldenPinyin, cases: [GoldenCase])? = try? load()

    @Test func fixtureLoads() throws {
        let data = try #require(Self.goldenData)
        #expect(data.cases.count > 400)
        #expect(!data.pinyin.table.isEmpty)
    }

    @Test(arguments: ["P", "Z", "T", "Y", "R", "L", "I", "IH", "IC", "RO", "NM", "TS", "M", "A", "N", "E", "RAW"])
    func matchesAndroid(kind: String) throws {
        let data = try #require(Self.goldenData)
        let cases = data.cases.filter { $0.kind == kind }
        #expect(!cases.isEmpty)
        var failures = 0
        for c in cases {
            let actual = try Self.run(c, data.pinyin)
            if !actual.isIdentical(to: c.expected) {
                failures += 1
                if failures <= 12 {
                    Issue.record("\(kind) \(c.args.map { $0.map { String($0.prefix(160)) } ?? "<null>" })\n  android: \(c.expected.prefix(900))\n  swift:   \(actual.prefix(900))")
                }
            }
        }
        #expect(failures == 0, "\(failures) of \(cases.count) \(kind) cases differ from Android")
    }
}
