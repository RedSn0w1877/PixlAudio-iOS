// Port of the Android `data/lyrics/sync/LyricsExportTest.kt`. The TTML checks parse the output with Foundation's
// `XMLParser` (namespace-aware, FoundationXML on Windows/Linux) into a tiny DOM, like the Android test's
// `DocumentBuilder`. The three round trips through the app's lyrics parser need the stage 2b parser port and are
// disabled until the integrator wires it in (see `parseLyrics`).

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLyrics

@Suite("LyricsExport")
struct LyricsExportTests {

    /// TODO(integrator): once the s02b lyrics parsers are merged, set this to the Swift port of
    /// `LyricsUtils.parseLyrics(String): Lyrics` (e.g. `{ LyricsUtils.parseLyrics($0) }`) and delete the
    /// `.disabled(...)` traits of `lrcRoundTripsThroughTheAppParser`, `lrcRoundTripsTappedDrafts` and
    /// `ttmlReadsBackThroughTheAppParser`.
    static let parseLyrics: (@Sendable (String) -> Lyrics)? = nil

    static let ttmlNs = "http://www.w3.org/ns/ttml"
    static let ttmlMetadataNs = "http://www.w3.org/ns/ttml#metadata"

    static let doc = LyricsDoc(
        metadata: LyricsMetadata(title: "Song", artist: "Artist", album: "Album", durationMs: 200_000, source: "user"),
        lines: [
            TimedLine(startMs: 1_234, endMs: 3_000, text: "Hello there, world", voiceId: "lead", syllables: [
                TimedSyllable(startMs: 1_234, durationMs: 400, text: "Hello "),
                TimedSyllable(startMs: 1_634, durationMs: 500, text: "there, "),
                TimedSyllable(startMs: 2_134, durationMs: 866, text: "world"),
            ]),
            TimedLine(startMs: 4_005, endMs: 6_000, text: "beautiful day", voiceId: "lead", syllables: [
                TimedSyllable(startMs: 4_005, durationMs: 300, text: "beau"),
                TimedSyllable(startMs: 4_305, durationMs: 300, text: "ti"),
                TimedSyllable(startMs: 4_605, durationMs: 400, text: "ful "),
                TimedSyllable(startMs: 5_005, durationMs: 995, text: "day"),
            ]),
        ]
    )

    static let duet = LyricsDoc(
        metadata: LyricsMetadata(title: "A & B", artist: "", album: "", durationMs: 200_000, source: "user"),
        voices: [Voice(id: "lead", role: "lead"), Voice(id: "v2", role: "duet"), Voice(id: "bg", role: "background")],
        lines: [
            TimedLine(startMs: 1_000, endMs: 2_500, text: "R&B <3 'yes\"", voiceId: "lead", syllables: [
                TimedSyllable(startMs: 1_000, durationMs: 400, text: "R&B "),
                TimedSyllable(startMs: 1_500, durationMs: 400, text: "<3 "),
                TimedSyllable(startMs: 2_000, durationMs: 400, text: "'yes\""),
            ]),
            TimedLine(startMs: 1_200, endMs: 2_400, text: "(ooh)", voiceId: "bg",
                      syllables: [TimedSyllable(startMs: 1_200, durationMs: 1_200, text: "(ooh)")]),
            TimedLine(startMs: 3_000, endMs: 4_000, text: "Hi there", voiceId: "v2", syllables: [
                TimedSyllable(startMs: 3_000, durationMs: 400, text: "Hi "),
                TimedSyllable(startMs: 3_400, durationMs: 600, text: "there"),
            ]),
        ]
    )

    static let odd = LyricsDoc(
        metadata: LyricsMetadata(),
        lines: [TimedLine(startMs: 0, endMs: 500, text: "a\u{1}b", voiceId: "lead",
                          syllables: [TimedSyllable(startMs: 0, durationMs: 500, text: "a\u{1}b")])]
    )

    static let bare = LyricsDoc(
        metadata: LyricsMetadata(title: "Two\nlines"),
        lines: [TimedLine(startMs: 0, endMs: 1_000, text: "plain words")]
    )

    func nonEmptyLines(_ text: String) -> [String] { LyricsTapSync.kotlinLines(text).filter { !$0.isEmpty } }

    // MARK: LRC

