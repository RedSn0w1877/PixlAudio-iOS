import Foundation
import Testing
@testable import PixlLibrary

/// The parts stage 3's first pass cut (docs/brain-spec.md, 5.10): the arm bandit, the novelty appetite, context lift and the
/// shelf bandit, plus Lately, the genre tree and "You and this genre". A port of the Android `Stage3bTest`. All of them have
/// run on synthetic data only: no test here says anything about real listeners.
@Suite("Brain stage 3 completion")
struct BrainStage3bTests {
    let day0: Int64 = 20_000

    func event(_ id: Int64, _ startedAtMs: Int64, arm: Int32 = Arm.radio, surface: Int32 = Surface.autoplay, finished: Bool = true,
               flags: Int32 = 0, rid: Int64? = nil) -> PlayEvent {
        PlayEvent(eventId: id, origin: Origin.live, rid: rid ?? id, primaryAid: 7, startedAtMs: startedAtMs, tzOffsetMin: 0,
                  playedMs: finished ? 200_000 : 3_000, durationMs: 200_000, startReason: StartReason.autoplay,
                  endReason: finished ? EndReason.trackDone : EndReason.next, flags: flags, surface: surface, arm: arm)
    }

    func graded(_ e: PlayEvent) -> Reward.Graded { Reward.grade(e, Reward.Context()) }

    var dayMs: Int64 { BrainMath.dayMs }

    // MARK: Arm bandit

    @Test func theArmsStartAtTheSpecsPriors() {
        let s = ArmBandit.newState(today: day0)
        let expected: [Int32: (Double, Double)] = [Arm.fav: (7, 3), Arm.back: (6, 4), Arm.deep: (5, 5), Arm.artist: (5, 5), Arm.new: (5, 5),
                                                   Arm.radio: (4, 6), Arm.ask: (4, 6), Arm.sim: (3, 7), Arm.edge: (2, 8)]
        for f in 0..<ArmBandit.families {
            for (arm, ab) in expected {
                #expect(s.alpha[f * ArmBandit.arms + Int(arm)] == ab.0)
                #expect(s.beta[f * ArmBandit.arms + Int(arm)] == ab.1)
            }
        }
        #expect(abs(ArmBandit.mean(s, family: ArmBandit.mix, arm: Int(Arm.fav)) - 0.7) < 1e-12)
    }

    @Test func aPlayMovesOnlyItsOwnFamilyAndArmAndAnExplorationPlayAlsoFeedsTheAudit() {
        var s = ArmBandit.newState(today: day0)
        #expect(ArmBandit.update(&s, family: ArmBandit.station, arm: Int(Arm.radio), r: 1.0, c: 2.0, explore: false, day: day0))
        let i = ArmBandit.station * ArmBandit.arms + Int(Arm.radio)
        #expect(s.alpha[i] == 6.0)
        #expect(s.beta[i] == 6.0)
        #expect(s.auditAlpha[i] == 4.0)
        #expect(ArmBandit.update(&s, family: ArmBandit.station, arm: Int(Arm.radio), r: 0.0, c: 1.5, explore: true, day: day0))
        #expect(s.beta[i] == 7.5)
        #expect(s.auditBeta[i] == 7.5)
        #expect(s.alpha[ArmBandit.mix * ArmBandit.arms + Int(Arm.radio)] == 4.0)
        #expect(!ArmBandit.update(&s, family: ArmBandit.home, arm: Int(Arm.none), r: 1.0, c: 1.0, explore: false, day: day0))
        #expect(!ArmBandit.update(&s, family: ArmBandit.home, arm: Int(Arm.radio), r: 1.0, c: 0.0, explore: false, day: day0))
        #expect(s.updates == 2)
    }

    @Test func theDailyDiscountDoesNotDependOnHowOftenItIsCalled() {
        func fresh() -> ArmBandit.State {
            var s = ArmBandit.newState(today: day0)
            ArmBandit.update(&s, family: ArmBandit.mix, arm: Int(Arm.fav), r: 1.0, c: 3.0, explore: true, day: day0)
            return s
        }
        var once = fresh()
        ArmBandit.discount(&once, today: day0 + 10)
        var many = fresh()
        for d in 1...10 { ArmBandit.discount(&many, today: day0 + Int64(d)) }
        #expect(once.alpha == many.alpha)
        #expect(once.auditBeta == many.auditBeta)
        var back = fresh()
        #expect(ArmBandit.discount(&back, today: day0 - 3) == 0)
        #expect(back.anchorDay == day0 - 3)
        let k = ArmBandit.mix * ArmBandit.arms + Int(Arm.fav)
        #expect(once.alpha[k] < 10.0 && once.alpha[k] > 7.0)
    }

    @Test func theAuditIsDrawnFromOnlyWithEvidenceAndWhenItDisagreesByMoreThan015() {
        var s = ArmBandit.newState(today: day0)
        let arm = Int(Arm.radio)
        let i = ArmBandit.mix * ArmBandit.arms + arm
        s.alpha[i] += 20.0
        s.auditBeta[i] += 12.0
        #expect(ArmBandit.auditInUse(s, family: ArmBandit.mix, arm: arm))
        #expect(abs(ArmBandit.mean(s, family: ArmBandit.mix, arm: arm) - s.auditAlpha[i] / (s.auditAlpha[i] + s.auditBeta[i])) < 1e-12)
        var thin = ArmBandit.newState(today: day0)
        thin.alpha[i] += 20.0
        thin.auditBeta[i] += 2.0
        #expect(!ArmBandit.auditInUse(thin, family: ArmBandit.mix, arm: arm))
    }

