// Port of the Android `data/lyrics/sync/LyricsTapSyncTest.kt`, case for case (same inputs, same expected values),
// plus a few Swift-only checks. Byte-exact parity with the Android implementation is checked separately in
// `TapSyncGoldenTests`.

import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLyrics

@Suite("LyricsTapSync")
struct LyricsTapSyncTests {

    // MARK: helpers

    func pasted(_ lines: String..., durationMs: Int64 = 240_000) -> SyncDraft {
        LyricsTapSync.buildDraft(songId: "song-1", title: "Title", artist: "Artist", album: "Album", durationMs: durationMs,
                                 lyrics: nil, pasted: lines.joined(separator: "\n")).draft!
    }

    func lineSynced(_ lines: (Int, String)..., durationMs: Int64 = 240_000) -> SyncDraft {
        LyricsTapSync.buildDraft(songId: "song-2", title: "Title", artist: "Artist", album: "Album", durationMs: durationMs,
                                 lyrics: Lyrics(synced: lines.map { SyncedLine(time: $0.0, line: $0.1) }), pasted: nil).draft!
    }

    func tapAll(_ draft: SyncDraft, startMs: Int64 = 1_000, stepMs: Int64 = 400, speed: Float = 1,
                offsetMs: Int = 0) -> SyncDraft {
        RandomSessions.tapAll(draft, startMs: startMs, stepMs: stepMs, speed: speed, offsetMs: offsetMs)
    }

    func taps(_ draft: SyncDraft, _ rawMs: Int64..., speed: Float = 1, offsetMs: Int = 0) -> SyncDraft {
        rawMs.reduce(draft) { d, t in LyricsTapSync.tap(d, rawStartMs: t, speed: speed, offsetMs: offsetMs).draft }
    }

    func start(_ d: SyncDraft, _ i: Int, _ offsetMs: Int = 0) -> Int64? {
        LyricsTapSync.builtStartMs(d, i, offsetMs: offsetMs)
    }

    func tap(_ d: SyncDraft, _ raw: Int64, _ speed: Float, _ offset: Int, scopeLine: Int? = nil) -> SyncStep {
        LyricsTapSync.tap(d, rawStartMs: raw, speed: speed, offsetMs: offset, scopeLine: scopeLine)
    }

    // MARK: tokenize

    @Test func tokenizeSplitsOnSpacesAndKeepsTrailingSpace() {
        #expect(LyricsTapSync.tokenize("Hello world") == ["Hello ", "world"])
        #expect(LyricsTapSync.tokenize("  Hello   big\tworld  ") == ["Hello ", "big ", "world"])
        #expect(LyricsTapSync.tokenize("   \t ") == [])
        #expect(LyricsTapSync.tokenize("Hi") == ["Hi"])
    }

    @Test func tokenizeMergesPunctuationOnlyChunks() {
        #expect(LyricsTapSync.tokenize("wait - what") == ["wait - ", "what"])
        #expect(LyricsTapSync.tokenize("— hey you") == ["— hey ", "you"])
        #expect(LyricsTapSync.tokenize("(oh yeah, baby)") == ["(oh ", "yeah, ", "baby)"])
        #expect(LyricsTapSync.tokenize("rock & roll…") == ["rock & ", "roll…"])
        #expect(LyricsTapSync.tokenize("… …") == ["… …"])
        #expect(LyricsTapSync.tokenize("so… — yes") == ["so… — ", "yes"])
    }

    @Test func tokenizeKeepsHyphenatedAndApostropheWordsWhole() {
        #expect(LyricsTapSync.tokenize("twenty-one rock'n'roll") == ["twenty-one ", "rock'n'roll"])
        #expect(LyricsTapSync.tokenize("don't night-time") == ["don't ", "night-time"])
    }

    @Test func tokenizeSplitsCjkIntoGraphemes() {
        #expect(LyricsTapSync.tokenize("君が好き") == ["君", "が", "好", "き"])
        // Small kana and the prolonged sound mark stay with the character before.
        #expect(LyricsTapSync.tokenize("東京ラーメン") == ["東", "京", "ラー", "メ", "ン"])
        #expect(LyricsTapSync.tokenize("きょうは") == ["きょ", "う", "は"])
        // CJK punctuation joins its neighbour.
        #expect(LyricsTapSync.tokenize("「愛してる」、") == ["「愛", "し", "て", "る」、"])
        // Latin inside a CJK chunk stays whole; spaces still separate chunks.
        #expect(LyricsTapSync.tokenize("私はOK です。") == ["私", "は", "OK ", "で", "す。"])
        #expect(LyricsTapSync.tokenize("Loveしてる") == ["Love", "し", "て", "る"])
    }

