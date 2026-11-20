import Foundation
import PixlModel
import Testing
@testable import PixlLibrary

/// Stage 3's completion in the engine and the stores (docs/brain-spec.md, 5.10, 5.12 point 8, 8.1, 8.6, 8.7): the choice of weights made
/// when a list is built and carried to the play, the posteriors saved with the learner, the shelf bandit's impressions, the context
/// table, the genre adjustment and the brain's backup state. The iOS twin of Android's `ControlSessionTest` and the stage 3 completion
/// cases of `LearnerEngineTest`; against real record files in a temporary folder. Synthetic data only: nothing here says anything
/// about real listeners.
private final class Clock3b: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ start: Int64) { value = start }

    var now: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ ms: Int64) {
        lock.lock()
        value += ms
        lock.unlock()
    }
}

private struct Harness3b {
    static let t0: Int64 = 1_760_000_000_000

    let directory: URL
    let clock: Clock3b
    let engine: BrainEngine

    init(directory: URL? = nil, withSources: Bool = false) {
        let dir = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-3b-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
        let clock = Clock3b(Self.t0)
        self.clock = clock
        let repository = BrainRepository(directory: dir, radioSource: nil, clock: { clock.now })
        let sources: BrainEngine.Sources? = withSources
            ? BrainEngine.Sources(library: { [] }, history: { [] }, importSignature: { "x" },
                                  imported: { ([], ExternalTasteSnapshot()) }, adjustments: { [] })
            : nil
        engine = BrainEngine(directory: dir, repository: repository, sources: sources, rebuildDelayMs: 0, clock: { clock.now })
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func shelves() -> ShelfStore {
        let clock = self.clock
        return ShelfStore(directory: directory, engine: engine, tzOffsetMin: { _ in 0 }, clock: { clock.now })
    }

    /// A saved learner whose gate is on.
    func learnerOn() {
        var model = Ranker.newModel(today: 20_000)
        model.lastEventId = 0
        let saved = LearnerCodec.Saved(model: model, gate: Gate.State(useLearned: true, winStreak: 2, atMs: 1),
                                       learnVersion: LearnReplay.version, summary: nil, rebuiltAtMs: 1)
        let log = BrainEventLog(directory: directory)
        log.setValue(BrainEventLog.keyLearner, LearnerCodec.encode(saved))
        log.setValue(BrainEventLog.keyPosteriors, PosteriorCodec.encode(Posteriors.newState(today: 20_000)))
        log.setValue(BrainEventLog.keyLearnVersion, String(LearnReplay.version))
    }

    static func event(_ i: Int, seq: Int64, surface: Int32 = Surface.playlist, arm: Int32 = Arm.none) -> PlayEvent {
        let atMs = 1_750_000_000_000 + Int64(i) * 400_000
        let finished = i % 2 == 0
        return PlayEvent(
            eventId: (atMs << 16) | (seq & 0xFFFF), origin: Origin.live, rid: finished ? 1 : 2, primaryAid: finished ? 10 : 11,
            startedAtMs: atMs, tzOffsetMin: 0, playedMs: finished ? 200_000 : 4_000, durationMs: 200_000,
            startReason: StartReason.tap, endReason: finished ? EndReason.trackDone : EndReason.next,
            surface: surface, arm: arm, sessionId: Int64(i / 12 + 1))
    }

    static func prefill(_ directory: URL, _ n: Int) {
        BrainEventLog(directory: directory).insert((0..<n).map { event($0, seq: Int64($0)) })
    }
}

private func control(_ wanted: Bool) -> Int64 {
    var id: Int64 = 1
    while Ranker.isControlSession(id) != wanted { id += 1 }
    return id
}

@Suite("Brain stage 3 completion in the engine")
struct BrainStage3bEngineTests {
    // MARK: The choice made when the list is built

