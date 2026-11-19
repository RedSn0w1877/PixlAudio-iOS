// The refresh (docs/brain-spec.md, 3.7, stage 2a): once a day, on an unmetered network, ask YouTube Music for the radios
// of the listener's own tracks and the artist pages of their top artists, so Daily Mix and Your Mix have new music to
// pick from. A port of Android's `BrainRefresh.kt` (its `BrainRefreshRunner`, `AppRefreshWork` and `BrainRefresh`).
//
// iOS has no WorkManager. The app runs this from a `BGProcessingTask` when the system grants one, and otherwise in the
// foreground when the app has been idle for a while; both ask the same `BrainRefresh.run`. Nothing here schedules
// anything and nothing here runs at app start.

import Foundation
import PixlModel

/// What a radio is asked for in the background, with the library track it is asked for.
public struct RefreshTarget: Sendable {
    public var seed: RadioSeed
    public var rid: Int64
    public var artistName: String

    public init(seed: RadioSeed, rid: Int64, artistName: String) {
        self.seed = seed
        self.rid = rid
        self.artistName = artistName
    }
}

public enum RefreshFetch: Sendable, Equatable {
    /// A request went out.
    case network
    /// A fresh list was already in the cache: no request.
    case cached
    /// Nothing came of it (offline, over budget, no radio for the seed).
    case none
}

/// What the refresh needs from the app; the real one reads the files and asks YouTube Music.
public protocol RefreshWork: Sendable {
    /// Lane 1 (3.6, 3.7): the day's radio seeds, best first.
    func radioSeeds() async -> [RefreshTarget]
    /// Lane 2 (3.7): one track for each of the listener's top artists.
    func artistSeeds() async -> [RefreshTarget]
    /// Network requests the brain may still make now, after the reserve the foreground keeps.
    func requestsLeft() async -> Int
    func radio(_ target: RefreshTarget) async -> RefreshFetch
    func artist(_ target: RefreshTarget) async -> RefreshFetch
    /// Lane 2 (3.7, 6.3): the artists whose releases are looked at, the one checked longest ago first. The default is
    /// none, so a work that has no releases lane runs exactly as before.
    func releaseTargets() async -> [RefreshTarget]
    /// One artist's releases: the artist page, the discography when a carousel was full, the tracks of what is new.
    func releases(_ target: RefreshTarget) async -> RefreshFetch
}

public extension RefreshWork {
    func releaseTargets() async -> [RefreshTarget] { [] }
    func releases(_ target: RefreshTarget) async -> RefreshFetch { .none }
}

/// The refresh's rules (3.7), as a plain value so they are unit-tested without the system's scheduler:
///
///  - **Off switches.** `allowed` is asked before the first request and before every one after it: flipping the local
///    or the remote switch stops the run within one fetch.
///  - **Never while music plays** (`playing`): the run stops and the app tries again later.
///  - **Bounded.** One request at a time. It stops when `RefreshWork.requestsLeft` says the daily budget (and the
///    reserve kept for what the listener is doing) is used.
///  - **Idempotent.** A list that is cached and fresh is answered from the cache with no request, so a run that is
///    repeated, resumed or restarted asks for nothing twice.
///  - **Cancellable.** Cancellation is checked between requests and ends the run.
///  - **Only the listener's own music seeds it** (5.12 rule 10): that is `RefreshWork.radioSeeds`' contract.
public struct BrainRefreshRunner: Sendable {
    public enum Stop: Sendable, Equatable {
        case none, off, playing, budget, cancelled
    }

    public struct Report: Sendable, Equatable {
        public var stopped: Stop
        public var radiosFetched: Int
        public var radiosCached: Int
        public var artistsFetched: Int
        public var artistsCached: Int
        public var missed: Int
        public var releasesFetched: Int = 0
        public var releasesCached: Int = 0

        public var fetched: Int { radiosFetched + artistsFetched + releasesFetched }
    }

    private let work: any RefreshWork
    private let allowed: @Sendable () async -> Bool
    private let playing: @Sendable () async -> Bool

    public init(work: any RefreshWork, allowed: @escaping @Sendable () async -> Bool,
                playing: @escaping @Sendable () async -> Bool) {
        self.work = work
        self.allowed = allowed
        self.playing = playing
    }

