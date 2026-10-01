import Foundation
import Testing
import PixlModel
@testable import PixlLyrics

/// Port of `presentation/lyrics/model/PreparedLyricsBuilderTest.kt` (all 25 cases).
@Suite("PreparedLyricsBuilder")
struct PreparedLyricsBuilderTests {

    func build(_ lines: SyncedLine...) throws -> PreparedLyrics {
        try #require(PreparedLyricsBuilder.build(Lyrics(synced: lines)))
    }

    func lineRows(_ p: PreparedLyrics) -> [Int] { p.rows.compactMap(\.lineIndex) }

    func texts(_ line: PreparedLine) -> [String] {
        (line.syllables ?? []).map { line.substring(utf16From: $0.charStart, to: $0.charEnd) }
    }

    // MARK: basics

    @Test func nullOrPlainLyrics_buildNothing() {
        #expect(PreparedLyricsBuilder.build(nil as Lyrics?) == nil)
        #expect(PreparedLyricsBuilder.build(Lyrics(plain: ["a", "b"])) == nil)
        #expect(PreparedLyricsBuilder.build(Lyrics(synced: [])) == nil)
    }

    @Test func linesAreSortedAndStartsMirrored() throws {
        let p = try build(SyncedLine(time: 5_000, line: "third"), SyncedLine(time: 1_000, line: "first"),
                          SyncedLine(time: 3_000, line: "second"))
        #expect(p.lines.map(\.text) == ["first", "second", "third"])
        #expect(p.lines.map(\.index) == [0, 1, 2])
        #expect(p.startsSorted == [1_000, 3_000, 5_000])
        #expect(lineRows(p) == [0, 1, 2])
        #expect(!p.hasWordTiming)
        #expect(!p.hasDuet)
    }

    // MARK: end inference

    @Test func inferredEnds_useNextLeadStart_andLastLineGetsAtLeastFourSeconds() throws {
        let p = try build(SyncedLine(time: 1_000, line: "a b"), SyncedLine(time: 3_000, line: "c"), SyncedLine(time: 5_000, line: "d"))
        #expect(p.lines[0].endMs == 3_000)
        #expect(p.lines[1].endMs == 5_000)
        // Last line: start + max(4000, clamp(1×450+800, 1500, 6000)) = 5000 + 4000.
        #expect(p.lines[2].endMs == 9_000)
        #expect(p.lines.allSatisfy { !$0.endIsExplicit })
        #expect(p.maxLineDurationMs == 4_000)
    }

    @Test func explicitLineEnd_isKept() throws {
        let p = try build(SyncedLine(time: 1_000, line: "hello", endTime: 2_500), SyncedLine(time: 3_000, line: "world"))
        #expect(p.lines[0].endMs == 2_500)
        #expect(p.lines[0].endIsExplicit)
    }

    @Test func inferredEnd_extendsPastNextLineWhenLastWordStartsLater() throws {
        let p = try build(
            SyncedLine(time: 1_000, line: "Hello world",
                       words: [SyncedWord(time: 1_000, word: "Hello"), SyncedWord(time: 2_500, word: "world")]),
            SyncedLine(time: 2_000, line: "next")
        )
        #expect(p.lines[0].endMs == 2_501)
    }

    @Test func inferredEnd_skipsBackgroundLinesWhenLookingForTheNextLead() throws {
        let p = try build(SyncedLine(time: 1_000, line: "lead one"),
                          SyncedLine(time: 1_500, line: "ooh", voiceRole: "background"),
                          SyncedLine(time: 4_000, line: "lead two"))
        #expect(p.lines[0].endMs == 4_000)
    }

    @Test func emptyLrcLine_isTheExplicitEndOfThePreviousLine() throws {
        let p = try build(SyncedLine(time: 1_000, line: "hello"), SyncedLine(time: 4_000, line: ""), SyncedLine(time: 6_000, line: "next"))
        #expect(p.lines.count == 2)
        #expect(p.lines[0].endMs == 4_000)
        #expect(p.lines[0].endIsExplicit)
        #expect(!p.lines[1].endIsExplicit)
    }