    @Test func aDrawIsDeterministicAndTheLargestDrawWinsAmongTheArmsThatHaveACandidate() {
        var s = ArmBandit.newState(today: day0)
        var r1 = BrainHash.Rng(seed: 42)
        var r2 = BrainHash.Rng(seed: 42)
        let a = ArmBandit.draw(s, family: ArmBandit.mix, arm: Int(Arm.fav), &r1)
        let b = ArmBandit.draw(s, family: ArmBandit.mix, arm: Int(Arm.fav), &r2)
        #expect(a.bitPattern == b.bitPattern)
        #expect(a >= 0.0 && a <= 1.0)
        for arm in 0..<ArmBandit.arms {
            let i = ArmBandit.mix * ArmBandit.arms + arm
            if arm == Int(Arm.edge) { s.alpha[i] += 500.0 } else { s.beta[i] += 500.0 }
        }
        let all = [Bool](repeating: true, count: ArmBandit.arms)
        for seed in 1...20 {
            var r = BrainHash.Rng(seed: UInt64(seed))
            #expect(ArmBandit.pickArm(s, family: ArmBandit.mix, eligible: all, &r) == Arm.edge)
        }
        let noEdge = (0..<ArmBandit.arms).map { $0 != Int(Arm.edge) }
        for seed in 1...20 {
            var r = BrainHash.Rng(seed: UInt64(seed))
            #expect(ArmBandit.pickArm(s, family: ArmBandit.mix, eligible: noEdge, &r) != Arm.edge)
        }
        var r = BrainHash.Rng(seed: 1)
        #expect(ArmBandit.pickArm(s, family: ArmBandit.mix, eligible: [Bool](repeating: false, count: ArmBandit.arms), &r) == -1)
    }

    func scored(_ rid: Int64, _ aid: Int64, _ arm: Int32, _ novel: Bool, _ z: Double) -> ListBuilder.Scored {
        ListBuilder.Scored(c: Candidate(rid: rid, aid: aid, albumKey: rid, inLibrary: !novel), arm: arm, z: z, p: BrainMath.sigmoid(z),
                           novel: novel, bestRank: 0, bestSeed: -1, newestSeedRank: 0, lastMs: 0, retrQ: 0)
    }

    func pool() -> [ListBuilder.Scored] {
        var out: [ListBuilder.Scored] = []
        for i in 1...12 { out.append(scored(Int64(i), 100 + Int64(i), Arm.fav, false, 1.0 - 0.01 * Double(i))) }
        for i in 1...6 { out.append(scored(100 + Int64(i), 200 + Int64(i), Arm.radio, true, 0.9 - 0.01 * Double(i))) }
        for i in 1...6 { out.append(scored(200 + Int64(i), 300 + Int64(i), Arm.sim, true, 0.5 - 0.01 * Double(i))) }
        for i in 1...6 { out.append(scored(300 + Int64(i), 400 + Int64(i), Arm.edge, true, 0.2 - 0.01 * Double(i))) }
        return out
    }

    func build(_ picker: (any ArmPicker)?) -> [ListBuilder.Pick] {
        ListBuilder.build(ListBuilder.Request(count: 20, prior: [], nu: 0.4, tieSeed: 5, nowMs: 1_750_000_000_000, tzOffsetMin: 0,
                                              armPicker: picker), scored: pool(), graph: Graph.empty)
    }

    @Test func withNoPickerTheNovelSlotsAreWhatStage2ChoseAndNothingIsFlagged() {
        let plain = build(nil)
        #expect(plain.contains { $0.scored.novel })
        #expect(plain.allSatisfy { !$0.explore })
        #expect(plain.filter { $0.scored.novel }.allSatisfy { $0.scored.arm == Arm.radio || $0.scored.arm == Arm.sim })
    }

    @Test func withAPickerANovelSlotGoesToTheDrawnArmAndIsFlaggedAFamiliarSlotIsNot() {
        let picker = ClosureArmPicker { eligible in
            if eligible[Int(Arm.edge)] { return Arm.edge }
            if eligible[Int(Arm.sim)] { return Arm.sim }
            return -1
        }
        let picks = build(picker)
        let novel = picks.filter { $0.scored.novel }
        #expect(!novel.isEmpty)
        #expect(novel.first?.scored.arm == Arm.edge)
        #expect(novel.allSatisfy { $0.explore })
        #expect(picks.filter { !$0.scored.novel }.allSatisfy { !$0.explore })
    }

