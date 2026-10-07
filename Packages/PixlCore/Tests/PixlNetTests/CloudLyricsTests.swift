import Foundation
import Testing
import PixlModel
@testable import PixlNet

@Suite struct CloudLyricsTests {
    static func aligned() throws -> CloudLyricsDocument {
        try CloudJSON.decode(CloudLyricsDocument.self, from: CloudFixtures.data("lyrics.aligned"))
    }

    @Test func wordsAreRebuiltFromTheOriginalText() throws {
        let doc = try #require(CloudLyrics.lyricsDoc(try Self.aligned(), durationMs: 241_000, title: "T", artist: "A"))
        #expect(doc.metadata.source == "cloud")
        #expect(doc.metadata.durationMs == 241_000)
        #expect(doc.lines.count == 4)
        // Korean: "원문 가사" → "원문 " + "가사".
        #expect(doc.lines[0].syllables.map(\.text) == ["원문 ", "가사"])
        #expect(doc.lines[0].syllables.map(\.startMs) == [12_410, 13_020])
        #expect(doc.lines[0].syllables[0].durationMs == 480)
        // Punctuation the aligner stripped stays with the word before it.
        #expect(doc.lines[1].syllables.map(\.text) == ["Hello, ", "bright ", "world"])
        // An emoji (a UTF-16 surrogate pair) between words joins the earlier word.
        #expect(doc.lines[2].syllables.map(\.text) == ["Fly 🚀 ", "high"])
        // Line timing only.
        #expect(doc.lines[3].syllables.isEmpty)
        #expect(doc.lines[3].startMs == 21_500 && doc.lines[3].endMs == 24_000)
        for line in doc.lines where !line.syllables.isEmpty {
            #expect(line.syllables.map(\.text).joined() == line.text)
        }
        #expect(CloudLyrics.level(of: doc) == .wordSynced)
        #expect(CloudLyrics.isUsable(doc))
        // The legacy view reads the same words.
        let lyrics = doc.toLyrics()
        #expect(lyrics.synced?[1].words?.map(\.word) == ["Hello,", "bright", "world"])
    }

    @Test func transcribedLyricsAreMarked() throws {
        let cloud = try CloudJSON.decode(CloudLyricsDocument.self, from: CloudFixtures.data("lyrics.transcribed"))
        #expect(cloud.isTranscribed)
        let doc = try #require(CloudLyrics.lyricsDoc(cloud, durationMs: 200_000))
        #expect(doc.metadata.source == CloudLyrics.transcribedSource)
        #expect(doc.lines[0].syllables.map(\.text) == ["Under ", "neon ", "rain"])
    }

    @Test func brokenOffsetsFallBackToLineTiming() throws {
        func line(_ words: [CloudLyricsWord], text: String = "abc def") -> CloudLyricsDocument {
            CloudLyricsDocument(mode: "aligned", language: "en",
                                lines: [CloudLyricsLine(i: 0, startMs: 1_000, endMs: 3_000, text: text, timing: "word", words: words)])
        }
        let outOfRange = line([CloudLyricsWord(startMs: 1_000, endMs: 1_500, text: "abc", conf: nil, c0: 0, c1: 30)])
        #expect(CloudLyrics.lyricsDoc(outOfRange, durationMs: 10_000)?.lines.first?.syllables.isEmpty == true)
        let overlapping = line([CloudLyricsWord(startMs: 1_000, endMs: 1_500, text: "abc", conf: nil, c0: 0, c1: 3),
                                CloudLyricsWord(startMs: 1_600, endMs: 1_900, text: "c d", conf: nil, c0: 2, c1: 5)])
        #expect(CloudLyrics.lyricsDoc(overlapping, durationMs: 10_000)?.lines.first?.syllables.isEmpty == true)
        // An offset inside a surrogate pair.
        let split = line([CloudLyricsWord(startMs: 1_000, endMs: 1_500, text: "x", conf: nil, c0: 0, c1: 1)], text: "\u{1F680}a")
        #expect(CloudLyrics.lyricsDoc(split, durationMs: 10_000)?.lines.first?.syllables.isEmpty == true)
        // Words out of order in time are clamped forward, never backward.
        let backwards = line([CloudLyricsWord(startMs: 2_000, endMs: 2_500, text: "abc", conf: nil, c0: 0, c1: 3),
                              CloudLyricsWord(startMs: 1_500, endMs: 1_800, text: "def", conf: nil, c0: 4, c1: 7)])
        let starts = try #require(CloudLyrics.lyricsDoc(backwards, durationMs: 10_000)?.lines.first?.syllables.map(\.startMs))
        #expect(starts == [2_000, 2_000])
    }

