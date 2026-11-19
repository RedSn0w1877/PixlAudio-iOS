import Foundation
import Testing
@testable import PixlLibrary

/// What Your sound reads from the log (8.6) and the names a genre page shows (8.7): the parts of `YourSoundReader` that are
/// pure. The screen itself is drawn by `App/Features/Brain/YourSoundView.swift`, which nothing here compiles.
@Suite("Brain Your sound reader (stage 3)")
struct BrainYourSoundReaderTests {
    private func event(_ i: Int, rid: Int64 = 1, surface: Int32 = Surface.autoplay, flags: Int32 = 0, played: Int32 = 200_000,
                       end: Int32 = EndReason.trackDone, model: Int32 = 0, origin: Int32 = Origin.live) -> PlayEvent {
        PlayEvent(eventId: Int64(i), origin: origin, rid: rid, primaryAid: 9, startedAtMs: 1_760_000_000_000 + Int64(i) * 300_000,
                  tzOffsetMin: 0, playedMs: played, durationMs: 200_000, endReason: end, flags: flags, surface: surface,
                  modelVersion: model)
    }

    @Test func aCountedPlayIsARealListenAndTheControlRatesComeFromEnginePicksOnly() {
        var events: [PlayEvent] = []
        // 4 control picks (3 finished), 5 picks ranked with the learned weights (4 finished), a skip heard for 3 s, an excluded
        // play, a silent one and a play of the listener's own choice.
        for i in 0..<4 {
            events.append(event(i, flags: EventFlags.controlSession, played: i < 3 ? 200_000 : 3_000,
                                end: i < 3 ? EndReason.trackDone : EndReason.next))
        }
        for i in 4..<9 {
            events.append(event(i, played: i < 8 ? 200_000 : 3_000, end: i < 8 ? EndReason.trackDone : EndReason.next,
                                model: BrainEngine.modelLearned))
        }
        events.append(event(20, flags: EventFlags.learnExcluded))
        events.append(event(21, flags: EventFlags.neverAudible))
        events.append(event(22, surface: Surface.playlist))
        let pass = YourSoundReader.pass(events)
        // The 3 s skips are not listens; the excluded and the silent ones are not counted at all.
        #expect(pass.rids.count == 3 + 4 + 1)
        #expect(pass.controlPlays == 4)
        #expect(pass.controlFinished == 3)
        #expect(pass.learnedPlays == 5)
        #expect(pass.learnedFinished == 4)
    }

    @Test func aRateIsShownOnlyFromThreeHundredPlays() {
        #expect(Gate.shownRate(finished: 10, total: 299) == nil)
        #expect(Gate.shownRate(finished: 150, total: 300) == 0.5)
    }

    @Test func everyGenreHasFactsWhoseLinksAreNamedAndOneTheAppDoesNotSayHasNone() throws {
        let atlas = try BrainStage2bGoldenTests.atlas()
        var shown = 0
        for id in atlas.allIds {
            guard let facts = YourSoundReader.facts(atlas, id) else {
                #expect(!AtlasNames.isShown(atlas.genre(id)?.name), "\(id) has a name the app says but no facts")
                continue
            }
            shown += 1
            #expect(AtlasNames.isShown(facts.name))
            for link in facts.parents + facts.children + facts.related + facts.influences {
                #expect(AtlasNames.isShown(link.name))
                #expect(atlas.genre(link.id)?.name == link.name)
            }
            if let text = facts.description { #expect(AtlasNames.isShown(text)) }
        }
        #expect(shown > atlas.size / 2)
        #expect(YourSoundReader.facts(atlas, GenreAtlas.none) == nil)
    }
}