    @Test func aSamplerSeededTheSameDrawsTheSameArmsAndLeavesItsStateAlone() {
        let s = ArmBandit.newState(today: day0)
        let eligible = (0..<ArmBandit.arms).map { $0 >= Int(Arm.radio) && $0 <= Int(Arm.edge) }
        let a = ArmBandit.Sampler(s, family: ArmBandit.home, seed: 9)
        let b = ArmBandit.Sampler(s, family: ArmBandit.home, seed: 9)
        for _ in 0..<10 { #expect(a.pick(eligible) == b.pick(eligible)) }
        #expect(s.updates == 0)
    }

    // MARK: Novelty appetite

    @Test func withNoHistoryTheAppetiteIs025() {
        var s = NoveltyAppetite.newState(today: day0)
        #expect(NoveltyAppetite.nu0(s, today: day0) == 0.25)
        NoveltyAppetite.advance(&s, today: day0)
        #expect(abs(NoveltyAppetite.target(s, today: day0) - 0.25) < 1e-12)
        #expect(abs(s.nuLong - 0.25) < 1e-12)
        #expect(abs(NoveltyAppetite.nu(s, nowMs: day0 * dayMs) - 0.25) < 1e-12)
    }

    @Test func nu0IsTheShareOfFirstPlaysInTheLastYearClipped() {
        var s = NoveltyAppetite.newState(today: day0)
        let g = graded(event(1, day0 * dayMs))
        for k in 0..<100 {
            NoveltyAppetite.onPlay(&s, event(10 + Int64(k), day0 * dayMs), g, novel: k < 45, recommender: false, day: day0)
        }
        #expect(abs(NoveltyAppetite.nu0(s, today: day0) - 0.45) < 1e-12)
        #expect(abs(NoveltyAppetite.nu0(s, today: day0 + 300) - 0.45) < 1e-12)
        #expect(NoveltyAppetite.nu0(s, today: day0 + 400) == 0.25)
        var allNew = NoveltyAppetite.newState(today: day0)
        for k in 0..<20 { NoveltyAppetite.onPlay(&allNew, event(10 + Int64(k), day0 * dayMs), g, novel: true, recommender: false, day: day0) }
        #expect(NoveltyAppetite.nu0(allNew, today: day0) == NoveltyAppetite.nu0Max)
        var none = NoveltyAppetite.newState(today: day0)
        for k in 0..<20 { NoveltyAppetite.onPlay(&none, event(10 + Int64(k), day0 * dayMs), g, novel: false, recommender: false, day: day0) }
        #expect(NoveltyAppetite.nu0(none, today: day0) == NoveltyAppetite.nu0Min)
    }

    @Test func novelPlaysFinishedMoreOftenRaiseTheTargetAndTheSlowAppetiteMovesAtMost002ADay() {
        var s = NoveltyAppetite.newState(today: day0)
        NoveltyAppetite.advance(&s, today: day0)
        let start = s.nuLong
        let finished = graded(event(1, day0 * dayMs))
        let skipped = graded(event(2, day0 * dayMs, finished: false))
        for k in 0..<40 {
            NoveltyAppetite.onPlay(&s, event(100 + Int64(k), day0 * dayMs), finished, novel: true, recommender: true, day: day0)
            NoveltyAppetite.onPlay(&s, event(200 + Int64(k), day0 * dayMs), skipped, novel: false, recommender: true, day: day0)
        }
        #expect(NoveltyAppetite.target(s, today: day0) > start)
        NoveltyAppetite.advance(&s, today: day0 + 1)
        #expect(s.nuLong - start <= NoveltyAppetite.maxStepPerDay + 1e-12)
        #expect(s.nuLong > start)
        NoveltyAppetite.advance(&s, today: day0 + 1)
        let after = s.nuLong
        NoveltyAppetite.advance(&s, today: day0 + 11)
        #expect(s.nuLong - after <= 10 * NoveltyAppetite.maxStepPerDay + 1e-12)
        #expect(s.nuLong <= NoveltyAppetite.nuLongMax)
    }

    @Test func aLikedNovelTrackAdds001ThatFadesOver30DaysAndIsCappedAt010() {
        var s = NoveltyAppetite.newState(today: day0)
        let t = day0 * dayMs
        let liked = event(1, t, flags: EventFlags.likedDuring)
        NoveltyAppetite.onPlay(&s, liked, graded(liked), novel: true, recommender: true, day: day0)
        #expect(abs(NoveltyAppetite.boost(s, nowMs: t) - 0.01) < 1e-12)
        #expect(abs(NoveltyAppetite.boost(s, nowMs: t + 15 * dayMs) - 0.005) < 1e-9)
        #expect(abs(NoveltyAppetite.boost(s, nowMs: t + 30 * dayMs)) < 1e-12)
        let old = event(2, t, flags: EventFlags.savedDuring)
        NoveltyAppetite.onPlay(&s, old, graded(old), novel: false, recommender: true, day: day0)
        #expect(abs(NoveltyAppetite.boost(s, nowMs: t) - 0.01) < 1e-12)
        for k in 0..<20 {
            let e = event(10 + Int64(k), t, flags: EventFlags.savedDuring)
            NoveltyAppetite.onPlay(&s, e, graded(e), novel: true, recommender: true, day: day0)
        }
        #expect(abs(NoveltyAppetite.boost(s, nowMs: t) - NoveltyAppetite.boostCap) < 1e-12)
        #expect(NoveltyAppetite.nu(s, nowMs: t) <= NoveltyAppetite.nuLongMax)
    }

    @Test func anExcludedPlayChangesNoPosterior() {
        var s = NoveltyAppetite.newState(today: day0)
        let e = event(1, day0 * dayMs, flags: EventFlags.learnExcluded)
        #expect(!NoveltyAppetite.onPlay(&s, e, graded(e), novel: true, recommender: true, day: day0))
        #expect(s.updates == 0)
        #expect(s.days.isEmpty)
    }

    // MARK: The posteriors together

    func history(_ n: Int) -> [PlayEvent] {
        var rng = BrainHash.Rng(seed: 77)
        var out: [PlayEvent] = []
        var t = day0 * dayMs
        let arms: [Int32] = [Arm.fav, Arm.deep, Arm.radio, Arm.sim, Arm.edge, Arm.artist]
        let surfaces: [Int32] = [Surface.autoplay, Surface.dailyMix, Surface.homeShelf, Surface.playlist]
        for i in 0..<n {
            t += 3_000_000
            let arm = arms[Int(BrainMath.clip(BrainMath.floorToLong(rng.uniform() * 6.0).asDouble, 0, 5))]
            let surface = surfaces[Int(BrainMath.clip(BrainMath.floorToLong(rng.uniform() * 4.0).asDouble, 0, 3))]
            let flags: Int32 = i % 9 == 0 ? EventFlags.exploreSlot : (i % 17 == 0 ? EventFlags.likedDuring : 0)
            out.append(event((t << 16) | (Int64(i) & 0xFFFF), t, arm: arm, surface: surface, finished: rng.uniform() < 0.6, flags: flags,
                             rid: 1 + Int64(i % 40)))
        }
        return out
    }

    @Test func theReplayBuildsThePosteriorsTheSameWayTwiceAndAppliesNoEventTwice() {
        let events = history(400)
        let now = events.last!.startedAtMs + 3_600_000
        let a = LearnReplay.run(events, facts: .empty, nowMs: now, likedRids: [])
        let b = LearnReplay.run(events, facts: .empty, nowMs: now, likedRids: [])
        #expect(PosteriorCodec.encode(a.posteriors) == PosteriorCodec.encode(b.posteriors))
        #expect(a.posteriors.arms.updates > 100)
        #expect(a.posteriors.appetite.updates > 100)
        let playlistOnly = events.filter { $0.surface == Surface.playlist }
        let c = LearnReplay.run(playlistOnly, facts: .empty, nowMs: now, likedRids: [])
        #expect(c.posteriors.arms.updates == 0)
        var p = a.posteriors
        let e = events.last!
        #expect(!PosteriorUpdate.onPlay(&p, e, graded(e), novel: true, nowMs: now))
        #expect(PosteriorCodec.encode(a.posteriors) == PosteriorCodec.encode(p))
    }

    @Test func aLivePassOverTheSameEventsGivesThePosteriorsTheReplayGives() {
        let events = history(300)
        let now = events.last!.startedAtMs + 3_600_000
        let replay = LearnReplay.run(events, facts: .empty, nowMs: now, likedRids: [])
        var affinity = Affinity.State()
        var tracker = GradeTracker()
        var live = Posteriors.newState(today: LearnReplay.dayOf(events[0], events[0].startedAtMs))
        for e in events {
            let novel = !Affinity.isHeard(affinity, family: Family.track, key: e.rid)
            let g = tracker.grade(e, completions: affinity.completions)
            PosteriorUpdate.onPlay(&live, e, g, novel: novel, nowMs: now)
            Affinity.applyEvent(&affinity, e, g, tMs: e.startedAtMs)
        }
        PosteriorUpdate.advanceTo(&live, today: BrainMath.localDay(now, tzOffsetMin: 0))
        #expect(PosteriorCodec.encode(replay.posteriors) == PosteriorCodec.encode(live))
    }

    @Test func playsBeforeAResetAreNotLearnedFromAndTheCodecRefusesADamagedState() {
        let events = history(200)
        let now = events.last!.startedAtMs + 3_600_000
        let after = events[99].eventId
        let result = LearnReplay.run(events, facts: .empty, nowMs: now, likedRids: [], tzNowMin: 0, learnAfterEventId: after)
        let full = LearnReplay.run(events, facts: .empty, nowMs: now, likedRids: [])
        #expect(result.posteriors.arms.updates < full.posteriors.arms.updates)
        let text = PosteriorCodec.encode(result.posteriors)
        let back = PosteriorCodec.decode(text)
        #expect(back != nil)
        #expect(back.map { PosteriorCodec.encode($0) } == text)
        for bad in ["", "{}", "not json", "{\"format\":\"brain-posteriors-v1\"}", text.replacingOccurrences(of: "brain-posteriors-v1", with: "other")] {
            #expect(PosteriorCodec.decode(bad) == nil, "\(bad.prefix(40))")
        }
        let hex = BrainJson.hex64(result.posteriors.arms.alpha[0].bitPattern)
        let nan = text.replacingOccurrences(of: "\"\(hex)\"", with: "\"7ff8000000000000\"")
        #expect(nan != text)
        #expect(PosteriorCodec.decode(nan) == nil)
    }

    // MARK: Context

    func at(_ hour: Int64, _ day: Int64 = 20_000) -> Int64 { day * dayMs + hour * 3_600_000 }

    @Test func theDaypartsAndTheEightBuckets() {
        #expect(ContextLift.daypart(at(4), tzOffsetMin: 0) == ContextLift.night)
        #expect(ContextLift.daypart(at(5), tzOffsetMin: 0) == ContextLift.morning)
        #expect(ContextLift.daypart(at(10), tzOffsetMin: 0) == ContextLift.morning)
        #expect(ContextLift.daypart(at(11), tzOffsetMin: 0) == ContextLift.day)
        #expect(ContextLift.daypart(at(16), tzOffsetMin: 0) == ContextLift.day)
        #expect(ContextLift.daypart(at(17), tzOffsetMin: 0) == ContextLift.evening)
        #expect(ContextLift.daypart(at(21), tzOffsetMin: 0) == ContextLift.evening)
        #expect(ContextLift.daypart(at(22), tzOffsetMin: 0) == ContextLift.night)
        #expect(ContextLift.daypart(at(23), tzOffsetMin: 120) == ContextLift.night)
        #expect(ContextLift.daypart(at(3), tzOffsetMin: 180) == ContextLift.morning)
        #expect(!ContextLift.isWeekendBucket(ContextLift.bucket(at(9, 20_000), tzOffsetMin: 0)))
        #expect(ContextLift.isWeekendBucket(ContextLift.bucket(at(9, 20_001), tzOffsetMin: 0)))
        #expect(ContextLift.bucket(at(9, 20_001), tzOffsetMin: 0) == 4 + ContextLift.morning)
        var all = Set<Int>()
        for d in Int64(20_000)..<20_007 { for h in 0..<24 { all.insert(ContextLift.bucket(at(Int64(h), d), tzOffsetMin: 0)) } }
        #expect(all.count == 8)
    }

    func table(_ plays: Int, _ now: Int64) -> ContextLift.Table {
        var b = ContextLift.Builder(nowMs: now)
        let fridayNight = 20_000 * dayMs + 23 * 3_600_000
        for k in 0..<plays { b.add(islandId: 1, startedAtMs: fridayNight - Int64(k) * 7 * dayMs, tzOffsetMin: 0, c: 1.0, r: 1.0) }
        for k in 0..<60 { b.add(islandId: 2, startedAtMs: 20_001 * dayMs + 9 * 3_600_000 - Int64(k) * 7 * dayMs, tzOffsetMin: 0, c: 1.0, r: 1.0) }
        for k in 0..<60 { b.add(islandId: 2, startedAtMs: 20_002 * dayMs + 9 * 3_600_000 - Int64(k) * 7 * dayMs, tzOffsetMin: 0, c: 1.0, r: 1.0) }
        for k in 0..<80 { b.add(islandId: 2, startedAtMs: 20_000 * dayMs + 18 * 3_600_000 - Int64(k) * dayMs, tzOffsetMin: 0, c: 1.0, r: 1.0) }
        return b.build()
    }

    @Test func theLiftIs0Below50PlaysInABucketAndFollowsTheFormulaAbove() {
        let now = 20_000 * dayMs + 23 * 3_600_000
        let thin = table(40, now)
        let night = ContextLift.bucket(now, tzOffsetMin: 0)
        #expect(!thin.hasLift(night))
        #expect(thin.lift(1, night) == 0.0)
        let full = table(80, now)
        #expect(full.hasLift(night))
        #expect(full.lift(1, night) > 0.3)
        #expect(full.lift(99, night) == 0.0)
        for id in [1, 2] { for b in 0..<8 { #expect(full.lift(id, b) >= -1.5 && full.lift(id, b) <= 1.5) } }
    }

    @Test func anOlderPlayCountsForLessAndTheBucketCountsSkips() {
        let now = 20_100 * dayMs
        var b = ContextLift.Builder(nowMs: now)
        b.add(islandId: 1, startedAtMs: now - 10 * dayMs, tzOffsetMin: 0, c: 1.0, r: 1.0)
        b.add(islandId: 1, startedAtMs: now - 130 * dayMs, tzOffsetMin: 0, c: 1.0, r: 1.0)
        #expect(b.build().plays.reduce(0, +) == 2)
        var skipOnly = ContextLift.Builder(nowMs: now)
        skipOnly.add(islandId: 1, startedAtMs: now, tzOffsetMin: 0, c: 1.0, r: 0.0)
        #expect(skipOnly.build().plays.reduce(0, +) == 1)
        var none = ContextLift.Builder(nowMs: now)
        none.add(islandId: -1, startedAtMs: now, tzOffsetMin: 0, c: 1.0, r: 1.0)
        none.add(islandId: 1, startedAtMs: now, tzOffsetMin: 0, c: 0.0, r: 1.0)
        #expect(none.build().plays.reduce(0, +) == 0)
    }

    @Test func theLeaderIsTheIslandWithTheLargestWeightTimesExpOfItsLift() {
        let now = 20_000 * dayMs + 23 * 3_600_000
        let t = table(80, now)
        let night = ContextLift.bucket(now, tzOffsetMin: 0)
        #expect(t.leader(night, [(id: 1, weight: 1.0), (id: 2, weight: 1.0)]) == 1)
        #expect(t.leader(night, [(id: 1, weight: 1.0), (id: 2, weight: 50.0)]) == 2)
        #expect(table(40, now).leader(night, [(id: 1, weight: 1.0)]) == -1)
        #expect(t.leader(night, []) == -1)
    }

    // MARK: Shelf bandit

    @Test func theShelvesStartAtThePessimisticPriors() {
        let s = ShelfBandit.newState()
        #expect(abs(ShelfBandit.mean(s, type: HomePlanner.madeForYou, daypart: 2) - 0.3) < 1e-12)
        #expect(abs(ShelfBandit.mean(s, type: HomePlanner.onRepeat, daypart: 0) - 0.2) < 1e-12)
        #expect(abs(ShelfBandit.mean(s, type: HomePlanner.rediscover, daypart: 3) - 0.1) < 1e-12)
        #expect(abs(ShelfBandit.mean(s, type: ShelfBandit.daypartMix, daypart: 1) - 0.1) < 1e-12)
    }

    @Test func aVisitUpdatesOnlyTheShelvesDownToTheLastOneSeenOrUsed() {
        var s = ShelfBandit.newState()
        let shown: [Int32] = [HomePlanner.madeForYou, HomePlanner.becauseListened, HomePlanner.onRepeat, HomePlanner.rediscover, HomePlanner.stations]
        #expect(ShelfBandit.visit(&s, daypart: 1, shown: shown, lastSeen: 2, used: 1, today: day0) == 3)
        func at(_ t: Int32, _ d: Int) -> Int { Int(t) * 4 + d }
        #expect(s.alpha[at(HomePlanner.madeForYou, 1)] == 3.0 && s.beta[at(HomePlanner.madeForYou, 1)] == 8.0)
        #expect(s.alpha[at(HomePlanner.becauseListened, 1)] == 2.0 && s.beta[at(HomePlanner.becauseListened, 1)] == 9.0)
        #expect(s.alpha[at(HomePlanner.onRepeat, 1)] == 2.0 && s.beta[at(HomePlanner.onRepeat, 1)] == 9.0)
        #expect(s.alpha[at(HomePlanner.rediscover, 1)] == 1.0 && s.beta[at(HomePlanner.rediscover, 1)] == 9.0)
        #expect(s.alpha[at(HomePlanner.madeForYou, 0)] == 3.0)
        #expect(ShelfBandit.visit(&s, daypart: 2, shown: shown, lastSeen: 0, used: 4, today: day0 + 1) == 5)
        #expect(s.alpha[at(HomePlanner.stations, 2)] == 2.0)
        #expect(ShelfBandit.visit(&s, daypart: 2, shown: shown, lastSeen: -1, used: -1, today: day0 + 2) == 0)
    }

    @Test func withNoDataTheStage2OrderStaysAndOnceThereIsDataTheOrderIsDrawnOncePerDaypartAndFrozen() {
        var s = ShelfBandit.newState()
        let types: [Int32] = [HomePlanner.madeForYou, HomePlanner.becauseListened, HomePlanner.newFromLoved, HomePlanner.onRepeat, HomePlanner.rediscover]
        #expect(ShelfBandit.order(&s, planKey: 100, daypart: 1, types: types, seed: 5, today: day0) == nil)
        for k in 0..<25 { ShelfBandit.visit(&s, daypart: 1, shown: types, lastSeen: 4, used: k % 2 == 0 ? 3 : 1, today: day0) }
        #expect(ShelfBandit.hasData(s))
        let first = ShelfBandit.order(&s, planKey: 100, daypart: 1, types: types, seed: 5, today: day0 + 1)!
        #expect(Set(first) == Set(types))
        ShelfBandit.visit(&s, daypart: 1, shown: types, lastSeen: 4, used: 0, today: day0 + 1)
        #expect(ShelfBandit.order(&s, planKey: 100, daypart: 1, types: types, seed: 999, today: day0 + 1)! == first)
        let fewer: [Int32] = [HomePlanner.madeForYou, HomePlanner.onRepeat]
        #expect(Set(ShelfBandit.order(&s, planKey: 100, daypart: 1, types: fewer, seed: 5, today: day0 + 1)!) == Set(fewer))
        #expect(ShelfBandit.order(&s, planKey: 101, daypart: 2, types: types, seed: 6, today: day0 + 1) != nil)
        #expect(s.frozenKey == 101)
    }

    @Test func aShelfTypeUnseenFor14DaysIsShownOnceAtTheTop() {
        var s = ShelfBandit.newState()
        let types: [Int32] = [HomePlanner.madeForYou, HomePlanner.becauseListened, HomePlanner.onRepeat, HomePlanner.rediscover]
        ShelfBandit.visit(&s, daypart: 0, shown: [HomePlanner.rediscover], lastSeen: 0, used: -1, today: day0)
        for k in 0..<40 {
            ShelfBandit.visit(&s, daypart: 0, shown: Array(types[0..<3]), lastSeen: 2, used: 0, today: day0 + 1 + Int64(k) / 10)
        }
        let today = day0 + 20
        let order = ShelfBandit.order(&s, planKey: 5, daypart: 0, types: types, seed: 1, today: today)!
        #expect(order[0] == HomePlanner.rediscover)
        // The exposure is spent when a visit shows the shelf, not when the order is drawn: a plan that leaves it out forces it again.
        #expect(s.lastSeenDay[Int(HomePlanner.rediscover)] == day0)
        #expect(ShelfBandit.order(&s, planKey: 6, daypart: 0, types: types, seed: 1, today: today)![0] == HomePlanner.rediscover)
        ShelfBandit.visit(&s, daypart: 0, shown: order, lastSeen: 0, used: -1, today: today)
        #expect(s.lastSeenDay[Int(HomePlanner.rediscover)] == today)
        let later = ShelfBandit.order(&s, planKey: 7, daypart: 0, types: types, seed: 1, today: today + 3)!
        #expect(later.contains(HomePlanner.rediscover))
    }

    @Test func aShelfTypeThatWasNeverOnScreenIsForcedToTheTopOnceThereIsData() {
        var s = ShelfBandit.newState()
        let types: [Int32] = [HomePlanner.madeForYou, HomePlanner.becauseListened, HomePlanner.onRepeat]
        for _ in 0..<60 { ShelfBandit.visit(&s, daypart: 0, shown: Array(types[0..<2]), lastSeen: 1, used: 0, today: day0) }
        #expect(s.lastSeenDay[Int(HomePlanner.onRepeat)] == Int64.min)
        #expect(ShelfBandit.order(&s, planKey: 1, daypart: 0, types: types, seed: 1, today: day0)![0] == HomePlanner.onRepeat)
    }

    @Test func theAppetitesDiscountKeepsRunningAfterTheFirstLongGapAndALateStampedPlayDoesNotStallTheLearner() {
        var s = NoveltyAppetite.newState(today: day0)
        func play(_ id: Int64) -> PlayEvent { event(id, day0 * BrainMath.dayMs) }
        let finished = graded(play(1))
        for k in 0..<40 { NoveltyAppetite.onPlay(&s, play(100 + Int64(k)), finished, novel: true, recommender: true, day: day0) }
        let excess0 = s.nAlpha - NoveltyAppetite.prior
        #expect(excess0 > 10.0)
        NoveltyAppetite.onPlay(&s, play(900), finished, novel: true, recommender: false, day: day0 + 60)
        let capped = Foundation.pow(NoveltyAppetite.dailyDiscount, Double(NoveltyAppetite.maxForgetRuns))
        #expect(abs((s.nAlpha - NoveltyAppetite.prior) - excess0 * capped) < 1e-9)
        NoveltyAppetite.onPlay(&s, play(901), finished, novel: true, recommender: false, day: day0 + 120)
        #expect(abs((s.nAlpha - NoveltyAppetite.prior) - excess0 * capped * capped) < 1e-9, "the second gap is discounted as well")
        // The live id: below the watermark the play goes under the next id; in order the real one is used.
        #expect(LearnReplay.liveId(10, watermark: 5) == 10)
        #expect(LearnReplay.liveId(3, watermark: 5) == 6)
        #expect(LearnReplay.liveId(3, watermark: Int64.max) == Int64.max)
    }

    @Test func thePosteriorsCanBeMadeAgainFromTheImpressionsAndTheCodecIsStrict() {
        var live = ShelfBandit.newState()
        var rows: [ShelfBandit.VisitRow] = []
        let types: [Int32] = [HomePlanner.madeForYou, HomePlanner.becauseListened, HomePlanner.onRepeat]
        for v in 0..<30 {
            let used = v % 3
            let lastSeen = v % 4 == 0 ? 2 : used
            ShelfBandit.visit(&live, daypart: v % 4, shown: types, lastSeen: lastSeen, used: used, today: day0 + Int64(v))
            for p in types.indices {
                rows.append(ShelfBandit.VisitRow(visitId: Int64(v), type: types[p], daypart: v % 4, position: p, seen: p <= lastSeen,
                                                 used: p == used, day: day0 + Int64(v)))
            }
        }
        let rebuilt = ShelfBandit.rebuild(rows)
        #expect(rebuilt.alpha == live.alpha)
        #expect(rebuilt.beta == live.beta)
        let text = ShelfBanditCodec.encode(live)
        #expect(ShelfBanditCodec.decode(text).map { ShelfBanditCodec.encode($0) } == text)
        for bad in ["", "{}", "{\"format\":\"brain-shelf-bandit-v1\"}", "xx"] { #expect(ShelfBanditCodec.decode(bad) == nil) }
    }

    @Test func thePageOrderFollowsTheShelfTypesAndKeepsShelvesOfOneTypeInTheirOrder() {
        func shelf(_ type: Int32, _ id: String) -> HomePlanner.ShelfIn { HomePlanner.ShelfIn(type: type, id: id, items: []) }
        let fixed = [shelf(HomePlanner.madeForYou, "a"), shelf(HomePlanner.becauseListened, "b1"), shelf(HomePlanner.becauseListened, "b2"),
                     shelf(HomePlanner.onRepeat, "c"), shelf(HomePlanner.rediscover, "d")]
        let out = HomePlanner.reorder(fixed, typeOrder: [HomePlanner.onRepeat, HomePlanner.becauseListened, HomePlanner.madeForYou])
        #expect(out.map { $0.id } == ["c", "b1", "b2", "a", "d"])
    }

    // MARK: Lately, the genre tree, "you and this genre"

    func play(_ aid: Int64, _ finished: Bool, _ t: Int64, _ id: Int64) -> PlayEvent {
        PlayEvent(eventId: id, origin: Origin.live, rid: aid * 100 + id % 3, primaryAid: aid, startedAtMs: t, tzOffsetMin: 0,
                  playedMs: finished ? 200_000 : 3_000, durationMs: 200_000, startReason: StartReason.tap,
                  endReason: finished ? EndReason.trackDone : EndReason.next, surface: Surface.playlist)
    }

    @Test func latelyNamesTheArtistsWhoseAffinityMovedMostInTheLast14DaysLargestFirstAtMostFive() {
        let now: Int64 = 1_760_000_000_000
        let cutoff = now - Int64(YourSound.latelyDays) * dayMs
        var before = Affinity.State()
        var after = Affinity.State()
        var tracker = GradeTracker()
        var trackerBefore = GradeTracker()
        var id: Int64 = 1
        for k in 0..<30 {
            let t = cutoff - Int64(30 - k) * 3_600_000
            for aid in [Int64(1), 3] {
                let e = play(aid, true, t, id)
                id += 1
                Affinity.applyEvent(&before, e, trackerBefore.grade(e, completions: before.completions), tMs: t)
                Affinity.applyEvent(&after, e, tracker.grade(e, completions: after.completions), tMs: t)
            }
        }
        for k in 0..<30 {
            let t = cutoff + Int64(k + 1) * 3_600_000
            let down = play(1, false, t, id)
            id += 1
            Affinity.applyEvent(&after, down, tracker.grade(down, completions: after.completions), tMs: t)
            let up = play(2, true, t + 60_000, id)
            id += 1
            Affinity.applyEvent(&after, up, tracker.grade(up, completions: after.completions), tMs: t + 60_000)
        }
        let moves = YourSound.lately(before: before, after: after, beforeMs: cutoff, nowMs: now)
        #expect(!moves.isEmpty && moves.count <= YourSound.latelyTop)
        var artists: [Int64: Double] = [:]
        for m in moves where m.family == Family.artist { artists[m.key] = m.delta }
        #expect((artists[2] ?? -1) > 0.0)
        #expect((artists[1] ?? 1) < 0.0)
        if let three = artists[3], let two = artists[2] { #expect(!(BrainMath.abs(three) > BrainMath.abs(two))) }
        for i in 1..<moves.count { #expect(BrainMath.abs(moves[i - 1].delta) >= BrainMath.abs(moves[i].delta) - 1e-9) }
        #expect(YourSound.lately(before: after, after: after, beforeMs: now, nowMs: now).isEmpty)
    }

    @Test func theGenreTreeRollsPlaysUpToTheirFamilyAndAnUnknownGenreIsAbsent() {
        func p(_ rid: Int64, _ t: Int64) -> YourSound.Play { YourSound.Play(rid: rid, aid: 1, startedAtMs: t, tzOffsetMin: 0, first: false) }
        let plays = [p(1, 1), p(1, 2), p(2, 3), p(3, 4), p(4, 5)]
        let tag: [Int64: Int] = [1: 11, 2: 12, 3: 20]
        let root: [Int: Int] = [11: 10, 12: 10, 20: 20]
        let tree = YourSound.genreTree(plays, top: 8, topTagOf: { tag[$0] ?? GenreAtlas.none }, rootOf: { root[$0] ?? $0 })
        #expect(tree.map { $0.rootId } == [10, 20])
        #expect(tree[0].permille == 750)
        #expect(tree[0].children == [YourSound.GenreShare(atlasId: 11, permille: 500), YourSound.GenreShare(atlasId: 12, permille: 250)])
        #expect(tree[1].permille == 250)
        #expect(YourSound.genreTree([], top: 8, topTagOf: { _ in GenreAtlas.none }, rootOf: { $0 }).isEmpty)
    }

    @Test func youAndThisGenreIsHiddenWhenNothingWasPlayedAndOtherwiseSaysFirstPlayShareAndTopTracks() {
        func p(_ rid: Int64, _ t: Int64) -> YourSound.Play { YourSound.Play(rid: rid, aid: 1, startedAtMs: t, tzOffsetMin: 0, first: false) }
        let plays = [p(5, 300), p(6, 100), p(5, 200), p(9, 400), p(5, 500)]
        #expect(YourSound.genreHistory(plays, top: 5, belongs: { _ in false }) == nil)
        let h = YourSound.genreHistory(plays, top: 5, belongs: { $0 == 5 || $0 == 6 })!
        #expect(h.firstPlayedMs == 100)
        #expect(h.permille == 800)
        #expect(h.plays == 4)
        #expect(h.topRids == [5, 6])
    }

    @Test func aTagAdjustmentBecomesAPseudoCountOnTheGenreAndNothingElse() {
        let facts = LibraryFacts(adjustments: [LibraryFacts.Adjustment(family: Family.tag, key: 77, more: true, strength: 2),
                                               LibraryFacts.Adjustment(family: Family.tag, key: 78, more: false, strength: 1)])
        var state = Affinity.State()
        Replay.applyFacts(&state, facts)
        #expect(Affinity.aff(state, family: Family.tag, key: 77, nowMs: 0, p0: 0.5) > 0.0)
        #expect(Affinity.aff(state, family: Family.tag, key: 78, nowMs: 0, p0: 0.5) < 0.0)
        #expect(state.sortedKeys(Family.track).isEmpty)
    }
}

private extension Int64 {
    var asDouble: Double { Double(self) }
}
