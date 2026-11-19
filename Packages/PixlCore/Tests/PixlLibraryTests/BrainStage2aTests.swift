import Foundation
import PixlModel
import Testing
@testable import PixlLibrary

private func scratch(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("brain2a-\(label)-\(UUID().uuidString)", isDirectory: true)
}

// MARK: - Spotify Connect and AirPlay (spec 14.6, owner question 7)

/// The trace is in the handoff. In short: AirPlay is a route (the phone still plays and streams the audio, so nothing
/// changes), Spotify Connect plays the phone's queue as Spotify track URIs and skips an entry Spotify does not have.
@Suite("Autoplay on remote outputs")
struct BrainRemoteOutputTests {
    @Test func onThisPhoneAndOnAnAirPlayRouteEverythingRuns() {
        let rule = AutoplayPolicy.remoteRule(.none)
        #expect(rule.picks)
        #expect(!rule.onlyWhatTheOutputPlays)
        #expect(rule.rescore)
        #expect(rule.settleOnLocalPlayer)
    }

    @Test func picksRunOnSpotifyConnectLimitedToWhatSpotifyHasAndTheTailIsNeverReplacedThere() {
        let rule = AutoplayPolicy.remoteRule(.connect)
        #expect(rule.picks)
        #expect(rule.onlyWhatTheOutputPlays)
        // Replacing what the device was told to play means sending it the list again, which is audible.
        #expect(!rule.rescore)
        // The phone's own player sits paused during a session: there is no position to wait for.
        #expect(!rule.settleOnLocalPlayer)
        // The trigger reads the rule: `decide` is asked "is it remote" as "may it not pick".
        #expect(AutoplayPolicy.decide(autoplayEnabled: true, repeatMode: 0, isRemoteSession: !rule.picks, isRestoring: false,
                                      fullQueueSize: 3, currentAbsoluteIndex: 1) == .topUp)
    }

    @Test func oneSwitchTurnsPicksOnSpotifyConnectOffAgain() {
        let rule = AutoplayPolicy.remoteRule(.connect, connectAllowed: false)
        #expect(!rule.picks)
        #expect(AutoplayPolicy.decide(autoplayEnabled: true, repeatMode: 0, isRemoteSession: !rule.picks, isRestoring: false,
                                      fullQueueSize: 1, currentAbsoluteIndex: 0) == .remote)
        #expect(AutoplayPolicy.autoplayOnConnect)
    }

    @Test func onlyThePicksTheOutputAnsweredYesForGoIntoTheQueueInThePlannedOrder() {
        let ids = ["a", "b", "c", "d"]
        #expect(AutoplayPolicy.keepPlayable(mediaIds: ids, playable: [true, false, true, false]) == ["a", "c"])
        #expect(AutoplayPolicy.keepPlayable(mediaIds: ids, playable: [false, false, false, false]).isEmpty)
        // A short answer (the lookup was cut off) keeps nothing it did not answer for.
        #expect(AutoplayPolicy.keepPlayable(mediaIds: ids, playable: [true]) == ["a"])
        #expect(AutoplayPolicy.keepPlayable(mediaIds: ["a", "a"], playable: [true, true]) == ["a"])
    }

    @Test func anIdSpotifyGaveOutPlaysOnConnectWithNoLookupTheAppsOwnIdsDoNot() {
        for (id, expected) in Self.idTable {
            #expect(AutoplayPolicy.isSpotifyTrackId(id) == expected, "\(id ?? "nil")")
        }
    }

    @Test func aPlanLosesTheInOrderPicksTheOutputDoesNotHaveAndKeepsTheRest() {
        func entry(_ id: String, _ rid: Int64) -> AutoplayPoolEntry {
            AutoplayPoolEntry(
                candidate: AutoplayPolicy.Candidate(mediaId: id, rid: rid, artistKey: "a", albumKey: nil, durationMs: 200_000,
                                                    versionFlags: 0, officialAudio: true, inLibrary: false, arm: Arm.radio, radioRank: 1),
                librarySong: nil, engineTrack: nil, whyArtist: "")
        }
        func pick(_ rid: Int64, _ slot: Int32) -> StationPlanner.Pick {
            StationPlanner.Pick(rid: rid, arm: Arm.radio, slot: slot, slotKind: ListBuilder.slotNovel, whyKey: WhyLine.none,
                                whyArg: 0, retrQ: 500, radioRank: 2, key: 1, pQ: 5000, novel: true)
        }
        let plan = StationPlanner.Plan(picks: [pick(1, 0), pick(2, 1), pick(3, 2)], usedLiked: true, usedFamiliarNext: false, poolSize: 40)
        let inputs = AutoplayPlanInputs(candidates: [], prior: [], excludedRids: [], seeds: [], nuMultiplier: 1, nowMs: 0, tzOffsetMin: 0, batch: 0)
        let context = AutoplayPlanContext(inputs: inputs, entriesByRid: [1: entry("yt:a", 1), 2: entry("yt:b", 2), 3: entry("yt:c", 3)])
        let ids = AutoplayPlanning.pickedEntries(plan: plan, context: context).map(\.candidate.mediaId)
        #expect(ids == ["yt:a", "yt:b", "yt:c"])
        let kept = Set(AutoplayPolicy.keepPlayable(mediaIds: ids, playable: [true, false, true]).map(BrainKey.init))
        let narrowed = AutoplayPlanning.narrowed(plan, context: context, kept: kept)
        #expect(narrowed.picks.map(\.rid) == [1, 3])
        #expect(narrowed.usedLiked, "something of the plan was used")
        let none = AutoplayPlanning.narrowed(plan, context: context, kept: [])
        #expect(none.picks.isEmpty && !none.usedLiked && none.poolSize == 40)
    }

    /// The same table `SpotifyConnect.isTrackId` is checked against in PixlNet's tests (`SpotifyConnectIdTests`), so
    /// the two copies of the rule cannot drift apart.
    static let idTable: [(String?, Bool)] = [
        ("4iV5W9uYEdYUVa79Axb7Rh", true),
        // 22 lower-case hex characters: the id the app gives a track saved from YouTube Music.
        ("0123456789abcdef012345", false),
        (nil, false), ("too-short", false), ("4iV5W9uYEdYUVa79Axb7R!", false), ("", false),
        ("ABCDEFGHIJKLMNOPQRSTUV", true), ("4iV5W9uYEdYUVa79Axb7Rhh", false),
    ]
}