    @Test func linesAreClampedToTheSong() throws {
        let cloud = CloudLyricsDocument(mode: "aligned", language: nil, lines: [
            CloudLyricsLine(i: 1, startMs: 9_000, endMs: 12_000, text: "late", timing: "line", words: nil),
            CloudLyricsLine(i: 0, startMs: 1_000, endMs: 900, text: "first", timing: "line", words: nil),
            CloudLyricsLine(i: 2, startMs: 9_500, endMs: 9_600, text: "   ", timing: "line", words: nil),
        ])
        let doc = try #require(CloudLyrics.lyricsDoc(cloud, durationMs: 10_000))
        #expect(doc.lines.map(\.text) == ["first", "late"])
        #expect(doc.lines[0].endMs == 1_001)
        #expect(doc.lines[1].endMs == 10_000)
        #expect(CloudLyrics.level(of: doc) == .lineSynced)
    }

    @Test func wrongSchemaIsRejected() {
        let other = CloudLyricsDocument(schema: "something.else", mode: "aligned", language: nil,
                                        lines: [CloudLyricsLine(i: 0, startMs: 0, endMs: 1, text: "a", timing: "line", words: nil)])
        #expect(CloudLyrics.lyricsDoc(other, durationMs: 1_000) == nil)
        #expect(CloudLyrics.lyricsDoc(CloudLyricsDocument(mode: "aligned", language: nil, lines: []), durationMs: 1_000) == nil)
    }

    @Test func requestLinesFromSyncedAndPlainLyrics() throws {
        let synced = Lyrics(plain: nil, synced: [SyncedLine(time: 1_000, line: "one"), SyncedLine(time: 2_000, line: " "),
                                                 SyncedLine(time: 3_000, line: "two")], areFromRemote: false)
        let request = try #require(CloudLyrics.requestLines(synced))
        #expect(request.hasLineTimes)
        #expect(request.lines == [CloudLyricsInputLine(startMs: 1_000, endMs: 3_000, text: "one"),
                                  CloudLyricsInputLine(startMs: 3_000, endMs: nil, text: "two")])
        let plain = try #require(CloudLyrics.requestLines(Lyrics(plain: ["a", "", "b"], synced: nil, areFromRemote: false)))
        #expect(!plain.hasLineTimes)
        #expect(plain.lines.map(\.text) == ["a", "b"])
        #expect(CloudLyrics.requestLines(nil) == nil)
        let many = Lyrics(plain: (0..<600).map { "line \($0)" }, synced: nil, areFromRemote: false)
        #expect(CloudLyrics.requestLines(many)?.lines.count == CloudLimits.maxLyricsLines)
    }

    @Test func importOnlyImproves() {
        #expect(CloudLyrics.shouldImport(stored: .none, incoming: .lineSynced, storedIsUserSynced: false, replaceUserSynced: false))
        #expect(CloudLyrics.shouldImport(stored: .lineSynced, incoming: .wordSynced, storedIsUserSynced: false, replaceUserSynced: false))
        #expect(!CloudLyrics.shouldImport(stored: .lineSynced, incoming: .lineSynced, storedIsUserSynced: false, replaceUserSynced: false))
        #expect(!CloudLyrics.shouldImport(stored: .wordSynced, incoming: .wordSynced, storedIsUserSynced: false, replaceUserSynced: false))
        #expect(!CloudLyrics.shouldImport(stored: .wordSynced, incoming: .wordSynced, storedIsUserSynced: true, replaceUserSynced: false))
        #expect(CloudLyrics.shouldImport(stored: .wordSynced, incoming: .wordSynced, storedIsUserSynced: true, replaceUserSynced: true))
        let lineOnly = Lyrics(plain: nil, synced: [SyncedLine(time: 10, line: "a")], areFromRemote: false)
        #expect(CloudLyrics.level(of: lineOnly) == .lineSynced)
        #expect(CloudLyrics.level(of: Lyrics(plain: ["x"], synced: nil, areFromRemote: false)) == .plain)
        #expect(CloudLyrics.level(of: nil) == .none)
    }
}
