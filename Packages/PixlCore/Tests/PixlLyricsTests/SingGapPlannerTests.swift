import Foundation
import Testing
@testable import PixlLyrics

/// The Sing button's switch: where the singer is quiet (`SingGapIndex`) and where the swap to the instrumental starts
/// and how long it fades (`SingSwitchPlanner`).
@Suite("Sing gap index and switch planner")
struct SingGapPlannerTests {
    // MARK: Fixtures

    /// A line whose words are `(startMs, endMs)` pairs.
    private func line(_ index: Int, _ words: [(Int64, Int64)], role: PreparedVoiceRole = .lead,
                      explicitEnds: Bool = true) -> PreparedLine {
        let syllables = words.enumerated().map { i, word in
            PreparedSyllable(charStart: i * 2, charEnd: i * 2 + 1, startMs: word.0, endMs: word.1,
                             endIsExplicit: explicitEnds, wordIndex: i, emphasis: false)
        }
        let start = words.first?.0 ?? 0
        return PreparedLine(index: index, startMs: start, endMs: words.last?.1 ?? start, endIsExplicit: explicitEnds,
                            text: String(repeating: "a ", count: words.count), role: role, groupLeadIndex: index,
                            bgAbove: false, syllables: syllables, translation: nil, romanization: nil)
    }

    /// A line timed as a whole only.
    private func lineOnly(_ index: Int, from startMs: Int64, to endMs: Int64) -> PreparedLine {
        PreparedLine(index: index, startMs: startMs, endMs: endMs, endIsExplicit: false, text: "la la", role: .lead,
                     groupLeadIndex: index, bgAbove: false, syllables: nil, translation: nil, romanization: nil)
    }

    private func lyrics(_ lines: [PreparedLine]) -> PreparedLyrics {
        PreparedLyrics(lines: lines, rows: lines.map { .line(lineIndex: $0.index) },
                       hasWordTiming: lines.contains { $0.hasWordTiming }, hasDuet: lines.contains { $0.role == .duet },
                       startsSorted: lines.map(\.startMs))
    }

    /// Two sung stretches, 920–2120 and 2920–4120 once padded (80 ms before, 120 ms after): quiet before, between
    /// (800 ms) and after.
    private var song: SingGapIndex {
        SingGapIndex(lyrics([line(0, [(1_000, 1_400), (1_500, 2_000)]), line(1, [(3_000, 3_500), (3_600, 4_000)])]))
    }

    private func bounds(_ gaps: [(start: Int64, end: Int64)]) -> [[Int64]] { gaps.map { [$0.start, $0.end] } }

    // MARK: Gap index

    @Test func spansArePaddedAndMerged() {
        #expect(song.hasWordTiming)
        #expect(song.spans == [.init(startMs: 920, endMs: 2_120), .init(startMs: 2_920, endMs: 4_120)])
    }

    @Test func aSyllableWithAnInferredEndSpansTheSameWay() {
        let inferred = SingGapIndex(lyrics([line(0, [(1_000, 1_400), (1_500, 2_000)], explicitEnds: false),
                                            line(1, [(3_000, 3_500), (3_600, 4_000)], explicitEnds: false)]))
        #expect(inferred == song)
    }

    @Test func gapsAreFoundByTheirRealBounds() {
        let index = song
        #expect(bounds(index.gaps(from: 2_000, to: 2_500)) == [[2_120, 2_920]])
        #expect(bounds(index.gaps(from: 0, to: 500)) == [[SingGapIndex.openStartMs, 920]])
        #expect(bounds(index.gaps(from: 5_000, to: 6_000)) == [[4_120, SingGapIndex.openEndMs]])
        // A query reaching several gaps lists them in order, the last one whole.
        #expect(bounds(index.gaps(from: 0, to: 3_000)) == [[SingGapIndex.openStartMs, 920], [2_120, 2_920]])
        #expect(bounds(index.gaps(from: 2_000, to: 9_000)) == [[2_120, 2_920], [4_120, SingGapIndex.openEndMs]])
    }

    @Test func aQueryInsideSungWordsFindsNoGap() {
        #expect(song.gaps(from: 1_000, to: 1_100).isEmpty)
        #expect(song.gaps(from: 3_000, to: 4_000).isEmpty)
    }

    @Test func aGapStartingExactlyAtTheEndOfTheQueryCounts() {
        #expect(bounds(song.gaps(from: 1_520, to: 2_120)) == [[2_120, 2_920]])
        #expect(song.gaps(from: 1_520, to: 2_119).isEmpty)
    }

    @Test func anInvertedRangeFindsNothing() {
        #expect(song.gaps(from: 3_000, to: 2_000).isEmpty)
    }