// MARK: - The refresh

@Suite("Brain refresh")
struct BrainRefreshTests {
    private final class Work: RefreshWork, @unchecked Sendable {
        private let lock = NSLock()
        let radios: [RefreshTarget]
        let artists: [RefreshTarget]
        private var budget: Int
        private var cache: Set<Int64> = []
        private var asked: [String] = []
        var onRadio: (@Sendable () -> Void)?

        init(radios: [RefreshTarget] = [], artists: [RefreshTarget] = [], budget: Int = 100) {
            self.radios = radios
            self.artists = artists
            self.budget = budget
        }

        var askedList: [String] { lock.withLock { asked } }
        var budgetLeft: Int { lock.withLock { budget } }

        func radioSeeds() async -> [RefreshTarget] { radios }
        func artistSeeds() async -> [RefreshTarget] { artists }
        func requestsLeft() async -> Int { budgetLeft }

        private func take(_ key: String, _ rid: Int64, _ cacheKey: Int64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            asked.append("\(key):\(rid)")
            let hit = cache.contains(cacheKey)
            if !hit {
                cache.insert(cacheKey)
                budget -= 1
            }
            return hit
        }

        func radio(_ target: RefreshTarget) async -> RefreshFetch {
            let hit = take("radio", target.rid, target.rid)
            onRadio?()
            return hit ? .cached : .network
        }

