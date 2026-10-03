import Foundation
import Observation
import PixlLibrary
import PixlModel

/// Everything Home shows, computed together off the main thread (Android: `HomeDiscoveryStateHolder`,
/// `DailyMixStateHolder`, `HomeGreetingStateHolder`, `StatsViewModel.homeOverview` and the recently-played
/// mapping in `HomeScreen`). One value, replaced atomically when the library or the history changes.
nonisolated struct HomeContent: Sendable, Equatable {
    var greeting = HomeGreeting(headline: HomeLogic.localHeadline(hour: 12, topArtist: nil, topGenre: nil),
                                subtitle: HomeLogic.defaultSubtitle)
    /// The inputs of the expanded greeting insight (Android `expandInsight`, local fallback).
    var insight = ""
    /// "Made for your listening" (`HomeRecommendationPlanner` mixes).
    var mixes: [HomeMusicSection] = []
    /// The discovery shelves under Your Mix.
    var shelves: [HomeMusicSection] = []
    /// Daily Mix (30, day-seeded) and the curated Your Mix (60).
    var dailyMix: [Song] = []
    var curatedYourMix: [Song] = []
    /// `homeMixPreviewSongs`: the 48 newest songs ("Just added", and the Your Mix fallback).
    var recentlyAdded: [Song] = []
    /// `playbackHistory` (newest first) and the Home recently played list (64 songs).
    var history: [PlaybackHistoryEntry] = []
    var recentlyPlayed: [RecentlyPlayedItem] = []
    /// `homeOverview`: the first of week / month / year / all with listening activity.
    var statsOverview: PlaybackStatsSummary?

    /// Android's Your Mix chain: curated → daily → newest songs.
    var yourMix: [Song] {
        if !curatedYourMix.isEmpty { return curatedYourMix }
        if !dailyMix.isEmpty { return dailyMix }
        return recentlyAdded
    }

    /// The fallback mix plays from the library, not as a mix queue.
    var usesFallbackYourMix: Bool { curatedYourMix.isEmpty && dailyMix.isEmpty }
}

/// A background job for the jobs button and sheet (Android `PixelPlayJob`).
nonisolated struct HomeJob: Sendable, Equatable, Identifiable {
    nonisolated enum State: Sendable, Equatable { case running, queued, finished }
    var id: String
    var label: String
    var detail: String?
    /// 0…100 when known.
    var percent: Int?
    var state: State
}

/// The Home tab's state holder. Lives in `AppEnvironment` (process-scoped like Android's `@Singleton` holders),
/// so Home keeps its snapshot across navigation.
@Observable
final class HomeStore {
    private(set) var content = HomeContent()
    /// True until the first computation finished (Android's Your Mix loading placeholder).
    private(set) var isPreparing = true
    /// The "Made for your listening" refresh button is spinning.
    private(set) var isRefreshing = false
    /// The greeting card's expand state (Android `homeGreetingExpandedInsight` / `isLoadingHomeGreetingInsight`).
    private(set) var isInsightExpanded = false
    /// UI-test jobs (the real ones come from the library import, see `jobs(libraryProgress:)`).
    private(set) var demoJobs: [HomeJob] = []

    let history: ListeningHistoryStore
    private let defaults: UserDefaults?
    @ObservationIgnored private var lastKey: Key?
    @ObservationIgnored private var computeTask: Task<Void, Never>?
    /// Music intelligence: the learned signals (Android `tasteRepository.signals()`) and the exploration setting,
    /// set by `AppEnvironment` (nil / 0.25 for previews).
    @ObservationIgnored var taste: MusicTasteStore?
    @ObservationIgnored var explorationFraction: () -> Float = { 0.25 }

    /// What a computation depends on; a refresh with the same key is skipped (Android throttles repeat passes).
    /// The library by its revision (comparing two snapshots walked the whole library on the main actor).
    private struct Key: Equatable {
        var libraryRevision: Int
        var revision: Int
        var epochDay: Int64
        var tasteRevision: Int
        var exploration: Float
        var learning: Bool
    }

    init(history: ListeningHistoryStore, defaults: UserDefaults?, demoJobs: [HomeJob] = []) {
        self.history = history
        self.defaults = defaults
        self.demoJobs = demoJobs
    }