    // MARK: interludes

    @Test func intro_ofNineSecondsOrMore_getsAnInterludeRowFirst() throws {
        let p = try build(SyncedLine(time: 12_000, line: "late start"), SyncedLine(time: 14_000, line: "then"))
        #expect(p.rows.first == .interlude(startMs: 0, endMs: 12_000, alignEnd: false))
        #expect(lineRows(p) == [0, 1])
    }

    @Test func intro_underNineSeconds_hasNoInterlude() throws {
        let p = try build(SyncedLine(time: 8_000, line: "soon"), SyncedLine(time: 10_000, line: "then"))
        #expect(!p.rows.contains { $0.isInterlude })
    }

    @Test func emptyLrcLine_opensAnInterludeWhenTheGapIsLongEnough() throws {
        let p = try build(SyncedLine(time: 1_000, line: "hello"), SyncedLine(time: 4_000, line: ""), SyncedLine(time: 20_000, line: "next"))
        #expect(p.rows == [.line(lineIndex: 0), .interlude(startMs: 4_000, endMs: 20_000, alignEnd: false), .line(lineIndex: 1)])
    }

    @Test func interludeAfterAnInferredEnd_usesTheEstimatedEnd_andClampsTheLine() throws {
        let p = try build(SyncedLine(time: 1_000, line: "one two three"), SyncedLine(time: 30_000, line: "after the solo"))
        // estimated = 1000 + clamp(3×450 + 800 = 2150, 1500, 6000) = 3150
        #expect(p.rows[1] == .interlude(startMs: 3_150, endMs: 30_000, alignEnd: false))
        #expect(p.lines[0].endMs == 3_150)
        #expect(!p.lines[0].endIsExplicit)
    }

    @Test func shortGap_hasNoInterlude() throws {
        let p = try build(SyncedLine(time: 1_000, line: "a", endTime: 2_000), SyncedLine(time: 10_500, line: "b"))
        #expect(!p.rows.contains { $0.isInterlude })
    }

