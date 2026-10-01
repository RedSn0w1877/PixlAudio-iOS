import Foundation
import Testing
import PixlModel
@testable import PixlLyrics

/// Port of the Android `utils/LyricsUtilsTest` (all 23 cases), plus Swift checks of the dispatcher.
@Suite("Parsing — LyricsUtils")
struct ParsingLyricsUtilsTests {

    static let sampleLines = [
        "[00:03.80]Time is standing still and I don't wanna leave your lips",
        "[00:09.86]Tracing my body with your fingertips",
        "[00:16.53]I know what you're feeling and I know you wanna say it (yeah, say it)",
        "[00:22.76]I do too, but we gotta be patient (gotta be patient)",
        "[00:28.32]'Cause someone like me (and someone like you)",
        "[00:31.65]Really shouldn't work, yeah, the history is proof",
        "[00:34.75]Damned if I don't (damned if I do)",
        "[00:38.08]You know, by now, we've seen it all",
        "[00:41.67]Said, oh, we should fall in love with our eyes closed",
        "[00:46.76]Better if we keep it where we don't know",
        "[00:49.97]The beds we've been in, the names and the faces of who we were with",
        "[00:54.36]And, oh, ain't nobody perfect, but it's all good",
        "[00:59.52]The past can't hurt us if we don't look",
        "[01:02.71]Let's let it go, better if we fall in love with our eyes closed",
        "[01:09.05](Oh, oh, oh)",
        "[01:13.94]I got tunnel vision every second that you're with me",
        "[01:19.88]No, I don't care what anybody says, just kiss me (oh)",
        "[01:26.05]'Cause you look like trouble, but it could be good",
        "[01:29.09]I've been the same, kind of misunderstood",
        "[01:32.32]Whatever you've done, trust, it ain't nothing new",
        "[01:35.48]You know by now, we've seen it all",
        "[01:39.23]Said, oh, we should fall in love with our eyes closed",
        "[01:44.48]Better if we keep it where we don't know",
        "[01:47.55]The beds we've been in, the names and the faces of who we were with",
        "[01:52.13]And, oh, ain't nobody perfect, but it's all good",
        "[01:57.17]The past can't hurt us if we don't look",
        "[02:00.27]Let's let it go, better if we fall in love with our eyes closed",
        "[02:06.25](Oh, oh, keep your eyes closed)",
        "[02:10.76]'Cause someone like me and someone like you",
        "[02:13.86]Really shouldn't work, yeah, the history is proof",
        "[02:17.25]Damned if I don't, damned if I do",
        "[02:20.26]You know by now, we've seen it all",
        "[02:24.13]Said, oh, we should fall in love with our eyes closed",
        "[02:29.09]Better if we keep it where we don't know",
        "[02:32.13]The beds we've been in, the names and the faces of who we were with",
        "[02:36.95]And, oh, ain't nobody perfect, but it's all good",
        "[02:41.75]The past can't hurt us if we don't look",
        "[02:45.08]Let's let it go, better if we fall in love with our eyes closed (oh)",
        "[02:54.13]With our eyes closed",
        "[02:58.92]",
    ]

    @Test func handlesBomAtStartOfSyncedLine() throws {
        let synced = try #require(LyricsUtils.parseLyrics("\u{FEFF}[00:03.80]Time is standing still\n[00:09.86]Tracing my body").synced)
        #expect(synced.count == 2)
        #expect(synced[0].time == 3_800)
        #expect(synced[0].line == "Time is standing still")
        #expect(synced[1].time == 9_860)
        #expect(synced[1].line == "Tracing my body")
    }

    @Test func handlesWhitespacesBeforeTimestamp() throws {
        let synced = try #require(LyricsUtils.parseLyrics("\u{FEFF}   [00:03.80]Time is standing still\r\n\t[00:09.86]Tracing my body").synced)
        #expect(synced.count == 2)
        #expect(synced[0].time == 3_800)
        #expect(synced[0].line == "Time is standing still")
        #expect(synced[1].time == 9_860)
        #expect(synced[1].line == "Tracing my body")
    }

    @Test func parsesFullSampleWithBom() throws {
        let synced = try #require(LyricsUtils.parseLyrics("\u{FEFF}" + Self.sampleLines.joined(separator: "\n")).synced)
        #expect(synced.count == 40)
        #expect(synced.first?.time == 3_800)
        #expect(synced.first?.line == "Time is standing still and I don't wanna leave your lips")
        #expect(synced.last?.time == 178_920)
        #expect(synced.last?.line == "")
    }

