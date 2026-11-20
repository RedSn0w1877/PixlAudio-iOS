import Foundation
import PixlModel
import Testing
@testable import PixlLibrary

/// Stage 4, milestone 1 on iOS (docs/handoff/2026-11-21-music-brain-stage4.md): the served vector rides with a pick from the planner to
/// the play event and is stored with it, and an older queue, mix or event still reads. Synthetic data only.
@Suite("Brain stage 4: the served vector")
struct BrainStage4Tests {
    private static let t0: Int64 = 1_760_000_000_000

    private func plan() -> StationPlanner.Plan {
        var candidates: [Candidate] = []
        for i in 0..<12 {
            candidates.append(Candidate(rid: 1_000 + Int64(i), aid: 50 + Int64(i % 4), inLibrary: i % 3 != 0, liked: i == 2))
        }
        let seeds = [Retrieval.SeedList(seedRid: 999, seedAid: 49, rids: candidates.map(\.rid))]
        var affinity = Affinity.State()
        affinity.recordsTouched = false
        let session = SessionState()
        let graph = StationPlanner.buildGraph(seeds: seeds, candidates: candidates, session: session)
        let request = StationPlanner.Request(mode: StationPlanner.modeAutoplay, count: 5, candidates: candidates, seeds: seeds,
                                             nowMs: Self.t0, tzOffsetMin: 0, tieSeed: 7, excludedRids: [], bridge: false)
        return StationPlanner.plan(request, affinity: affinity, session: session, graph: graph)
    }

    @Test func everyPickOfAPlanCarriesTheVectorItWasScoredWith() throws {
        let p = plan()
        #expect(p.picks.count >= 3 && p.picks.count <= 5)
        for pick in p.picks {
            let x = try #require(ServedVector.dequantize(pick.servedX), "a pick without its served vector")
            #expect(x.count == Ranker.d)
            // Feature 0 is the bias, always 1.
            #expect(x[0] == 1.0)
            // Every value is a multiple of 1/4096 within the learner's own limit.
            for v in x { #expect(abs(v) <= Ranker.xMax) }
        }
        // The same inputs give the same plan and the same vectors (it is a pure function).
        let again = plan()
        #expect(again.picks.map(\.rid) == p.picks.map(\.rid))
        #expect(again.picks.map(\.servedX) == p.picks.map(\.servedX))
    }

    @Test func theVectorSurvivesTheTagTheSavedQueueAndTheOpenPlay() throws {
        let hex = ServedVector.toHex(try #require(plan().picks.first?.servedX))
        #expect(hex.utf16.count == 204)
        let tag = BrainItemTag(surface: "autoplay", surfaceId: "s", recId: 3, slot: 1, arm: "RADIO", servedX: hex)
        #expect(!tag.isEmpty)
        #expect(!BrainItemTag(servedX: hex).isEmpty, "a tag with only the vector must not be dropped on the way")
        // A text that is not exactly 204 characters is no vector.
        #expect(BrainItemTag(arm: "FAV", servedX: "abcd").servedX == nil)
        let item = PlaybackQueueItemSnapshot(mediaId: "m", uri: "spotify://0123456789abcdef012345").withBrainTag(tag)
        let data = try JSONEncoder().encode(item)
        #expect(try #require(JSONDecoder().decode(PlaybackQueueItemSnapshot.self, from: data).brainTag()).servedX == hex)
        // A queue saved by an earlier build has no such field.
        let old = #"{"mediaId":"m","uri":"spotify://0123456789abcdef012345","brainSurface":"autoplay","brainArm":"RADIO"}"#
        #expect(try #require(JSONDecoder().decode(PlaybackQueueItemSnapshot.self, from: Data(old.utf8)).brainTag()).servedX == nil)
        // The play in flight.
        let ctx = PlayContext(title: "t", artistDisplay: "a", tag: tag)
        let play = FinishedPlay(songId: "s1", context: ctx, startedAtMs: Self.t0, playedMs: 1, durationMs: 2, endReason: EndReason.killed)
        let back = try #require(OpenPlayCodec.decode(OpenPlayCodec.encode(play)))
        #expect(back.context.tag?.servedX == hex)
        let plain = FinishedPlay(songId: "s2", context: PlayContext(title: "t", artistDisplay: "a"), startedAtMs: Self.t0,
                                 playedMs: 1, durationMs: 2, endReason: EndReason.killed)
        #expect(!OpenPlayCodec.encode(plain).contains("\"sx\""))
    }

    @Test func aMixOrAShelfSavedBeforeStage4StillReads() throws {
        let item = StoredMixItem(rid: 5, songId: "s", arm: Arm.radio, slot: 0, sx: "")
        let old = #"{"rid":5,"songId":"s","arm":1,"slot":0}"#
        let decoded = try JSONDecoder().decode(StoredMixItem.self, from: Data(old.utf8))
        #expect(decoded.sx.isEmpty)
        #expect(item.sx.isEmpty)
        let hex = ServedVector.toHex(try #require(plan().picks.first?.servedX))
        let withVec = StoredMixItem(rid: 5, songId: "s", arm: Arm.radio, slot: 0, sx: hex)
        let round = try JSONDecoder().decode(StoredMixItem.self, from: JSONEncoder().encode(withVec))
        #expect(round.sx == hex)
        let planItem = PlanItem(rid: 5, songId: "s", arm: Arm.radio, slot: 0, sx: hex)
        let planRound = try JSONDecoder().decode(PlanItem.self, from: JSONEncoder().encode(planItem))
        #expect(planRound.sx == hex)
    }
}