        func artist(_ target: RefreshTarget) async -> RefreshFetch {
            take("artist", target.rid, -target.rid) ? .cached : .network
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var isOn: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    private func target(_ rid: Int64) -> RefreshTarget {
        RefreshTarget(seed: RadioSeed(mediaId: "m\(rid)", videoId: "v\(rid)", title: "T\(rid)", primaryArtist: "A\(rid)",
                                      durationMs: 200_000), rid: rid, artistName: "A\(rid)")
    }

    private func runner(_ work: Work, allowed: Flag = Flag(true), playing: Flag = Flag(false)) -> BrainRefreshRunner {
        BrainRefreshRunner(work: work, allowed: { allowed.isOn }, playing: { playing.isOn })
    }

    @Test func lane1ComesBeforeLane2AndEachSeedIsAskedOnce() async {
        let work = Work(radios: [target(1), target(2)], artists: [target(3)])
        let report = await runner(work).run()
        #expect(work.askedList == ["radio:1", "radio:2", "artist:3"])
        #expect(report.radiosFetched == 2)
        #expect(report.artistsFetched == 1)
        #expect(report.stopped == .none)
    }

    @Test func aSecondRunTheSameDayAsksForNothing() async {
        let work = Work(radios: [target(1), target(2)], artists: [target(3)])
        _ = await runner(work).run()
        let again = await runner(work).run()
        #expect(again.fetched == 0)
        #expect(again.radiosCached == 2)
        #expect(again.artistsCached == 1)
        #expect(work.budgetLeft == 97)
    }

    @Test func itNeverStartsWhenASwitchIsOffAndStopsWithinOneFetchWhenOneIsFlipped() async {
        let work = Work(radios: [target(1), target(2), target(3)])
        let off = await runner(work, allowed: Flag(false)).run()
        #expect(off.stopped == .off)
        #expect(work.askedList.isEmpty)

        let allowed = Flag(true)
        let flip = Work(radios: [target(1), target(2), target(3)])
        flip.onRadio = { allowed.isOn = false }
        let report = await runner(flip, allowed: allowed).run()
        #expect(report.stopped == .off)
        #expect(flip.askedList.count == 1, "the first fetch finished, the second never started")
    }

    @Test func itWaitsWhileMusicPlays() async {
        let work = Work(radios: [target(1)])
        #expect(await runner(work, playing: Flag(true)).run().stopped == .playing)
        #expect(work.askedList.isEmpty)
        let playing = Flag(false)
        let later = Work(radios: [target(1), target(2)])
        later.onRadio = { playing.isOn = true }
        let report = await runner(later, playing: playing).run()
        #expect(report.stopped == .playing)
        #expect(later.askedList.count == 1)
    }

    @Test func itStopsWhenTheDailyBudgetIsSpentWithTheForegroundsReserveAlreadyTakenOff() async {
        let work = Work(radios: (1...10).map { target(Int64($0)) }, budget: 3)
        let report = await runner(work).run()
        #expect(report.stopped == .budget)
        #expect(report.radiosFetched == 3)
        #expect(work.askedList.count == 3)
    }

    @Test func aMissedSeedIsCountedAndDoesNotStopTheRun() async {
        struct Missing: RefreshWork {
            func radioSeeds() async -> [RefreshTarget] {
                [RefreshTarget(seed: RadioSeed(mediaId: "m1", videoId: "v1", title: "t", primaryArtist: "a", durationMs: 1), rid: 1, artistName: "a"),
                 RefreshTarget(seed: RadioSeed(mediaId: "m2", videoId: "v2", title: "t", primaryArtist: "a", durationMs: 1), rid: 2, artistName: "a")]
            }
            func artistSeeds() async -> [RefreshTarget] { [] }
            func requestsLeft() async -> Int { 10 }
            func radio(_ target: RefreshTarget) async -> RefreshFetch { target.rid == 1 ? .none : .network }
            func artist(_ target: RefreshTarget) async -> RefreshFetch { .none }
        }
        let report = await BrainRefreshRunner(work: Missing(), allowed: { true }, playing: { false }).run()
        #expect(report.missed == 1)
        #expect(report.radiosFetched == 1)
    }

    @Test func cancellationEndsTheRunBetweenRequests() async {
        let work = Work(radios: (1...50).map { target(Int64($0)) })
        let task = Task { await self.runner(work).run() }
        task.cancel()
        let report = await task.value
        #expect(report.stopped == .cancelled)
        #expect(work.askedList.count < 50)
    }

    @Test func theRemoteSwitchIsOnUnlessTheConfigSaysItIsOff() {
        #expect(BrainRemoteConfig.refreshAllowed(configText: nil))
        #expect(BrainRemoteConfig.refreshAllowed(configText: ""))
        #expect(BrainRemoteConfig.refreshAllowed(configText: "not json"))
        #expect(BrainRemoteConfig.refreshAllowed(configText: #"{"innertube":{"hedge":{"enabled":false}}}"#))
        #expect(BrainRemoteConfig.refreshAllowed(configText: #"{"brain":{"refresh":{"enabled":true}}}"#))
        #expect(BrainRemoteConfig.refreshAllowed(configText: #"{"brain":{"refresh":{}}}"#))
        #expect(BrainRemoteConfig.refreshAllowed(configText: #"{"schema":1,"innertube":{"hedge":{"afterSeconds":1.5}},"brain":{"refresh":{"enabled":true}}}"#))
        #expect(!BrainRemoteConfig.refreshAllowed(configText: #"{"brain":{"refresh":{"enabled":false}}}"#))
    }

    // MARK: When it runs

    @Test func theSystemsTaskIsADayAfterTheLastRunPlusAtMostAnHour() {
        let now: Int64 = 1_760_000_000_000
        #expect(RefreshSchedule.periodMs == 24 * 60 * 60 * 1000)
        #expect(RefreshSchedule.earliestBegin(lastRunMs: nil, nowMs: now, unit: 0.0) == now)
        #expect(RefreshSchedule.earliestBegin(lastRunMs: nil, nowMs: now, unit: 0.5) == now + 30 * 60 * 1000)
        #expect(RefreshSchedule.earliestBegin(lastRunMs: now - 3_600_000, nowMs: now, unit: 0.0) == now + 23 * 3_600_000)
        // A long-ago run: now, and the delay is at most an hour.
        let late = RefreshSchedule.earliestBegin(lastRunMs: now - 5 * RefreshSchedule.periodMs, nowMs: now, unit: 2.0)
        #expect(late >= now && late <= now + RefreshSchedule.maxDelayMs)
        // A last run in the future (a clock that was set ahead) is ignored.
        #expect(RefreshSchedule.earliestBegin(lastRunMs: now + 1_000_000, nowMs: now, unit: 0.0) == now)
    }

    @Test func aForegroundRunNeedsTheBrainUsedAnIdleAppAndADaySinceTheLast() {
        let now: Int64 = 1_760_000_000_000
        func due(last: Int64? = nil, attempt: Int64? = nil, idle: Int64 = 120_000, used: Bool = true, allowed: Bool = true) -> Bool {
            RefreshSchedule.foregroundRunDue(nowMs: now, lastRunMs: last, lastAttemptMs: attempt, idleMs: idle, brainUsed: used, allowed: allowed)
        }
        #expect(due())
        #expect(!due(used: false), "never before a mix was built")
        #expect(!due(allowed: false))
        #expect(!due(idle: 10_000))
        #expect(!due(last: now - 3_600_000))
        #expect(due(last: now - RefreshSchedule.periodMs))
        #expect(!due(last: now - RefreshSchedule.periodMs, attempt: now - 60_000), "a try that stopped early is not repeated at once")
        #expect(due(last: now - RefreshSchedule.periodMs, attempt: now - RefreshSchedule.retryMs))
    }

    @Test func theNoteSaysHowTheRunWentAndAStoppedRunIsNotTheDaysRun() {
        let report = BrainRefreshRunner.Report(stopped: .none, radiosFetched: 3, radiosCached: 2, artistsFetched: 1, artistsCached: 0, missed: 4)
        let note = RefreshSchedule.note(nowMs: 123_456, report)
        #expect(note == "123456|r3+2|a1+0|n0+0|m4|none")
        #expect(RefreshSchedule.lastRunMs(note: note) == 123_456)
        #expect(RefreshSchedule.countsAsRun(note: note))
        var playing = report
        playing.stopped = .playing
        #expect(!RefreshSchedule.countsAsRun(note: RefreshSchedule.note(nowMs: 1, playing)))
        var budget = report
        budget.stopped = .budget
        #expect(RefreshSchedule.countsAsRun(note: RefreshSchedule.note(nowMs: 1, budget)))
        #expect(RefreshSchedule.lastRunMs(note: nil) == nil)
        #expect(!RefreshSchedule.countsAsRun(note: nil))
    }
}

// MARK: - The new record files

@Suite("Brain stage 2a record files")
struct BrainStage2aStoreTests {
    // MARK: Graph edges