    @Test func overlappingVoicesAreOneSungStretch() {
        // A duet: the second voice starts inside the first one's phrase and ends after it.
        let duet = SingGapIndex(lyrics([line(0, [(1_000, 2_000)]), line(1, [(1_500, 3_000)], role: .duet),
                                        line(2, [(3_040, 3_500)], role: .background)]))
        #expect(duet.spans == [.init(startMs: 920, endMs: 3_620)], "the background word overlaps the duet's padded end")
        #expect(bounds(duet.gaps(from: 2_000, to: 3_000)).isEmpty)
    }

    @Test func linesWithoutWordTimingHaveNoGaps() {
        let index = SingGapIndex(lyrics([lineOnly(0, from: 1_000, to: 3_000), lineOnly(1, from: 5_000, to: 7_000)]))
        #expect(!index.hasWordTiming)
        #expect(index.spans.isEmpty)
        #expect(index.gaps(from: 0, to: 10_000).isEmpty, "the whole song is not a gap just because nothing is timed")
    }

    @Test func aLineTimedByLineAmongWordTimedOnesCountsAsSung() {
        let index = SingGapIndex(lyrics([line(0, [(1_000, 1_400), (1_500, 2_000)]), lineOnly(1, from: 3_000, to: 4_000)]))
        #expect(index.hasWordTiming)
        #expect(index.spans == [.init(startMs: 920, endMs: 2_120), .init(startMs: 2_920, endMs: 4_120)])
    }

    @Test func aSongWithoutLinesHasNoWordTiming() {
        #expect(!SingGapIndex(lyrics([])).hasWordTiming)
    }

    // MARK: Planner

    @Test func theConstantsAreTheOnesTheEngineClampsTo() {
        #expect(SingSwitchPlanner.minFadeMs == 300)
        #expect(SingSwitchPlanner.maxFadeMs == 700)
        #expect(SingSwitchPlanner.minGapMs == 300)
        #expect(SingSwitchPlanner.maxWaitMs == 600)
    }

    @Test func anEarliestStartInsideAGapStartsThereAndFadesToTheEndOfTheGap() {
        let placement = SingSwitchPlanner.plan(index: song, earliestPlayerMs: 2_300, offsetMs: 0, rate: 1)
        #expect(placement == .init(startPlayerMs: 2_300, fadeMs: 620, reason: .insideGap))
    }

    @Test func aLongGapGivesTheFullFade() {
        let placement = SingSwitchPlanner.plan(index: song, earliestPlayerMs: 5_000, offsetMs: 0, rate: 1)
        #expect(placement == .init(startPlayerMs: 5_000, fadeMs: 700, reason: .insideGap))
    }

    @Test func aGapThatBeginsWithinTheWaitIsWaitedFor() {
        let placement = SingSwitchPlanner.plan(index: song, earliestPlayerMs: 1_700, offsetMs: 0, rate: 1)
        #expect(placement == .init(startPlayerMs: 2_120, fadeMs: 700, reason: .nextGap))
    }

    @Test func aGapBeyondTheWaitIsNotWaitedFor() {
        let placement = SingSwitchPlanner.plan(index: song, earliestPlayerMs: 1_400, offsetMs: 0, rate: 1)
        #expect(placement == .init(startPlayerMs: 1_400, fadeMs: 700, reason: .noGapInWindow))
    }

    @Test func theWaitIncludesAGapStartingExactlyAtItsEnd() {
        let placement = SingSwitchPlanner.plan(index: song, earliestPlayerMs: 1_520, offsetMs: 0, rate: 1)
        #expect(placement == .init(startPlayerMs: 2_120, fadeMs: 700, reason: .nextGap))
    }

    @Test func aGapShorterThanTheMinimumIsSkipped() {
        // 100 ms of quiet between two phrases, then more singing: nothing usable in the wait.
        let tight = SingGapIndex(lyrics([line(0, [(1_000, 1_400)]), line(1, [(1_700, 2_000)])]))
        #expect(tight.spans == [.init(startMs: 920, endMs: 1_520), .init(startMs: 1_620, endMs: 2_120)])
        let placement = SingSwitchPlanner.plan(index: tight, earliestPlayerMs: 1_300, offsetMs: 0, rate: 1)
        #expect(placement.reason == .noGapInWindow)
        #expect(placement.startPlayerMs == 1_300)
    }