    @Test func ignoresFormatCharactersInsideTimestamp() throws {
        let synced = try #require(LyricsUtils.parseLyrics("\u{202A}[00:03.80\u{202C}]Time is standing still\n[00:09.86]Tracing my body").synced)
        #expect(synced.count == 2)
        #expect(synced[0].time == 3_800)
        #expect(synced[0].line == "Time is standing still")
        #expect(synced[1].time == 9_860)
        #expect(synced[1].line == "Tracing my body")
    }

    @Test func parsesSampleWrappedInQuotes() throws {
        // Kotlin buildString: '"' + each line + "\n" (appendLine) + last line + '"'.
        let body = Self.sampleLines.dropLast().map { $0 + "\n" }.joined() + Self.sampleLines.last!
        let synced = try #require(LyricsUtils.parseLyrics("\"" + body + "\"").synced)
        #expect(synced.count == 40)
        #expect(synced.first?.time == 3_800)
        #expect(synced.first?.line == "Time is standing still and I don't wanna leave your lips")
        #expect(synced.last?.time == 178_920)
        #expect(synced.last?.line == "")
    }

    static let chaseAtlanticTtml = """
        <?xml version='1.0' encoding='utf-8'?>
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word" xml:lang="en">
          <head>
            <metadata>
              <ttm:agent type="person" xml:id="v1">
                <ttm:name type="full">Chase Atlantic</ttm:name>
              </ttm:agent>
            </metadata>
          </head>
          <body dur="0:15.000">
            <div begin="7.531" end="12.005" itunes:songPart="Verse">
              <p begin="7.531" end="12.005" itunes:key="L1" ttm:agent="v1"><span begin="7.531" end="7.782">Yeah,</span> <span begin="9.208" end="9.443">I</span> <span begin="9.443" end="9.675">bet</span></p>
            </div>
          </body>
        </tt>
        """

    @Test func convertsAppleTtmlWithXmlDeclarationAndNamespaces() throws {
        let synced = try #require(LyricsUtils.parseLyrics(Self.chaseAtlanticTtml).synced)
        let first = try #require(synced.first)
        #expect(synced.count == 1)
        #expect(first.time == 7_530)
        #expect(first.line == "Yeah, I bet")
        #expect(try #require(first.words).map(\.word) == ["Yeah,", "I", "bet"])
    }

    @Test func doesNotExposeBrokenTtmlAsPlainText() {
        let malformed = """
            <?xml version='1.0' encoding='utf-8'?>
            <tt xmlns="http://www.w3.org/ns/ttml">
              <body>
                <div>
                  <p begin="00:01.000">Hello
                </div>
              </body>
            </tt>
            """
        let lyrics = LyricsUtils.parseLyrics(malformed)
        #expect((lyrics.synced ?? []).isEmpty)
        #expect((lyrics.plain ?? []).isEmpty)
    }

    @Test func stripsAdditionalLrcTimestampsFromLines() throws {
        let lrc = """
            [00:12.57] Sinking under
            [00:26.42][01:12.34] Three in the morning, I ain't slept all weekend
            [00:41.71][00:52.96][01:27.42] My heart keeps breaking
            """
        let synced = try #require(LyricsUtils.parseLyrics(lrc).synced)
        #expect(synced.map(\.line) == ["Sinking under", "Three in the morning, I ain't slept all weekend", "My heart keeps breaking"])
    }

    @Test func wordByWordIgnoresTrailingUntaggedTranslationInWordTiming() throws {
        let synced = try #require(LyricsUtils.parseLyrics("[00:10.00]<00:10.00>To <00:10.30>fall <00:10.60>in <00:10.90>love\\n怦然心动").synced)
        let first = try #require(synced.first)
        let words = try #require(first.words)
        #expect(first.line == "To fall in love\\n怦然心动")
        #expect(words.map(\.word) == ["To", "fall", "in", "love"])
        #expect(words.map(\.startsNewWord) == [true, true, true, true])
        #expect(!words.contains { $0.word.contains("怦然心动") })
    }

    @Test func pairsSameTimestampLinesAsTranslation() throws {
        let synced = try #require(LyricsUtils.parseLyrics("[00:10.00]Hello world\n[00:10.00]你好世界\n[00:20.00]Goodbye").synced)
        #expect(synced.count == 2)
        #expect(synced[0].line == "Hello world")
        #expect(synced[0].translation == "你好世界")
        #expect(synced[1].line == "Goodbye")
        #expect(synced[1].translation == nil)
    }

    @Test func singleLineWithoutDuplicateTranslationIsNull() throws {
        let synced = try #require(LyricsUtils.parseLyrics("[00:10.00]Hello world\n[00:20.00]Goodbye\n[00:30.00]See you").synced)
        #expect(synced.count == 3)
        #expect(synced.allSatisfy { $0.translation == nil })
    }

