import Foundation
import Testing
import PixlModel
@testable import PixlLyrics

/// Duet songs end to end (Android `DuetLyricsTest`): catalog-shaped TTML → `TtmlDocumentParser` →
/// `PreparedLyricsBuilder`, and the side every line lands on. All lyric text is made up for the tests.
@Suite("Lyrics — duet sides")
struct DuetLyricsTests {
    func tt(_ head: String, _ body: String) -> String {
        #"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" "#
            + #"xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word" xml:lang="en">"#
            + "<head><metadata>\(head)</metadata></head><body><div>\(body)</div></body></tt>"
    }

    let agents = #"<ttm:agent type="person" xml:id="v1"/><ttm:agent type="person" xml:id="v2"/>"#
        + #"<ttm:agent type="group" xml:id="v1000"/>"#

    let duetBody =
        // Singer one, with a background echo that starts while singer two's line is already playing.
        #"<p begin="1.000" end="4.000" ttm:agent="v1"><span begin="1.000" end="1.500">I</span> "#
        + #"<span begin="1.500" end="2.000">said</span> <span begin="2.000" end="2.800">hello</span>"#
        + #"<span ttm:role="x-bg"><span begin="3.000" end="3.800">(hello)</span></span></p>"#
        // Singer two overlaps singer one.
        + #"<p begin="2.500" end="5.000" ttm:agent="v2"><span begin="2.500" end="3.000">You</span> "#
        + #"<span begin="3.000" end="3.500">said</span> <span begin="3.500" end="5.000">goodbye</span></p>"#
        // Singer two with their own background vocal.
        + #"<p begin="6.000" end="8.000" ttm:agent="v2"><span begin="6.000" end="6.500">Say</span> "#
        + #"<span begin="6.500" end="7.000">it</span> <span begin="7.000" end="8.000">back</span>"#
        + #"<span ttm:role="x-bg"><span begin="7.000" end="7.500">(back)</span></span></p>"#
        // Both, after a long instrumental.
        + #"<p begin="20.000" end="22.000" ttm:agent="v1000"><span begin="20.000" end="22.000">Together</span></p>"#
        // Singer two again, after another long gap.
        + #"<p begin="35.000" end="37.000" ttm:agent="v2"><span begin="35.000" end="37.000">Alone</span></p>"#

    func prepared(_ ttml: String) throws -> PreparedLyrics {
        try #require(PreparedLyricsBuilder.build(try #require(TtmlDocumentParser.parse(ttml))))
    }

    func line(_ p: PreparedLyrics, _ text: String) throws -> PreparedLine {
        try #require(p.lines.first { $0.text == text })
    }