    /// The store for a launch: UI tests get the demo history, a pinned clock, no persistence and two demo jobs.
    static func make(launch: LaunchConfiguration) -> HomeStore {
        if launch.isUITest {
            let clock = HomeClock.uiTest
            let history = ListeningHistoryStore(
                clock: clock, file: nil,
                seed: DemoListeningHistory.events(songs: DemoLibrary.songs, nowMs: clock.nowMs()))
            return HomeStore(history: history, defaults: nil, demoJobs: [
                HomeJob(id: "align", label: "Syncing lyrics word by word", detail: "Neon Harbor", percent: 64,
                        state: .running),
                HomeJob(id: "match", label: "Matching Spotify tracks", detail: nil, percent: nil, state: .queued),
            ])
        }
        let history = ListeningHistoryStore(clock: .live, file: ListeningHistoryFile.defaultURL().map(ListeningHistoryFile.init))
        return HomeStore(history: history, defaults: .standard)
    }

    /// Jobs shown by the top bar and the jobs sheet.
    func jobs(libraryProgress: LibraryImportProgress?) -> [HomeJob] {
        var jobs = demoJobs
        if let progress = libraryProgress, progress.total > 0, progress.completed < progress.total {
            jobs.insert(HomeJob(id: "library", label: "Syncing your library", detail: progress.phase,
                                percent: Int((progress.fraction * 100).rounded()), state: .running), at: 0)
        }
        return jobs
    }

    // MARK: Refresh

    /// Recomputes when the library (`libraryRevision`), the history or the day changed (`force` = the refresh
    /// button).
    func refresh(snapshot: LibrarySnapshot, libraryRevision: Int, force: Bool = false) async {
        await history.ensureLoaded()
        await taste?.ensureLoaded()
        let clock = history.clock
        let now = clock.nowMs()
        let epochDay = ZoneClock(clock.timeZone).localDate(at: now).epochDay
        let signals = taste?.learnedSignals ?? [:]
        let exploration = explorationFraction()
        let key = Key(libraryRevision: libraryRevision, revision: history.revision, epochDay: epochDay,
                      tasteRevision: taste?.revision ?? 0, exploration: exploration, learning: !signals.isEmpty)
        if !force, key == lastKey { return }
        lastKey = key
        computeTask?.cancel()
        if force { isRefreshing = true }

        let events = history.events
        let saved = savedMixes(epochDay: epochDay, zone: clock.timeZone)
        let task = Task.detached(priority: .userInitiated) {
            HomeStore.compute(snapshot: snapshot, events: events, nowMs: now, timeZone: clock.timeZone,
                              savedDaily: saved.daily, savedYourMix: saved.yourMix, storedSignals: signals,
                              exploration: exploration)
        }
        let stamp = ScreenDataCache.Stamp(historyRevision: history.revision, songCount: snapshot.songs.count)
        let computation = Task { [weak self] in
            let result = await task.value
            guard let self, !Task.isCancelled else { return }
            // The overview card's week summary seeds Stats' default range.
            if let overview = result.content.statsOverview, overview.range == .week {
                ScreenDataCache.storeStats(overview, stamp: stamp)
            }
            if result.content != self.content { self.content = result.content }
            if result.generatedMixes { self.saveMixes(result.content, nowMs: now) }
            self.isPreparing = false
            self.isRefreshing = false
        }
        computeTask = computation
        await computation.value
    }

    func toggleInsight() { isInsightExpanded.toggle() }

    /// Android `regenerateYourMix`: a fresh, non-day-seeded draw, so repeated taps give a different mix.
    func regenerateYourMix(snapshot: LibrarySnapshot) async {
        await history.ensureLoaded()
        await taste?.ensureLoaded()
        let events = history.events
        let now = history.clock.nowMs()
        let seed = Int64.random(in: Int64.min...Int64.max)
        let signals = taste?.learnedSignals ?? [:]
        let exploration = explorationFraction()
        let mix = await Task.detached(priority: .userInitiated) { () -> [Song] in
            let songs = snapshot.songs
            guard !songs.isEmpty else { return [] }
            return DailyMix.personalizedPicks(
                allSongs: songs, favoriteSongIds: Set(songs.filter(\.isFavorite).map(\.id)),
                engagements: HomeStore.engagementStats(events), storedSignals: signals, exploration: exploration,
                nowMs: now, limit: 60, seed: seed).map(\.song)
        }.value
        guard !mix.isEmpty else { return }
        content.curatedYourMix = mix
        defaults?.set(mix.map(\.id), forKey: PreferenceKeys.yourMixSongIds)
    }