    @Test func theChoiceSaysWhatRankedTheListAndTheArmBanditFollowsTheGate() {
        var loaded = BrainEngine.Loaded(affinity: Affinity.State())
        loaded.learner.gate = Gate.State(useLearned: true, winStreak: 2, atMs: 1)
        loaded.learner.learnVersion = LearnReplay.version
        let controlChoice = loaded.rankingChoice(sessionId: control(true))
        #expect(controlChoice.source == nil)
        #expect(controlChoice.control)
        #expect(controlChoice.modelVersion == 0)
        let learned = loaded.rankingChoice(sessionId: control(false))
        #expect(learned.source != nil)
        #expect(!learned.control)
        #expect(learned.modelVersion == BrainEngine.modelLearned)
        #expect(loaded.armPicker(sessionId: control(false), family: ArmBandit.mix, seed: 5) != nil)
        // A control session is ranked by the prior, with no bandit: stage 2's choice, exactly.
        #expect(loaded.armPicker(sessionId: control(true), family: ArmBandit.mix, seed: 5) == nil)
        loaded.learner.gate = Gate.State()
        let prior = loaded.rankingChoice(sessionId: control(false))
        #expect(prior.source == nil)
        #expect(!prior.control)
        #expect(prior.modelVersion == 0)
        #expect(loaded.armPicker(sessionId: control(false), family: ArmBandit.mix, seed: 5) == nil)
    }

    @Test func aNewSessionStartsAtTheLearnedAppetiteOnlyWhileTheLearnedWeightsAreOn() {
        var loaded = BrainEngine.Loaded(affinity: Affinity.State())
        loaded.newSession(nowMs: 20_000 * BrainMath.dayMs)
        #expect(loaded.session.nuSession == Session.nuDefault)
        loaded.learner.gate = Gate.State(useLearned: true, winStreak: 2, atMs: 1)
        loaded.learner.learnVersion = LearnReplay.version
        loaded.learner.posteriors.appetite.nuLong = 0.4
        loaded.newSession(nowMs: 20_000 * BrainMath.dayMs)
        #expect(abs(loaded.session.nuSession - 0.4) < 1e-9)
    }

    @Test func theTagCarriesTheChoiceThroughTheSavedQueue() throws {
        let tag = BrainItemTag(surface: "station", surfaceId: "x", recId: 5, slot: 1, arm: "FAV", control: true, modelVersion: 0)
        let item = PlaybackQueueItemSnapshot(mediaId: "m", uri: "spotify://0123456789abcdef012345", title: "t", artist: "a").withBrainTag(tag)
        let data = try JSONEncoder().encode(item)
        let restored = try #require(try JSONDecoder().decode(PlaybackQueueItemSnapshot.self, from: data).brainTag())
        #expect(restored.control)
        #expect(restored.modelVersion == 0)
        let learned = try #require(item.withBrainTag(BrainItemTag(surface: "station", arm: "FAV", modelVersion: 1, explore: true)).brainTag())
        #expect(!learned.control)
        #expect(learned.modelVersion == 1)
        #expect(learned.explore)
        // A tag with nothing but the decision is not empty: it must not be dropped on the way.
        #expect(!BrainItemTag(modelVersion: 0).isEmpty)
        #expect(BrainItemTag().isEmpty)
        // A queue saved by an older build has none of the three fields.
        let old = #"{"mediaId":"m","uri":"spotify://0123456789abcdef012345","brainSurface":"autoplay","brainArm":"RADIO"}"#
        let oldTag = try #require(try JSONDecoder().decode(PlaybackQueueItemSnapshot.self, from: Data(old.utf8)).brainTag())
        #expect(!oldTag.control)
        #expect(oldTag.modelVersion == -1)
        #expect(!oldTag.explore)
    }