    @Test func everyLineLandsOnItsSingersSide() throws {
        let p = try prepared(tt(agents, duetBody))
        #expect(p.hasDuet)
        let sides = Dictionary(uniqueKeysWithValues: p.lines.map { ($0.text, $0.duetEnd ? "right" : "left") })
        // Background vocals lose their wrapping parentheses in the parser.
        #expect(sides == [
            "I said hello": "left", "hello": "left",
            "You said goodbye": "right",
            "Say it back": "right", "back": "right",
            "Together": "left",
            "Alone": "right",
        ])
        for l in p.lines { #expect(p.sideRole(of: l) == (l.duetEnd ? .duet : l.role)) }
    }

    @Test func backgroundVocalStaysWithTheLineItWasNestedInEvenWhenTheOtherSingerOverlaps() throws {
        let p = try prepared(tt(agents, duetBody))
        // By time alone, "You said goodbye" (started 2.5 s, still playing at 3.0 s) would win.
        #expect(p.lines[try line(p, "hello").groupLeadIndex].text == "I said hello")
        #expect(p.lines[try line(p, "back").groupLeadIndex].text == "Say it back")
        let doc = try #require(TtmlDocumentParser.parse(tt(agents, duetBody))?.document)
        #expect(doc.voices.map(\.id) == ["lead", "duet", LyricsVoiceIds.leadBackground, LyricsVoiceIds.duetBackground])
        #expect(doc.voices.dropFirst(2).allSatisfy { $0.role == VoiceRole.background })
    }

    @Test func interludeDotsSitOnTheSideOfTheGroupTheyLeadInto() throws {
        let p = try prepared(tt(agents, duetBody))
        let interludes = p.rows.compactMap { row -> (Int64, Bool)? in
            if case .interlude(_, let end, let alignEnd) = row { return (end, alignEnd) }
            return nil
        }
        #expect(interludes.map(\.0) == [20_000, 35_000])
        #expect(interludes.map(\.1) == [false, true])
    }

    @Test func undeclaredAgentsFirstSingerLeadsOthersAreDuetGroupIdsLead() throws {
        let p = try prepared(tt("", duetBody))
        #expect(p.hasDuet)
        #expect(try !line(p, "I said hello").duetEnd)
        #expect(try line(p, "You said goodbye").duetEnd)
        #expect(try !line(p, "Together").duetEnd)
        #expect(try line(p, "back").duetEnd)
        #expect(TtmlDocumentParser.Builder.isGroupAgentId("v1000"))
        #expect(TtmlDocumentParser.Builder.isGroupAgentId("V1002"))
        #expect(!TtmlDocumentParser.Builder.isGroupAgentId("v999"))
        #expect(!TtmlDocumentParser.Builder.isGroupAgentId("voice1000"))
    }

    @Test func soloSongNoLineIsOnTheRightAndBackgroundIdsStayPlain() throws {
        let solo = duetBody.replacingOccurrences(of: #"ttm:agent="v2""#, with: #"ttm:agent="v1""#)
        let lyrics = try #require(TtmlDocumentParser.parse(tt(agents, solo)))
        #expect(lyrics.document?.voices.map(\.id) == ["lead", "background"])
        let p = try #require(PreparedLyricsBuilder.build(lyrics))
        #expect(!p.hasDuet)
        #expect(p.lines.allSatisfy { !$0.duetEnd })
    }

    @Test func lrcDuetBackgroundVocalFollowsTheDuetLineItIsGroupedUnder() throws {
        let p = try #require(PreparedLyricsBuilder.build(Lyrics(synced: [
            SyncedLine(time: 1_000, line: "Lead line", voiceRole: "lead"),
            SyncedLine(time: 5_000, line: "Answer line", endTime: 8_000, voiceRole: "duet"),
            SyncedLine(time: 6_000, line: "(answer)", voiceRole: "background"),
        ])))
        #expect(try line(p, "(answer)").duetEnd)
        #expect(try !line(p, "Lead line").duetEnd)
    }

    @Test func oldDocsWithoutOwnerIdsStillGroupByTime() throws {
        let doc = LyricsDoc(
            voices: [Voice(id: "lead", role: "lead"), Voice(id: "duet", role: "duet"),
                     Voice(id: "background", role: "background")],
            lines: [
                TimedLine(startMs: 1_000, endMs: 4_000, text: "One", voiceId: "lead"),
                TimedLine(startMs: 2_500, endMs: 5_000, text: "Two", voiceId: "duet"),
                TimedLine(startMs: 3_000, endMs: 3_800, text: "(echo)", voiceId: "background"),
            ]
        )
        let p = try #require(PreparedLyricsBuilder.build(doc))
        // No owner hint: the latest line already playing wins, and the vocal takes its side.
        #expect(p.lines[try line(p, "(echo)").groupLeadIndex].text == "Two")
        #expect(try line(p, "(echo)").duetEnd)
    }

    @Test func orphanBackgroundNestedInADuetLineSitsOnTheDuetSide() throws {
        let doc = LyricsDoc(
            voices: [Voice(id: "lead", role: "lead"), Voice(id: "duet", role: "duet"),
                     Voice(id: LyricsVoiceIds.duetBackground, role: "background")],
            lines: [
                TimedLine(startMs: 1_000, endMs: 2_000, text: "One", voiceId: "lead"),
                TimedLine(startMs: 3_000, endMs: 4_000, text: "Two", voiceId: "duet"),
                TimedLine(startMs: 30_000, endMs: 31_000, text: "far echo", voiceId: LyricsVoiceIds.duetBackground),
            ]
        )
        let p = try #require(PreparedLyricsBuilder.build(doc))
        let echo = try line(p, "far echo")
        #expect(echo.isGroupLead)
        #expect(echo.duetEnd)
        #expect(p.sideRole(of: echo) == .duet)
    }
}