    /// Settings › Developer › Regenerate Daily Mix and Music intelligence › Refresh (Android `regenerateDailyMix` /
    /// `enqueueDailyMixRefresh`): today's saved picks are dropped and the mixes are drawn again.
    func regenerateDailyMix(snapshot: LibrarySnapshot, libraryRevision: Int) async {
        defaults?.removeObject(forKey: PreferenceKeys.dailyMixSongIds)
        defaults?.removeObject(forKey: PreferenceKeys.yourMixSongIds)
        defaults?.removeObject(forKey: PreferenceKeys.lastDailyMixUpdate)
        await refresh(snapshot: snapshot, libraryRevision: libraryRevision, force: true)
    }

    /// Music intelligence › Preview recommendations (Android `MusicIntelligenceViewModel.preview`): ranks the real
    /// library with the real inputs — playback and the queue are untouched — and saves the report.
    func previewRecommendations(snapshot: LibrarySnapshot) async {
        await history.ensureLoaded()
        await taste?.ensureLoaded()
        let events = history.events
        let now = history.clock.nowMs()
        let signals = taste?.learnedSignals ?? [:]
        let exploration = explorationFraction()
        let epochDay = ZoneClock(history.clock.timeZone).localDate(at: now).epochDay
        let report = await Task.detached(priority: .userInitiated) { () -> String in
            let songs = snapshot.songs
            let start = Date()
            let picks = DailyMix.personalizedPicks(
                allSongs: songs, favoriteSongIds: Set(songs.filter(\.isFavorite).map(\.id)),
                engagements: HomeStore.engagementStats(events), storedSignals: signals, exploration: exploration,
                nowMs: now, limit: 30, seed: DailyMix.dailySeed(epochDay: epochDay))
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let artists = Set(picks.map(\.song.artist)).count
            let unheard = picks.filter(\.unheard).count
            let lines = picks.prefix(15).map { "\($0.song.title) — \($0.reason)" }.joined(separator: "\n")
            return "Local preview · \(elapsed) ms · \(songs.count) candidates\n"
                + "\(picks.count) picks · \(artists) artists · \(unheard) unheard\n\n" + lines
        }.value
        taste?.saveReport(report)
    }

    /// Stage 13: an AI-curated mix replaces today's Daily Mix (Android `DailyMixStateHolder.setDailyMixSongs`):
    /// shown at once and saved as today's picks.
    func setDailyMix(_ songs: [Song]) {
        content.dailyMix = songs
        defaults?.set(songs.map(\.id), forKey: PreferenceKeys.dailyMixSongIds)
        defaults?.set(Double(history.clock.nowMs()), forKey: PreferenceKeys.lastDailyMixUpdate)
    }

    /// Per-song engagement from the history (Android `SongEngagementEntity`: plays, listened time, last play).
    nonisolated static func engagementStats(_ events: [PlaybackEvent]) -> [String: EngagementStats] {
        var engagements: [String: EngagementStats] = [:]
        for event in events {
            var stats = engagements[event.songId] ?? EngagementStats()
            stats.playCount += 1
            stats.totalPlayDurationMs += event.durationMs
            stats.lastPlayedTimestamp = max(stats.lastPlayedTimestamp, event.endMillis)
            engagements[event.songId] = stats
        }
        return engagements
    }

    // MARK: Daily mix persistence (Android DailyMixStateHolder: today's mix stays put for the day)

    private func savedMixes(epochDay: Int64, zone: TimeZone) -> (daily: [String], yourMix: [String]) {
        guard let defaults else { return ([], []) }
        let last = Int64(defaults.double(forKey: PreferenceKeys.lastDailyMixUpdate))
        guard last > 0, ZoneClock(zone).localDate(at: last).epochDay == epochDay else { return ([], []) }
        return (defaults.stringArray(forKey: PreferenceKeys.dailyMixSongIds) ?? [],
                defaults.stringArray(forKey: PreferenceKeys.yourMixSongIds) ?? [])
    }

    private func saveMixes(_ content: HomeContent, nowMs: Int64) {
        guard let defaults, !content.dailyMix.isEmpty else { return }
        defaults.set(content.dailyMix.map(\.id), forKey: PreferenceKeys.dailyMixSongIds)
        defaults.set(content.curatedYourMix.map(\.id), forKey: PreferenceKeys.yourMixSongIds)
        defaults.set(Double(nowMs), forKey: PreferenceKeys.lastDailyMixUpdate)
    }

    // MARK: Computation (pure, off the main thread)

    nonisolated static let mixPreviewLimit = 48
    nonisolated static let recentlyPlayedLimit = 64
    nonisolated static let overviewRanges: [StatsTimeRange] = [.week, .month, .year, .all]