    @Test func anEdgeWeighsWhatTheGraphBuilderGivesTheSameRowToSixteenBits() {
        var builder = Graph.Builder()
        let rids: [Int64] = [11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
        builder.addList(seed: 1, rids: rids, factor: Graph.radio)
        builder.addList(seed: 2, rids: rids, factor: Graph.related)
        let graph = builder.build()
        for type in [GraphEdgeStore.typeRadio, GraphEdgeStore.typeRelated] {
            let seed: Int64 = type == GraphEdgeStore.typeRadio ? 1 : 2
            for (i, rid) in rids.enumerated() {
                let stored = Double(GraphEdgeStore.weightQ16(type: type, rank: i + 1)) / GraphEdgeStore.weightUnit
                #expect(abs(stored - graph.edgeWeight(seed, rid)) <= 1.0 / GraphEdgeStore.weightUnit, "type \(type) rank \(i + 1)")
            }
        }
    }

    @Test func aListIsStoredAsEdgesAndAFetchOfTheSameSeedReplacesThem() {
        let directory = scratch("edges")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GraphEdgeStore(directory: directory)
        store.record(seedRid: 1, kind: RadioList.kindSong, rids: [10, 11, 12, 0, 1, 11], nowMs: 1_000)
        #expect(store.count == 3, "no zero, no seed, no repeat")
        store.record(seedRid: 1, kind: RadioList.kindSong, rids: [12, 13], nowMs: 2_000)
        #expect(store.count == 2)
        // The Related tab of the same seed is its own set of edges.
        store.record(seedRid: 1, kind: RadioList.kindRelated, rids: [20, 21], nowMs: 2_000)
        #expect(store.count == 4)
        let edges = store.edgesFor([13])
        #expect(edges.count == 1 && edges[0].a == 1 && edges[0].b == 13)
        #expect(abs(edges[0].weight - Double(GraphEdgeStore.weightQ16(type: GraphEdgeStore.typeRadio, rank: 2)) / 65_536.0) < 1e-12)
        // A node at either end finds the edge, once.
        #expect(store.edgesFor([1, 13]).count == 4, "the seed touches all four; the edge to 13 is counted once")
    }

    @Test func theEdgesComeBackAfterARestartAndOldOnesArePruned() {
        let directory = scratch("edges-restart")
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = Repetition.dayMs
        let first = GraphEdgeStore(directory: directory)
        first.record(seedRid: 1, kind: RadioList.kindSong, rids: [10, 11], nowMs: 1_000)
        first.record(seedRid: 2, kind: RadioList.kindSong, rids: [20, 21], nowMs: 1_000 + 29 * day)
        first.markBackfilled(nowMs: 5)
        let second = GraphEdgeStore(directory: directory)
        #expect(second.count == 4)
        #expect(second.isBackfilled)
        #expect(second.prune(nowMs: 1_000 + 31 * day) == 2, "the first list is older than 30 days")
        #expect(second.count == 2)
        #expect(GraphEdgeStore(directory: directory).count == 2, "the removal is on disk")
    }

    @Test func aStageOneInstallHasNoGraphFileAndAFutureRecordIsSkippedNotDeleted() throws {
        let directory = scratch("edges-tolerant")
        defer { try? FileManager.default.removeItem(at: directory) }
        // No file at all: an empty graph, not a failure.
        let empty = GraphEdgeStore(directory: directory)
        #expect(empty.count == 0 && !empty.isBackfilled && empty.edgesFor([1, 2]).isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A file with a record of a version this code does not know, a torn one and a good one.
        let text = "1|10|1\t{\"r\":1,\"t\":1,\"v\":99,\"w\":100}\n1|11|1\t{\"r\":2,\"t\":1,\"v\":1,\"w\":200}\n1|12|1\tnot json\n1|13|"
        try text.write(to: directory.appendingPathComponent("graph_edge.pbl"), atomically: true, encoding: .utf8)
        let store = GraphEdgeStore(directory: directory)
        #expect(store.count == 1)
        #expect(store.edgesFor([1]).map(\.b) == [11])
    }

    @Test func oldRadioListsBecomeEdgesOnceWithTheAgeOfTheirList() async throws {
        let directory = scratch("backfill")
        defer { try? FileManager.default.removeItem(at: directory) }
        // A stage 1 install: radio lists, no graph file. (The tables are written the way stage 1 wrote them.)
        let tables = BrainTables(directory: directory)
        let rows: [StoredRadioRow] = (1...5).map { i in
            StoredRadioRow(row: RadioRow(videoId: "vid\(i)", title: "Song \(i)", artists: [RadioArtistRef(name: "Artist", channelId: nil)],
                                         durationSec: 200, kind: .atv), rid: 100 + Int64(i))
        }
        tables.upsertRadio(RadioList(seedRid: 7, kind: RadioList.kindSong, chip: "", fetchedAt: 5_000, lastUsedAt: 5_000, healthy: true, rows: rows, chips: []))
        tables.upsertRadio(RadioList(seedRid: 8, kind: RadioList.kindRelated, chip: "", fetchedAt: 6_000, lastUsedAt: 6_000, healthy: true, rows: rows, chips: []))
        tables.upsertRadio(RadioList(seedRid: 9, kind: RadioList.kindArtist, chip: BrainRepository.artistStationChip, fetchedAt: 6_000,
                                     lastUsedAt: 6_000, healthy: true, rows: rows, chips: []))
        tables.upsertRadio(RadioList(seedRid: 10, kind: RadioList.kindSong, chip: "", fetchedAt: 6_000, lastUsedAt: 6_000, healthy: false, rows: [], chips: []))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("graph_edge.pbl").path))