    @Test func tokenizeLeavesHangulAndLongChunksOnWhitespace() {
        #expect(LyricsTapSync.tokenize("사랑해 너를") == ["사랑해 ", "너를"])
        let long = String(repeating: "あ", count: 41)
        #expect(LyricsTapSync.tokenize(long) == [long])
        #expect(LyricsTapSync.tokenize(String(repeating: "あ", count: 40)).count == 40)
    }

    @Test func tokenizeKeepsEmojiGraphemesIntact() {
        let family = "👨‍👩‍👧"
        let heart = "❤️"
        let thumbs = "👍🏽"
        #expect(LyricsTapSync.tokenize("君\(family)と") == ["君", family, "と"])
        #expect(LyricsTapSync.tokenize("愛\(heart)") == ["愛", heart])
        #expect(LyricsTapSync.tokenize("\(thumbs) yes") == ["\(thumbs) ", "yes"])
        #expect(LyricsTapSync.tokenize("Café ok") == ["Café ", "ok"])
    }

    @Test func tokenizeJoinAlwaysEqualsNormalizedLine() {
        let samples = [
            "Hello world", "  spaced   out  ", "— lead", "trail —", "a - b — c … d & e",
            "君が好き", "「愛してる」、", "私はOK です。", "사랑해 너를", "twenty-one rock'n'roll",
            "👨‍👩‍👧 君と", "ゃ小さい", "ーラ", "(oh", "…",
        ]
        let pool = [
            "love", "君", "が", "ラー", "ょ", "—", "&", "…", "、", "。", "「", "」", "a-b", "it's", " ", "  ", "\t",
            "❤️", "👨‍👩", "사랑", "OK", "(", ")", "é", "　",
        ]
        var random = KotlinRandom(seed: 7)
        var fuzz: [String] = []
        for _ in 0..<400 {
            let n = random.nextInt(1, 14)
            var line = ""
            for _ in 0..<n { line += random.pick(pool) }
            fuzz.append(line)
        }
        for line in samples + fuzz {
            let tokens = LyricsTapSync.tokenize(line)
            #expect(tokens.joined().isIdentical(to: LyricsTapSync.normalizeLine(line)), "join for <\(line)>")
            #expect(!tokens.contains { $0.isEmpty }, "empty token for <\(line)>")
            #expect(!tokens.contains { $0.unicodeScalars.first == " " }, "leading space for <\(line)>")
            #expect(tokens.last?.unicodeScalars.last != " ", "last token has no trailing space for <\(line)>")
        }
    }

    // MARK: building drafts

    @Test func buildDraftLineSyncedKeepsAnchorsAndTranslations() throws {
        let lyrics = Lyrics(synced: [
            SyncedLine(time: 10_000, line: "Hello world", translation: "Hola mundo"),
            SyncedLine(time: 15_000, line: "   "),
            SyncedLine(time: 20_000, line: "Bye"),
        ])
        let seed = LyricsTapSync.buildDraft(songId: "id", title: "T", artist: "A", album: "Al", durationMs: 60_000,
                                            lyrics: lyrics, pasted: nil)
        #expect(seed.origin == .lineSynced)
        let draft = try #require(seed.draft)
        #expect(draft.lines.map(\.text) == ["Hello world", "Bye"])
        #expect(draft.lines.map(\.anchorMs) == [10_000, 20_000])
        #expect(draft.lines[0].translation == "Hola mundo")
        #expect(draft.cursor == 0)
        #expect(draft.tappableCount == 3)
        #expect(draft.tappedCount == 0)
    }

