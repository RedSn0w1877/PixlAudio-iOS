import Foundation
import PixlModel
import Testing
@testable import PixlLibrary

/// The learner inside the engine (docs/brain-spec.md, 5.9, 5.12 points 2 and 8): trained by the rebuild, updated by each
/// live play and saved with it, put back to the prior by "Reset what I've learned" without a rebuild bringing it back, and
/// used for ranking only while the gate says so. The iOS twin of Android's `LearnerEngineTest`, against real record files
/// in a temporary folder. The learner has only ever run on synthetic listeners.
private final class LearnerClock: @unchecked Sendable {
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

private struct LearnerHarness {
    static let t0: Int64 = 1_760_000_000_000

    let directory: URL
    let clock: LearnerClock
    let engine: BrainEngine

    /// `rebuildDelayMs` keeps the first-use rebuild from starting by itself, so a test sees the state before it.
    init(directory: URL? = nil, withSources: Bool = true, rebuildDelayMs: Int64 = 0) {
        let dir = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-learner-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
        let clock = LearnerClock(Self.t0)
        self.clock = clock
        let repository = BrainRepository(directory: dir, radioSource: nil, clock: { clock.now })
        let sources: BrainEngine.Sources? = withSources
            ? BrainEngine.Sources(library: { [] }, history: { [] }, importSignature: { "x" },
                                  imported: { ([], ExternalTasteSnapshot()) }, adjustments: { [] })
            : nil
        engine = BrainEngine(directory: dir, repository: repository, sources: sources, rebuildDelayMs: rebuildDelayMs,
                             clock: { clock.now })
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    /// Rid 1 (artist 10) is finished, rid 2 (artist 11) skipped, in sessions of twelve.
    static func event(_ i: Int, seq: Int64) -> PlayEvent {
        let atMs = 1_750_000_000_000 + Int64(i) * 400_000
        let finished = i % 2 == 0
        return PlayEvent(
            eventId: (atMs << 16) | (seq & 0xFFFF), origin: Origin.live, rid: finished ? 1 : 2, primaryAid: finished ? 10 : 11,
            startedAtMs: atMs, tzOffsetMin: 0, playedMs: finished ? 200_000 : 4_000, durationMs: 200_000,
            startReason: StartReason.tap, endReason: finished ? EndReason.trackDone : EndReason.next,
            surface: Surface.playlist, sessionId: Int64(i / 12 + 1))
    }

    /// Writes `n` plays into the log before an engine reads it.
    static func prefill(_ directory: URL, _ n: Int) {
        let log = BrainEventLog(directory: directory)
        log.insert((0..<n).map { event($0, seq: Int64($0)) })
    }
}

private func livePlay(at startedAtMs: Int64, id: String = "s1", tag: BrainItemTag? = nil, start: Int32 = StartReason.tap) -> FinishedPlay {
    let context = PlayContext(title: "Dreams", artistDisplay: "Fleetwood Mac", artists: ["Fleetwood Mac"], spotifyId: nil,
                              videoId: nil, inLibrary: true, startReason: start, tag: tag)
    return FinishedPlay(songId: id, context: context, startedAtMs: startedAtMs, playedMs: 200_000, durationMs: 200_000,
                        endReason: EndReason.trackDone, flags: 0, tzOffsetMin: 0)
}

/// The learner as the engine last saved it.
private func savedLearner(_ engine: BrainEngine) async throws -> LearnerCodec.Saved {
    let text = try #require(await engine.storedValue(BrainEventLog.keyLearner))
    return try #require(LearnerCodec.decode(text))
}

@Suite("Brain learner in the engine (stage 3)")
struct BrainLearnerEngineTests {
    @Test func theFirstUseTrainsTheLearnerFromTheLogAndSavesIt() async throws {
        let h = LearnerHarness()
        defer { h.cleanUp() }
        LearnerHarness.prefill(h.directory, 600)
        _ = await h.engine.heardTrackCount()
        await h.engine.awaitRebuild()
        let figures = await h.engine.learnerFigures()
        #expect(figures.updates > 300)
        #expect(figures.summary != nil)
        // The gate has seen one evaluation: it needs two weeks running before the learned weights rank.
        #expect(!figures.useLearned)
        let saved = try await savedLearner(h.engine)
        #expect(saved.model.isValid())
        #expect(saved.learnVersion == LearnReplay.version)
        #expect(await h.engine.storedValue(BrainEventLog.keyLearnVersion) == String(LearnReplay.version))
    }