        let repository = BrainRepository(directory: directory, radioSource: nil, clock: { 1_000_000 })
        await repository.backfillEdgesOnce(nowMs: 1_000_000)
        #expect(await repository.edgeCount() == 10, "two lists of five; not the artist station's, not the junk marker")
        let edges = await repository.edgesFor([7])
        #expect(edges.count == 5 && Set(edges.map(\.a)) == [7])
        // Once: a second run changes nothing, even when a list changed meanwhile.
        tables.upsertRadio(RadioList(seedRid: 11, kind: RadioList.kindSong, chip: "", fetchedAt: 6_000, lastUsedAt: 6_000, healthy: true, rows: rows, chips: []))
        let again = BrainRepository(directory: directory, radioSource: nil, clock: { 1_000_000 })
        await again.backfillEdgesOnce(nowMs: 2_000_000)
        #expect(await again.edgeCount() == 10)
        // The edges keep the age of the list: 5,000 is far older than 30 days before 100 days.
        #expect(await again.pruneEdges(nowMs: 100 * Repetition.dayMs) == 10)
    }

    // MARK: The served log and the saved mixes

    private func mix(kind: Int32, at ms: Int64, rids: [Int64], outside: Set<Int64> = []) -> StoredMix {
        StoredMix(kind: kind, builtAtMs: ms, seed: 42, novelty: Novelty.blend, tasteSignature: "sig", seedLists: 2,
                  items: rids.enumerated().map { i, rid in
            outside.contains(rid)
                ? StoredMixItem(rid: rid, row: StoredRadioRow(row: RadioRow(videoId: "v\(rid)", title: "T\(rid)", artists: [RadioArtistRef(name: "A", channelId: nil)], durationSec: 200, kind: .atv), rid: rid), arm: Arm.radio, slot: i, whyKey: WhyLine.radioFans, whyArg: 5, whyName: "Fans", retrQ: 400, radioRank: 3)
                : StoredMixItem(rid: rid, songId: "song\(rid)", arm: Arm.fav, slot: i)
        })
    }

