import Foundation
import Testing
@testable import PixlLibrary

/// The learner of docs/brain-spec.md, 5.9 and 5.12, the gate, the saved state and the replay that trains it: a port of the
/// Android `LearnerTest`. The learner has only ever run on synthetic listeners; nothing here says anything about real ones.
@Suite("Brain learner (stage 3)")
struct BrainLearnerTests {
    private func x(_ pairs: [(Int, Double)] = []) -> [Double] {
        var v = [Double](repeating: 0.0, count: Ranker.d)
        v[0] = 1.0
        for (i, value) in pairs { v[i] = value }
        return v
    }

    private func sameBits(_ a: [Double], _ b: [Double], _ note: String = "") {
        #expect(a.count == b.count)
        for i in 0..<min(a.count, b.count) where a[i].bitPattern != b[i].bitPattern {
            Issue.record("index \(i): \(a[i]) vs \(b[i]) \(note)")
            return
        }
    }

    // MARK: The update

    @Test func anUpdateMovesTheWeightsTowardTheOutcomeAndNeverLowersAPrecision() {
        var model = Ranker.newModel(today: 100)
        let q0 = model.q
        let v = x([(1, 0.8), (2, 0.5)])
        let before = Ranker.predict(model, v, bias: 0.0)
        #expect(Ranker.update(&model, v, r: 1.0, c: 1.0, bias: 0.0) == Ranker.updateApplied)
        #expect(Ranker.predict(model, v, bias: 0.0) > before)
        for i in 0..<Ranker.d { #expect(model.q[i] >= q0[i]) }
        #expect(model.m[5] == Ranker.m0(5))
        #expect(model.updates == 1)
    }

    @Test func aSkipLowersThePredictionAndAPlayWithNoWeightChangesNothing() {
        var model = Ranker.newModel(today: 100)
        let v = x([(1, 0.8), (23, 0.9)])
        let p = Ranker.predict(model, v, bias: 0.0)
        #expect(Ranker.update(&model, v, r: 0.0, c: 0.0, bias: 0.0) == Ranker.updateSkipped)
        #expect(model.isPrior())
        #expect(Ranker.update(&model, v, r: 0.0, c: 1.0, bias: 0.0) == Ranker.updateApplied)
        #expect(Ranker.predict(model, v, bias: 0.0) < p)
    }

    @Test func theStepIsClippedAndEachMeanStaysInsideItsBox() {
        var model = Ranker.newModel(today: 100)
        let v = x([(1, 1.0)])
        let q0 = Ranker.priorPrecision()
        Ranker.update(&model, v, r: 1.0, c: 4.5, bias: -3.0)
        #expect(model.m[1] - Ranker.m0(1) <= Ranker.stepClip + 1e-12)
        for _ in 0..<1000 { Ranker.update(&model, v, r: 1.0, c: 4.5, bias: -3.0) }
        for i in 0..<Ranker.d {
            #expect(model.m[i] <= Ranker.m0(i) + Ranker.boxSd * Ranker.sd0(i) + 1e-12)
            #expect(model.m[i] >= Ranker.m0(i) - Ranker.boxSd * Ranker.sd0(i) - 1e-12)
        }
        #expect(abs(model.m[1] - (Ranker.m0(1) + Ranker.boxSd * Ranker.sd0(1))) < 1e-12)
        #expect(model.q[1] > q0[1])
        for _ in 0..<1000 { Ranker.update(&model, v, r: 0.0, c: 4.5, bias: 3.0) }
        #expect(abs(model.m[1] - (Ranker.m0(1) - Ranker.boxSd * Ranker.sd0(1))) < 1e-12)
    }

    @Test func aNonFiniteWeightAtAnActiveFeatureResetsTheModelItIsNotClamped() {
        for corrupt in [Double.nan, Double.infinity, -Double.infinity] {
            var model = Ranker.newModel(today: 100)
            model.m[0] = corrupt
            #expect(Ranker.update(&model, x([(1, 0.5)]), r: 1.0, c: 1.0, bias: 0.0) == Ranker.updateReset)
            #expect(model.isPrior())
            #expect(model.resets == 1)
            #expect(model.updates == 0)
        }
        var badQ = Ranker.newModel(today: 100)
        badQ.q[3] = -1.0
        #expect(Ranker.update(&badQ, x([(3, 1.0)]), r: 1.0, c: 1.0, bias: 0.0) == Ranker.updateReset)
        #expect(badQ.isPrior())
        var zeroQ = Ranker.newModel(today: 100)
        zeroQ.q[40] = 0.0
        #expect(Ranker.update(&zeroQ, x([(1, 1.0)]), r: 1.0, c: 1.0, bias: 0.0) == Ranker.updateReset)
        var outside = Ranker.newModel(today: 100)
        outside.m[2] = Ranker.m0(2) + 10.0
        #expect(!outside.isValid())
        #expect(Ranker.update(&outside, x([(1, 1.0)]), r: 1.0, c: 1.0, bias: 0.0) == Ranker.updateReset)
        var idle = Ranker.newModel(today: 100)
        idle.m[44] = Double.nan
        #expect(Ranker.update(&idle, x([(1, 1.0)]), r: 1.0, c: 1.0, bias: 0.0) == Ranker.updateReset)
    }

    @Test func anInputThatIsNotFiniteOrIsHugeIsRefusedAndChangesNothing() {
        var model = Ranker.newModel(today: 100)
        let before = model
        #expect(Ranker.update(&model, x([(1, .nan)]), r: 1.0, c: 1.0) == Ranker.updateSkipped)
        #expect(Ranker.update(&model, x([(1, 1.0e8)]), r: 1.0, c: 1.0) == Ranker.updateSkipped)
        #expect(Ranker.update(&model, x([(1, -4.5)]), r: 1.0, c: 1.0) == Ranker.updateSkipped)
        #expect(Ranker.update(&model, x([(1, 1.0)]), r: .nan, c: 1.0) == Ranker.updateSkipped)
        #expect(Ranker.update(&model, x([(1, 1.0)]), r: 1.0, c: .nan) == Ranker.updateSkipped)
        #expect(Ranker.update(&model, x([(1, 1.0)]), r: 1.0, c: 1.0, bias: .infinity) == Ranker.updateSkipped)
        sameBits(before.m, model.m)
        sameBits(before.q, model.q)
        #expect(model.resets == 0)
    }

    @Test func oneHugeButFiniteFeatureIsSkippedInsteadOfWipingTheModel() {
        var model = Ranker.newModel(today: 100)
        for _ in 0..<20 { Ranker.update(&model, x([(1, 0.7), (2, 0.3)]), r: 1.0, c: 1.0) }
        let learned = model
        #expect(Ranker.update(&model, x([(1, 1.0e8)]), r: 1.0, c: 1.0) == Ranker.updateSkipped)
        sameBits(learned.m, model.m)
        #expect(!model.isPrior())
    }

    // MARK: Batch refit

    private struct Data {
        var xs: [[Double]]
        var ys: [Double]
    }

    private let features = [1, 2, 3, 8, 12, 13, 17, 18, 22, 23, 25, 26]

    private func synth(_ n: Int, seed: UInt64, truth: [Double]) -> Data {
        var rng = BrainHash.Rng(seed: seed)
        var xs: [[Double]] = []
        var ys = [Double](repeating: 0.0, count: n)
        for k in 0..<n {
            var v = [Double](repeating: 0.0, count: Ranker.d)
            v[0] = 1.0
            let common = (rng.uniform() - 0.5) * 2.0
            for (j, i) in features.enumerated() {
                v[i] = BrainMath.clip(0.6 * common + 0.8 * (rng.uniform() - 0.5) * 2.0 * (j % 3 == 0 ? 1.0 : 0.8), -2.0, 2.0)
            }
            var z = 0.0
            for i in 0..<Ranker.d { z += truth[i] * v[i] }
            let p = 1.0 / (1.0 + Foundation.exp(-z))
            ys[k] = rng.uniform() < p ? 1.0 : 0.0
            xs.append(v)
        }
        return Data(xs: xs, ys: ys)
    }

    private func logLoss(_ w: [Double], _ d: Data) -> Double {
        var s = 0.0
        for k in d.xs.indices {
            var z = 0.0
            for i in 0..<Ranker.d { z += w[i] * d.xs[k][i] }
            let p = BrainMath.clip(1.0 / (1.0 + Foundation.exp(-z)), 1e-6, 1 - 1e-6)
            s += d.ys[k] > 0.5 ? -Foundation.log(p) : -Foundation.log(1 - p)
        }
        return s / Double(d.xs.count)
    }

    /// MAP with the prior N(M0, SD0^2) by Newton's method over the 13 active weights.
    private func batchMap(_ d: Data) -> [Double] {
        let idx = [0] + features
        let k = idx.count
        var w = (0..<Ranker.d).map { Ranker.m0($0) }
        w[0] = 0.0
        for _ in 0..<25 {
            var g = [Double](repeating: 0.0, count: k)
            var h = [[Double]](repeating: [Double](repeating: 0.0, count: k), count: k)
            for a in 0..<k {
                let i = idx[a]
                g[a] += (w[i] - Ranker.m0(i)) / (Ranker.sd0(i) * Ranker.sd0(i))
                h[a][a] += 1.0 / (Ranker.sd0(i) * Ranker.sd0(i))
            }
            for n in d.xs.indices {
                var z = 0.0
                for i in 0..<Ranker.d { z += w[i] * d.xs[n][i] }
                let p = 1.0 / (1.0 + Foundation.exp(-z))
                for a in 0..<k {
                    g[a] += (p - d.ys[n]) * d.xs[n][idx[a]]
                    for b in 0..<k { h[a][b] += p * (1 - p) * d.xs[n][idx[a]] * d.xs[n][idx[b]] }
                }
            }
            let step = solve(h, g)
            for a in 0..<k { w[idx[a]] -= step[a] }
        }
        return w
    }

    private func solve(_ a: [[Double]], _ b: [Double]) -> [Double] {
        let n = b.count
        var m = a
        var v = b
        for c in 0..<n {
            var piv = c
            var r = c + 1
            while r < n {
                if abs(m[r][c]) > abs(m[piv][c]) { piv = r }
                r += 1
            }
            m.swapAt(c, piv)
            v.swapAt(c, piv)
            r = c + 1
            while r < n {
                let f = m[r][c] / m[c][c]
                for j in c..<n { m[r][j] -= f * m[c][j] }
                v[r] -= f * v[c]
                r += 1
            }
        }
        var out = [Double](repeating: 0.0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = v[r]
            var j = r + 1
            while j < n {
                s -= m[r][j] * out[j]
                j += 1
            }
            out[r] = s / m[r][r]
        }
        return out
    }

    @Test func oneOnlinePassMatchesABatchRefitOnHeldOutLogLoss() {
        var truth = (0..<Ranker.d).map { Ranker.m0($0) }
        var rng = BrainHash.Rng(seed: 77)
        truth[0] = 0.2
        for i in features {
            truth[i] = Ranker.m0(i) + (rng.uniform() < 0.5 ? -1.0 : 1.0) * Ranker.sd0(i) * (0.6 + 0.8 * rng.uniform())
        }
        for n in [200, 1000, 4000] {
            let train = synth(n, seed: UInt64(1000 + n), truth: truth)
            let test = synth(3000, seed: 99, truth: truth)
            var model = Ranker.newModel(today: 0)
            for k in train.xs.indices { Ranker.update(&model, train.xs[k], r: train.ys[k], c: 1.0, bias: 0.0) }
            let online = logLoss(model.m, test)
            let batch = logLoss(batchMap(train), test)
            var priorWeights = Ranker.weights(p0: 0.5)
            priorWeights[0] = 0.0
            let prior = logLoss(priorWeights, test)
            #expect(online < Foundation.log(2.0), "n=\(n) online \(online) below the uninformed")
            #expect(online < prior, "n=\(n) online \(online) beats the prior \(prior)")
            #expect(online <= batch + 0.01, "n=\(n) online \(online) within 0.01 of the batch refit \(batch)")
        }
    }

    // MARK: Forgetting

    private func trained() -> RankerModel {
        var model = Ranker.newModel(today: 1000)
        for k in 0..<25 {
            Ranker.applyEvent(&model, x([(1, 0.9), (2, 0.5), (22, 0.6)]), r: k % 3 == 0 ? 0.0 : 1.0, c: 1.0, bias: 0.0,
                              day: 1000, eventId: Int64(10 + k))
        }
        return model
    }

    @Test func forgettingDoesNotDependOnHowOftenItIsCalled() {
        var once = trained()
        var twice = trained()
        var thrice = trained()
        Ranker.forget(&once, today: 1060)
        Ranker.forget(&twice, today: 1030)
        Ranker.forget(&twice, today: 1060)
        Ranker.forget(&thrice, today: 1010)
        Ranker.forget(&thrice, today: 1045)
        Ranker.forget(&thrice, today: 1060)
        sameBits(once.m, twice.m)
        sameBits(once.q, twice.q)
        sameBits(once.m, thrice.m)
        sameBits(once.q, thrice.q)
        var thirty = trained()
        Ranker.forget(&thirty, today: 1030)
        sameBits(once.q, thirty.q)
        let fresh = trained()
        #expect(once.q[1] < fresh.q[1])
        #expect(abs(once.m[1] - Ranker.m0(1)) < abs(fresh.m[1] - Ranker.m0(1)))
    }

    @Test func aReplayedPlayAndALivePlayForgetTheSame() {
        var live = trained()
        Ranker.forget(&live, today: 1040)
        Ranker.applyEvent(&live, x([(1, 0.9)]), r: 1.0, c: 1.0, bias: 0.0, day: 1050, eventId: 500)
        var replayed = trained()
        Ranker.applyEvent(&replayed, x([(1, 0.9)]), r: 1.0, c: 1.0, bias: 0.0, day: 1050, eventId: 500)
        sameBits(live.m, replayed.m)
        sameBits(live.q, replayed.q)
    }

    @Test func aClockSetBackMakesNoRunAndPullsTheAnchorBack() {
        var model = trained()
        let m = model.m
        let q = model.q
        #expect(Ranker.forget(&model, today: 990) == 0)
        sameBits(m, model.m)
        sameBits(q, model.q)
        #expect(model.anchorDay == 990)
        #expect(Ranker.forget(&model, today: 993) == 3)
        #expect(Ranker.forget(&model, today: 993) == 0)
    }

    @Test func aDayWrittenByAClockThatWasAYearAheadDoesNotStallTheForgetting() {
        var model = trained()
        Ranker.applyEvent(&model, x([(1, 0.5)]), r: 1.0, c: 1.0, bias: 0.0, day: 1000 + 365, eventId: 900)
        #expect(model.anchorDay == 1365)
        Ranker.applyEvent(&model, x([(1, 0.5)]), r: 1.0, c: 1.0, bias: 0.0, day: 1005, eventId: 901)
        #expect(model.anchorDay == 1005)
        #expect(Ranker.forget(&model, today: 1012) == 7)
    }

    @Test func anEventIsAppliedOnce() {
        var model = Ranker.newModel(today: 10)
        #expect(Ranker.applyEvent(&model, x([(1, 1.0)]), r: 1.0, c: 1.0, bias: 0.0, day: 10, eventId: 55) == Ranker.updateApplied)
        let copy = model
        #expect(Ranker.applyEvent(&model, x([(1, 1.0)]), r: 1.0, c: 1.0, bias: 0.0, day: 10, eventId: 55) == Ranker.updateSkipped)
        #expect(Ranker.applyEvent(&model, x([(1, 1.0)]), r: 1.0, c: 1.0, bias: 0.0, day: 10, eventId: 54) == Ranker.updateSkipped)
        sameBits(copy.m, model.m)
        #expect(model.lastEventId == 55)
    }

    // MARK: Reset, weights, seeds

    @Test func aResetReturnsToThePriorAndTheCountOfPlaysStartsAgain() {
        var model = trained()
        #expect(model.updates > 0)
        let mark = model.lastEventId
        model.resetToPrior()
        #expect(model.isPrior())
        #expect(model.updates == 0)
        #expect(model.lastEventId == mark)
        sameBits(Ranker.weights(p0: 0.7), Ranker.weightsFor(model, learned: true, p0: 0.7, seed: nil))
    }

    @Test func theLearnedWeightsCarryTheLiveBiasAndThePriorDoesNotUseThem() {
        let model = trained()
        let learned = Ranker.weightsFor(model, learned: true, p0: 0.75, seed: nil)
        #expect(learned[0] == model.m[0] + Ranker.biasOf(0.75))
        sameBits(Ranker.weights(p0: 0.75), Ranker.weightsFor(model, learned: false, p0: 0.75, seed: nil))
        sameBits(Ranker.weights(p0: 0.75), Ranker.weightsFor(nil, learned: true, p0: 0.75, seed: nil))
        var broken = trained()
        broken.m[5] = Double.nan
        sameBits(Ranker.weights(p0: 0.75), Ranker.weightsFor(broken, learned: true, p0: 0.75, seed: nil))
        let a = Ranker.weightsFor(model, learned: true, p0: 0.75, seed: 42)
        let b = Ranker.weightsFor(model, learned: true, p0: 0.75, seed: 42)
        let c = Ranker.weightsFor(model, learned: true, p0: 0.75, seed: 43)
        sameBits(a, b)
        #expect(a != c)
        #expect(a != learned)
    }

    @Test func aModelAtItsPriorPredictsBitForBitWhatThePriorPredicts() {
        let model = Ranker.newModel(today: 10)
        for p0 in [0.2, 0.5, 0.63, 0.8] {
            let v = x([(1, 0.7), (2, -0.3), (12, 1.0), (22, 0.45), (38, 0.31)])
            #expect(Ranker.predictPrior(v, p0: p0).bitPattern == Ranker.predict(model, v, bias: Ranker.biasOf(p0)).bitPattern)
        }
    }

    @Test func aWeightSourceIsASnapshotAndDoesNotFollowLaterChanges() {
        var model = trained()
        let source = Ranker.WeightSource(model: model, learned: true)
        let before = source.weights(p0: 0.6)
        let precision = source.precision()!
        Ranker.update(&model, x([(1, 1.0), (2, 1.0)]), r: 0.0, c: 4.0)
        model.resetToPrior()
        sameBits(before, source.weights(p0: 0.6))
        sameBits(precision, source.precision()!)
        #expect(source.usesLearned)
        let off = Ranker.WeightSource(model: model, learned: false)
        #expect(!off.usesLearned)
        #expect(off.precision() == nil)
        sameBits(Ranker.weights(p0: 0.6), off.weights(p0: 0.6))
    }

    @Test func aListSeedCannotCollideTheWayASeparatorCould() {
        var seeds: Set<Int64> = []
        for id in ["", "a", "ab", "a\u{1f}", "a\u{1f}b", "daily:1", "daily:1\u{1f}"] {
            for day in [Int64(0), 1, 31, 20_000] { #expect(seeds.insert(Ranker.listSeed(salt: 7, listId: id, localDay: day)).inserted) }
        }
        #expect(Ranker.listSeed(salt: 1, listId: "x", localDay: 5) != Ranker.listSeed(salt: 2, listId: "x", localDay: 5))
        #expect(Ranker.listSeed(salt: 1, listId: "x", localDay: 5) == Ranker.listSeed(salt: 1, listId: "x", localDay: 5))
    }

    @Test func oneSessionInTenIsAControlSession() {
        var control = 0
        for id in Int64(1)...10_000 where Ranker.isControlSession(id) { control += 1 }
        #expect((900...1100).contains(control), "about a tenth: \(control)")
    }

    // MARK: The gate

    private func summary(_ plays: Int, _ learned: Double, _ prior: Double) -> Gate.Summary {
        Gate.Summary(plays: plays, playsTotal: plays, logLossLearned: learned, logLossPrior: prior, accLearned: 0.6,
                     accPrior: 0.55, accLearnedBefore: nil, accPriorBefore: nil)
    }

    @Test func theGateIsOffUntilTheLearnedWeightsWinTwoWeeksRunningAndOffAgainAtOnce() {
        let week: Int64 = 7 * 86_400_000
        let t0: Int64 = 1_700_000_000_000
        var state = Gate.State()
        #expect(!state.useLearned)
        state = Gate.decide(state, summary(500, 0.50, 0.55), nowMs: t0)
        #expect(!state.useLearned)
        #expect(state.winStreak == 1)
        let same = Gate.decide(state, summary(500, 0.50, 0.55), nowMs: t0 + 86_400_000)
        #expect(same.winStreak == 1)
        #expect(!same.useLearned)
        state = Gate.decide(state, summary(500, 0.50, 0.55), nowMs: t0 + week)
        #expect(state.useLearned)
        state = Gate.decide(state, summary(500, 0.50, 0.55), nowMs: t0 + 2 * week)
        #expect(state.useLearned)
        state = Gate.decide(state, summary(500, 0.56, 0.55), nowMs: t0 + 3 * week)
        #expect(!state.useLearned)
        #expect(state.winStreak == 0)
        #expect(!Gate.decide(Gate.State(useLearned: true, winStreak: 3, atMs: t0), summary(500, 0.55, 0.55), nowMs: t0 + week).useLearned)
    }

    @Test func tooFewGradedPlaysKeepThePrior() {
        let s = summary(Gate.minPlays - 1, 0.1, 0.9)
        #expect(!s.learnedBetter)
        #expect(!Gate.decide(Gate.State(useLearned: true, winStreak: 5, atMs: 1), s, nowMs: 10_000_000_000).useLearned)
    }

    @Test func logLossAndAccuracyArePlainFormulas() {
        let p = [0.9, 0.2, 0.5]
        let y = [true, false, true]
        let expected = (-Foundation.log(0.9) - Foundation.log(0.8) - Foundation.log(0.5)) / 3.0
        #expect(abs(Gate.logLoss(p, y, from: 0, to: 3) - expected) < 1e-9)
        #expect(Gate.accuracy(p, [0.5, 0.5, 0.5], y, from: 0, to: 3) == 1.0)
        #expect(Gate.logLoss(p, y, from: 2, to: 2) == 0.0)
        #expect(BrainMath.isFinite(Gate.logLoss([0.0, 1.0], [true, false], from: 0, to: 2)))
        #expect(Gate.shownRate(finished: 5, total: Gate.controlMinPlays - 1) == nil)
        #expect(Gate.shownRate(finished: 150, total: 300) == 0.5)
    }

    // MARK: Saved state

    @Test func theSavedStateReadsBackBitForBitAndABadOneIsRefused() throws {
        let model = trained()
        let saved = LearnerCodec.Saved(model: model, gate: Gate.State(useLearned: true, winStreak: 2, atMs: 1_700_000_000_000),
                                       learnVersion: LearnReplay.version, summary: summary(900, 0.5, 0.55), rebuiltAtMs: 123)
        let text = LearnerCodec.encode(saved)
        let back = try #require(LearnerCodec.decode(text))
        sameBits(model.m, back.model.m)
        sameBits(model.q, back.model.q)
        #expect(model.anchorDay == back.model.anchorDay)
        #expect(model.lastEventId == back.model.lastEventId)
        #expect(model.updates == back.model.updates)
        #expect(back.gate.useLearned)
        #expect(LearnerCodec.encode(back) == text)
        #expect(LearnerCodec.decode(text.replacingOccurrences(of: "brain-learner-v1", with: "other")) == nil)
        #expect(LearnerCodec.decode("{}") == nil)
        #expect(LearnerCodec.decode("") == nil)
        func saving(_ m: RankerModel) -> String {
            LearnerCodec.encode(LearnerCodec.Saved(model: m, gate: Gate.State(), learnVersion: 1, summary: nil, rebuiltAtMs: 0))
        }
        var nan = trained()
        nan.m[7] = Double.nan
        #expect(LearnerCodec.decode(saving(nan)) == nil)
        var zero = trained()
        zero.q[9] = 0.0
        #expect(LearnerCodec.decode(saving(zero)) == nil)
        var outside = trained()
        outside.m[9] = 50.0
        #expect(LearnerCodec.decode(saving(outside)) == nil)
        #expect(LearnerCodec.decode(saving(Ranker.newModel(today: 5))) != nil)
    }

    // MARK: Replay

    @Test func theLearnedReplayBuildsTheSameTablesAsThePlainReplay() {
        for listener in SyntheticListeners.all() {
            let plain = Replay.rebuild(listener.events, facts: .empty, nowMs: listener.nowMs)
            let learned = LearnReplay.run(listener.events, facts: .empty, nowMs: listener.nowMs, likedRids: [])
            #expect(Snapshot.encode(plain) == Snapshot.encode(learned.state), "\(listener.name)")
            #expect(learned.events == listener.events.count)
            #expect(learned.lastEventId == listener.events.last?.eventId)
        }
    }

    @Test func aReplayIsDeterministicAndLearnsSomethingFromAListenerWithATaste() {
        let listener = SyntheticListeners.loyal()
        let a = LearnReplay.run(listener.events, facts: .empty, nowMs: listener.nowMs, likedRids: [])
        let b = LearnReplay.run(listener.events, facts: .empty, nowMs: listener.nowMs, likedRids: [])
        sameBits(a.model.m, b.model.m)
        sameBits(a.model.q, b.model.q)
        #expect(a.model.updates > 1000)
        #expect(!a.model.isPrior())
        #expect(a.model.isValid())
        #expect(a.predictions.prior[0].bitPattern == a.predictions.learned[0].bitPattern)
        #expect(a.predictions.size > 1000)
    }

    @Test func theLearnedWeightsBeatThePriorOnAListenerWhoseTasteThePriorDoesNotKnow() {
        let listener = SyntheticListeners.loyal()
        let run = LearnReplay.run(listener.events, facts: .empty, nowMs: listener.nowMs, likedRids: [])
        let summary = Gate.summarize(run.predictions, nowMs: listener.nowMs)
        #expect(summary.plays <= Gate.window)
        #expect(summary.learnedBetter, "learned \(summary.logLossLearned) against prior \(summary.logLossPrior)")
        let t6 = LearnReplay.test6(run.predictions, resamples: 100)
        #expect(t6.improvement > 0.0)
        if t6.enoughPlays { #expect(t6.passes, "improvement \(t6.improvement), interval \(t6.gainLow)..\(t6.gainHigh)") }
        let week: Int64 = 7 * 86_400_000
        var gate = Gate.decide(Gate.State(), summary, nowMs: listener.nowMs)
        gate = Gate.decide(gate, summary, nowMs: listener.nowMs + week)
        #expect(gate.useLearned)
    }

    @Test func test6KeepsThePriorBelow2000GradedPlays() {
        let listener = SyntheticListeners.loyal()
        let run = LearnReplay.run(Array(listener.events.prefix(600)), facts: .empty, nowMs: listener.nowMs, likedRids: [])
        let t6 = LearnReplay.test6(run.predictions, resamples: 50)
        #expect(!t6.enoughPlays)
        #expect(!t6.passes)
    }

    @Test func test6DoesNotPassWhenTheTwoPredictorsAreTheSame() {
        let n = 2500
        var rng = BrainHash.Rng(seed: 5)
        var p: [Double] = []
        var y: [Bool] = []
        for _ in 0..<n { p.append(0.3 + 0.4 * rng.uniform()) }
        for _ in 0..<n { y.append(rng.uniform() < 0.6) }
        let pred = Gate.Predictions(times: (0..<n).map { Int64($0) }, sessions: (0..<n).map { Int64($0 / 12) }, finished: y,
                                    learned: p, prior: p, threshold: [Double](repeating: 0.5, count: n))
        let t6 = LearnReplay.test6(pred, resamples: 50)
        #expect(t6.improvement == 0.0)
        #expect(!t6.passes)
    }

    @Test func anImportedPlayTrainsTheOriginFeatureButIsPredictedWithoutIt() {
        let e = PlayEvent(eventId: 1, origin: Origin.importSpotify, rid: 5, primaryAid: 6, startedAtMs: 1_700_000_000_000,
                          playedMs: 200_000, durationMs: 200_000, endReason: EndReason.trackDone)
        let run = LearnReplay.run([e], facts: .empty, nowMs: 1_700_000_100_000, likedRids: [])
        #expect(run.model.m[LearnReplay.originBase] != Ranker.m0(LearnReplay.originBase))
        #expect(run.predictions.size == 1)
        #expect(run.predictions.prior[0].bitPattern == run.predictions.learned[0].bitPattern)
    }

    @Test func theLivePathLearnsExactlyWhatTheReplayLearns() {
        let listener = SyntheticListeners.loyal()
        let events = Array(listener.events.prefix(700))
        let now = listener.nowMs
        let replayed = LearnReplay.run(events, facts: .empty, nowMs: now, likedRids: [])
        var affinity = Affinity.State()
        Replay.applyFacts(&affinity, .empty)
        var tracker = GradeTracker()
        var session = SessionState()
        var live = Ranker.newModel(today: LearnReplay.dayOf(events[0], events[0].startedAtMs))
        for e in events {
            if Session.isExpired(session, startedAtMs: e.startedAtMs) { session = SessionState() }
            _ = Session.begin(&session, startedAtMs: e.startedAtMs, startReason: e.startReason)
            var model = live
            Brain.onEvent(affinity: &affinity, tracker: &tracker, session: &session, event: e) { ev, g, aff, sess in
                LearnReplay.applyLive(&model, ev, g, liked: false, affinity: aff, session: sess, nowMs: now)
            }
            live = model
        }
        Ranker.forget(&live, today: BrainMath.localDay(now, tzOffsetMin: 0))
        sameBits(replayed.model.m, live.m)
        sameBits(replayed.model.q, live.q)
        #expect(replayed.model.updates == live.updates)
        #expect(replayed.model.lastEventId == live.lastEventId)
    }

    @Test func playsAtOrBelowTheResetMarkBuildTheTablesButAreNotLearnedFrom() {
        let listener = SyntheticListeners.loyal()
        let events = Array(listener.events.prefix(600))
        let mark = events[399].eventId
        let run = LearnReplay.run(events, facts: .empty, nowMs: listener.nowMs, likedRids: [], tzNowMin: 0, learnAfterEventId: mark)
        let plain = Replay.rebuild(events, facts: .empty, nowMs: listener.nowMs)
        #expect(Snapshot.encode(plain) == Snapshot.encode(run.state))
        #expect(run.predictions.size <= 200)
        #expect(run.model.updates <= 200)
        let none = LearnReplay.run(events, facts: .empty, nowMs: listener.nowMs, likedRids: [], tzNowMin: 0,
                                   learnAfterEventId: events.last!.eventId)
        #expect(none.model.isPrior())
        #expect(none.predictions.size == 0)
    }
}
