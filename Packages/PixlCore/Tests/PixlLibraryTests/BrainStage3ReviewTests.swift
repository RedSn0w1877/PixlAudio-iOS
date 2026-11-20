import Foundation
import PixlModel
import Testing
@testable import PixlLibrary

/// The two reviews of stage 3 (docs/handoff/2026-11-20-music-brain-stage3.md, "Review pass"): the control draw, the gate's margin,
/// what the screens may say about the model, imported history in Your sound, the lists a reset must reach, the Home shelf's tag.
/// Synthetic data only: nothing here says anything about real listeners.
@Suite("Brain stage 3 review fixes")
struct BrainStage3ReviewTests {
    private static let t0: Int64 = 1_760_000_000_000

    private func sessionKey(_ wanted: Bool, from start: Int64 = 1) -> Int64 {
        var id = start
        while Ranker.isControlSession(id) != wanted { id += 1 }
        return id
    }

    private func gateOn() -> BrainEngine.Loaded {
        var loaded = BrainEngine.Loaded(affinity: Affinity.State())
        loaded.learner.gate = Gate.State(useLearned: true, winStreak: 2, atMs: 1)
        loaded.learner.learnVersion = LearnReplay.version
        return loaded
    }

    // MARK: The control draw

    @Test func aListBuiltBeforeAnySessionIsDrawnOnOneKeyPerGapAndItsFlagDoesNotChangeInsideTheGap() {
        var loaded = gateOn()
        let control = sessionKey(true)
        let notControl = sessionKey(false)
        // Session id 0 (right after launch): the draw is on the time the gap was first seen, so a control is possible at all.
        #expect(loaded.rankingChoice(sessionId: 0, nowMs: control).control)
        // Later in the same gap the key does not move: every list of the gap says the same thing.
        #expect(loaded.rankingChoice(sessionId: 0, nowMs: notControl).control)
        #expect(loaded.armPicker(sessionId: 0, family: ArmBandit.mix, seed: 1, nowMs: notControl) == nil)
        // A new session starts a new gap, drawn afresh.
        loaded.newSession(nowMs: notControl)
        #expect(!loaded.rankingChoice(sessionId: 0, nowMs: notControl).control)
        #expect(!loaded.rankingChoice(sessionId: 0, nowMs: control).control)
    }

    @Test func aLiveSessionKeepsItsOwnIdForTheDraw() {
        var loaded = gateOn()
        var session = SessionState()
        _ = Session.begin(&session, startedAtMs: Self.t0, startReason: StartReason.tap)
        loaded.session = session
        let id = session.sessionId
        let now = Self.t0 + 60_000
        #expect(loaded.rankingChoice(sessionId: id, nowMs: now).control == Ranker.isControlSession(id))
        // An expired session has no live id: the list is drawn on the gap's key, not on the old session's.
        let later = Self.t0 + Session.gapMs + 60_000
        let expired = loaded.rankingChoice(sessionId: id, nowMs: later)
        #expect(expired.control == Ranker.isControlSession(later))
    }

    @Test func thereIsNoControlWhileTheGateHasThePriorOn() {
        var loaded = BrainEngine.Loaded(affinity: Affinity.State())
        let control = sessionKey(true)
        let choice = loaded.rankingChoice(sessionId: control, nowMs: Self.t0)
        #expect(choice.source == nil)
        #expect(!choice.control, "everything is ranked with the prior: nothing to compare a control with")
        #expect(choice.modelVersion == 0)
    }

    @Test func aControlSessionStartsWithTheStandardShareOfNewMusic() {
        var loaded = gateOn()
        loaded.learner.posteriors.appetite.nuLong = 0.4
        let control = sessionKey(true)
        let notControl = sessionKey(false)
        // The first draw of the gap decides: a control gap gets stage 2's constant, the others the learned appetite.
        loaded.newSession(nowMs: control)
        #expect(loaded.session.nuSession == Session.nuDefault)
        loaded.newSession(nowMs: notControl)
        #expect(abs(loaded.session.nuSession - 0.4) < 1e-9)
    }

    // MARK: The gate

    private func summary(_ plays: Int, _ learned: Double, _ prior: Double) -> Gate.Summary {
        Gate.Summary(plays: min(plays, Gate.window), playsTotal: plays, logLossLearned: learned, logLossPrior: prior, accLearned: 0.6,
                     accPrior: 0.55, accLearnedBefore: nil, accPriorBefore: nil)
    }