    @Test func threeLinesAtSameTimestampPairsFirstTwoOnly() throws {
        let synced = try #require(LyricsUtils.parseLyrics("[00:10.00]Hello world\n[00:10.00]你好世界\n[00:10.00]Hola mundo").synced)
        #expect(synced.count == 2)
        #expect(synced[0].line == "Hello world")
        #expect(synced[0].translation == "你好世界")
        #expect(synced[1].line == "Hola mundo")
        #expect(synced[1].translation == nil)
    }

    @Test func translationCreditAtSameTimestampIsGroupedIntoTranslation() throws {
        let synced = try #require(LyricsUtils.parseLyrics("[00:10.00]Hello world\n[00:10.00]你好世界\n[00:10.00]by: translator\n[00:20.00]Goodbye").synced)
        #expect(synced.count == 2)
        #expect(synced[0].line == "Hello world")
        #expect(synced[0].translation == "你好世界\nby: translator")
        #expect(synced[1].line == "Goodbye")
        #expect(synced[1].translation == nil)
    }

    @Test func nonTimestampedLinePreservedAsMergeNotTranslation() throws {
        let synced = try #require(LyricsUtils.parseLyrics("[00:10.00]Hello world\ncontinuation line\n[00:20.00]Next").synced)
        #expect(synced.count == 2)
        #expect(synced[0].line == "Hello world\ncontinuation line")
        #expect(synced[0].translation == nil)
    }

    @Test func colonSubSecondSeparatorParsedAndPairedWithTranslation() throws {
        let lrc = "[00:00.000]作词: イマニシ\n[00:01.000]作曲: イマニシ\n[00:22:43]愛情なんて忘れて\n[00:25:39]一人ワルツを踊る\n[00:22.43]忘掉爱情什么的\n[00:25.39]一个人舞动华尔兹"
        let synced = try #require(LyricsUtils.parseLyrics(lrc).synced)
        #expect(synced.count == 4)
        let line22 = try #require(synced.first { $0.line == "愛情なんて忘れて" })
        #expect(line22.time == 22_430)
        #expect(line22.translation == "忘掉爱情什么的")
        let line25 = try #require(synced.first { $0.line == "一人ワルツを踊る" })
        #expect(line25.time == 25_390)
        #expect(line25.translation == "一个人舞动华尔兹")
    }

    @Test func wordByWordColonSubSecondSeparatorSupported() throws {
        let synced = try #require(LyricsUtils.parseLyrics("[00:10:00]<00:10:00>Hello <00:10:50>world").synced)
        let line = try #require(synced.first)
        #expect(synced.count == 1)
        let words = try #require(line.words)
        #expect(line.line == "Hello world")
        #expect(words.map(\.word) == ["Hello", "world"])
        #expect(words.map(\.time) == [10_000, 10_500])
        #expect(words.map(\.startsNewWord) == [true, true])
    }

    @Test func wordByWordMarksSyllablesAsSameVisualWord() throws {
        let synced = try #require(LyricsUtils.parseLyrics("[00:10.00]<00:10.00>to<00:10.20>geth<00:10.40>er <00:10.60>now").synced)
        let words = try #require(synced.first?.words)
        #expect(synced.first?.line == "together now")
        #expect(words.map(\.word) == ["to", "geth", "er", "now"])
        #expect(words.map(\.startsNewWord) == [true, false, false, true])
    }

    @Test func wordByWordStandaloneWhitespaceStillStartsNextWord() throws {
        let synced = try #require(LyricsUtils.parseLyrics("[00:10.00]<00:10.00>To<00:10.20> <00:10.40>fall").synced)
        let words = try #require(synced.first?.words)
        #expect(synced.first?.line == "To fall")
        #expect(words.map(\.word) == ["To", "fall"])
        #expect(words.map(\.startsNewWord) == [true, true])
    }

    @Test func syncedToLrcStringPreservesPairedTranslations() {
        let lrc = LyricsUtils.syncedToLrcString([
            SyncedLine(time: 10_000, line: "Hello world", translation: "你好世界"),
            SyncedLine(time: 20_000, line: "Goodbye"),
        ])
        #expect(lrc == "[00:10.00]Hello world\n[00:10.00]你好世界\n[00:20.00]Goodbye")
    }

    @Test func syncedToLrcStringExpandsMultilineTranslationWithTimestampPerLine() {
        let lrc = LyricsUtils.syncedToLrcString([SyncedLine(time: 10_000, line: "Hello world", translation: "你好世界\nby: translator")])
        #expect(lrc == "[00:10.00]Hello world\n[00:10.00]你好世界\n[00:10.00]by: translator")
    }

