import Foundation
import Testing
@testable import PixlLibrary

/// Lanes 3 to 5 inside the one refresh job (docs/brain-spec.md, 3.7): their order, their switches, and that they never
/// double the job. A port of Android's `DnaLanesTest`.
@Suite("DNA lanes")
struct DnaLanesTests {
    final class Work: RefreshWork, @unchecked Sendable {
        private let lock = NSLock()
        var lane3: [DnaTarget]
        var lane4: [DnaTarget]
        var lane5: [DnaTarget]
        var youTubeBudget: Int
        var saves: Bool
        var onEnrich: (@Sendable () -> Void)?
        private var _asked: [String] = []

        init(lane3: [DnaTarget] = [], lane4: [DnaTarget] = [], lane5: [DnaTarget] = [], youTubeBudget: Int = 100, saves: Bool = true) {
            self.lane3 = lane3
            self.lane4 = lane4
            self.lane5 = lane5
            self.youTubeBudget = youTubeBudget
            self.saves = saves
        }

        var asked: [String] { lock.lock(); defer { lock.unlock() }; return _asked }
        func radioSeeds() async -> [RefreshTarget] { [] }
        func artistSeeds() async -> [RefreshTarget] { [] }
        func requestsLeft() async -> Int { youTubeBudget }
        func radio(_ target: RefreshTarget) async -> RefreshFetch { .none }
        func artist(_ target: RefreshTarget) async -> RefreshFetch { .none }

        private func targets(_ lane: Int, _ limit: Int) -> [DnaTarget] {
            lock.lock(); defer { lock.unlock() }
            return Array((lane == 3 ? lane3 : (lane == 4 ? lane4 : lane5)).prefix(limit))
        }

        private func record(_ targets: [DnaTarget]) {
            lock.lock(); defer { lock.unlock() }
            _asked.append("enrich:" + targets.map { String($0.rid) }.joined(separator: ","))
        }

        private func remove(_ targets: [DnaTarget]) {
            lock.lock(); defer { lock.unlock() }
            let gone = Set(targets.map(\.rid))
            lane3.removeAll { gone.contains($0.rid) }
            lane4.removeAll { gone.contains($0.rid) }
            lane5.removeAll { gone.contains($0.rid) }
        }

        func dnaTargets(lane: Int, limit: Int) async -> [DnaTarget] { targets(lane, limit) }