    @Test func aWeekThatIsBetterByLessThanOnePercentIsNotAWinAndNeverSwitchesTheLearnedWeightsOn() {
        let week: Int64 = 7 * 86_400_000
        var state = Gate.State()
        // 0.4% better in log-loss: a coin-flip week on a few hundred plays.
        for k in 0..<6 { state = Gate.decide(state, summary(400, 0.5480, 0.5502), nowMs: 1_000 + Int64(k) * week) }
        #expect(!state.useLearned)
        #expect(state.winStreak == 0)
        // 2% better, two weeks running: on.
        state = Gate.decide(state, summary(400, 0.539, 0.5502), nowMs: 100 * week)
        #expect(state.winStreak == 1 && !state.useLearned)
        state = Gate.decide(state, summary(400, 0.539, 0.5502), nowMs: 101 * week)
        #expect(state.useLearned)
        // Once on, a week that is still better but by less than the margin changes nothing; one that is worse switches it off at once.
        let quiet = Gate.decide(state, summary(400, 0.5480, 0.5502), nowMs: 102 * week)
        #expect(quiet == state)
        #expect(!Gate.decide(state, summary(400, 0.56, 0.55), nowMs: 102 * week).useLearned)
    }

    @Test func aWeekBetweenTwoWinsThatIsNotClearlyBetterEndsTheStreak() {
        let week: Int64 = 7 * 86_400_000
        var state = Gate.decide(Gate.State(), summary(400, 0.539, 0.5502), nowMs: week)
        #expect(state.winStreak == 1)
        state = Gate.decide(state, summary(400, 0.5495, 0.5502), nowMs: 2 * week)
        #expect(state.winStreak == 0 && !state.useLearned)
    }

    @Test func fromTwoThousandPlaysTheBootstrapIntervalMustBeAboveZeroToo() {
        let week: Int64 = 7 * 86_400_000
        var state = Gate.State()
        for k in 0..<4 {
            state = Gate.decide(state, summary(2_500, 0.50, 0.55), nowMs: Int64(k + 1) * week, intervalAboveZero: false)
        }
        #expect(!state.useLearned, "a 9% gain whose interval includes zero is not a win from 2,000 plays")
        for k in 0..<2 {
            state = Gate.decide(state, summary(2_500, 0.50, 0.55), nowMs: Int64(10 + k) * week, intervalAboveZero: true)
        }
        #expect(state.useLearned)
        // Below 2,000 plays the interval does not apply (test 6 does not apply either).
        let few = Gate.decide(Gate.State(), summary(500, 0.50, 0.55), nowMs: week, intervalAboveZero: false)
        #expect(few.winStreak == 1)
    }

    // MARK: What the screen may say

    @Test func theWeightsAtThePriorAreTheStandardRecipeWhateverTheGateStillHolds() {
        let s = summary(500, 0.50, 0.55)
        #expect(ModelVoice.of(s, useLearned: true, modelUpdates: 0).kind == ModelVoice.standardRecipe)
        #expect(ModelVoice.of(s, useLearned: true, modelUpdates: 1).kind == ModelVoice.learning)
        #expect(ModelVoice.of(s, useLearned: false, modelUpdates: 900).kind == ModelVoice.standardRecipe)
    }

    @Test func theAccuracyLinesAreShownOnlyWhenTheLearnedFigureIsNotBelowTheStandardRecipes() {
        func voice(learned: Double, prior: Double) -> ModelVoice.State {
            ModelVoice.of(Gate.Summary(plays: 500, playsTotal: 500, logLossLearned: 0.5, logLossPrior: 0.55, accLearned: learned, accPrior: prior,
                                       accLearnedBefore: nil, accPriorBefore: nil), useLearned: true, modelUpdates: 400)
        }
        #expect(voice(learned: 0.62, prior: 0.58).showsAccuracy)
        #expect(voice(learned: 0.58, prior: 0.58).showsAccuracy)
        #expect(!voice(learned: 0.57, prior: 0.61).showsAccuracy)
        let standard = ModelVoice.of(summary(500, 0.5, 0.55), useLearned: false, modelUpdates: 400)
        #expect(!standard.showsAccuracy)
    }

    // MARK: Home

