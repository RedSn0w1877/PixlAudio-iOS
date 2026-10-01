// Byte-exact parity with the Android implementation. `Fixtures/tapsync-android-golden.txt` was written by
// `tools/android-reference/TapSyncGen.java`, which runs the Android app's compiled `LyricsTapSync`, `LyricsExport`
// and `LyricsSyncDraftStore` codec (kotlinx.serialization 1.11) on the JVM. See that file for the line kinds.

import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLyrics

@Suite("Tap-sync Android golden vectors")
struct TapSyncGoldenTests {

    struct Golden {
        var random: [(seed: Int32, values: [String])] = []
        var tokenize: [(input: String, tokens: [String])] = []
        var sessions: [(seed: Int32, actions: Int, hash: String)] = []
        var draft = ""
        var decode: [(input: String, output: String?)] = []
        var sha1: [(id: String, hex: String)] = []
        var lrc: [String: String] = [:]
        var ttml: [String: String] = [:]
    }

    static func jsonString(_ literal: Substring) throws -> String {
        try #require(JSONParser().parse(String(literal)).stringValue)
    }

    /// Splits `"json string literal" rest` into the decoded string and `rest`.
    static func leadingJSONString(_ s: Substring) throws -> (String, Substring) {
        let utf8 = s.utf8
        var it = utf8.index(after: utf8.startIndex) // past the opening quote
        var escaped = false
        while it < utf8.endIndex {
            let byte = utf8[it]
            if escaped {
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                break
            }
            it = utf8.index(after: it)
        }
        let end = utf8.index(after: it)
        return (try jsonString(s[s.startIndex..<end]), s[end...].dropFirst())
    }