    @Test func aStoredMixAHomeRowAndAPlanShelfKeepTheChoiceTheyWereBuiltWith() throws {
        var mix = StoredMix(kind: 0, builtAtMs: 1, seed: 2, items: [StoredMixItem(rid: 5, songId: "a", explore: true)], control: true, model: 0)
        let back = try JSONDecoder().decode(StoredMix.self, from: JSONEncoder().encode(mix))
        #expect(back.control)
        #expect(back.items.first?.explore == true)
        mix.control = false
        mix.model = 1
        #expect(try JSONDecoder().decode(StoredMix.self, from: JSONEncoder().encode(mix)).model == 1)
        // A mix saved before this build has neither field: the prior, no control.
        let old = #"{"v":1,"kind":0,"builtAtMs":1,"seed":2,"items":[{"rid":5,"songId":"a","arm":0,"slot":0}]}"#
        let oldMix = try JSONDecoder().decode(StoredMix.self, from: Data(old.utf8))
        #expect(!oldMix.control)
        #expect(oldMix.model == 0)
        #expect(oldMix.items.first?.explore == false)
        // The same for a plan shelf and its items.
        let shelf = PlanShelf(type: HomePlanner.daypartMix, id: "daypart:3", titleKey: "your_daypart", items: [PlanItem(rid: 1, explore: true)],
                              control: true, model: 0)
        let shelfBack = try JSONDecoder().decode(PlanShelf.self, from: JSONEncoder().encode(shelf))
        #expect(shelfBack.control)
        #expect(shelfBack.items.first?.explore == true)
        let oldShelf = #"{"type":1,"id":"a","titleKey":"k","titleArg":"","subtitleKey":"","items":[{"rid":1,"aid":2,"arm":3,"whyKey":0,"whyName":"","slot":0}],"mixes":[],"stations":[],"recId":0}"#
        let oldDecoded = try JSONDecoder().decode(PlanShelf.self, from: Data(oldShelf.utf8))
        #expect(!oldDecoded.control)
        #expect(oldDecoded.model == 0)
        #expect(oldDecoded.items.first?.explore == false)
    }

    @Test func aDaypartMixHasItsOwnIdAndTheStage2IdsAreUnchanged() {
        let spec = MixSpec(kind: MixKinds.daypart, islandId: 3, part: 6)
        #expect(spec.surfaceId == "daypart:6:3")
        #expect(MixSpec.of(surfaceId: "daypart:6:3") == spec)
        #expect(MixSpec.of(surfaceId: "daypart:x:3") == nil)
        #expect(MixSpec.of(surfaceId: "daypart:6") == nil)
        #expect(MixKinds.usesPlanner(MixKinds.daypart))
        #expect(MixSpec(kind: MixKinds.daily, islandId: 2).surfaceId == "daily:2")
        #expect(MixSpec.of(surfaceId: "your") == MixSpec(kind: MixKinds.your))
        #expect(BrainMixes.nuOf(spec, multiplier: 2.0) == BrainMixes.daypartNu)
    }

    // MARK: Posteriors in the engine

    @Test func theFirstReplayBuildsThePosteriorsAndAPlayMovesAndSavesThem() async throws {
        let h = Harness3b(withSources: true)
        defer { h.cleanUp() }
        // Surface and arm of an engine pick: the arm bandit and the appetite learn from these plays only.
        BrainEventLog(directory: h.directory).insert((0..<600).map { Harness3b.event($0, seq: Int64($0), surface: Surface.autoplay, arm: Arm.radio) })
        _ = await h.engine.heardTrackCount()
        await h.engine.awaitRebuild()
        let text = try #require(await h.engine.storedValue(BrainEventLog.keyPosteriors))
        let posteriors = try #require(PosteriorCodec.decode(text))
        #expect(posteriors.arms.updates > 300)
        #expect(posteriors.appetite.updates > 300)
        // A live play after it moves them, and a second process reads the same state.
        let tag = BrainItemTag(surface: "autoplay", surfaceId: "s", recId: 1, slot: 0, arm: "RADIO", modelVersion: 0)
        let context = PlayContext(title: "Dreams", artistDisplay: "Fleetwood Mac", artists: ["Fleetwood Mac"], spotifyId: nil, videoId: nil,
                                  inLibrary: true, startReason: StartReason.autoplay, tag: tag)
        let play = FinishedPlay(songId: "s1", context: context, startedAtMs: Harness3b.t0, playedMs: 200_000, durationMs: 200_000,
                                endReason: EndReason.trackDone)
        _ = try #require(await h.engine.record(play))
        let afterText = try #require(await h.engine.storedValue(BrainEventLog.keyPosteriors))
        let after = try #require(PosteriorCodec.decode(afterText))
        #expect(after.arms.updates == posteriors.arms.updates + 1)
        let restarted = Harness3b(directory: h.directory)
        _ = await restarted.engine.heardTrackCount()
        let againText = try #require(await restarted.engine.storedValue(BrainEventLog.keyPosteriors))
        let again = try #require(PosteriorCodec.decode(againText))
        #expect(PosteriorCodec.encode(again) == PosteriorCodec.encode(after))
    }