    @Test func interludeBeforeADuetLine_isRightAligned() throws {
        let p = try build(SyncedLine(time: 1_000, line: "lead", endTime: 2_000), SyncedLine(time: 20_000, line: "duet", voiceRole: "duet"))
        let interludes = p.rows.filter(\.isInterlude)
        #expect(interludes.count == 1)
        if case .interlude(_, _, let alignEnd) = interludes[0] { #expect(alignEnd) }
        #expect(p.hasDuet)
    }

    // MARK: word timing

    @Test func syllables_indexIntoTheLineText_andMergeIntoWords() throws {
        let p = try build(
            SyncedLine(time: 1_000, line: "Hello world", words: [
                SyncedWord(time: 1_000, word: "Hel", startsNewWord: true),
                SyncedWord(time: 1_600, word: "lo", startsNewWord: false),
                SyncedWord(time: 2_000, word: "world", startsNewWord: true),
            ]),
            SyncedLine(time: 6_000, line: "next")
        )
        let line = p.lines[0]
        let syl = try #require(line.syllables)
        #expect(line.text == "Hello world")
        #expect(texts(line) == ["Hel", "lo", "world"])
        #expect(syl.map(\.wordIndex) == [0, 0, 1])
        #expect(line.lastWordIndex == 1)
        // Inner ends = next start; last = min(lineEnd, start + 1200).
        #expect(syl.map(\.endMs) == [1_600, 2_000, 3_200])
        #expect(syl.allSatisfy { !$0.endIsExplicit })
        #expect(p.hasWordTiming)
    }

    @Test func wordsThatDoNotMatchTheText_rebuildTheText() throws {
        let p = try build(SyncedLine(time: 1_000, line: "Totally different",
                                     words: [SyncedWord(time: 1_000, word: "Howdy"), SyncedWord(time: 1_500, word: "there")]))
        #expect(p.lines[0].text == "Howdy there")
        #expect(texts(p.lines[0]) == ["Howdy", "there"])
    }

    @Test func leadingVoiceTag_isStripped() throws {
        let p = try build(SyncedLine(time: 1_000, line: "v1: Hello"))
        #expect(p.lines[0].text == "Hello")
    }

    // MARK: emphasis

    @Test func emphasis_onlyOnExplicitEnds() throws {
        // Enhanced-LRC style: ends are inferred, so nothing may glow however long the word is.
        let inferred = try build(
            SyncedLine(time: 1_000, line: "Hold on", words: [SyncedWord(time: 1_000, word: "Hold"), SyncedWord(time: 4_000, word: "on")]),
            SyncedLine(time: 9_000, line: "next")
        )
        #expect(inferred.lines[0].syllables!.allSatisfy { !$0.emphasis })

        let explicit = try build(SyncedLine(time: 1_000, line: "Hello world", words: [
            SyncedWord(time: 1_000, word: "Hello", endTime: 2_500),
            SyncedWord(time: 2_600, word: "world", endTime: 2_900),
        ]))
        let syl = explicit.lines[0].syllables!
        #expect(syl[0].emphasis, "1.5 s, 5 graphemes")
        #expect(!syl[1].emphasis, "300 ms is too short")
        #expect(syl.allSatisfy { $0.endIsExplicit })
    }

    @Test func emphasis_graphemeLengthRule_andCjkException() throws {
        let p = try build(SyncedLine(time: 1_000, line: "extraordinary 爱 a", words: [
            SyncedWord(time: 1_000, word: "extraordinary", endTime: 3_000),
            SyncedWord(time: 3_000, word: "爱", endTime: 4_500),
            SyncedWord(time: 4_500, word: "a", endTime: 6_000),
        ]))
        let syl = p.lines[0].syllables!
        #expect(!syl[0].emphasis, "13 graphemes")
        #expect(syl[1].emphasis, "CJK only needs the duration")
        #expect(!syl[2].emphasis, "1 grapheme")
    }

    @Test func emphasis_testsMergedSyllablesAsOneWord() throws {
        let p = try build(SyncedLine(time: 1_000, line: "sugar", words: [
            SyncedWord(time: 1_000, word: "su", startsNewWord: true, endTime: 1_500),
            SyncedWord(time: 1_500, word: "gar", startsNewWord: false, endTime: 2_200),
        ]))
        let syl = p.lines[0].syllables!
        #expect(syl.map(\.wordIndex) == [0, 0])
        #expect(syl.allSatisfy { $0.emphasis }, "su + gar = 1.2 s")
    }

    // MARK: LyricsDoc path: voices, grouping

    static let doc = LyricsDoc(
        voices: [Voice(id: "v1", role: "lead"), Voice(id: "v2", role: "background"), Voice(id: "v3", role: "duet")],
        lines: [
            TimedLine(startMs: 900, endMs: 2_000, text: "ooh", voiceId: "v2"),
            TimedLine(startMs: 1_000, endMs: 4_000, text: "Hello world", voiceId: "v1", syllables: [
                TimedSyllable(startMs: 1_000, durationMs: 1_500, text: "Hello "),
                TimedSyllable(startMs: 2_600, durationMs: 1_400, text: "world"),
            ]),
            TimedLine(startMs: 3_000, endMs: 3_800, text: "yeah", voiceId: "v2"),
            TimedLine(startMs: 5_000, endMs: 7_000, text: "hi there", voiceId: "v3"),
            TimedLine(startMs: 40_000, endMs: 41_000, text: "lonely echo", voiceId: "v2"),
        ]
    )

    @Test func doc_backgroundVocalsGroupUnderTheirLead_aboveOrBelow() throws {
        let p = try #require(PreparedLyricsBuilder.build(Lyrics(document: Self.doc)))
        #expect(p.lines.map(\.text) == ["ooh", "Hello world", "yeah", "hi there", "lonely echo"])
        let ooh = p.lines[0], lead = p.lines[1], yeah = p.lines[2], duet = p.lines[3], orphan = p.lines[4]
        #expect(ooh.role == .background)
        #expect(ooh.groupLeadIndex == 1)
        #expect(ooh.bgAbove, "starts before its lead")
        #expect(yeah.groupLeadIndex == 1)
        #expect(!yeah.bgAbove)
        #expect(lead.isGroupLead)
        #expect(duet.role == .duet)
        #expect(duet.isGroupLead)
        #expect(orphan.isGroupLead, "no lead near it")
        #expect(!orphan.isGroupedBackground)
        #expect(p.rows == [.line(lineIndex: 0), .line(lineIndex: 1), .line(lineIndex: 2), .line(lineIndex: 3),
                           .interlude(startMs: 7_000, endMs: 40_000, alignEnd: false), .line(lineIndex: 4)])
        #expect(p.hasDuet)
        #expect(p.lines.allSatisfy { $0.endIsExplicit })
    }

    @Test func doc_syllableRangesExcludeWhitespace_andDurationsAreExplicit() throws {
        let p = try #require(PreparedLyricsBuilder.build(Lyrics(document: Self.doc)))
        let lead = p.lines[1]
        let syl = try #require(lead.syllables)
        #expect(texts(lead) == ["Hello", "world"])
        #expect(syl.map(\.wordIndex) == [0, 1])
        #expect(syl.map(\.endMs) == [2_500, 4_000])
        #expect(syl.allSatisfy { $0.endIsExplicit })
        #expect(syl.allSatisfy { $0.emphasis }, "1.5 s and 1.4 s with explicit ends")
    }

    @Test func everyLineAppearsInRowsExactlyOnce() throws {
        let p = try #require(PreparedLyricsBuilder.build(Lyrics(document: Self.doc)))
        #expect(lineRows(p).sorted() == Array(p.lines.indices))
    }

    @Test func docWinsOverSynced_butSyncedTranslationsAreKept() throws {
        let lyrics = Lyrics(synced: [SyncedLine(time: 1_000, line: "Hello world", translation: "Hola mundo")], document: Self.doc)
        let p = try #require(PreparedLyricsBuilder.build(lyrics))
        #expect(p.lines.count == 5)
        #expect(p.lines[1].translation == "Hola mundo")
    }

    @Test func equalModels_areEqual() {
        let a = PreparedLyricsBuilder.build(Lyrics(document: Self.doc))
        let b = PreparedLyricsBuilder.build(Lyrics(document: Self.doc))
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func graphemeAndWordCounts() {
        #expect(PreparedLyricsBuilder.graphemeCount("hello") == 5)
        #expect(PreparedLyricsBuilder.graphemeCount("e\u{301}a") == 2)
        #expect(PreparedLyricsBuilder.estimateWordCount("one two  three") == 3)
        #expect(PreparedLyricsBuilder.estimateWordCount("我爱你") == 3)
    }

    // MARK: Swift-only

    @Test func syllableOffsetsAreUTF16_withEmojiAndCombiningMarks() throws {
        let doc = LyricsDoc(lines: [TimedLine(startMs: 0, endMs: 3_000, text: "😀 cafe\u{301}", syllables: [
            TimedSyllable(startMs: 0, durationMs: 1_000, text: "😀 "),
            TimedSyllable(startMs: 1_000, durationMs: 2_000, text: "cafe\u{301}"),
        ])])
        let p = try #require(PreparedLyricsBuilder.build(doc))
        let syl = try #require(p.lines[0].syllables)
        #expect(syl.map(\.charStart) == [0, 3])
        #expect(syl.map(\.charEnd) == [2, 8])
        #expect(texts(p.lines[0]) == ["😀", "cafe\u{301}"])
        #expect(syl[1].emphasis, "4 graphemes, 2 s")
    }

    @Test func voiceRoleParsing() {
        #expect(PreparedVoiceRole.fromRole(" BG ") == .background)
        #expect(PreparedVoiceRole.fromRole("x-bg") == .background)
        #expect(PreparedVoiceRole.fromRole("Duet") == .duet)
        #expect(PreparedVoiceRole.fromRole("choir") == .lead)
        #expect(PreparedVoiceRole.fromRole(nil) == .lead)
    }
}