    @Test func aLivePlayUpdatesTheLearnerAndIsSavedWithItAndARestartLoadsTheSameWeights() async throws {
        let h = LearnerHarness()
        defer { h.cleanUp() }
        LearnerHarness.prefill(h.directory, 600)
        _ = await h.engine.heardTrackCount()
        await h.engine.awaitRebuild()
        let before = await h.engine.learnerFigures().updates
        let play = livePlay(at: LearnerHarness.t0)
        let reaction = try #require(await h.engine.record(play))
        #expect(await h.engine.learnerFigures().updates == before + 1)
        let saved = try await savedLearner(h.engine)
        #expect(saved.model.lastEventId == reaction.event.eventId)
        #expect(saved.model.updates == before + 1)
        // A second process reads the same weights from the files (a new engine, no rebuild).
        let restarted = LearnerHarness(directory: h.directory, withSources: false)
        #expect(await restarted.engine.learnerFigures().updates == before + 1)
        let again = try await savedLearner(restarted.engine)
        #expect(again.model.m.map(\.bitPattern) == saved.model.m.map(\.bitPattern))
        #expect(again.model.q.map(\.bitPattern) == saved.model.q.map(\.bitPattern))
        // The same play handed over again changes nothing.
        #expect(await h.engine.record(play) == nil)
        #expect(await h.engine.learnerFigures().updates == before + 1)
    }

    @Test func resetPutsTheWeightsBackToThePriorAndTheRebuildThatFollowsDoesNotBringThemBack() async throws {
        let h = LearnerHarness()
        defer { h.cleanUp() }
        LearnerHarness.prefill(h.directory, 600)
        _ = await h.engine.heardTrackCount()
        await h.engine.awaitRebuild()
        #expect(await h.engine.learnerFigures().updates > 0)
        h.clock.advance(1_000)
        await h.engine.resetLearned()
        let right = await h.engine.learnerFigures()
        #expect(right.updates == 0)
        #expect(!right.useLearned)
        #expect(right.summary == nil)
        await h.engine.awaitRebuild()
        // The rebuild replayed the whole log for the tables but learned from nothing before the reset.
        #expect(await h.engine.learnerFigures().updates == 0)
        #expect(await h.engine.storedValue(BrainEventLog.keyLearnAfter) != nil)
        let saved = try await savedLearner(h.engine)
        #expect(saved.model.isPrior())
        // A play after the reset is learned from.
        h.clock.advance(1_000_000)
        #expect(await h.engine.record(livePlay(at: h.clock.now)) != nil)
        #expect(await h.engine.learnerFigures().updates == 1)
        // And a restart keeps the reset: the next rebuild learns only from plays after the mark.
        let restarted = LearnerHarness(directory: h.directory)
        restarted.clock.advance(2_000_000)
        #expect(await restarted.engine.learnerFigures().updates == 1)
        await restarted.engine.requestRebuild(force: true)
        await restarted.engine.awaitRebuild()
        #expect(await restarted.engine.learnerFigures().updates == 1)
    }

    @Test func aSavedLearnerThatCannotBeReadIsReplacedByAPriorOneAndAReplayIsDue() async throws {
        let h = LearnerHarness(rebuildDelayMs: 600_000)
        defer { h.cleanUp() }
        LearnerHarness.prefill(h.directory, 300)
        let log = BrainEventLog(directory: h.directory)
        log.setValue(BrainEventLog.keyLearner, "{\"format\":\"brain-learner-v1\"}")
        log.setValue(BrainEventLog.keyLearnVersion, String(LearnReplay.version))
        _ = await h.engine.heardTrackCount()
        let first = await h.engine.learnerFigures()
        #expect(first.updates == 0)
        #expect(first.summary == nil)
        #expect(await h.engine.storedValue(BrainEventLog.keyLearnVersion) == nil)
        await h.engine.requestRebuild(force: true)
        await h.engine.awaitRebuild()
        #expect(await h.engine.storedValue(BrainEventLog.keyLearnVersion) == String(LearnReplay.version))
        #expect(await h.engine.learnerFigures().summary != nil)
    }