    @Test func aLearnerSavedBeforeThePosteriorsExistedIsReplayedAgain() async throws {
        let h = Harness3b()
        defer { h.cleanUp() }
        Harness3b.prefill(h.directory, 300)
        h.learnerOn()
        let log = BrainEventLog(directory: h.directory)
        log.setValue(BrainEventLog.keyPosteriors, nil)
        _ = await h.engine.heardTrackCount()
        // The replay is due again (it makes both from the log), and until then they start from their priors.
        #expect(await h.engine.storedValue(BrainEventLog.keyLearnVersion) == nil)
    }

    @Test func resetPutsThePosteriorsBackToTheirPriorsWithTheResetWatermark() async throws {
        let h = Harness3b()
        defer { h.cleanUp() }
        Harness3b.prefill(h.directory, 300)
        h.learnerOn()
        _ = await h.engine.heardTrackCount()
        h.clock.advance(1_000)
        await h.engine.resetLearned()
        let resetText = try #require(await h.engine.storedValue(BrainEventLog.keyPosteriors))
        let posteriors = try #require(PosteriorCodec.decode(resetText))
        #expect(posteriors.arms.updates == 0)
        #expect(posteriors.appetite.updates == 0)
        let after = try #require(await h.engine.storedValue(BrainEventLog.keyLearnAfter).flatMap { Int64($0) })
        #expect(posteriors.lastEventId == after)
        #expect(!(await h.engine.usesLearned()))
    }

    @Test func aMixPlannedOnTheEngineSaysHowItWasRanked() async throws {
        let h = Harness3b()
        defer { h.cleanUp() }
        h.learnerOn()
        let candidates = (1...30).map { Candidate(rid: Int64($0), aid: Int64($0 % 7 + 1), albumKey: Int64($0), inLibrary: true) }
        let request = MixPlanner.Request(kind: MixPlanner.kindDaily, candidates: candidates, seeds: [], nowMs: Harness3b.t0, tzOffsetMin: 0)
        let plan = await h.engine.planMix(request)
        #expect(!plan.picks.isEmpty)
        // The session of a fresh engine is 0: whichever it is, the plan says what ranked it and a control is never "learned".
        if Ranker.isControlSession(0) {
            #expect(plan.control)
            #expect(plan.modelVersion == 0)
        } else {
            #expect(!plan.control)
            #expect(plan.modelVersion == BrainEngine.modelLearned)
        }
        #expect(plan.picks.allSatisfy { !$0.explore || $0.novel })
    }

    // MARK: The shelf bandit's store