    static func load() throws -> Golden {
        let url = try #require(Bundle.module.url(forResource: "tapsync-android-golden", withExtension: "txt",
                                                 subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        var golden = Golden()
        var pendingDecode: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let kind = line[..<space]
            let rest = line[line.index(after: space)...]
            switch kind {
            case "R":
                let parts = rest.split(separator: " ").map(String.init)
                golden.random.append((Int32(parts[0])!, Array(parts.dropFirst())))
            case "T":
                let (input, remainder) = try leadingJSONString(rest)
                let tokens = try #require(JSONParser().parse(String(remainder)).arrayValue).map { try #require($0.stringValue) }
                golden.tokenize.append((input, tokens))
            case "S":
                let parts = rest.split(separator: " ")
                golden.sessions.append((Int32(parts[0])!, Int(parts[1])!, String(parts[2])))
            case "D":
                golden.draft = try jsonString(rest)
            case "DIN":
                pendingDecode = try jsonString(rest)
            case "DOUT":
                let input = try #require(pendingDecode)
                golden.decode.append((input, rest == "null" ? nil : try jsonString(rest)))
                pendingDecode = nil
            case "H":
                let split = try #require(rest.lastIndex(of: " "))
                golden.sha1.append((try jsonString(rest[..<split]), String(rest[rest.index(after: split)...])))
            case "L", "X":
                let split = try #require(rest.firstIndex(of: " "))
                let name = String(rest[..<split])
                let value = try jsonString(rest[rest.index(after: split)...])
                if kind == "L" { golden.lrc[name] = value } else { golden.ttml[name] = value }
            default:
                continue
            }
        }
        return golden
    }

    // MARK: Kotlin Random

    @Test func kotlinRandomMatchesTheJvm() throws {
        let golden = try Self.load()
        #expect(golden.random.count == 9)
        for (seed, expected) in golden.random {
            var r = KotlinRandom(seed: seed)
            var v: [String] = []
            for _ in 0..<3 { v.append(String(r.nextInt())) }
            for _ in 0..<3 { v.append(String(r.nextInt(1, 14))) }
            v.append(String(r.nextInt(0, 401)))
            v.append(String(r.nextInt(100)))
            v.append(String(r.nextInt(8)))
            v.append(String(r.nextInt(3)))
            v.append(String(r.nextInt(16)))
            v.append(String(r.nextInt(-500, 501)))
            v.append(String(r.nextInt(Int32.min, Int32.max)))
            for _ in 0..<2 { v.append(String(r.nextLong(-400, 2_000))) }
            v.append(String(r.nextLong(0, 5_000)))
            v.append(String(r.nextLong(1, 900)))
            v.append(String(r.nextLong(-100, 900)))
            v.append(String(r.nextLong(0, 4_096)))
            v.append(String(r.nextLong(0, 1 << 32)))
            v.append(String(r.nextLong(0, 1 << 40)))
            v.append(String(r.nextLong(Int64.min, Int64.max)))
            v.append(String(r.nextLong()))
            for _ in 0..<3 { v.append(r.nextBoolean() ? "1" : "0") }
            #expect(v == expected, "seed \(seed)")
        }
    }

    // MARK: tokenize

    @Test func tokenizeMatchesAndroid() throws {
        let golden = try Self.load()
        #expect(golden.tokenize.count > 460)
        for (input, expected) in golden.tokenize {
            let tokens = LyricsTapSync.tokenize(input)
            let same = tokens.count == expected.count && zip(tokens, expected).allSatisfy { $0.isIdentical(to: $1) }
            #expect(same, "tokenize(\(JSONWriter.write(.string(input)))) = \(tokens), Android \(expected)")
        }
    }

    // MARK: Random sessions

    static func fnv(_ hash: inout UInt64, _ text: String) {
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
    }

    static func resultRecord(_ draft: SyncDraft, _ offset: Int) -> String {
        guard case .success(let result) = LyricsTapSync.buildResult(draft, offsetMs: offset) else { return "F" }
        return LyricsDocCodec.encode(result.doc) + "\u{1}" + result.roughLineIndices.sorted().map(String.init).joined(separator: ",")
    }

    static func stepInfo(_ step: SyncStep?) -> String {
        guard let step else { return "-" }
        return (step.seekToMs.map(String.init) ?? "n") + ",\(step.clearedCount),\(step.pastNextLine ? 1 : 0),\(step.tapBeforeAnchor ? 1 : 0)"
    }

    /// `TapSyncGen.stepRecord`.
    static func stepRecord(_ draft: SyncDraft, _ step: SyncStep?, _ offset: Int) -> String {
        LyricsSyncDraftCodec.encode(draft, nowMs: 0) + "\u{1}" + stepInfo(step) + "\u{1}"
            + (LyricsTapSync.isConsistent(draft) ? "C1" : "C0") + "\u{1}" + resultRecord(draft, offset) + "\n"
    }

    /// Replays one seed and returns (actions, hash, per-step records).
    static func replay(_ seed: Int32) -> (actions: Int, hash: String, records: [String]) {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        var records: [String] = []
        let (actions, _) = RandomSessions.run(seed: seed) { event, offset in
            var record: String
            switch event.label {
            case "init":
                record = stepRecord(event.after, nil, offset)
            case "final":
                record = stepRecord(event.after, nil, offset)
                if case .success(let result) = LyricsTapSync.buildResult(event.after, offsetMs: offset) {
                    record += LyricsExport.toEnhancedLrc(result.doc) + "\u{1}" + LyricsExport.toTtml(result.doc)
                }
            default:
                record = stepRecord(event.after, event.step, offset)
            }
            fnv(&hash, record)
            records.append("\(event.label) a\(event.action) " + record)
        }
        let hex = String(hash, radix: 16)
        return (actions, String(repeating: "0", count: 16 - hex.count) + hex, records)
    }

    @Test func randomSessionsMatchAndroidStepByStep() throws {
        let golden = try Self.load()
        #expect(golden.sessions.count == 500)
        var mismatches = 0
        for (seed, actions, hash) in golden.sessions {
            let replayed = Self.replay(seed)
            if replayed.actions != actions || replayed.hash != hash {
                mismatches += 1
                if mismatches <= 3 {
                    // Write the replay next to the temp dir so it can be diffed against `TapSyncGen debug <seed>`.
                    let dump = FileManager.default.temporaryDirectory
                        .appendingPathComponent("tapsync-seed-\(seed).txt", isDirectory: false)
                    try? replayed.records.joined().write(to: dump, atomically: true, encoding: .utf8)
                    Issue.record("seed \(seed): \(replayed.actions) actions, hash \(replayed.hash); Android \(actions), \(hash) (replay in \(dump.path))")
                }
            }
        }
        #expect(mismatches == 0)
    }

    // MARK: Draft JSON

    func storeDraft(_ songId: String = "content://media/42") -> SyncDraft {
        var d = LyricsTapSync.buildDraft(songId: songId, title: "Title", artist: "Artist", album: "Album",
                                         durationMs: 200_000, lyrics: nil, pasted: "Hello world\n君が好き").draft!
        d = LyricsTapSync.tap(d, rawStartMs: 1_000, speed: 0.75, offsetMs: 100).draft
        d = LyricsTapSync.tap(d, rawStartMs: 1_400, speed: 1, offsetMs: 100).draft
        d = LyricsTapSync.release(d, tokenIndex: 1, rawEndMs: 2_600, speed: 1, offsetMs: 100)
        return LyricsTapSync.setNudge(d, nudgeMs: -20)
    }

    @Test func draftEncodesByteForByte() throws {
        let golden = try Self.load()
        #expect(LyricsSyncDraftCodec.encode(storeDraft(), nowMs: 1_234_567_890_123).isIdentical(to: golden.draft))
    }

    @Test func draftDecodesLikeAndroid() throws {
        let golden = try Self.load()
        #expect(golden.decode.count > 50)
        for (index, (input, expected)) in golden.decode.enumerated() {
            let decoded = LyricsSyncDraftCodec.decode(input).map { LyricsSyncDraftCodec.encode($0, nowMs: 0) }
            switch (decoded, expected) {
            case (nil, nil):
                break
            case (let d?, let e?):
                #expect(d.isIdentical(to: e), "case \(index): \(d) vs Android \(e)")
            default:
                Issue.record("case \(index): Swift \(decoded ?? "null"), Android \(expected ?? "null") for \(input)")
            }
        }
    }

    @Test func sha1MatchesAndroid() throws {
        let golden = try Self.load()
        #expect(golden.sha1.count == 8)
        for (id, hex) in golden.sha1 { #expect(LyricsSyncDraftStore.sha1(id) == hex, "sha1(\(id))") }
    }

    // MARK: Exports

    static let docs: [String: LyricsDoc] = [
        "doc": LyricsExportTests.doc,
        "duet": LyricsExportTests.duet,
        "odd": LyricsExportTests.odd,
        "bare": LyricsExportTests.bare,
        "edge": LyricsDoc(
            metadata: LyricsMetadata(title: "  Spaced\r\nTitle ", artist: " ", album: "Al\rbum", durationMs: 59_499),
            voices: [Voice(id: "bg", role: "background"), Voice(id: "d", role: "duet"), Voice(id: "lead", role: "lead")],
            lines: [
                TimedLine(startMs: 0, endMs: 900, text: "(intro)", voiceId: "bg",
                          syllables: [TimedSyllable(startMs: 0, durationMs: 900, text: "(intro)")]),
                TimedLine(startMs: 100, endMs: 800, text: "(also)", voiceId: "bg"),
                TimedLine(startMs: 1_000, endMs: 2_000, text: "  line only\n ", voiceId: "d"),
                TimedLine(startMs: 2_000, endMs: 3_000, text: "ab cd", voiceId: "missing", syllables: [
                    TimedSyllable(startMs: 2_000, durationMs: 300, text: " "),
                    TimedSyllable(startMs: 2_300, durationMs: 300, text: "ab "),
                    TimedSyllable(startMs: 2_600, durationMs: 400, text: "cd\r\n"),
                ]),
                TimedLine(startMs: 2_500, endMs: 2_900, text: "(echo)", voiceId: "bg",
                          syllables: [TimedSyllable(startMs: 2_500, durationMs: 400, text: "(echo)")]),
            ]
        ),
    ]

    @Test func exportsMatchAndroidByteForByte() throws {
        let golden = try Self.load()
        #expect(golden.lrc.count == 5 && golden.ttml.count == 5)
        for (name, doc) in Self.docs {
            let lrc = try #require(golden.lrc[name])
            let ttml = try #require(golden.ttml[name])
            #expect(LyricsExport.toEnhancedLrc(doc).isIdentical(to: lrc), "lrc \(name)")
            #expect(LyricsExport.toTtml(doc).isIdentical(to: ttml), "ttml \(name)")
        }
    }
}