    private func gate() async -> Stop {
        if Task.isCancelled { return .cancelled }
        if !(await allowed()) { return .off }
        if await playing() { return .playing }
        if await work.requestsLeft() <= 0 { return .budget }
        return .none
    }

    public func run() async -> Report {
        var report = Report(stopped: .none, radiosFetched: 0, radiosCached: 0, artistsFetched: 0, artistsCached: 0, missed: 0)
        report.stopped = await gate()
        if report.stopped == .none {
            for target in await work.radioSeeds() {
                let stop = await gate()
                if stop != .none {
                    report.stopped = stop
                    break
                }
                switch await work.radio(target) {
                case .network: report.radiosFetched += 1
                case .cached: report.radiosCached += 1
                case .none: report.missed += 1
                }
            }
        }
        if report.stopped == .none {
            // Lane 2 of the spec: what is new from the artists the listener plays. It goes before the artist lists below
            // so the daily budget cannot be spent before it is reached; it has its own share.
            for target in await work.releaseTargets() {
                let stop = await gate()
                if stop != .none {
                    report.stopped = stop
                    break
                }
                switch await work.releases(target) {
                case .network: report.releasesFetched += 1
                case .cached: report.releasesCached += 1
                case .none: report.missed += 1
                }
            }
        }
        if report.stopped == .none {
            for target in await work.artistSeeds() {
                let stop = await gate()
                if stop != .none {
                    report.stopped = stop
                    break
                }
                switch await work.artist(target) {
                case .network: report.artistsFetched += 1
                case .cached: report.artistsCached += 1
                case .none: report.missed += 1
                }
            }
        }
        return report
    }
}

/// The app's `RefreshWork`: seeds from `BrainMixes`, radios through `BrainRepository`, one budget.
public struct BrainRefreshWork: RefreshWork {
    /// The worker's share of the day: the foreground (autoplay, stations, Home) has the rest of `HostBudget.dailyLimit`.
    public static let workerDailyCeiling = 40
    /// Tokens of the burst bucket the worker never takes: what the listener is doing right now may need them.
    public static let foregroundReserve = 4

    private let mixes: BrainMixes
    private let repository: BrainRepository
    /// The releases lane's share of the worker's day (6.3, 3.7 lane 2): artist pages, discographies, album playlists.
    public static let releasesDailyCeiling = 14
    /// Artists looked at per run: the top 20 are all covered within about four days, not daily (Android's deviation 101).
    public static let releaseArtistsPerRun = 6

    private let budget: HostBudget?
    private let matchedVideoId: @Sendable (String) async -> String?
    private let clock: @Sendable () -> Int64
    private let newReleases: NewReleases?
    /// The library as it is now: a release's tracks the listener already has are not news to them.
    private let librarySongs: @Sendable () async -> [Song]

    public init(mixes: BrainMixes, repository: BrainRepository, budget: HostBudget?,
                matchedVideoId: @escaping @Sendable (String) async -> String?,
                newReleases: NewReleases? = nil, librarySongs: @escaping @Sendable () async -> [Song] = { [] },
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.newReleases = newReleases
        self.librarySongs = librarySongs
        self.mixes = mixes
        self.repository = repository
        self.budget = budget
        self.matchedVideoId = matchedVideoId
        self.clock = clock
    }

    public func radioSeeds() async -> [RefreshTarget] { await targets(of: await mixes.seedsForRefresh()) }

    public func artistSeeds() async -> [RefreshTarget] { await targets(of: await mixes.topArtistSeeds()) }

    public func requestsLeft() async -> Int {
        let since = clock() - HostBudget.dayMs
        let today = await repository.radiosFetchedSince(since) + (await newReleases?.requestsSince(since) ?? 0)
        let byCeiling = Self.workerDailyCeiling - today
        guard let budget else { return byCeiling }
        let byBucket = await budget.available() - Self.foregroundReserve
        return min(byCeiling, byBucket)
    }

    public func radio(_ target: RefreshTarget) async -> RefreshFetch {
        guard let radio = await repository.radioFor(seed: target.seed, allowNetwork: true) else { return .none }
        return radio.fromCache ? .cached : .network
    }

    public func artist(_ target: RefreshTarget) async -> RefreshFetch {
        guard let radio = await repository.artistRadio(seed: target.seed, allowNetwork: true) else { return .none }
        return radio.fromCache ? .cached : .network
    }