    @Test func aSavedMixIsTodaysUntilTheFourOClockRolloverAndComesBackAfterARestart() {
        let directory = scratch("served")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tz: Int32 = 60
        // 2025-01-10 14:00 local (UTC+1).
        let noon: Int64 = 1_736_514_000_000
        let store = ServedListStore(directory: directory)
        let recId = store.put(surface: Surface.dailyMix, surfaceId: "daily", mix: mix(kind: 0, at: noon, rids: [1, 2, 3], outside: [2]),
                              nuQ: 250, nowMs: noon)
        #expect(recId == ServedListStore.recIdOf(builtAtMs: noon, surface: Surface.dailyMix))
        let back = ServedListStore(directory: directory)
        let todays = back.todays(surface: Surface.dailyMix, nowMs: noon + 3_600_000, tzOffsetMin: tz)
        #expect(todays?.items.map(\.rid) == [1, 2, 3])
        #expect(todays?.items[1].isOutsideLibrary == true && todays?.items[1].row?.row.videoId == "v2")
        #expect(todays?.items[0].songId == "song1")
        // The other surface has nothing; the same surface after 04:00 the next local day is a new day.
        #expect(back.todays(surface: Surface.yourMix, nowMs: noon, tzOffsetMin: tz) == nil)
        #expect(back.todays(surface: Surface.dailyMix, nowMs: noon + 13 * 3_600_000, tzOffsetMin: tz) != nil, "03:00 the next day is still the same day")
        #expect(back.todays(surface: Surface.dailyMix, nowMs: noon + 15 * 3_600_000, tzOffsetMin: tz) == nil, "05:00 the next day is not")
        #expect(back.buildsToday(surface: Surface.dailyMix, nowMs: noon, tzOffsetMin: tz) == 1)
    }