        func enrich(_ targets: [DnaTarget], gate: @Sendable () async -> Bool) async -> DnaEnricher.Report {
            record(targets)
            onEnrich?()
            if !saves { return DnaEnricher.Report(tracks: 0, stopped: false) }
            remove(targets)
            return DnaEnricher.Report(tracks: targets.count, stopped: false)
        }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Bool
        init(_ v: Bool) { self.v = v }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); defer { lock.unlock() }; v = newValue }
        }
    }

    func t(_ rid: Int64) -> DnaTarget { DnaTarget(rid: rid, aid: 0, spotifyId: "sp\(rid)", title: "T\(rid)", artist: "A\(rid)", durationMs: 1) }

    func run(_ work: any RefreshWork, allowed: Flag = Flag(true), playing: Flag = Flag(false), elapsed: Int64 = 0) -> BrainRefreshRunner {
        BrainRefreshRunner(work: work, allowed: { allowed.value }, playing: { playing.value }, elapsedMs: { elapsed })
    }

    @Test func laneThreeComesBeforeLaneFourAndFiveInRoundsOfSixteen() async {
        let work = Work(lane3: (1...20).map { t(Int64($0)) }, lane4: [t(100)], lane5: [t(200)])
        let report = await run(work).run()
        #expect(work.asked == ["enrich:" + (1...16).map(String.init).joined(separator: ","), "enrich:17,18,19,20", "enrich:100", "enrich:200"])
        #expect(report.dnaLane3 == 20)
        #expect(report.dnaLane4 == 1)
        #expect(report.dnaLane5 == 1)
        #expect(report.stopped == .none)
    }

    @Test func theLanesUseNoYouTubeRequestSoASpentYouTubeBudgetDoesNotStopThem() async {
        let work = Work(lane3: [t(1)], youTubeBudget: 0)
        let report = await run(work).run()
        #expect(report.dnaLane3 == 1)
        #expect(report.stopped == .budget, "the YouTube lanes stopped; the DNA lane did not need them")
    }

    @Test func neverWhileMusicPlaysAndNeverWithTheSwitchOff() async {
        let playing = Work(lane3: [t(1)])
        let p = await run(playing, playing: Flag(true)).run()
        #expect(p.stopped == .playing)
        #expect(playing.asked.isEmpty)
        let off = Work(lane3: [t(1)])
        #expect(await run(off, allowed: Flag(false)).run().stopped == .off)
        #expect(off.asked.isEmpty)
    }

    @Test func aSwitchFlippedBetweenRoundsStopsTheNextOne() async {
        let allowed = Flag(true)
        let work = Work(lane3: (1...40).map { t(Int64($0)) })
        work.onEnrich = { allowed.value = false }
        let report = await run(work, allowed: allowed).run()
        #expect(report.stopped == .off)
        #expect(report.dnaLane3 == 16, "the round that was running finished, the next never started")
    }

    @Test func aRoundThatSavedNothingEndsTheLaneInsteadOfAskingAgain() async {
        let work = Work(lane3: (1...5).map { t(Int64($0)) }, saves: false)
        _ = await run(work).run()
        #expect(work.asked.count == 1, "lane 3 asked once; lanes 4 and 5 had nothing")
    }

    @Test func theLanesStopOnTheirOwnBeforeABackgroundTasksTenMinutes() async {
        let work = Work(lane3: (1...40).map { t(Int64($0)) })
        let report = await run(work, elapsed: BrainRefreshRunner.dnaTimeLimitMs + 1).run()
        #expect(report.stopped == .time)
        #expect(work.asked.isEmpty)
    }

    @Test func aWorkWithNoDnaLanesRunsExactlyAsBefore() async {
        struct Plain: RefreshWork {
            func radioSeeds() async -> [RefreshTarget] { [] }
            func artistSeeds() async -> [RefreshTarget] { [] }
            func requestsLeft() async -> Int { 10 }
            func radio(_ target: RefreshTarget) async -> RefreshFetch { .none }
            func artist(_ target: RefreshTarget) async -> RefreshFetch { .none }
        }
        let r = await run(Plain()).run()
        #expect(r.dnaTracks == 0)
        #expect(r.stopped == .none)
    }

    @Test func theNoteOfARunIsReadBackForTheDeveloperScreen() throws {
        let n = try #require(RefreshSchedule.parseNote("1795000000000|r5+3|a1+0|n0+2|m4|d7+8+9|playing"))
        #expect(n.atMs == 1_795_000_000_000)
        #expect(n.radios == 8)
        #expect(n.artists == 1)
        #expect(n.releases == 2)
        #expect(n.tracksEnriched == 24)
        #expect(n.stopped == "playing")
        // A stage 2a note has no DNA part.
        #expect(try #require(RefreshSchedule.parseNote("5|r1+1|a0+0|n0+0|m0|none")).tracksEnriched == 0)
        #expect(RefreshSchedule.parseNote("") == nil)
        #expect(RefreshSchedule.parseNote("garbage") == nil)
    }

    @Test func aRunThatHitItsTimeLimitStillCountsAsTheDaysRun() {
        var report = BrainRefreshRunner.Report(stopped: .time, radiosFetched: 1, radiosCached: 0, artistsFetched: 0, artistsCached: 0, missed: 0)
        report.dnaLane3 = 5
        let note = RefreshSchedule.note(nowMs: 9, report)
        #expect(note == "9|r1+0|a0+0|n0+0|m0|d5+0+0|time")
        #expect(RefreshSchedule.countsAsRun(note: note))
    }
}