    @Test func theImpressionsOfAVisitAreWrittenAndReadBackByAnotherProcess() async throws {
        let h = Harness3b()
        defer { h.cleanUp() }
        let store = h.shelves()
        let ids = ["0:made_for_you", "1:because_x", "2:on_repeat"]
        let types: [Int32] = [HomePlanner.madeForYou, HomePlanner.becauseListened, HomePlanner.onRepeat]
        await store.onPlanShown(ids: ids, types: types, daypart: 1)
        #expect(await store.impressionCount() == 3)
        // The same page shown again within half an hour is the same visit.
        h.clock.advance(60_000)
        await store.onPlanShown(ids: ids, types: types, daypart: 1)
        #expect(await store.impressionCount() == 3)
        await store.onShelfSeen(ids[1])
        await store.onShelfActivated(ids[2])
        let restarted = h.shelves()
        #expect(await restarted.impressionCount() == 3)
        // A page that is not this one starts a visit of its own.
        h.clock.advance(60_000)
        await restarted.onPlanShown(ids: ["0:made_for_you"], types: [HomePlanner.madeForYou], daypart: 1)
        #expect(await restarted.impressionCount() == 4)
    }

    @Test func aFinishedVisitIsGivenToTheBanditWithTheRewardTheLogShows() async throws {
        let h = Harness3b()
        defer { h.cleanUp() }
        let store = h.shelves()
        let ids = ["0:a", "1:b", "2:c"]
        let types: [Int32] = [HomePlanner.madeForYou, HomePlanner.becauseListened, HomePlanner.onRepeat]
        await store.onPlanShown(ids: ids, types: types, daypart: 2)
        await store.onShelfSeen(ids[2])
        h.clock.advance(5_000)
        await store.onShelfActivated(ids[1])
        let activatedAt = h.clock.now
        // The play the tap started, heard for a minute, is in the log.
        let play = PlayEvent(eventId: ((activatedAt + 2_000) << 16) | 1, origin: Origin.live, rid: 1, primaryAid: 1,
                             startedAtMs: activatedAt + 2_000, tzOffsetMin: 0, playedMs: 60_000, durationMs: 200_000,
                             startReason: StartReason.tap, endReason: EndReason.next, surface: Surface.homeShelf)
        BrainEventLog(directory: h.directory).insert([play])
        // Still on screen: nothing is settled yet.
        await store.settle()
        #expect((await store.snapshot()).updates == 0)
        h.clock.advance(ShelfStore.sameVisitMs + 1_000)
        await store.settle()
        let state = await store.snapshot()
        // Seen down to the third shelf, the second used: three shelves updated, the second with reward 1.
        #expect(state.updates == 3)
        #expect(state.alpha[Int(HomePlanner.becauseListened) * 4 + 2] == ShelfBandit.priorAlpha(HomePlanner.becauseListened) + 1.0)
        #expect(state.beta[Int(HomePlanner.madeForYou) * 4 + 2] == ShelfBandit.priorBeta(HomePlanner.madeForYou) + 1.0)
        // The state is saved: another process reads it, and settling again changes nothing.
        let restarted = h.shelves()
        #expect((await restarted.snapshot()).updates == 3)
        await restarted.settle()
        #expect((await restarted.snapshot()).updates == 3)
        // Reset forgets the visits and the posteriors.
        await restarted.reset()
        #expect((await restarted.snapshot()).updates == 0)
        #expect(await restarted.impressionCount() == 0)
        #expect((await h.shelves().snapshot()).updates == 0)
    }

    @Test func aVisitIsOverOnlyAfterHalfAnHourWithoutASignalSoAPlayThatIsStillRunningIsNotGradedAsNoReward() async throws {
        let h = Harness3b()
        defer { h.cleanUp() }
        let store = h.shelves()
        let ids = ["0:a", "1:b"]
        let types: [Int32] = [HomePlanner.madeForYou, HomePlanner.becauseListened]
        await store.onPlanShown(ids: ids, types: types, daypart: 2)
        // The page stays open for an hour, then the listener taps a shelf: the song is playing and not yet in the log.
        h.clock.advance(60 * 60_000)
        await store.onShelfActivated(ids[1])
        let tapped = h.clock.now
        // Two minutes later another page is shown and the refresh settles: the visit has a tap from two minutes ago, so it is not over.
        h.clock.advance(2 * 60_000)
        await store.onPlanShown(ids: ["0:other"], types: [HomePlanner.madeForYou], daypart: 2)
        await store.settle()
        #expect((await store.snapshot()).updates == 0, "a tap two minutes ago keeps its visit open")
        // The song ends and is written; half an hour after the tap the visit is given to the bandit with its reward.
        let play = PlayEvent(eventId: ((tapped + 1_000) << 16) | 1, origin: Origin.live, rid: 1, primaryAid: 1, startedAtMs: tapped + 1_000,
                             tzOffsetMin: 0, playedMs: 200_000, durationMs: 200_000, startReason: StartReason.tap,
                             endReason: EndReason.trackDone, surface: Surface.homeShelf)
        BrainEventLog(directory: h.directory).insert([play])
        h.clock.advance(ShelfStore.sameVisitMs)
        await store.settle()
        let state = await store.snapshot()
        #expect(state.alpha[Int(HomePlanner.becauseListened) * 4 + 2] == ShelfBandit.priorAlpha(HomePlanner.becauseListened) + 1.0)
    }