    public func releaseTargets() async -> [RefreshTarget] {
        guard let newReleases else { return [] }
        // The lane's own share of the day: the rest of the worker's requests belong to the radios.
        let since = clock() - HostBudget.dayMs
        if await newReleases.requestsSince(since) >= Self.releasesDailyCeiling { return [] }
        let artists = await artistSeeds()
        let order = await newReleases.checkOrder(artists.map(\.artistName))
        var byKey: [BrainKey: RefreshTarget] = [:]
        for a in artists where byKey[BrainKey(BrainText.fold(a.artistName))] == nil { byKey[BrainKey(BrainText.fold(a.artistName))] = a }
        return Array(order.compactMap { byKey[BrainKey(BrainText.fold($0))] }.prefix(Self.releaseArtistsPerRun))
    }

    public func releases(_ target: RefreshTarget) async -> RefreshFetch {
        guard let newReleases else { return .none }
        let since = clock() - HostBudget.dayMs
        if await newReleases.requestsSince(since) >= Self.releasesDailyCeiling { return .none }
        var channel = await newReleases.channelOf(target.artistName)
        if channel == nil { channel = await repository.artistChannelId(seed: target.seed, allowNetwork: true) }
        guard let channel else { return .none }
        if await newReleases.isFresh(channel) { return .cached }
        let index = BrainLibraryIndex(songs: await librarySongs())
        return await newReleases.check(channelId: channel, artistName: target.artistName) { row in index.match(row) != nil }
    }

    /// A seed without a known YouTube audio id is not a seed: matching it is the matcher's job (3.6).
    private func targets(of picked: [PickedSeed]) async -> [RefreshTarget] {
        var out: [RefreshTarget] = []
        out.reserveCapacity(picked.count)
        for p in picked {
            if let song = p.song {
                var videoId = TrackCatalog.videoId(ofSongId: song.id)
                var spotifyId: String?
                if let id = song.spotifyId, !BrainText.isBlank(id) {
                    if !TrackCatalog.isSyntheticId(id) { spotifyId = id }
                    if videoId == nil { videoId = await matchedVideoId(id) }
                }
                guard let videoId, !BrainText.isBlank(videoId) else { continue }
                out.append(RefreshTarget(
                    seed: RadioSeed(mediaId: song.id, videoId: videoId, title: song.title, primaryArtist: p.artist,
                                    durationMs: song.duration, spotifyId: spotifyId),
                    rid: p.rid, artistName: p.artist))
            } else if let track = p.playable {
                out.append(RefreshTarget(
                    seed: RadioSeed(mediaId: track.songId, videoId: track.videoId, title: track.title, primaryArtist: p.artist,
                                    durationMs: track.durationMs),
                    rid: p.rid, artistName: p.artist))
            }
        }
        return out
    }
}

/// When the refresh runs (3.7). Android has one unique periodic job: 24 hours, unmetered network, battery not low, a
/// random delay of up to 60 minutes. iOS asks the system for a `BGProcessingTask` with the same period and, because the
/// system decides when (or whether) it ever runs, also runs the same work in the foreground once the app has been idle
/// for a while and a day has passed. Never at launch, and only after the brain was first used (a mix was built).
public enum RefreshSchedule {
    /// One run a day.
    public static let periodMs: Int64 = 24 * 60 * 60 * 1000
    /// The random delay added to the first request of a day, so a million phones do not ask at one minute.
    public static let maxDelayMs: Int64 = 60 * 60 * 1000
    /// A foreground run needs the app to have been quiet (no touch, no playback) for this long.
    public static let foregroundIdleMs: Int64 = 90 * 1000
    /// A run that stopped because music played, or found nothing allowed, is tried again no sooner than this.
    public static let retryMs: Int64 = 30 * 60 * 1000

    /// The earliest time the system's task may begin: a day after the last run, and never before `nowMs` plus a
    /// random delay of up to an hour (`unit` is a number in [0, 1)). Never run: now plus the delay.
    public static func earliestBegin(lastRunMs: Int64?, nowMs: Int64, unit: Double) -> Int64 {
        let delay = Int64(BrainMath.floorToLong(BrainMath.clip(unit, 0.0, 0.999999) * Double(maxDelayMs)))
        guard let lastRunMs, lastRunMs > 0, lastRunMs <= nowMs else { return nowMs + delay }
        return max(lastRunMs + periodMs, nowMs) + delay
    }