    nonisolated static func compute(snapshot: LibrarySnapshot, events: [PlaybackEvent], nowMs: Int64,
                                    timeZone: TimeZone, savedDaily: [String], savedYourMix: [String],
                                    storedSignals: [String: MusicRecommendationEngine.Signal] = [:],
                                    exploration: Float = 0.25)
        -> (content: HomeContent, generatedMixes: Bool)
    {
        let songs = snapshot.songs
        var content = HomeContent()
        let zone = ZoneClock(timeZone)
        let hour = zone.localHour(at: nowMs)
        let songsById = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Greeting + insight (all-time summary).
        let allTime = songs.isEmpty ? nil
            : PlaybackStats.buildSummary(range: .all, songs: songs, nowMillis: nowMs, events: events, timeZone: timeZone)
        content.greeting = HomeLogic.greeting(hour: hour, librarySize: songs.count, allTime: allTime)
        content.insight = HomeLogic.expandedFallback(librarySize: songs.count, totalPlayCount: allTime?.totalPlayCount ?? 0,
                                                     topArtist: allTime?.topArtists.first?.artist,
                                                     topGenre: HomeLogic.topGenre(allTime))

        // Newest songs (`ORDER BY date_added DESC, id DESC LIMIT 48`).
        content.recentlyAdded = Array(songs.sorted { a, b in
            if a.dateAdded != b.dateAdded { return a.dateAdded > b.dateAdded }
            return b.id.utf16.lexicographicallyPrecedes(a.id.utf16)
        }.prefix(mixPreviewLimit))

        // History → recently played.
        content.history = PlaybackStats.playbackHistory(events)
        content.recentlyPlayed = HomeLogic.mapRecentlyPlayed(history: content.history, songsById: songsById, nowMs: nowMs,
                                                             timeZone: timeZone, maxItems: recentlyPlayedLimit)

        // Stats overview card.
        if !songs.isEmpty {
            for range in overviewRanges {
                let summary = range == .all ? allTime!
                    : PlaybackStats.buildSummary(range: range, songs: songs, nowMillis: nowMs, events: events,
                                                 timeZone: timeZone)
                if summary.totalDurationMs > 0 || summary.totalPlayCount > 0 || summary.uniqueSongs > 0
                    || summary.activeDays > 0 || summary.totalSessions > 0 {
                    content.statsOverview = summary
                    break
                }
            }
        }

        guard !songs.isEmpty else { return (content, false) }

        let engagements = engagementStats(events)
        let favorites = Set(songs.filter(\.isFavorite).map(\.id))
        let today = zone.localDate(at: nowMs)
        let epochDay = today.epochDay

        // Daily Mix / Your Mix: today's saved picks, else generated (`generateDailyMix` / `generateYourMix`).
        var generated = false
        let savedDailySongs = savedDaily.compactMap { songsById[$0] }
        if !savedDailySongs.isEmpty {
            content.dailyMix = savedDailySongs
            content.curatedYourMix = savedYourMix.compactMap { songsById[$0] }
        } else {
            content.dailyMix = DailyMix.personalizedPicks(
                allSongs: songs, favoriteSongIds: favorites, engagements: engagements, storedSignals: storedSignals,
                exploration: exploration, nowMs: nowMs, limit: 30,
                seed: DailyMix.dailySeed(epochDay: epochDay)).map(\.song)
            let dayOfYear = Int(epochDay - LocalDate(year: today.year, month: 1, day: 1).epochDay) + 1
            content.curatedYourMix = DailyMix.personalizedPicks(
                allSongs: songs, favoriteSongIds: favorites, engagements: engagements, storedSignals: storedSignals,
                exploration: exploration, nowMs: nowMs, limit: 60,
                seed: DailyMix.yourMixSeed(year: today.year, dayOfYear: dayOfYear)).map(\.song)
            generated = true
        }

        // "Made for your listening" + shelves (`HomeRecommendationPlanner.plan`, seed = today's epoch day).
        let inputs = RecommendationInputs.resolve(library: songs, storedSignals: storedSignals,
                                                  storedHistory: engagements.mapValues(\.history))
        let plan = HomeRecommendationPlanner.plan(library: songs, favorites: favorites, signals: inputs.signals,
                                                  history: inputs.history, nowMs: nowMs, seed: epochDay,
                                                  signalSources: inputs.signalSources,
                                                  historySources: inputs.historySources)
        content.mixes = plan.mixes
        content.shelves = plan.shelves
        return (content, generated)
    }
}