    @Test func theNewestBuildOfTheDayWinsAndEveryBuildCountsForRegenerate() {
        let directory = scratch("served-regen")
        defer { try? FileManager.default.removeItem(at: directory) }
        let noon: Int64 = 1_736_514_000_000
        let store = ServedListStore(directory: directory)
        store.put(surface: Surface.yourMix, surfaceId: "your", mix: mix(kind: 1, at: noon, rids: [1, 2]), nuQ: 200, nowMs: noon)
        store.put(surface: Surface.yourMix, surfaceId: "your", mix: mix(kind: 1, at: noon + 1_000, rids: [3, 4]), nuQ: 200, nowMs: noon + 1_000)
        #expect(store.todays(surface: Surface.yourMix, nowMs: noon + 2_000, tzOffsetMin: 0)?.items.map(\.rid) == [3, 4])
        #expect(store.buildsToday(surface: Surface.yourMix, nowMs: noon + 2_000, tzOffsetMin: 0) == 2)
        // A build "from the future" (a clock that was set back since) is not today's.
        #expect(store.todays(surface: Surface.yourMix, nowMs: noon - 3_600_000, tzOffsetMin: 0) == nil)
    }

    @Test func theLogIsKeptSixtyDaysAndTheBudgetReadsItBack() {
        let directory = scratch("served-retention")
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = Repetition.dayMs
        let start: Int64 = 1_736_514_000_000
        let store = ServedListStore(directory: directory)
        store.put(surface: Surface.dailyMix, surfaceId: "daily", mix: mix(kind: 0, at: start, rids: [1, 2]), nuQ: 250, nowMs: start)
        store.put(surface: Surface.dailyMix, surfaceId: "daily", mix: mix(kind: 0, at: start + 40 * day, rids: [2, 3]), nuQ: 250, nowMs: start + 40 * day)
        #expect(store.count == 2)
        // 61 days after the first one the write prunes it.
        store.put(surface: Surface.yourMix, surfaceId: "your", mix: mix(kind: 1, at: start + 61 * day, rids: [9]), nuQ: 200, nowMs: start + 61 * day)
        #expect(store.count == 2)
        let reopened = ServedListStore(directory: directory)
        let recent = reopened.recent(nowMs: start + 61 * day)
        #expect(recent.map(\.rids) == [[2, 3], [9]])
        // Within 30 days only the list of day 40 and day 61 count for "times served".
        #expect(Repetition.timesServed(recent, nowMs: start + 61 * day) == [2: 1, 3: 1, 9: 1])
    }

    @Test func aMixRecordOfAFutureVersionOrWithMissingFieldsIsReadTolerantly() throws {
        // Fields a later stage adds are read with a default; a version this code does not know is not a mix.
        let json = #"{"v":1,"kind":0,"builtAtMs":5,"items":[{"rid":3,"songId":"s"}]}"#
        let decoded = try JSONDecoder().decode(StoredMix.self, from: Data(json.utf8))
        #expect(decoded.novelty == Novelty.blend && decoded.seedLists == 0 && decoded.items[0].slot == -1 && decoded.items[0].arm == Arm.none)
        let directory = scratch("served-future")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let future = #"{"builtAt":1736514000000,"mix":{"v":1,"kind":0,"builtAtMs":1736514000000,"items":[]},"modelVersion":2,"nuQ":250,"recId":7,"rids":[],"seed":1,"surface":1,"surfaceId":"daily","v":99}"#
        try ("7\t" + future + "\n").write(to: directory.appendingPathComponent("served_list.pbl"), atomically: true, encoding: .utf8)
        let store = ServedListStore(directory: directory)
        #expect(store.count == 0)
        #expect(store.todays(surface: Surface.dailyMix, nowMs: 1_736_514_000_000, tzOffsetMin: 0) == nil)
    }