    @Test func aResetWhileVisitsAreWaitingLeavesNothingToComeBack() async throws {
        let h = Harness3b()
        defer { h.cleanUp() }
        let store = h.shelves()
        await store.onPlanShown(ids: ["0:a"], types: [HomePlanner.madeForYou], daypart: 0)
        await store.reset()
        h.clock.advance(ShelfStore.sameVisitMs + 1_000)
        await store.settle()
        #expect((await store.snapshot()).updates == 0)
        #expect(await store.impressionCount() == 0)
    }

    @Test func theRewardNeedsAPlayOfThirtySecondsOrToTheEndStartedWithinTenMinutes() {
        func play(_ start: Int64, played: Int32, end: Int32 = EndReason.next, reason: Int32 = StartReason.tap,
                  flags: Int32 = 0) -> PlayEvent {
            PlayEvent(eventId: start << 16, origin: Origin.live, rid: 1, primaryAid: 1, startedAtMs: start, tzOffsetMin: 0, playedMs: played,
                      durationMs: 200_000, startReason: reason, endReason: end, flags: flags)
        }
        // A private or silent play, and one the queue moved on to by itself, is not what the tap started; a play rewards one shelf.
        #expect(ShelfStore.reward(events: [play(1_200, played: 3_000, flags: EventFlags.learnExcluded), play(1_500, played: 40_000)],
                                  activatedAtMs: 1_000))
        #expect(!ShelfStore.reward(events: [play(1_200, played: 90_000, reason: StartReason.autoAdvance)], activatedAtMs: 1_000))
        var claimed = Set<Int64>()
        let rewarded = [play(1_500, played: 60_000)]
        #expect(ShelfStore.reward(events: rewarded, activatedAtMs: 1_000, claimed: &claimed))
        #expect(!ShelfStore.reward(events: rewarded, activatedAtMs: 1_000, claimed: &claimed), "the same play is not given to a second shelf")
        #expect(ShelfStore.reward(events: [play(1_500, played: 31_000)], activatedAtMs: 1_000))
        #expect(!ShelfStore.reward(events: [play(1_500, played: 29_000)], activatedAtMs: 1_000))
        #expect(ShelfStore.reward(events: [play(1_500, played: 10_000, end: EndReason.trackDone)], activatedAtMs: 1_000))
        // The first play after the tap is the one that counts, and one more than two minutes later is not the tap's.
        #expect(!ShelfStore.reward(events: [play(1_500, played: 5_000), play(2_000, played: 90_000)], activatedAtMs: 1_000))
        #expect(!ShelfStore.reward(events: [play(1_000 + ShelfStore.playWindowMs + 1, played: 90_000)], activatedAtMs: 1_000))
        #expect(!ShelfStore.reward(events: [], activatedAtMs: 1_000))
    }

    @Test func theOrderIsOnlyDrawnWhileTheLearnedWeightsAreOn() async throws {
        let off = Harness3b()
        defer { off.cleanUp() }
        let types: [Int32] = [HomePlanner.madeForYou, HomePlanner.becauseListened, HomePlanner.onRepeat]
        #expect(await off.shelves().order(types: types, planKey: 5, daypart: 1, salt: 7, nowMs: Harness3b.t0) == nil)
        let on = Harness3b()
        defer { on.cleanUp() }
        on.learnerOn()
        // On, but with no data yet: the stage 2 order stays.
        #expect(await on.shelves().order(types: types, planKey: 5, daypart: 1, salt: 7, nowMs: Harness3b.t0) == nil)
    }

    @Test func theImpressionFileReadsOnlyWhatItKnowsAndIsBounded() async throws {
        #expect(ImpressionFile.decode(Array("[1,5,0,2,1,100,0,0,0]".utf8)[...]) != nil)
        // Another version, too few numbers, or not numbers: not a record.
        #expect(ImpressionFile.decode(Array("[2,5,0,2,1,100,0,0,0]".utf8)[...]) == nil)
        #expect(ImpressionFile.decode(Array("[1,5,0]".utf8)[...]) == nil)
        #expect(ImpressionFile.decode(Array("{\"a\":1}".utf8)[...]) == nil)
        let h = Harness3b()
        defer { h.cleanUp() }
        let store = h.shelves()
        for _ in 0..<(ImpressionFile.keepVisits + 20) {
            h.clock.advance(ShelfStore.sameVisitMs + 1)
            await store.onPlanShown(ids: ["0:a", "1:b"], types: [HomePlanner.madeForYou, HomePlanner.onRepeat], daypart: 0)
        }
        #expect(await store.impressionCount() <= ImpressionFile.keepVisits * 2)
    }

    // MARK: The context table

    @Test func theContextTableCountsGradedPlaysOfIslandsByLocalTime() {
        // Island 1 owns weekday nights; every play is of rid 1 or 2, and rid 3 belongs to no island.
        var events: [PlayEvent] = []
        for k in 0..<80 {
            let at = (20_000 - Int64(k) * 7) * BrainMath.dayMs + 23 * 3_600_000
            events.append(PlayEvent(eventId: at << 16, origin: Origin.live, rid: 1, primaryAid: 1, startedAtMs: at, tzOffsetMin: 0,
                                    playedMs: 200_000, durationMs: 200_000, endReason: EndReason.trackDone))
        }
        let outside = 19_000 * BrainMath.dayMs
        events.append(PlayEvent(eventId: outside << 16, origin: Origin.live, rid: 3, primaryAid: 3, startedAtMs: outside, tzOffsetMin: 0,
                                playedMs: 200_000, durationMs: 200_000, endReason: EndReason.trackDone))
        // An imported play has no timezone: the device's offset is used.
        let imported = PlayEvent(eventId: (outside + 1) << 16, origin: Origin.importSpotify, rid: 2, primaryAid: 2, startedAtMs: outside,
                                 playedMs: 200_000, durationMs: 200_000, endReason: EndReason.trackDone)
        events.append(imported)
        let now = 20_000 * BrainMath.dayMs + 23 * 3_600_000
        let table = ContextStore.build(events, memberOf: [1: 1, 2: 2], deviceTzOffsetMin: 0, nowMs: now)
        let night = ContextLift.bucket(now, tzOffsetMin: 0)
        #expect(table.plays.reduce(0, +) == 81)
        #expect(table.plays[night] >= 80)
        #expect(table.hasLift(night))
        #expect(table.lift(1, night) >= 0.0)
        #expect(table.lift(9, night) == 0.0)
    }

    // MARK: A genre adjustment and the brain's backup state

    @Test func aGenreAdjustmentIsAPseudoCountOnItsTagAndANameTheAtlasLacksIsAbsent() {
        let more = TasteAdjustment(kind: .boost, strength: 2, targetType: .genre, key: "shoegaze", label: "Shoegaze", reason: "",
                                   source: .user, createdMs: 1)
        let facts = LibraryFactsBuilder.build(library: [], ridBySongId: [:], taste: ExternalTasteSnapshot(), adjustments: [more],
                                              aidByName: [:], topTrackRids: [], genreIdByName: [BrainKey("Shoegaze"): 77])
        #expect(facts.adjustments.count == 1)
        #expect(facts.adjustments.first?.family == Family.tag)
        #expect(facts.adjustments.first?.key == 77)
        #expect(facts.adjustments.first?.more == true)
        let unknown = LibraryFactsBuilder.build(library: [], ridBySongId: [:], taste: ExternalTasteSnapshot(), adjustments: [more],
                                                aidByName: [:], topTrackRids: [])
        #expect(unknown.adjustments.isEmpty)
        let change = BrainFeedback.genreChange(name: "Shoegaze", more: false)
        #expect(change?.action == .reduce)
        #expect(change?.targetType == .genre)
        #expect(BrainFeedback.genreChange(name: "  ", more: true) == nil)
    }

    @Test func theBackupStateHoldsTheSaltAndTheExclusionsAndRestoreBringsThemBack() async throws {
        let h = Harness3b()
        defer { h.cleanUp() }
        let salt = await h.engine.salt()
        let store = FeedbackStore(directory: h.directory)
        store.insert(FeedbackStore.Record(id: 16, kind: FeedbackKinds.dontCount, targetKind: FeedbackKinds.targetSong, targetId: 9, createdAtMs: 5))
        let state = await h.engine.backupState()
        #expect(state.salt == salt)
        // A second install: a different salt, a different exclusion.
        let other = Harness3b()
        defer { other.cleanUp() }
        _ = await other.engine.salt()
        FeedbackStore(directory: other.directory).insert(FeedbackStore.Record(id: 24, kind: 2, targetKind: 1, targetId: 3, createdAtMs: 7))
        await other.engine.restoreBackupState(salt: state.salt, feedback: state.feedback)
        let restored = await other.engine.backupState()
        #expect(restored.salt == salt)
        // Merged in, not swapped: the exclusion made on this install since the backup keeps its record (its plays are flagged in the log).
        #expect(restored.feedback.map(\.id).sorted() == [16, 24])
        #expect(await other.engine.salt() == salt)
    }

    // MARK: Your sound: Lately

    @Test func theLogPassForLatelyKeepsTheTablesAsTheyAreNowAndAsTheyWereTwoWeeksAgo() {
        let now: Int64 = 1_760_000_000_000
        let cutoff = now - Int64(YourSound.latelyDays) * BrainMath.dayMs
        var events: [PlayEvent] = []
        for k in 0..<40 {
            let before = cutoff - Int64(40 - k) * 3_600_000
            events.append(PlayEvent(eventId: before << 16, origin: Origin.live, rid: 1, primaryAid: 5, startedAtMs: before, tzOffsetMin: 0,
                                    playedMs: 200_000, durationMs: 200_000, endReason: EndReason.trackDone))
        }
        for k in 0..<40 {
            let later = cutoff + Int64(k + 1) * 3_600_000
            events.append(PlayEvent(eventId: later << 16, origin: Origin.live, rid: 2, primaryAid: 5, startedAtMs: later, tzOffsetMin: 0,
                                    playedMs: 3_000, durationMs: 200_000, endReason: EndReason.next))
        }
        let pass = YourSoundReader.pass(events, lately: now)
        // The earlier tables stop at the cutoff, the later ones go on to now.
        #expect(Affinity.weight(pass.earlierTables, family: Family.artist, key: 5, nowMs: cutoff) >= YourSound.latelyMinWeight)
        let moves = YourSound.lately(before: pass.earlierTables, after: pass.nowTables, beforeMs: cutoff, nowMs: now)
        #expect(moves.contains { $0.family == Family.artist && $0.key == 5 && $0.delta < 0.0 })
        #expect(pass.tagRids.count == 80)
        // Without `lately` nothing of this is kept.
        #expect(YourSoundReader.pass(events).tagRids.isEmpty)
    }
}