    @Test func aCardPlayedFromAHomeShelfCarriesTheChoiceTheShelfWasBuiltWith() {
        let item = PlanItem(rid: 5, arm: Arm.radio, slot: 2, explore: true)
        let learned = PlanShelf(type: HomePlanner.becauseListened, id: "because_a", titleKey: "because_listened", items: [item], recId: 9,
                                control: false, model: 1)
        let tag = BrainItemTag.homeShelf(learned, item)
        #expect(tag.modelVersion == 1)
        #expect(!tag.control)
        #expect(tag.explore)
        #expect(tag.surfaceId == "because_a" && tag.recId == 9 && tag.slot == 2 && tag.chosen)
        let control = PlanShelf(type: HomePlanner.daypartMix, id: "daypart:3", titleKey: "your_daypart", items: [item], control: true, model: 0)
        let controlTag = BrainItemTag.homeShelf(control, PlanItem(rid: 6))
        #expect(controlTag.control)
        #expect(controlTag.modelVersion == 0)
        #expect(!controlTag.explore)
    }

    // MARK: Imported history, the favourites file, the live id

    @Test func yourSoundReadsTheImportedHistoryToo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brain-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Self.t0
        let repository = BrainRepository(directory: dir, radioSource: nil, clock: { clock })
        let imported = (0..<5).map { i in
            ImportedPlay(source: .spotifyExport, timestampMs: Self.t0 - Int64(i + 1) * 86_400_000, title: "Dreams", artist: "Fleetwood Mac",
                         spotifyTrackId: "4uLU6hMCjMI75M1A2tKUQC", msPlayed: 200_000, reasonEnd: "trackdone")
        }
        let sources = BrainEngine.Sources(library: { [] }, history: { [] }, importSignature: { "x" },
                                          imported: { (imported, ExternalTasteSnapshot()) }, adjustments: { [] })
        let engine = BrainEngine(directory: dir, repository: repository, sources: sources, rebuildDelayMs: 0, clock: { clock })
        let merged = await engine.mergedPlays()
        #expect(merged.count == 5)
        #expect(merged.allSatisfy { $0.origin == Origin.importSpotify })
        // They are one track: the first of them is the only first play, so "new to you" is not claimed for a song heard five times.
        let pass = YourSoundReader.pass(merged, deviceOffsetMin: { _ in 60 })
        #expect(pass.rids.count == 5)
        #expect(pass.tzs.allSatisfy { $0 == 60 })
        let plays = YourSound.withFirsts(rids: pass.rids, aids: pass.aids, startedAtMs: pass.starts, tzOffsetMin: pass.tzs)
        #expect(plays.filter(\.first).count == 1)
        // Switched off, Spotify's own history is left out as a rebuild leaves it out.
        let off = BrainEngine.Sources(library: { [] }, history: { [] }, importSignature: { "x" },
                                      imported: { (imported, ExternalTasteSnapshot()) }, adjustments: { [] },
                                      spotifyShapesPicks: { false })
        let offEngine = BrainEngine(directory: dir, repository: repository, sources: off, rebuildDelayMs: 0, clock: { clock })
        #expect(await offEngine.mergedPlays().isEmpty)
    }

    @Test func theFavouritesLiveInTheirOwnFileAndAnOlderStateValueStillReads() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brain-liked-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = BrainEventLog(directory: dir)
        // A value an earlier build wrote to brain_state is still read.
        log.setValue(BrainEventLog.keyLearnerLiked, "a,b")
        #expect(log.likedText() == "a,b")
        log.setLikedText(BrainEngine.encodeLiked([5, 9, 70]))
        #expect(log.value(BrainEventLog.keyLearnerLiked) == nil, "moved out of the file the learner is written to on every play")
        let again = BrainEventLog(directory: dir)
        #expect(BrainEngine.decodeLiked(again.likedText()) == [5, 9, 70])
    }

    @Test func aPlayStampedByAClockADayAheadDoesNotStopTheLearningOfTheNextOnes() {
        let now = Self.t0
        var model = Ranker.newModel(today: BrainMath.localDay(now, tzOffsetMin: 0))
        var posteriors = Posteriors.newState(today: BrainMath.localDay(now, tzOffsetMin: 0))
        let affinity = Affinity.State()
        let session = SessionState()
        func play(_ atMs: Int64, rid: Int64) -> PlayEvent {
            PlayEvent(eventId: atMs << 16, origin: Origin.live, rid: rid, primaryAid: 7, startedAtMs: atMs, tzOffsetMin: 0, playedMs: 200_000,
                      durationMs: 200_000, startReason: StartReason.autoplay, endReason: EndReason.trackDone, surface: Surface.autoplay,
                      arm: Arm.radio)
        }
        func graded(_ e: PlayEvent) -> Reward.Graded { Reward.grade(e, Reward.Context()) }
        let ahead = play(now + BrainMath.dayMs, rid: 10)
        #expect(LearnReplay.applyLive(&model, posteriors: &posteriors, ahead, graded(ahead), liked: false, affinity: affinity, session: session,
                                      nowMs: now + 2_000) == Ranker.updateApplied)
        let a = play(now + 1_000, rid: 11)
        let b = play(now + 2_000, rid: 12)
        #expect(LearnReplay.applyLive(&model, posteriors: &posteriors, a, graded(a), liked: false, affinity: affinity, session: session,
                                      nowMs: now + 3_000) == Ranker.updateApplied)
        #expect(LearnReplay.applyLive(&model, posteriors: &posteriors, b, graded(b), liked: false, affinity: affinity, session: session,
                                      nowMs: now + 4_000) == Ranker.updateApplied)
        #expect(model.updates == 3)
        #expect(posteriors.arms.updates == 3)
        #expect(model.lastEventId == ahead.eventId + 2)
    }

    // MARK: Section minimums

    @Test func aSectionNeedsMoreThanAPlayOrTwoToSaySomething() {
        let day = BrainMath.dayMs
        let now = Self.t0
        func play(_ rid: Int64, at: Int64) -> YourSound.Play { YourSound.Play(rid: rid, aid: 0, startedAtMs: at, tzOffsetMin: 0, first: false) }
        let few = (1...5).map { play(Int64($0), at: now - day) }
        #expect(YourSound.islands(few, islandOf: { _ in 7 }, nowMs: now, minPlays: YourSound.islandsMinPlays).isEmpty)
        let many = (1...40).map { play(Int64($0), at: now - day) }
        let covered = YourSound.islands(many, islandOf: { _ in 7 }, nowMs: now, minPlays: YourSound.islandsMinPlays,
                                        minCoveragePermille: YourSound.islandsMinCoveragePermille)
        #expect(covered.count == 1)
        #expect(YourSound.islands(many, islandOf: { $0 <= 22 ? -1 : 7 }, nowMs: now, minPlays: YourSound.islandsMinPlays,
                                  minCoveragePermille: YourSound.islandsMinCoveragePermille).isEmpty, "under half could be placed")
        let thousand = (1...1000).map { play(Int64($0), at: now - day) }
        #expect(YourSound.genres(thousand, minPlays: YourSound.genresMinPlays, minCoveragePermille: YourSound.genresMinCoveragePermille,
                                 topTagOf: { $0 <= 3 ? 12 : GenreAtlas.none }).isEmpty)
        #expect(YourSound.genres(thousand, minPlays: YourSound.genresMinPlays, minCoveragePermille: YourSound.genresMinCoveragePermille,
                                 topTagOf: { _ in 12 }).count == 1)
        #expect(YourSound.genreTree(thousand, top: 8, topTagOf: { $0 <= 3 ? 12 : GenreAtlas.none }, rootOf: { $0 },
                                    minPlays: YourSound.genresMinPlays, minCoveragePermille: YourSound.genresMinCoveragePermille).isEmpty)
        let morning = now - now % day + 8 * 3_600_000
        let one = [YourSound.Play(rid: 1, aid: 0, startedAtMs: morning, tzOffsetMin: 0, first: false)]
        #expect(YourSound.dayparts(one, minPlays: YourSound.daypartMinPlays, islandOf: { _ in 5 })[Int(HomePlanner.daypartMorning)].leadingIslandId == -1)
        let ten = (0..<10).map { YourSound.Play(rid: 1, aid: 0, startedAtMs: morning + Int64($0), tzOffsetMin: 0, first: false) }
        #expect(YourSound.dayparts(ten, minPlays: YourSound.daypartMinPlays, islandOf: { _ in 5 })[Int(HomePlanner.daypartMorning)].leadingIslandId == 5)
        let tenYears = (1...10).map { play(Int64($0), at: now) }
        #expect(YourSound.decades(tenYears, minPlays: YourSound.erasMinPlays, yearOf: { _ in 1994 }).isEmpty)
    }

    @Test func aSharePercentIsRoundedNotCutAndANonZeroShareIsNeverZero() {
        // The pure rule the screen's helper follows: round(permille / 10), "<1%" for a real share under half a percent.
        func percent(_ permille: Int) -> Int { (permille + 5) / 10 }
        #expect(percent(333) == 33 && percent(334) == 33 && percent(335) == 34 && percent(999) == 100)
        #expect(percent(4) == 0, "4 per mille is under half a percent: the screen says <1%")
    }

    // MARK: Reset reaches the lists the learned weights ranked

    private func learnerOn(_ directory: URL) {
        var model = Ranker.newModel(today: 20_000)
        model.lastEventId = 0
        let saved = LearnerCodec.Saved(model: model, gate: Gate.State(useLearned: true, winStreak: 2, atMs: 1),
                                       learnVersion: LearnReplay.version, summary: nil, rebuiltAtMs: 1)
        let log = BrainEventLog(directory: directory)
        log.setValue(BrainEventLog.keyLearner, LearnerCodec.encode(saved))
        log.setValue(BrainEventLog.keyPosteriors, PosteriorCodec.encode(Posteriors.newState(today: 20_000)))
        log.setValue(BrainEventLog.keyLearnVersion, String(LearnReplay.version))
    }

    @Test func aMixTheLearnedWeightsRankedIsBuiltAgainAfterAReset() async throws {
        let world = BrainMixesTests.World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository)
        await world.fetchRadios(repository)
        learnerOn(world.directory)
        // A key that is not a control draw, so the first list is ranked by the learned weights.
        var t = BrainMixesTests.start
        while Ranker.isControlSession(t) { t += 1 }
        world.clock.value = t
        let engine = world.engine(repository)
        let mixes = world.mixes(repository, engine)
        let first = try #require(await mixes.today(kind: MixPlanner.kindDaily))
        #expect(first.model == Int(BrainEngine.modelLearned))
        // Asked again the same day: the same saved list.
        world.clock.value = t + 30_000
        #expect(try #require(await mixes.today(kind: MixPlanner.kindDaily)).builtAtMs == first.builtAtMs)
        #expect(await engine.learnResetAtMs() == nil)
        // Reset: the saved list the learned weights ranked is not the day's list any more.
        world.clock.value = t + 60_000
        await engine.resetLearned()
        #expect(await engine.learnResetAtMs() == t + 60_000)
        world.clock.value = t + 120_000
        let after = try #require(await mixes.today(kind: MixPlanner.kindDaily))
        #expect(after.builtAtMs > first.builtAtMs)
        #expect(after.model == 0, "built after the reset, with the standard recipe")
    }

    @Test func resetDropsTheSavedHomeRowsTheLearnedWeightsRankedAndKeepsTheOthers() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brain-rows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Self.t0
        let repository = BrainRepository(directory: dir, radioSource: nil, clock: { clock })
        let engine = BrainEngine(directory: dir, repository: repository, sources: nil, clock: { clock })
        let rows = BrainHomeRows(directory: dir, repository: repository, engine: engine, clock: { clock })
        let url = dir.appendingPathComponent(BrainHomeRows.fileName)
        let anchor = HomeAnchor(rid: 1, aid: 2, mediaId: "m", title: "t", primaryArtist: "a", heardAtMs: clock)
        func write(model: Int) throws {
            let row = StoredHomeRow(anchor: anchor, recId: 3, items: [], control: false, model: model)
            try JSONEncoder().encode(StoredHomeRows(builtAtMs: clock, signature: "s", rows: [row])).write(to: url)
        }
        try write(model: 0)
        await rows.dropLearned()
        #expect(FileManager.default.fileExists(atPath: url.path), "rows ranked by the standard recipe stay")
        try write(model: 1)
        let fresh = BrainHomeRows(directory: dir, repository: repository, engine: engine, clock: { clock })
        await fresh.dropLearned()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aBackupRestoreKeepsTheExclusionsMadeSinceAndTheFeedbackFileInsertsBeforeItRemoves() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brain-fb-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FeedbackStore(directory: dir)
        store.insert(FeedbackStore.Record(id: 24, kind: FeedbackKinds.dontCount, targetKind: FeedbackKinds.targetSong, targetId: 3, createdAtMs: 7))
        store.merge([FeedbackStore.Record(id: 16, kind: FeedbackKinds.dontCount, targetKind: FeedbackKinds.targetSong, targetId: 9, createdAtMs: 5)])
        #expect(Set(store.all().map(\.id)) == [16, 24])
        store.replaceAll([FeedbackStore.Record(id: 16, kind: FeedbackKinds.dontCount, targetKind: FeedbackKinds.targetSong, targetId: 9, createdAtMs: 5)])
        #expect(store.all().map(\.id) == [16])
    }
}