    @Test func theLearnedWeightsRankOnlyWhileTheGateHasThemOnAndNeverInAControlSession() {
        var loaded = BrainEngine.Loaded(affinity: Affinity.State())
        var control: Int64 = 0
        while !Ranker.isControlSession(control) { control += 1 }
        var normal: Int64 = 0
        while Ranker.isControlSession(normal) { normal += 1 }
        // Not trained yet: the prior, whatever the gate says.
        loaded.learner.gate = Gate.State(useLearned: true, winStreak: 2, atMs: 1)
        #expect(loaded.ranking(sessionId: normal) == nil)
        loaded.learner.learnVersion = LearnReplay.version
        #expect(loaded.ranking(sessionId: control) == nil)
        let source = loaded.ranking(sessionId: normal)
        #expect(source?.usesLearned == true)
        #expect(loaded.ranking(sessionId: normal, seed: 5)?.seed == 5)
        // The gate off: the prior.
        loaded.learner.gate = Gate.State()
        #expect(loaded.ranking(sessionId: normal) == nil)
        // A model that went bad does not rank.
        loaded.learner.gate = Gate.State(useLearned: true, winStreak: 2, atMs: 1)
        loaded.learner.model.m[3] = Double.nan
        #expect(!loaded.learner.useLearned)
        #expect(loaded.ranking(sessionId: normal) == nil)
    }

    @Test func anEnginePickInAControlSessionIsFlaggedAndOneRankedWithTheLearnedWeightsSaysSo() async throws {
        let h = LearnerHarness(withSources: false)
        defer { h.cleanUp() }
        // A saved learner whose gate is on, in the files before the engine reads them.
        var model = Ranker.newModel(today: 20_000)
        model.lastEventId = 0
        let saved = LearnerCodec.Saved(model: model, gate: Gate.State(useLearned: true, winStreak: 2, atMs: 1),
                                       learnVersion: LearnReplay.version, summary: nil, rebuiltAtMs: 1)
        BrainEventLog(directory: h.directory).setValue(BrainEventLog.keyLearner, LearnerCodec.encode(saved))
        // Which weights ranked a list and whether it was a control is decided when the list is built and carried with each entry
        // (5.12 point 8): the recorder reads it, it does not work it out at the end of the play.
        let controlTag = BrainItemTag(surface: "autoplay", surfaceId: "yt:seed", recId: 7_700, slot: 3, arm: "RADIO", radioRank: 4,
                                      retrQ: 812, primaryArtist: "Fleetwood Mac", control: true, modelVersion: 0)
        let learnedTag = BrainItemTag(surface: "autoplay", surfaceId: "yt:seed", recId: 7_701, slot: 3, arm: "RADIO", radioRank: 4,
                                      retrQ: 812, primaryArtist: "Fleetwood Mac", control: false, modelVersion: 1, explore: true)
        let control = try #require(await h.engine.record(livePlay(at: LearnerHarness.t0, id: "c", tag: controlTag, start: StartReason.autoplay)))
        #expect(control.event.has(EventFlags.controlSession))
        #expect(control.event.modelVersion == 0)
        #expect(!control.event.has(EventFlags.exploreSlot))
        let learned = try #require(await h.engine.record(livePlay(at: LearnerHarness.t0 + 10 * 3_600_000, id: "n", tag: learnedTag,
                                                                 start: StartReason.autoplay)))
        #expect(!learned.event.has(EventFlags.controlSession))
        #expect(learned.event.modelVersion == BrainEngine.modelLearned)
        #expect(learned.event.has(EventFlags.exploreSlot))
        // A queue entry from before this build carries nothing about it: the prior, and not a control.
        let oldTag = BrainItemTag(surface: "autoplay", surfaceId: "yt:seed", recId: 7_702, slot: 3, arm: "RADIO")
        let old = try #require(await h.engine.record(livePlay(at: LearnerHarness.t0 + 20 * 3_600_000, id: "o", tag: oldTag,
                                                              start: StartReason.autoplay)))
        #expect(!old.event.has(EventFlags.controlSession))
        #expect(old.event.modelVersion == 0)
        // A pick the listener chose is neither flagged nor counted as served by the model.
        let chosen = try #require(await h.engine.record(livePlay(at: LearnerHarness.t0 + 30 * 3_600_000, id: "m")))
        #expect(!chosen.event.has(EventFlags.controlSession))
        #expect(chosen.event.modelVersion == 0)
    }
}