    @Test func lrcHasHeadersWordTagsAndClosingTag() {
        #expect(nonEmptyLines(LyricsExport.toEnhancedLrc(Self.doc)) == [
            "[ti:Song]",
            "[ar:Artist]",
            "[al:Album]",
            "[length:03:20]",
            "[by:PixlAudio]",
            "[00:01.23]<00:01.23>Hello <00:01.63>there, <00:02.13>world<00:03.00>",
            "[00:04.01]<00:04.01>beau<00:04.31>ti<00:04.61>ful <00:05.01>day<00:06.00>",
        ])
    }

    @Test func lrcTimeFormatRoundsTo10msAndGrowsMinutes() {
        #expect(LyricsExport.lrcTime(1_235) == "00:01.24")
        #expect(LyricsExport.lrcTime(1_234) == "00:01.23")
        #expect(LyricsExport.lrcTime(59_995) == "01:00.00")
        #expect(LyricsExport.lrcTime(6_000_000) == "100:00.00")
        #expect(LyricsExport.lrcTime(-5) == "00:00.00")
    }

    @Test func lrcSkipsEmptyHeadersAndFlattensNewlines() {
        #expect(nonEmptyLines(LyricsExport.toEnhancedLrc(Self.bare)) == ["[ti:Two lines]", "[by:PixlAudio]", "[00:00.00]plain words"])
    }

    @Test(.disabled("Needs the stage 2b LRC parser: set LyricsExportTests.parseLyrics"))
    func lrcRoundTripsThroughTheAppParser() throws {
        try assertRoundTrip(Self.doc)
    }

    @Test(.disabled("Needs the stage 2b LRC parser: set LyricsExportTests.parseLyrics"))
    func lrcRoundTripsTappedDrafts() throws {
        for seed in Int32(0)..<40 {
            var random = KotlinRandom(seed: seed)
            let words = ["love", "you", "twenty-one", "rock'n'roll", "(oh", "yeah,", "night", "—", "don't", "stay"]
            var text: [String] = []
            for _ in 0..<random.nextInt(1, 8) {
                var line: [String] = []
                for _ in 0..<random.nextInt(1, 7) { line.append(random.pick(words)) }
                text.append(line.joined(separator: " "))
            }
            var draft = LyricsTapSync.buildDraft(songId: "id", title: "Title", artist: "Artist", album: "",
                                                 durationMs: 300_000, lyrics: nil, pasted: text.joined(separator: "\n")).draft!
            var t = random.nextLong(0, 3_000)
            while !draft.isFinished {
                t += random.nextLong(30, 1_500)
                draft = LyricsTapSync.tap(draft, rawStartMs: t, speed: random.pick([0.5, 1] as [Float]), offsetMs: 120).draft
            }
            try assertRoundTrip(LyricsTapSync.toLyricsDoc(draft, offsetMs: 120).get())
        }
    }

    private func assertRoundTrip(_ source: LyricsDoc) throws {
        let parse = try #require(Self.parseLyrics)
        let parsed = try #require(parse(LyricsExport.toEnhancedLrc(source)).synced)
        #expect(source.lines.count == parsed.count)
        for (expected, actual) in zip(source.lines, parsed) {
            #expect(expected.text == actual.line)
            #expect(abs(expected.startMs - Int64(actual.time)) <= 10, "line start \(expected.startMs) vs \(actual.time)")
            let words = try #require(actual.words)
            #expect(expected.syllables.map { $0.text.kotlinTrimmed() } == words.map(\.word))
            for (syllable, word) in zip(expected.syllables, words) {
                #expect(abs(syllable.startMs - Int64(word.time)) <= 10, "word start \(syllable.startMs) vs \(word.time)")
            }
        }
    }

    // MARK: TTML

    @Test func ttmlIsWellFormedAndEscaped() throws {
        let ttml = LyricsExport.toTtml(Self.duet)
        let root = try #require(XMLTree.parse(ttml))
        #expect(root.name == "tt")
        #expect(root.namespace == Self.ttmlNs)
        #expect(root.attribute("itunes:timing") == "Word")

        let body = try #require(root.descendants(named: "body", namespace: Self.ttmlNs).first)
        #expect(body.attribute("dur") == "0:03:20.000")

        let paragraphs = root.descendants(named: "p", namespace: Self.ttmlNs)
        #expect(paragraphs.count == 2) // the background line is nested, not its own <p>
        let first = paragraphs[0]
        let second = paragraphs[1]
        #expect(first.attribute("ttm:agent") == "v1")
        #expect(second.attribute("ttm:agent") == "v2")
        #expect(first.attribute("begin") == "0:00:01.000")
        #expect(first.attribute("end") == "0:00:02.500")
        #expect(first.textContent == "R&B <3 'yes\" (ooh)")
        #expect(second.textContent == "Hi there")

        let spans = first.descendants(named: "span", namespace: Self.ttmlNs)
        #expect(spans.count == 5)
        #expect(spans.prefix(3).map(\.textContent) == ["R&B", "<3", "'yes\""])
        let background = spans.filter { $0.attribute("ttm:role") == "x-bg" }
        #expect(background.count == 1)
        #expect(background.first?.textContent == "(ooh)")
        #expect(background.first?.attribute("begin") == "0:00:01.200")
        #expect(background.first?.attribute("end") == "0:00:02.400")

        for span in root.descendants(named: "span", namespace: Self.ttmlNs) {
            #expect(Self.isClock(span.attribute("begin")), "\(span.attribute("begin") ?? "nil")")
            #expect(Self.isClock(span.attribute("end")), "\(span.attribute("end") ?? "nil")")
        }
        #expect(!ttml.contains("R&B <"), "raw markup leaked into the file")
        let agents = root.descendants(named: "agent", namespace: Self.ttmlMetadataNs)
        #expect(agents.map { $0.attribute("xml:id") } == ["v1", "v2"])
    }

    @Test func ttmlSyllablesOfOneWordSitFlushAndTimesUseClockFormat() throws {
        let ttml = LyricsExport.toTtml(Self.doc)
        #expect(ttml.contains("<span begin=\"0:00:04.005\" end=\"0:00:04.305\">beau</span><span begin=\"0:00:04.305\""))
        #expect(ttml.contains("ful</span> <span begin=\"0:00:05.005\" end=\"0:00:06.000\">day</span></p>"))
        #expect(LyricsExport.ttmlTime(3_723_004) == "1:02:03.004")
        let root = try #require(XMLTree.parse(ttml))
        #expect(root.descendants(named: "p", namespace: Self.ttmlNs)[1].textContent == "beautiful day")
    }

    @Test func ttmlDropsCharactersXmlCannotCarryAndOmitsUnknownDuration() throws {
        let ttml = LyricsExport.toTtml(Self.odd)
        let root = try #require(XMLTree.parse(ttml))
        #expect(root.descendants(named: "p", namespace: Self.ttmlNs).first?.textContent == "ab")
        let body = try #require(root.descendants(named: "body", namespace: Self.ttmlNs).first)
        #expect(body.attribute("dur") == nil)
    }

    @Test(.disabled("Needs the stage 2b TTML parser: set LyricsExportTests.parseLyrics"))
    func ttmlReadsBackThroughTheAppParser() throws {
        let parse = try #require(Self.parseLyrics)
        let parsed = try #require(parse(LyricsExport.toTtml(Self.doc)).synced)
        #expect(parsed.map(\.line) == ["Hello there, world", "beautiful day"])
        for (expected, actual) in zip(Self.doc.lines, parsed) {
            #expect(abs(expected.startMs - Int64(actual.time)) <= 10, "line start \(expected.startMs) vs \(actual.time)")
        }
    }

    // MARK: Swift-only

    @Test func lrcAndTtmlHandleBackgroundOnlyAndLineOnlyParagraphs() throws {
        let ttml = LyricsExport.toTtml(try #require(TapSyncGoldenTests.docs["edge"]))
        let root = try #require(XMLTree.parse(ttml))
        let paragraphs = root.descendants(named: "p", namespace: Self.ttmlNs)
        // Two host-less background lines, the duet line and the lead line (with the trailing echo nested). The
        // whitespace-only first syllable of the lead line leaves just its word-ending space.
        #expect(paragraphs.count == 4)
        #expect(paragraphs[0].textContent == "(intro)")
        #expect(paragraphs[2].attribute("ttm:agent") == "v2")
        #expect(paragraphs[3].textContent == " ab cd (echo)")
        #expect(root.attribute("itunes:timing") == "Word")
    }

    /// `^\d+:\d{2}:\d{2}\.\d{3}$`.
    static func isClock(_ value: String?) -> Bool {
        guard let value else { return false }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy(\.isASCIIDigit), parts[1].count == 2,
              parts[1].allSatisfy(\.isASCIIDigit) else { return false }
        let seconds = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        return seconds.count == 2 && seconds[0].count == 2 && seconds[1].count == 3
            && seconds.allSatisfy { $0.allSatisfy(\.isASCIIDigit) }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// A minimal namespace-aware DOM built with `XMLParser`, for the TTML assertions.
final class XMLTree {
    let name: String
    let namespace: String?
    let attributes: [String: String]
    private(set) var children: [Child] = []

    enum Child {
        case element(XMLTree)
        case text(String)
    }

    init(name: String, namespace: String?, attributes: [String: String]) {
        self.name = name
        self.namespace = namespace
        self.attributes = attributes
    }

    /// An attribute by qualified name (`ttm:agent`), falling back to its local name: parsers differ in whether
    /// namespaced attribute keys keep their prefix.
    func attribute(_ qualifiedName: String) -> String? {
        if let value = attributes[qualifiedName] { return value }
        guard let colon = qualifiedName.firstIndex(of: ":") else { return nil }
        let local = qualifiedName[qualifiedName.index(after: colon)...]
        return attributes.first { key, _ in
            key == String(local) || key.split(separator: ":").last.map { $0 == local } == true
        }?.value
    }

    /// DOM `textContent`: every descendant text node, in order.
    var textContent: String {
        children.map { child in
            switch child {
            case .element(let element): element.textContent
            case .text(let text): text
            }
        }.joined()
    }

    /// `getElementsByTagNameNS`: descendants in document order.
    func descendants(named localName: String, namespace: String) -> [XMLTree] {
        var out: [XMLTree] = []
        for case .element(let element) in children {
            if element.name == localName && element.namespace == namespace { out.append(element) }
            out += element.descendants(named: localName, namespace: namespace)
        }
        return out
    }

    fileprivate func append(_ child: Child) { children.append(child) }

    /// Parses a document; nil when it is not well-formed.
    static func parse(_ xml: String) -> XMLTree? {
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        let builder = Builder()
        parser.delegate = builder
        guard parser.parse(), builder.stack.isEmpty else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        var stack: [XMLTree] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let element = XMLTree(name: elementName, namespace: namespaceURI, attributes: attributeDict)
            if let parent = stack.last { parent.append(.element(element)) } else { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.append(.text(string))
        }
    }
}