    @Test func failedZeroWordSyncKeepsEveryOriginalLine() throws {
        let raw = "[00:00.00]<00:00.00>First <00:00.00>line\n[00:00.00]<00:00.00>Second <00:00.00>line\n[00:00.00]<00:00.00>First <00:00.00>line"
        let synced = try #require(LyricsUtils.parseLyrics(raw).synced)
        #expect(synced.map(\.line) == ["First line", "Second line", "First line"])
        #expect(synced.reduce(0) { $0 + ($1.words ?? []).count } == 6)
        #expect(synced.allSatisfy { $0.translation == nil })
    }

    @Test func wordTimedLinesAtSameStartAreNotTranslations() throws {
        let synced = try #require(LyricsUtils.parseLyrics("[00:01.00]<00:01.00>First\n[00:01.00]<00:01.00>Second").synced)
        #expect(synced.map(\.line) == ["First", "Second"])
        #expect(synced.allSatisfy { $0.translation == nil })
    }

    // MARK: Swift-only

    @Test func emptyAndNilInputGiveEmptyLyrics() {
        for input in [nil, ""] as [String?] {
            let lyrics = LyricsUtils.parseLyrics(input)
            #expect(lyrics.plain == [])
            #expect(lyrics.synced == [])
        }
    }

    @Test func plainTextKeepsLinesAndDropsBlankOnes() {
        let lyrics = LyricsUtils.parseLyrics("Hello\nWorld\n\nAgain")
        #expect(lyrics.plain == ["Hello", "World", "Again"])
        #expect(lyrics.synced == nil)
    }

    @Test func metadataTagsAreSkippedAndStandardOffsetIsIgnored() throws {
        let synced = try #require(LyricsUtils.parseLyrics("[ti:Song]\n[ar:Artist]\n[offset:+500]\n[00:01.00]Line").synced)
        #expect(synced.map(\.time) == [1_000])
    }

    @Test func kugouFormatUsesRelativeWordOffsetsAndGlobalOffset() throws {
        let lyrics = LyricsUtils.parseLyrics("[offset:500]\n[1000,2000]<0,500,0>Hel<500,500,0>lo <1000,1000,0>world")
        let line = try #require(lyrics.synced?.first)
        #expect(line.time == 1_500)
        #expect(line.line == "Hello world")
        #expect(line.words?.map(\.time) == [1_500, 2_000, 2_500])
        #expect(line.words?.map(\.startsNewWord) == [true, false, true])
    }

    @Test func dispatchesDocumentsRichsyncAndYrc() throws {
        let doc = LyricsDoc(lines: [TimedLine(startMs: 1000, endMs: 2000, text: "Doc")])
        #expect(LyricsUtils.parseLyrics(LyricsDocCodec.encode(doc)).document == doc)
        #expect(LyricsUtils.parseLyrics("{\"format\":\"pixelplay-lyrics\",\"version\":9,\"lines\":[]}").synced == [])
        let rich = LyricsUtils.parseLyrics("[{\"ts\":1,\"te\":2,\"x\":\"hi\"}]")
        #expect(rich.document?.metadata.source == "Musixmatch")
        let yrc = LyricsUtils.parseLyrics("[1000,500](1000,500,0)yo")
        #expect(yrc.document?.metadata.source == "NetEase")
    }

    @Test func romanisesKoreanLinesAndAppendsThemToPlain() throws {
        let lyrics = LyricsUtils.parseLyrics("[00:01.00]안녕하세요")
        let line = try #require(lyrics.synced?.first)
        #expect(line.romanization == "Annyeonghaseyo")
        #expect(lyrics.plain == ["안녕하세요\nAnnyeonghaseyo"])
        #expect(LyricsUtils.plainToString(lyrics.plain ?? []) == "안녕하세요")
    }

    @Test func injectedProviderRomanisesJapanese() throws {
        struct Romaji: CJKRomanizationProvider {
            func romanizeJapanese(_ text: String) -> String? { "konnichiwa" }
            func pinyinReading(for hanzi: Character) -> String? { nil }
        }
        let line = try #require(LyricsUtils.parseLyrics("[00:01.00]こんにちは", romanization: Romaji()).synced?.first)
        #expect(line.romanization == "Konnichiwa")
        #expect(LyricsUtils.parseLyrics("[00:01.00]こんにちは").synced?.first?.romanization == nil)
    }

    @Test func toLrcStringPrefersSyncedThenPlain() {
        let lyrics = Lyrics(plain: ["a", "b\nroman"], synced: [SyncedLine(time: 61_230, line: "x")])
        #expect(LyricsUtils.toLrcString(lyrics) == "[01:01.23]x")
        #expect(LyricsUtils.toLrcString(lyrics, preferSynced: false) == "a\nb")
        #expect(LyricsUtils.toLrcString(Lyrics()) == "")
    }
}