    @Test func buildDraftPlainDropsRomanizationAndPastedDropsBlankLines() {
        let plain = LyricsTapSync.buildDraft(songId: "id", title: "", artist: "", album: "", durationMs: 0,
                                             lyrics: Lyrics(plain: ["こんにちは\nKonnichiwa", "Next"]), pasted: nil)
        #expect(plain.origin == .plain)
        #expect(plain.draft!.lines.map(\.text) == ["こんにちは", "Next"])

        let paste = pasted("  first   line ", "", "   ", "second")
        #expect(paste.lines.map(\.text) == ["first line", "second"])
        #expect(paste.lines[0].anchorMs == nil)

        let none = LyricsTapSync.buildDraft(songId: "id", title: "", artist: "", album: "", durationMs: 0, lyrics: nil,
                                            pasted: nil)
        #expect(none.origin == .none)
        #expect(none.draft == nil)
        #expect(LyricsTapSync.buildDraft(songId: "id", title: "", artist: "", album: "", durationMs: 0, lyrics: nil,
                                         pasted: " \n \n").draft == nil)
    }

    @Test func buildDraftWordSyncedOpensFinishedWithExactTimes() throws {
        let lyrics = Lyrics(synced: [
            SyncedLine(time: 1_000, line: "Hello there", words: [
                SyncedWord(time: 1_000, word: "Hel", startsNewWord: true),
                SyncedWord(time: 1_200, word: "lo", startsNewWord: false),
                SyncedWord(time: 1_500, word: "there", startsNewWord: true),
            ]),
        ])
        let seed = LyricsTapSync.buildDraft(songId: "id", title: "", artist: "", album: "", durationMs: 60_000,
                                            lyrics: lyrics, pasted: nil)
        #expect(seed.origin == .wordSynced)
        let draft = try #require(seed.draft)
        #expect(draft.isFinished)
        #expect(draft.tokens.map(\.text) == ["Hel", "lo ", "there"])
        let doc = try LyricsTapSync.toLyricsDoc(draft, offsetMs: 300).get()
        #expect(doc.lines.count == 1)
        #expect(doc.lines[0].syllables.map(\.startMs) == [1_000, 1_200, 1_500])
        #expect(doc.lines[0].text == "Hello there")
    }

    @Test func buildDraftUserDocRoundTripsExactly() throws {
        let original = try LyricsTapSync.toLyricsDoc(
            tapAll(pasted("Hello world", "Second line here"), startMs: 2_000, stepMs: 530, offsetMs: 120),
            offsetMs: 120
        ).get()
        let seed = LyricsTapSync.buildDraft(songId: "song-1", title: "Title", artist: "Artist", album: "Album",
                                            durationMs: 240_000, lyrics: original.toLyrics(), pasted: nil)
        #expect(seed.origin == .userSynced)
        let draft = try #require(seed.draft)
        #expect(draft.isFinished)
        let again = try LyricsTapSync.toLyricsDoc(draft, offsetMs: 250).get()
        #expect(original.lines == again.lines)
        #expect(again.metadata.source == "user")
    }

    @Test func buildDraftLocksTimedBackgroundLinesAndCarriesThemThrough() throws {
        let doc = LyricsDoc(
            metadata: LyricsMetadata(durationMs: 60_000, source: "amll"),
            voices: [Voice(id: "lead", role: "lead"), Voice(id: "bg", role: "background")],
            lines: [
                TimedLine(startMs: 1_000, endMs: 1_900, text: "Hi there", voiceId: "lead", syllables: [
                    TimedSyllable(startMs: 1_000, durationMs: 400, text: "Hi "),
                    TimedSyllable(startMs: 1_500, durationMs: 400, text: "there"),
                ]),
                TimedLine(startMs: 1_200, endMs: 1_800, text: "(yeah)", voiceId: "bg", syllables: [
                    TimedSyllable(startMs: 1_200, durationMs: 600, text: "(yeah)"),
                ]),
                TimedLine(startMs: 3_000, endMs: 5_000, text: "Next line", voiceId: "lead"),
            ]
        )
        let seed = LyricsTapSync.buildDraft(songId: "id", title: "", artist: "", album: "", durationMs: 60_000,
                                            lyrics: Lyrics(document: doc), pasted: nil)
        #expect(seed.origin == .wordSynced)
        let cleared = LyricsTapSync.clearAll(try #require(seed.draft))
        #expect(cleared.lines[1].locked)
        #expect(!cleared.lines[2].skipped)
        #expect(cleared.cursor == 0)
        #expect(cleared.tappableCount == 4)

        var d = taps(cleared, 1_000, 1_500)
        #expect(d.cursor == 3) // skips the locked background word
        d = taps(d, 3_000, 3_500)
        #expect(d.isFinished)
        let out = try LyricsTapSync.toLyricsDoc(d, offsetMs: 0).get()
        #expect(LyricsDocCodec.isValid(out))
        let background = out.lines.filter { $0.voiceId == "bg" }
        #expect(background.count == 1)
        #expect(background.first?.syllables == [TimedSyllable(startMs: 1_200, durationMs: 600, text: "(yeah)")])
        #expect(out.lines.map(\.startMs) == [1_000, 1_200, 3_000])
        // Lead line: continuous sweep into word 2, last word 2 × 500 ms (the next open line is at 3 s).
        #expect(out.lines[0].syllables.map(\.durationMs) == [500, 1_000])
    }

    // MARK: tapping

    @Test func tapStartsAreStrictlyIncreasing() {
        var d = pasted("one two three four")
        d = tap(d, 1_000, 1, 100).draft
        #expect(start(d, 0, 100) == 900)
        d = tap(d, 950, 1, 100).draft // earlier than the previous tap
        #expect(start(d, 1, 100) == 910)
        #expect(d.tokens[1].rawStartMs == 1_010)
        #expect(d.cursor == 2)

        var random = KotlinRandom(seed: 3)
        var r = pasted((1...60).map { "w\($0)" }.joined(separator: " "))
        var position: Int64 = 5_000
        while !r.isFinished {
            position += random.nextLong(-500, 800)
            let index = r.cursor
            r = tap(r, position, random.pick([0.5, 0.75, 1] as [Float]), 150).draft
            if index > 0 { #expect(start(r, index, 150)! >= start(r, index - 1, 150)! + 10) }
        }
    }

    @Test func tapOffsetIsScaledBySpeed() {
        #expect(LyricsTapSync.rawTapPositionMs(positionMs: 10_000, nowUptimeMs: 1_200, eventUptimeMs: 1_000, speed: 0.5) == 9_900)
        #expect(LyricsTapSync.rawTapPositionMs(positionMs: 10_000, nowUptimeMs: 1_200, eventUptimeMs: 1_000, speed: 1) == 9_800)
        #expect(LyricsTapSync.rawTapPositionMs(positionMs: 10_000, nowUptimeMs: 1_000, eventUptimeMs: 1_200, speed: 1) == 10_000)

        // A 100 ms reaction lets the media run on by 100 ms × speed; the built start lands on the onset.
        let onset: Int64 = 20_000
        for speed in [0.5, 0.75, 1] as [Float] {
            let raw = onset + KotlinMath.toLong(100 * speed)
            let d = tap(pasted("word"), raw, speed, 100).draft
            #expect(start(d, 0, 100) == onset, "speed \(speed)")
            #expect(d.tokens[0].startSpeed == speed)
        }
    }

    @Test func tapAfterTheLastWordDoesNothing() {
        let done = tapAll(pasted("a b"))
        let step = tap(done, 99_000, 1, 0)
        #expect(step.draft == done)
    }

    @Test func tapWarnsWhenFarAheadOfTheLineAnchor() {
        let d = lineSynced((10_000, "hello there"))
        #expect(tap(d, 6_000, 1, 0).tapBeforeAnchor)
        #expect(!tap(d, 7_500, 1, 0).tapBeforeAnchor)
    }

    @Test func releaseStampsHeldEndsOnlyAfterTheStart() throws {
        var d = tap(pasted("long note"), 1_000, 1, 0).draft
        #expect(LyricsTapSync.release(d, tokenIndex: 0, rawEndMs: 1_020, speed: 1, offsetMs: 0) == d) // shorter than 40 ms
        d = LyricsTapSync.release(d, tokenIndex: 0, rawEndMs: 2_600, speed: 1, offsetMs: 0)
        #expect(LyricsTapSync.builtHeldEndMs(d, 0, offsetMs: 0) == 2_600)
        d = tap(d, 3_000, 1, 0).draft
        let doc = try LyricsTapSync.toLyricsDoc(d, offsetMs: 0).get()
        #expect(doc.lines.count == 1)
        #expect(doc.lines[0].syllables[0].durationMs == 1_600)
    }

    // MARK: mistakes

    @Test func undoPopsOneTapAndSeeksBeforeThePreviousWord() {
        var d = taps(lineSynced((10_000, "a b c"), (20_000, "d e")), 10_000, 10_500, 11_000, 20_000)
        #expect(d.cursor == 4)

        var step = LyricsTapSync.undo(d, speed: 1, offsetMs: 0)
        d = step.draft
        #expect(d.cursor == 3)
        #expect(d.tokens[3].rawStartMs == nil)
        #expect(step.seekToMs == 9_000)
        #expect(step.clearedCount == 1)

        step = LyricsTapSync.undo(d, speed: 1, offsetMs: 0)
        d = step.draft
        #expect(step.seekToMs == 8_500)

        step = LyricsTapSync.undo(d, speed: 0.5, offsetMs: 0) // pre-roll scales with speed
        d = step.draft
        #expect(step.seekToMs == 9_000)

        step = LyricsTapSync.undo(d, speed: 1, offsetMs: 0) // nothing before: anchor − 3 s
        d = step.draft
        #expect(d.cursor == 0)
        #expect(step.seekToMs == 7_000)

        step = LyricsTapSync.undo(d, speed: 1, offsetMs: 0)
        #expect(step.draft == d)
        #expect(step.seekToMs == nil)
    }

    @Test func undoWithoutAnchorFallsBackToTheRemovedTapAndClampsAtZero() {
        let d = taps(pasted("a b"), 1_000)
        let step = LyricsTapSync.undo(d, speed: 1, offsetMs: 0)
        #expect(step.seekToMs == 0)
        #expect(step.draft.tappedCount == 0)
    }

    @Test func undoAfterSkipUndoesTheWholeRoughRun() {
        var d = lineSynced((10_000, "one two three"), (20_000, "four"), (30_000, "five"))
        d = taps(d, 10_000)
        #expect(LyricsTapSync.canSkipLine(d))
        d = LyricsTapSync.skipLine(d, offsetMs: 0).draft
        #expect(d.lines[0].skipped)
        #expect(d.cursor == 3)

        let step = LyricsTapSync.undo(d, speed: 1, offsetMs: 0)
        #expect(step.draft.cursor == 1)
        #expect(step.clearedCount == 2)
        #expect(!step.draft.lines[0].skipped)
        #expect(step.draft.tokens[0].rawStartMs == 10_000)
        #expect(step.seekToMs == 8_000)
    }

    @Test func rewindClearsOnlyTapsAfterTheNewPosition() {
        let d = taps(pasted("a b c d e"), 1_000, 2_000, 3_000, 4_000)
        let step = LyricsTapSync.rewind(d, positionMs: 8_000, offsetMs: 0)
        #expect(step.seekToMs == 3_000)
        #expect(step.clearedCount == 2)
        #expect(step.draft.cursor == 2)
        #expect(step.draft.tokens.map(\.rawStartMs) == [1_000, 2_000, nil, nil, nil])

        let withOffset = LyricsTapSync.rewind(d, positionMs: 8_000, offsetMs: 100)
        #expect(withOffset.clearedCount == 1) // built starts are 900/1900/2900/3900
        #expect(withOffset.draft.cursor == 3)

        let nothing = LyricsTapSync.rewind(d, positionMs: 20_000, offsetMs: 0)
        #expect(nothing.draft == d)
        #expect(nothing.seekToMs == 15_000)
        #expect(LyricsTapSync.rewind(d, positionMs: 2_000, offsetMs: 0).seekToMs == 0)
    }

    @Test func jumpToLineClearsFromThatLineAndSeeksBeforeIt() {
        let d = taps(pasted("a b", "c d"), 1_000, 2_000, 3_000)
        #expect(d.cursor == 3)

        let toCurrent = LyricsTapSync.jumpToLine(d, lineIndex: 1, speed: 1, offsetMs: 0)
        #expect(toCurrent.seekToMs == 1_000)
        #expect(toCurrent.clearedCount == 1)
        #expect(toCurrent.draft.cursor == 2)
        #expect(LyricsTapSync.jumpToLine(d, lineIndex: 1, speed: 0.5, offsetMs: 0).seekToMs == 2_000)

        let toFirst = LyricsTapSync.jumpToLine(d, lineIndex: 0, speed: 1, offsetMs: 0)
        #expect(toFirst.seekToMs == 0)
        #expect(toFirst.clearedCount == 3)
        #expect(toFirst.draft.cursor == 0)
        #expect(toFirst.draft.tappedCount == 0)

        let fresh = pasted("a b", "c d")
        let ahead = LyricsTapSync.jumpToLine(fresh, lineIndex: 1, speed: 1, offsetMs: 0)
        #expect(ahead.draft == fresh)
        #expect(ahead.seekToMs == nil)
    }

    @Test func jumpToLineUsesTheAnchorWhenTheLineIsUntapped() {
        let d = taps(lineSynced((10_000, "a b"), (20_000, "c d")), 10_000, 10_400)
        let step = LyricsTapSync.jumpToLine(d, lineIndex: 1, speed: 1, offsetMs: 0)
        #expect(step.seekToMs == 18_000)
        #expect(step.clearedCount == 0)
    }

    @Test func fixLineRewritesOneLineAndKeepsTheRest() throws {
        let done = taps(pasted("a b", "c d"), 1_000, 2_000, 3_000, 4_000)
        let step = LyricsTapSync.fixLine(done, lineIndex: 0, speed: 1, offsetMs: 0)
        #expect(step.seekToMs == 0)
        #expect(step.draft.cursor == 0)
        #expect(step.draft.tokens.map(\.rawStartMs) == [nil, nil, 3_000, 4_000])

        var d = tap(step.draft, 1_200, 1, 0, scopeLine: 0).draft
        let past = tap(d, 5_000, 1, 0, scopeLine: 0)
        #expect(past.pastNextLine)
        #expect(start(past.draft, 1) == 2_959)
        d = tap(d, 2_100, 1, 0, scopeLine: 0).draft
        #expect(d.cursor == 2)
        #expect(tap(d, 2_500, 1, 0, scopeLine: 0).draft == d) // next line is out of scope
        #expect(try LyricsDocCodec.isValid(LyricsTapSync.toLyricsDoc(d, offsetMs: 0).get()))
    }

    @Test func skipLineSpreadsWordsByCharacterCountBetweenAnchors() {
        let d = lineSynced((10_000, "one two three"), (20_000, "four"), (30_000, "five"))
        let skipped = LyricsTapSync.skipLine(d, offsetMs: 0).draft
        #expect(skipped.tokens.prefix(3).map(\.rawStartMs) == [10_000, 12_727, 15_454])
        let allExact = skipped.tokens.prefix(3).allSatisfy(\.exact)
        #expect(allExact)
        #expect(skipped.lines[0].skipped)
        #expect(skipped.cursor == 3)
        #expect(LyricsTapSync.canSkipLine(skipped))
        let last = LyricsTapSync.skipLine(skipped, offsetMs: 0).draft
        #expect(!LyricsTapSync.canSkipLine(last)) // no next line

        let plain = pasted("a b", "c")
        #expect(!LyricsTapSync.canSkipLine(plain))
        #expect(LyricsTapSync.skipLine(plain, offsetMs: 0).draft == plain)
    }

    @Test func fillRestTimesTheRemainingWordsAtMost600msApart() throws {
        let d = taps(pasted("a b c d", durationMs: 10_000), 1_000, 1_500)
        let filled = LyricsTapSync.fillRest(d, offsetMs: 0).draft
        #expect(filled.isFinished)
        #expect(filled.tokens.map(\.rawStartMs) == [1_000, 1_500, 2_100, 2_700])
        #expect(filled.lines[0].skipped)
        let result = try LyricsTapSync.buildResult(filled, offsetMs: 0).get()
        #expect(LyricsDocCodec.isValid(result.doc))
        #expect(result.roughLineIndices == [0])
    }

    @Test func nudgeAndOffsetLearning() throws {
        let d = tapAll(pasted("a b c"), startMs: 5_000)
        let base = try LyricsTapSync.toLyricsDoc(d, offsetMs: 0).get()
        let later = try LyricsTapSync.toLyricsDoc(LyricsTapSync.setNudge(d, nudgeMs: 40), offsetMs: 0).get()
        #expect(base.lines[0].syllables.map { $0.startMs + 40 } == later.lines[0].syllables.map(\.startMs))
        #expect(LyricsTapSync.setNudge(d, nudgeMs: 999).nudgeMs == 400)
        #expect(LyricsTapSync.setNudge(d, nudgeMs: -999).nudgeMs == -400)

        #expect(LyricsTapSync.learnedOffsetMs(currentOffsetMs: 100, nudgeMs: 40) == 80)
        #expect(LyricsTapSync.learnedOffsetMs(currentOffsetMs: 100, nudgeMs: -40) == 120)
        #expect(LyricsTapSync.learnedOffsetMs(currentOffsetMs: 10, nudgeMs: 100) == 0)
        #expect(LyricsTapSync.learnedOffsetMs(currentOffsetMs: 390, nudgeMs: -100) == 400)
    }

    // MARK: ends

    func ends(_ starts: [Int64], held: [Int64?]? = nil, next: Int64? = nil, ceiling: Int64 = 1_000_000) -> [Int64] {
        LyricsTapSync.deriveEnds(starts: starts, heldEnds: held ?? starts.map { _ in nil }, nextLineStartMs: next,
                                 endCeilingMs: ceiling)
    }

    @Test func deriveEndsContinuousSweepAndLastWord() {
        #expect(ends([0, 500, 1_000]) == [500, 1_000, 2_000])
        #expect(ends([1_000]) == [1_900]) // no gaps: median 450 → 900
    }

    @Test func deriveEndsPauseInsideALine() {
        #expect(ends([0, 5_000]) == [1_200, 7_000])
    }

    @Test func deriveEndsHeldEndsWin() {
        #expect(ends([0, 500], held: [300, nil]) == [300, 1_500])
        #expect(ends([0], held: [10]) == [40])
    }

    @Test func deriveEndsClamps() {
        #expect(ends([0, 500], next: 1_200) == [500, 1_199])
        #expect(ends([0, 10, 20]) == [40, 50, 420])
        #expect(ends([0, 500], ceiling: 900) == [500, 900])
        // A "next line" that starts before this one (duet overlap) does not cut it short.
        #expect(ends([5_000, 5_500], next: 4_000) == [5_500, 6_500])
    }

    // MARK: the finished document

    @Test func toLyricsDocBuildsUserDocument() throws {
        let d = tapAll(pasted("Hello world", "Second line"), startMs: 1_000, stepMs: 400)
        let doc = try LyricsTapSync.toLyricsDoc(d, offsetMs: 0).get()
        #expect(doc.lines == [
            TimedLine(startMs: 1_000, endMs: 1_799, text: "Hello world", voiceId: "lead", syllables: [
                TimedSyllable(startMs: 1_000, durationMs: 400, text: "Hello "),
                TimedSyllable(startMs: 1_400, durationMs: 399, text: "world"),
            ]),
            TimedLine(startMs: 1_800, endMs: 3_000, text: "Second line", voiceId: "lead", syllables: [
                TimedSyllable(startMs: 1_800, durationMs: 400, text: "Second "),
                TimedSyllable(startMs: 2_200, durationMs: 800, text: "line"),
            ]),
        ])
        #expect(doc.metadata == LyricsMetadata(title: "Title", artist: "Artist", album: "Album", durationMs: 240_000,
                                               source: "user"))
        #expect(LyricsDocCodec.decode(LyricsDocCodec.encode(doc)) != nil)
    }

    @Test func toLyricsDocFailsWithoutTaps() {
        guard case .failure(let error) = LyricsTapSync.toLyricsDoc(pasted("a b"), offsetMs: 0) else {
            Issue.record("expected a failure")
            return
        }
        #expect(error == .noTaps)
    }

    @Test func toLyricsDocJapanesePasteIsSplitPerCharacterAndValid() throws {
        let d = tapAll(pasted("君が好きだよ", "東京ラーメン。"), stepMs: 250)
        let doc = try LyricsTapSync.toLyricsDoc(d, offsetMs: 100).get()
        #expect(LyricsDocCodec.isValid(doc))
        #expect(doc.lines[0].syllables.map(\.text) == ["君", "が", "好", "き", "だ", "よ"])
        #expect(doc.lines[1].syllables.map(\.text) == ["東", "京", "ラー", "メ", "ン。"])
    }

    @Test func toLyricsDocTapsPastTheSongEndAreClamped() throws {
        var d = tapAll(pasted("a b c"), startMs: 9_900, stepMs: 400)
        d.durationMs = 10_000
        let doc = try LyricsTapSync.toLyricsDoc(d, offsetMs: 0).get()
        #expect(LyricsDocCodec.isValid(doc))
        #expect(doc.lines.allSatisfy { $0.endMs <= 10_000 })
    }

    @Test func toLyricsDocIsAlwaysValidForRandomSessions() throws {
        for seed in Int32(0)..<500 {
            var problems = 0
            RandomSessions.run(seed: seed) { event, offset in
                guard problems == 0 else { return }
                let context = "seed \(seed) step \(event.label)"
                if (0...59).contains(event.action), event.after != event.before {
                    let index = LyricsTapSync.nextTappable(event.before, from: event.before.cursor)
                    if index < event.before.tokens.count {
                        let next = event.after
                        let previous = stride(from: index - 1, through: 0, by: -1).first {
                            !next.lines[next.tokens[$0].line].locked && next.tokens[$0].rawStartMs != nil
                        }
                        if let previous, start(next, index, offset)! < start(next, previous, offset)! + 10 {
                            Issue.record("\(context): tap not after the previous one")
                            problems += 1
                        }
                    }
                }
                if event.label != "final" && !LyricsTapSync.isConsistent(event.after) {
                    Issue.record("\(context): inconsistent draft")
                    problems += 1
                }
                if !buildsValid(event.after, offset, context) { problems += 1 }
            }
            if problems > 0 { return }
        }
    }

    /// `assertBuildsValid`.
    func buildsValid(_ draft: SyncDraft, _ offsetMs: Int, _ context: String) -> Bool {
        let result = LyricsTapSync.buildResult(draft, offsetMs: offsetMs)
        if draft.tappedCount == 0 && draft.tappableCount > 0 {
            if case .success = result {
                Issue.record("\(context): expected failure without taps")
                return false
            }
            return true
        }
        guard case .success(let built) = result else {
            Issue.record("\(context): \(result)")
            return false
        }
        let doc = built.doc
        var ok = true
        if !LyricsDocCodec.isValid(doc) {
            Issue.record("\(context): invalid doc \(doc)")
            ok = false
        }
        if draft.lines.map(\.text).sorted() != doc.lines.map(\.text).sorted() {
            Issue.record("\(context): lines lost")
            ok = false
        }
        if LyricsDocCodec.decode(LyricsDocCodec.encode(doc)) == nil {
            Issue.record("\(context): does not decode")
            ok = false
        }
        return ok
    }

    // MARK: Swift-only checks

    @Test func kotlinLinesSplitsLikeKotlin() {
        #expect(LyricsTapSync.kotlinLines("a\r\nb\rc\nd") == ["a", "b", "c", "d"])
        #expect(LyricsTapSync.kotlinLines("a\n") == ["a", ""])
        #expect(LyricsTapSync.kotlinLines("") == [""])
        #expect(LyricsTapSync.kotlinLines("\r\r\n") == ["", "", ""])
    }

    @Test func tokenizeSplitsOnScalarSpacesEvenBeforeCombiningMarks() {
        // " \u{301}" is a single Character in Swift; Android splits on the U+0020 code unit.
        let tokens = LyricsTapSync.tokenize("a \u{301}b")
        #expect(tokens.joined().isIdentical(to: "a \u{301}b"))
        #expect(tokens.count == 2)
    }

    @Test func isConsistentRejectsBrokenDrafts() {
        let d = taps(pasted("a b", "c"), 1_000)
        #expect(LyricsTapSync.isConsistent(d))
        var wrongText = d
        wrongText.lines[0].text = "a  b"
        #expect(!LyricsTapSync.isConsistent(wrongText))
        var badSpeed = d
        badSpeed.tokens[0].startSpeed = .nan
        #expect(!LyricsTapSync.isConsistent(badSpeed))
        var badCursor = d
        badCursor.cursor = 4
        #expect(!LyricsTapSync.isConsistent(badCursor))
        var lockedUntimed = d
        lockedUntimed.lines[1].locked = true
        #expect(!LyricsTapSync.isConsistent(lockedUntimed))
    }

    @Test func buildDraftFromSongUsesItsMetadata() throws {
        let song = Song(id: "f:abc/song.mp3", title: "Song", artist: "Main", artistId: 1,
                        artists: [ArtistRef(id: 2, name: "Feat", isPrimary: false), ArtistRef(id: 1, name: "Main", isPrimary: true)],
                        album: "LP", albumId: 3, path: "song.mp3", contentUriString: "", albumArtUriString: nil,
                        duration: 180_000, mimeType: nil, bitrate: nil, sampleRate: nil)
        let draft = try #require(LyricsTapSync.buildDraft(song: song, lyrics: nil, pasted: "la la").draft)
        #expect(draft.songId == "f:abc/song.mp3")
        #expect(draft.artist == "Main, Feat")
        #expect(draft.album == "LP")
        #expect(draft.durationMs == 180_000)
    }
}