    /// Whether a foreground run is due: the brain was used, the switches allow it, a day has gone by since the last
    /// run, the last try (if any) is not recent, and the app has been idle long enough.
    public static func foregroundRunDue(nowMs: Int64, lastRunMs: Int64?, lastAttemptMs: Int64?, idleMs: Int64,
                                        brainUsed: Bool, allowed: Bool) -> Bool {
        if !brainUsed || !allowed || idleMs < foregroundIdleMs { return false }
        if let lastRunMs, lastRunMs > 0 {
            let age = nowMs - lastRunMs
            if age >= 0 && age < periodMs { return false }
        }
        if let lastAttemptMs, lastAttemptMs > 0 {
            let since = nowMs - lastAttemptMs
            if since >= 0 && since < retryMs { return false }
        }
        return true
    }

    /// The note of a run (`brain_state` `refresh_last`): the time it finished, and how it went.
    public static func note(nowMs: Int64, _ r: BrainRefreshRunner.Report) -> String {
        let stop: String
        switch r.stopped {
        case .none: stop = "none"
        case .off: stop = "off"
        case .playing: stop = "playing"
        case .budget: stop = "budget"
        case .cancelled: stop = "cancelled"
        }
        return "\(nowMs)|r\(r.radiosFetched)+\(r.radiosCached)|a\(r.artistsFetched)+\(r.artistsCached)"
            + "|n\(r.releasesFetched)+\(r.releasesCached)|m\(r.missed)|\(stop)"
    }

    /// When the last run that got to ask for something finished, from its note; nil for no note.
    public static func lastRunMs(note: String?) -> Int64? {
        guard let note, let first = note.split(separator: "|", omittingEmptySubsequences: false).first else { return nil }
        return Int64(first)
    }

    /// Whether a note says the run was cut short by something that is not a day's work done (the player, the switch):
    /// such a run does not count as the day's run.
    public static func countsAsRun(note: String?) -> Bool {
        guard let note else { return false }
        return !(note.hasSuffix("|playing") || note.hasSuffix("|off") || note.hasSuffix("|cancelled"))
    }
}

/// One run of the refresh with the app's real parts, and the note of how it went (`brain_state` `refresh_last`, for the
/// diagnostics and the handoff's phone checklist).
public struct BrainRefresh: Sendable {
    public static let keyLast = "refresh_last"
    /// The time of the last try, whatever came of it (a retry is not sooner than `RefreshSchedule.retryMs`).
    public static let keyAttempt = "refresh_attempt"

    private let work: any RefreshWork
    private let repository: BrainRepository
    private let engine: BrainEngine
    private let allowed: @Sendable () async -> Bool
    private let clock: @Sendable () -> Int64

    /// `allowed` is the local switch AND the remote one (`BrainRemoteConfig`); it is asked before every request.
    public init(work: any RefreshWork, repository: BrainRepository, engine: BrainEngine,
                allowed: @escaping @Sendable () async -> Bool,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.work = work
        self.repository = repository
        self.engine = engine
        self.allowed = allowed
        self.clock = clock
    }

    /// When the last run that did a day's work finished.
    public func lastRunMs() async -> Int64? {
        let note = await engine.storedValue(Self.keyLast)
        return RefreshSchedule.countsAsRun(note: note) ? RefreshSchedule.lastRunMs(note: note) : nil
    }

    public func lastAttemptMs() async -> Int64? { await engine.storedValue(Self.keyAttempt).flatMap { Int64($0) } }

    public func run(playing: @escaping @Sendable () async -> Bool) async -> BrainRefreshRunner.Report {
        await engine.setStoredValue(Self.keyAttempt, String(clock()))
        // The lists stage 1 left behind become edges, once (3.6); a no-op on every later run.
        await repository.backfillEdgesOnce(nowMs: clock())
        let report = await BrainRefreshRunner(work: work, allowed: allowed, playing: playing).run()
        let now = clock()
        await repository.pruneEdges(nowMs: now)
        await engine.setStoredValue(Self.keyLast, RefreshSchedule.note(nowMs: now, report))
        return report
    }
}