    // MARK: Feedback

    @Test func feedbackRecordsAreKeptUndoneAndReadBackAndNothingWritesThemYet() {
        let directory = scratch("feedback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FeedbackStore(directory: directory)
        #expect(store.active().isEmpty)
        #expect(store.insert(FeedbackStore.Record(id: 2, kind: 1, targetKind: 0, targetId: 55, createdAtMs: 200)))
        #expect(store.insert(FeedbackStore.Record(id: 1, kind: 1, targetKind: 0, targetId: 56, createdAtMs: 100)))
        #expect(store.active().map(\.id) == [1, 2])
        #expect(store.undo(id: 1, nowMs: 300))
        #expect(!store.undo(id: 1, nowMs: 400), "already undone")
        let reopened = FeedbackStore(directory: directory)
        #expect(reopened.active().map(\.id) == [2])
        #expect(reopened.count == 2, "an undone record stays: feedback is truth")
    }

    // MARK: The engine switch

    @Test func theBrainOwnsTheMixesOnlyWhenItIsOnAndHasHeardTenDifferentTracks() {
        #expect(BrainEngineChoice.useBrain(engine: BrainEngineChoice.brain, hasState: true))
        #expect(!BrainEngineChoice.useBrain(engine: BrainEngineChoice.legacy, hasState: true))
        #expect(!BrainEngineChoice.useBrain(engine: BrainEngineChoice.brain, hasState: false))
        #expect(BrainEngineChoice.clamp(7) == BrainEngineChoice.brain, "anything but 0 is the brain")
        #expect(BrainEngineChoice.clamp(-1) == BrainEngineChoice.brain)
        #expect(BrainEngineChoice.clamp(0) == BrainEngineChoice.legacy)
        #expect(!BrainEngineChoice.hasState(heardTracks: 9))
        #expect(BrainEngineChoice.hasState(heardTracks: 10))
    }

    @Test func theSeedQueriesReadTheLastWeeksOfTheLog() {
        let now: Int64 = 1_760_000_000_000
        let day = Repetition.dayMs
        func event(_ rid: Int64, _ aid: Int64, daysAgo: Int64, arm: Int32 = Arm.none, end: Int32 = EndReason.trackDone,
                   played: Int32 = 200_000, flags: Int32 = 0) -> PlayEvent {
            PlayEvent(eventId: (now - daysAgo * day) << 16 | rid, origin: Origin.live, rid: rid, primaryAid: aid,
                      startedAtMs: now - daysAgo * day, playedMs: played, durationMs: 200_000, endReason: end,
                      flags: flags, arm: arm)
        }
        let events = [
            event(1, 10, daysAgo: 1),
            event(1, 10, daysAgo: 3),
            event(2, 20, daysAgo: 2, arm: Arm.radio),
            event(3, 30, daysAgo: 2, arm: Arm.radio, flags: EventFlags.likedDuring),
            event(4, 40, daysAgo: 2, end: EndReason.next, played: 5_000),
            event(5, 50, daysAgo: 2, flags: EventFlags.neverAudible),
            event(6, 60, daysAgo: 20),
            event(7, 70, daysAgo: 4, played: 20_000),
            event(8, 80, daysAgo: 5, arm: Arm.radio, flags: EventFlags.savedDuring),
        ]
        let chosen = SeedQueries.recentChosen(events, sinceMs: now - 14 * day, limit: 40)
        #expect(chosen.map(\.rid) == [1, 3, 8], "own plays and liked or saved picks finished in 14 days: not a pick, a skip, a silent play, an old one or a short one")
        #expect(chosen[0].lastMs == now - day)
        let saved = SeedQueries.recentlySaved(events, sinceMs: now - 30 * day, limit: 20)
        #expect(saved.map(\.rid) == [3, 8], "newest first")
        #expect(SeedQueries.recentChosen(events, sinceMs: now - 14 * day, limit: 1).count == 1)
    }
}
