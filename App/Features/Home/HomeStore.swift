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
    /// What the AI greeting and insight prompts say about the listener.
    var greetingFacts = HomeGreetingFacts()
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
    /// The AI-written insight once it arrived (nil: the local `content.insight`).
    private(set) var aiInsight: String?
    /// The AI insight is being written (the card shows a small spinner).
    private(set) var isLoadingInsight = false

    /// Asks the selected AI assistant for the greeting's headline or insight (Android `HomeGreetingStateHolder`'s
    /// AI half). Set at launch (`HomeAIGreeter`); nil in UI tests and previews, where the local texts stay.
    typealias Greeter = @MainActor (HomeGreetingKind, HomeGreetingFacts) async -> String?
    @ObservationIgnored var greeter: Greeter?
    /// One AI headline request per process (Android `hasRequestedAiGreetingThisProcess`).
    @ObservationIgnored private var hasRequestedAIGreeting = false
    @ObservationIgnored private var insightTask: Task<Void, Never>?

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

        /// The same library, day and taste: only the listening history moved.
        func onlyHistoryDiffers(from other: Key) -> Bool {
            revision != other.revision && libraryRevision == other.libraryRevision && epochDay == other.epochDay
                && tasteRevision == other.tasteRevision && exploration == other.exploration
                && learning == other.learning
        }
    }

    init(history: ListeningHistoryStore, defaults: UserDefaults?) {
        self.history = history
        self.defaults = defaults
    }

    /// The store for a launch: UI tests get the demo history, a pinned clock, no persistence.
    static func make(launch: LaunchConfiguration) -> HomeStore {
        if launch.isUITest {
            let clock = HomeClock.uiTest
            let history = ListeningHistoryStore(
                clock: clock, file: nil,
                seed: DemoListeningHistory.events(songs: DemoLibrary.songs, nowMs: clock.nowMs()))
            return HomeStore(history: history, defaults: nil)
        }
        let history = ListeningHistoryStore(clock: .live, file: ListeningHistoryFile.defaultURL().map(ListeningHistoryFile.init))
        return HomeStore(history: history, defaults: .standard)
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
        // A finished song or skip changes only the history: wait until the skip, the carousel and the re-theme are
        // done before the (cancellable) recomputation starts. A newer change cancels this task during the wait.
        if !force, let last = lastKey, last.onlyHistoryDiffers(from: key) {
            try? await Task.sleep(for: .milliseconds(1_500))
            if Task.isCancelled { return }
        }
        lastKey = key
        computeTask?.cancel()
        if force { isRefreshing = true }

        let events = history.events
        let saved = savedMixes(epochDay: epochDay, zone: clock.timeZone)
        let task = Task.detached(priority: force ? .userInitiated : .utility) { () -> (content: HomeContent, generatedMixes: Bool)? in
            HomeStore.computeIfActive(snapshot: snapshot, events: events, nowMs: now, timeZone: clock.timeZone,
                              savedDaily: saved.daily, savedYourMix: saved.yourMix, storedSignals: signals,
                              exploration: exploration)
        }
        let stamp = ScreenDataCache.Stamp(historyRevision: history.revision, songCount: snapshot.songs.count)
        let day = ZoneClock(clock.timeZone).localDate(at: now).description
        let computation = Task { [weak self] in
            // Cancelling this wrapper (a newer refresh) stops the detached computation at its next stage.
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard let self, let result, !Task.isCancelled else { return }
            // The overview card's week summary seeds Stats' default range.
            if let overview = result.content.statsOverview, overview.range == .week {
                ScreenDataCache.storeStats(overview, stamp: stamp)
            }
            var content = result.content
            // Today's AI headline, once written, replaces the local one for the rest of the day.
            if let cached = self.cachedAIGreeting(day: day) { content.greeting.headline = cached }
            if content != self.content { self.content = content }
            self.requestAIGreeting(day: day)
            if result.generatedMixes { self.saveMixes(result.content, nowMs: now) }
            self.isPreparing = false
            self.isRefreshing = false
        }
        computeTask = computation
        await computation.value
    }

    /// Expands the card and asks for the AI insight (Android `expandInsight`: on demand, not cached), or collapses
    /// it and forgets the insight (`collapseInsight`). Without an assistant the local insight shows.
    func toggleInsight() {
        if isInsightExpanded || isLoadingInsight {
            insightTask?.cancel()
            insightTask = nil
            isLoadingInsight = false
            aiInsight = nil
            isInsightExpanded = false
            return
        }
        isInsightExpanded = true
        let facts = content.greetingFacts
        guard let greeter, facts.librarySize > 0 else { return }
        isLoadingInsight = true
        insightTask = Task { [weak self] in
            let text = await greeter(.insight, facts)
            guard let self, !Task.isCancelled else { return }
            self.aiInsight = text.flatMap { HomeLogic.cleanGreeting($0, limit: 600) }
            self.isLoadingInsight = false
        }
    }

    // MARK: AI greeting (Android HomeGreetingStateHolder.refresh)

    /// Today's AI headline (`home_greeting_date` / `home_greeting_text`, Android's keys).
    private func cachedAIGreeting(day: String) -> String? {
        guard let defaults, defaults.string(forKey: PreferenceKeys.homeGreetingDate) == day,
              let text = defaults.string(forKey: PreferenceKeys.homeGreetingText) else { return nil }
        return HomeLogic.cleanGreeting(text)
    }

    /// Asks once per process for today's headline when none is cached; it replaces the local headline when it
    /// arrives and is kept for the day.
    private func requestAIGreeting(day: String) {
        let facts = content.greetingFacts
        guard let greeter, defaults != nil, !hasRequestedAIGreeting, facts.librarySize > 0,
              cachedAIGreeting(day: day) == nil else { return }
        hasRequestedAIGreeting = true
        Task { [weak self] in
            // Not during launch: the model (the downloaded one loads ~900 MB onto the GPU) waits until the first
            // screens, the library and the restored queue have settled. The local headline shows meanwhile.
            try? await Task.sleep(for: .seconds(8))
            if Task.isCancelled { return }
            let text = await greeter(.headline, facts)
            guard let self, let headline = text.flatMap({ HomeLogic.cleanGreeting($0) }) else { return }
            self.content.greeting.headline = headline
            self.defaults?.set(day, forKey: PreferenceKeys.homeGreetingDate)
            self.defaults?.set(headline, forKey: PreferenceKeys.homeGreetingText)
        }
    }

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
        computeIfActive(snapshot: snapshot, events: events, nowMs: nowMs, timeZone: timeZone, savedDaily: savedDaily,
                        savedYourMix: savedYourMix, storedSignals: storedSignals, exploration: exploration)
            ?? (HomeContent(), false)
    }

    /// `compute`, abandoned (nil) at the next stage boundary once the surrounding task is cancelled: a superseded
    /// computation stops instead of running to completion in the background.
    nonisolated static func computeIfActive(snapshot: LibrarySnapshot, events: [PlaybackEvent], nowMs: Int64,
                                            timeZone: TimeZone, savedDaily: [String], savedYourMix: [String],
                                            storedSignals: [String: MusicRecommendationEngine.Signal] = [:],
                                            exploration: Float = 0.25)
        -> (content: HomeContent, generatedMixes: Bool)?
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
        content.greetingFacts = HomeGreetingFacts(hour: hour, topArtist: allTime?.topArtists.first?.artist,
                                                  topGenre: HomeLogic.topGenre(allTime),
                                                  totalPlays: allTime?.totalPlayCount ?? 0, librarySize: songs.count)

        if Task.isCancelled { return nil }
        // Newest songs (`ORDER BY date_added DESC, id DESC LIMIT 48`).
        content.recentlyAdded = Array(songs.sorted { a, b in
            if a.dateAdded != b.dateAdded { return a.dateAdded > b.dateAdded }
            return b.id.utf16.lexicographicallyPrecedes(a.id.utf16)
        }.prefix(mixPreviewLimit))

        // History → recently played.
        content.history = PlaybackStats.playbackHistory(events)
        content.recentlyPlayed = HomeLogic.mapRecentlyPlayed(history: content.history, songsById: songsById, nowMs: nowMs,
                                                             timeZone: timeZone, maxItems: recentlyPlayedLimit)

        if Task.isCancelled { return nil }
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

        if Task.isCancelled { return nil }
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

        if Task.isCancelled { return nil }
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