    @Test func aGapJustLongEnoughFadesForExactlyItsLength() {
        let snug = SingGapIndex(lyrics([line(0, [(1_000, 1_400)]), line(1, [(1_900, 2_300)])]))
        #expect(snug.spans == [.init(startMs: 920, endMs: 1_520), .init(startMs: 1_820, endMs: 2_420)])
        let placement = SingSwitchPlanner.plan(index: snug, earliestPlayerMs: 1_500, offsetMs: 0, rate: 1)
        #expect(placement == .init(startPlayerMs: 1_520, fadeMs: 300, reason: .nextGap))
    }

    @Test func theRestOfAGapShorterThanTheMinimumIsNotEnough() {
        // 220 ms of the 800 ms gap are left at the earliest start; the next gap is out of reach.
        let placement = SingSwitchPlanner.plan(index: song, earliestPlayerMs: 2_700, offsetMs: 0, rate: 1)
        #expect(placement == .init(startPlayerMs: 2_700, fadeMs: 700, reason: .noGapInWindow))
    }

    @Test func aLaterGapInTheWaitIsUsedWhenTheFirstIsTooShort() {
        // 100 ms of quiet at 1 520, then 300 ms from 1 920: both begin within the 600 ms from 1 500.
        let index = SingGapIndex(lyrics([line(0, [(1_000, 1_400)]), line(1, [(1_700, 1_800)]), line(2, [(2_300, 2_600)])]))
        #expect(index.spans == [.init(startMs: 920, endMs: 1_520), .init(startMs: 1_620, endMs: 1_920),
                                .init(startMs: 2_220, endMs: 2_720)])
        let placement = SingSwitchPlanner.plan(index: index, earliestPlayerMs: 1_500, offsetMs: 0, rate: 1)
        #expect(placement == .init(startPlayerMs: 1_920, fadeMs: 300, reason: .nextGap))
    }

    @Test func theLyricsOffsetMovesTheWindowAndComesBackOutOfTheStart() {
        // Lyrics time is the player's plus the offset.
        let inside = SingSwitchPlanner.plan(index: song, earliestPlayerMs: 1_800, offsetMs: 500, rate: 1)
        #expect(inside == .init(startPlayerMs: 1_800, fadeMs: 620, reason: .insideGap), "lyrics time 2 300")
        let later = SingSwitchPlanner.plan(index: song, earliestPlayerMs: 1_500, offsetMs: 500, rate: 1)
        #expect(later == .init(startPlayerMs: 1_620, fadeMs: 700, reason: .nextGap), "the gap opens at lyrics time 2 120")
        let early = SingSwitchPlanner.plan(index: song, earliestPlayerMs: 2_800, offsetMs: -500, rate: 1)
        #expect(early == .init(startPlayerMs: 2_800, fadeMs: 620, reason: .insideGap), "lyrics time 2 300")
    }

    @Test func aSlowedSongReachesLessFarIntoItsLyrics() {
        // 600 ms of waiting is 450 ms of a song played at 0.75×.
        let slow = SingSwitchPlanner.plan(index: song, earliestPlayerMs: 1_600, offsetMs: 0, rate: 0.75)
        #expect(slow == .init(startPlayerMs: 1_600, fadeMs: 700, reason: .noGapInWindow))
        let normal = SingSwitchPlanner.plan(index: song, earliestPlayerMs: 1_600, offsetMs: 0, rate: 1)
        #expect(normal == .init(startPlayerMs: 2_120, fadeMs: 700, reason: .nextGap))
        // A fast one reaches further.
        let fast = SingSwitchPlanner.plan(index: song, earliestPlayerMs: 1_300, offsetMs: 0, rate: 1.5)
        #expect(fast == .init(startPlayerMs: 2_120, fadeMs: 700, reason: .nextGap))
    }

    @Test func withoutWordTimingTheSwitchStartsAtOnceWithTheFullFade() {
        let lineTimed = SingGapIndex(lyrics([lineOnly(0, from: 1_000, to: 3_000)]))
        let a = SingSwitchPlanner.plan(index: lineTimed, earliestPlayerMs: 2_300, offsetMs: 120, rate: 1)
        #expect(a == .init(startPlayerMs: 2_300, fadeMs: 700, reason: .noWordTiming))
        let b = SingSwitchPlanner.plan(index: nil, earliestPlayerMs: 9_000, offsetMs: -400, rate: 1)
        #expect(b == .init(startPlayerMs: 9_000, fadeMs: 700, reason: .noWordTiming))
    }

    @Test func aWildRateStillGivesAPlacement() {
        let placement = SingSwitchPlanner.plan(index: song, earliestPlayerMs: 1_700, offsetMs: 0, rate: 0)
        #expect(placement.reason == .noGapInWindow, "a zero rate is read as the slowest the player allows")
        #expect(placement.startPlayerMs == 1_700)
    }
}
