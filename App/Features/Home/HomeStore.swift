import Foundation
import Observation
import PixlLibrary
import PixlModel

/// Everything Home shows, computed together off the main thread (Android: `HomeDiscoveryStateHolder`,
/// `DailyMixStateHolder`, `HomeGreetingStateHolder`, `StatsViewModel.homeOverview` and the recently-played
/// mapping in `HomeScreen`). One value, replaced atomically when the library or the history changes.
nonisolated struct HomeContent: Sendable, Equatable {
    var greeting = HomeGreeting(headline: HomeSummary.headline(HomeSummaryFacts(hasLibrary: false)),
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

/// Where Home gets the music brain's "Because you listened to" rows from (docs/brain-spec.md, 8.1). Closures set by
/// `AppEnvironment`; nil in UI tests and previews.
struct HomeBrainRowsSource {
    /// The existing discovery switch (the queue's Autoplay switch): off, the rows are hidden too.
    var isEnabled: @MainActor () -> Bool
    /// The saved rows: one small file, never the brain's own state.
    var cached: @MainActor () async -> [BrainHomeRow]
    /// "New from artists you play" (6.3), from its saved file; nil under six cards. Never the network.
    var releaseRow: @MainActor () async -> BrainReleaseRow?
    /// Rebuilds the rows when they are due; nil when nothing was rebuilt (always, until music played in this run).
    var refreshIfDue: @MainActor () async -> [BrainHomeRow]?
}

/// What the brain says about the rows of the mixes it built (docs/brain-spec.md, 8.2, stage 2a): the reason under a row,
/// which rows are music the listener does not have yet, and what a play of each mix carries into the queue and the
/// event log. Empty while the legacy mixes are showing.
struct BrainMixDetails: Equatable {
    /// What one mix says about its rows.
    struct Part: Equatable {
        var reasons: [String: MixReason] = [:]
        var novelIds: Set<String> = []
        var tags: [String: BrainItemTag] = [:]

        init() {}

        init(_ view: MixView) {
            reasons = view.reasons
            novelIds = view.novelIds
            tags = view.tags
        }
    }

    var ownsMixes = false
    var daily = Part()
    var your = Part()
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
    /// Listening history imported from Spotify / YouTube Music (spec B3): its plays, signals and artist affinity join
    /// the app's own in every mix and shelf. Set by `AppEnvironment` (nil for previews).
    @ObservationIgnored var imported: ImportedHistoryStore?
    /// Ask Taizo's taste changes: boosts and reductions move the ranking, mutes and blocks leave songs out of every mix,
    /// shelf and pool Home computes. Set by `AppEnvironment` (nil for previews).
    @ObservationIgnored var adjustments: TasteAdjustmentStore?
    @ObservationIgnored var explorationFraction: () -> Float = { 0.25 }
    /// The tracks from outside the library that Autoplay played, by id (docs/brain-spec.md, 7.2): Recently Played
    /// resolves ids the library does not have through them. Set by `AppEnvironment` (nil for previews).
    @ObservationIgnored var engineSongs: (() async -> [String: Song])?
    @ObservationIgnored private var engineTracksRevision = 0
    /// The music brain's "Because you listened to X" rows, in front of the legacy shelves (decision D10). Shown
    /// from their saved file; a rebuild is what the next visit shows.
    private(set) var brainShelves: [BrainHomeShelf] = []
    @ObservationIgnored var brainRows: HomeBrainRowsSource?
    @ObservationIgnored private var brainRowsLoaded = false
    @ObservationIgnored private var pendingBrainRows: [BrainHomeShelf]?
    @ObservationIgnored private var brainRowsTask: Task<Void, Never>?
    /// Daily Mix and Your Mix built by the brain, when it owns them (docs/brain-spec.md, 8.2, stage 2a). They replace the
    /// legacy mixes in `content` a few seconds after launch (the brain's files stay closed while the app starts), and
    /// stay in place while the rest of Home is recomputed.
    private(set) var brainMixDetails = BrainMixDetails()
    @ObservationIgnored var brainMixes: BrainMixes?
    /// Waits out the app's first seconds; the brain is touched after it.
    @ObservationIgnored var brainQuiet: (() async -> Void)?
    /// Whether the engine switch (Developer mode) is on, read at the moment it matters.
    @ObservationIgnored var brainEngineIsOn: () -> Bool = { true }
    /// The tracks from outside the library a mix holds, so the app knows them (Like, "Add to playlist", Recently Played).
    @ObservationIgnored var onBrainMixTracks: (([EngineTrack]) -> Void)?
    /// A track from outside the library as the queue shows it: its artist pointed at the library's own artist of the name.
    @ObservationIgnored var linkBrainSong: ((Song) -> Song)?
    @ObservationIgnored private var brainDaily: [Song] = []
    @ObservationIgnored private var brainYour: [Song] = []
    @ObservationIgnored private var brainMixesTask: Task<Void, Never>?
    @ObservationIgnored private var pendingBrainRegenerate = false
    @ObservationIgnored private var regenerateBrainMixesNext = false
    /// Blocked artists: their songs are left out of every mix, shelf and list Home computes.
    @ObservationIgnored private(set) var blockedMatcher: BlockedArtistMatcher = .empty
    @ObservationIgnored private var blockedRevision = 0

    /// Settings › Blocked artists changed: the next `refresh` recomputes without those songs.
    func setBlocked(_ matcher: BlockedArtistMatcher) {
        guard matcher != blockedMatcher else { return }
        blockedMatcher = matcher
        blockedRevision &+= 1
    }

    /// The taste changes in force as the engine reads them (empty until the file is read, and when there are none).
    func tasteSet() async -> TasteAdjustmentSet {
        guard let adjustments else { return .empty }
        await adjustments.ensureLoaded()
        return adjustments.activeSet(nowMs: history.clock.nowMs())
    }

    /// `snapshot` without the blocked artists' songs (the same value when nothing is blocked).
    private func unblocked(_ snapshot: LibrarySnapshot) -> LibrarySnapshot {
        guard !blockedMatcher.isEmpty else { return snapshot }
        var copy = snapshot
        copy.songs = blockedMatcher.allowed(snapshot.songs)
        return copy
    }

    /// What a computation depends on; a refresh with the same key is skipped (Android throttles repeat passes).
    /// The library by its revision (comparing two snapshots walked the whole library on the main actor).
    private struct Key: Equatable {
        var libraryRevision: Int
        var revision: Int
        var epochDay: Int64
        var tasteRevision: Int
        var exploration: Float
        var learning: Bool
        var blocked = 0
        var importedRevision = 0
        var adjustmentsRevision = 0
        /// The brain's stored tracks were read after launch: Recently Played can resolve more ids.
        var engineTracksRevision = 0

        /// The same library, day and taste: only the listening history moved.
        func onlyHistoryDiffers(from other: Key) -> Bool {
            revision != other.revision && libraryRevision == other.libraryRevision && epochDay == other.epochDay
                && tasteRevision == other.tasteRevision && exploration == other.exploration && blocked == other.blocked
                && learning == other.learning && importedRevision == other.importedRevision
                && adjustmentsRevision == other.adjustmentsRevision
                && engineTracksRevision == other.engineTracksRevision
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
        refreshBrainRows()
        let snapshot = unblocked(snapshot)
        await history.ensureLoaded()
        await taste?.ensureLoaded()
        await imported?.ensureLoaded()
        let importedAggregate = imported?.aggregate ?? .empty
        let adjustmentSet = await tasteSet()
        let clock = history.clock
        let now = clock.nowMs()
        let epochDay = ZoneClock(clock.timeZone).localDate(at: now).epochDay
        let signals = taste?.learnedSignals ?? [:]
        let exploration = explorationFraction()
        let key = Key(libraryRevision: libraryRevision, revision: history.revision, epochDay: epochDay,
                      tasteRevision: taste?.revision ?? 0, exploration: exploration, learning: !signals.isEmpty,
                      blocked: blockedRevision, importedRevision: imported?.revision ?? 0,
                      adjustmentsRevision: adjustments?.revision ?? 0, engineTracksRevision: engineTracksRevision)
        if !force, key == lastKey { return }
        // Only a refresh that will compute asks for the tracks from outside the library (Recently Played shows
        // them), and at launch that answer does not wait for a file (`BrainService.engineSongsForHome`).
        let engineSongs = await self.engineSongs?() ?? [:]
        // A finished song or skip changes only the history: wait until the skip, the carousel and the re-theme are
        // done before the (cancellable) recomputation starts. A newer change cancels this task during the wait.
        if !force, let last = lastKey, last.onlyHistoryDiffers(from: key) {
            try? await Task.sleep(for: .milliseconds(1_500))
            if Task.isCancelled { return }
        }
        // A taste change redraws today's mixes (the saved picks would hide a boost until tomorrow).
        let tasteChanged = lastKey.map { $0.adjustmentsRevision != key.adjustmentsRevision } ?? false
        lastKey = key
        computeTask?.cancel()
        if force { isRefreshing = true }

        let events = history.events
        var saved = savedMixes(epochDay: epochDay, zone: clock.timeZone)
        if tasteChanged { saved = (daily: [], yourMix: []) }
        let task = Task.detached(priority: force ? .userInitiated : .utility) { () -> (content: HomeContent, generatedMixes: Bool)? in
            HomeStore.computeIfActive(snapshot: snapshot, events: events, nowMs: now, timeZone: clock.timeZone,
                              savedDaily: saved.daily, savedYourMix: saved.yourMix, storedSignals: signals,
                              exploration: exploration, importedHistory: importedAggregate, adjustments: adjustmentSet,
                              engineSongs: engineSongs)
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
            // The brain's mixes, when it owns them, stay in place while the rest of Home is recomputed.
            self.overlayBrainMixes(&content)
            if content != self.content { self.content = content }
            self.requestAIGreeting(day: day)
            if result.generatedMixes { self.saveMixes(result.content, nowMs: now) }
            self.isPreparing = false
            self.isRefreshing = false
            // Only the Developer mode "Regenerate" draws new brain mixes; the refresh button keeps today's.
            let regenerate = self.regenerateBrainMixesNext
            self.regenerateBrainMixesNext = false
            self.scheduleBrainMixes(regenerate: regenerate)
        }
        computeTask = computation
        await computation.value
    }

    // MARK: The brain's mixes (docs/brain-spec.md, 8.2)

    private func overlayBrainMixes(_ content: inout HomeContent) {
        guard brainEngineIsOn(), !brainDaily.isEmpty, !brainYour.isEmpty else { return }
        content.dailyMix = brainDaily
        content.curatedYourMix = brainYour
    }

    /// Asks for today's mixes once the app has settled: the saved ones (a small read, no brain state), or new ones when
    /// the brain owns the mixes and has played enough. Off the main actor; what comes back is shown at once.
    private func scheduleBrainMixes(regenerate: Bool) {
        guard let mixes = brainMixes else { return }
        if brainMixesTask != nil {
            if regenerate { pendingBrainRegenerate = true }
            return
        }
        brainMixesTask = Task { [weak self] in
            await self?.brainQuiet?()
            let pair = await mixes.publish(regenerate: regenerate)
            guard let self else { return }
            self.brainMixesTask = nil
            self.publishBrainMixes(pair)
            if self.pendingBrainRegenerate {
                self.pendingBrainRegenerate = false
                self.scheduleBrainMixes(regenerate: true)
            }
        }
    }

    private func publishBrainMixes(_ pair: (daily: MixView, your: MixView)?) {
        guard let pair else {
            // The legacy engine owns the mixes (the switch is off, or the brain has heard too little): the next
            // refresh brings them back.
            if brainMixDetails.ownsMixes {
                brainDaily = []
                brainYour = []
                brainMixDetails = BrainMixDetails()
                lastKey = nil
            }
            return
        }
        let link = linkBrainSong ?? { $0 }
        let daily = pair.daily.songs.map(link)
        let your = pair.your.songs.map(link)
        onBrainMixTracks?(pair.daily.engineTracks + pair.your.engineTracks)
        brainDaily = daily
        brainYour = your
        var details = BrainMixDetails(ownsMixes: true)
        details.daily = BrainMixDetails.Part(pair.daily)
        details.your = BrainMixDetails.Part(pair.your)
        if details != brainMixDetails { brainMixDetails = details }
        var next = content
        next.dailyMix = daily
        next.curatedYourMix = your
        if next != content { content = next }
        // The legacy keys keep the library songs of the mixes, so a restart shows them before the brain is read.
        let libraryIds: ([Song], Set<String>) -> [String] = { songs, novel in songs.map(\.id).filter { !novel.contains($0) } }
        defaults?.set(libraryIds(daily, pair.daily.novelIds), forKey: PreferenceKeys.dailyMixSongIds)
        defaults?.set(libraryIds(your, pair.your.novelIds), forKey: PreferenceKeys.yourMixSongIds)
        defaults?.set(Double(history.clock.nowMs()), forKey: PreferenceKeys.lastDailyMixUpdate)
        isPreparing = false
    }

    // MARK: The music brain's rows (docs/brain-spec.md, 8.1)

    /// Shows the saved rows the first time, then asks for a rebuild. Never waits: Home's own computation goes on
    /// beside it. A rebuilt row is what the NEXT visit shows (`showPendingBrainRows`); only a Home with no row yet
    /// takes a new one right away, so nothing changes under the thumb.
    private func refreshBrainRows() {
        guard let source = brainRows, brainRowsTask == nil else { return }
        guard source.isEnabled() else {
            if !brainShelves.isEmpty { brainShelves = [] }
            pendingBrainRows = nil
            brainRowsLoaded = false
            return
        }
        let loaded = brainRowsLoaded
        brainRowsLoaded = true
        brainRowsTask = Task { [weak self] in
            // The release row comes from its own small file and follows the "Because you listened to" rows.
            let release = await source.releaseRow()
            if !loaded {
                let shelves = await HomeStore.shelves(of: await source.cached(), release: release)
                if let self, self.brainShelves != shelves { self.brainShelves = shelves }
            }
            var shelves: [BrainHomeShelf]?
            if let rebuilt = await source.refreshIfDue() { shelves = await HomeStore.shelves(of: rebuilt, release: release) }
            guard let self else { return }
            self.brainRowsTask = nil
            guard let shelves else {
                // Nothing was rebuilt, but a release found since is shown with the rows already there.
                if loaded, let release {
                    let withRelease = await HomeStore.shelves(of: [], release: release)
                    let kept = self.brainShelves.filter { $0.id != BrainReleaseRow.id }
                    let next = kept + withRelease
                    if next != self.brainShelves { self.pendingBrainRows = next }
                } else if loaded, release == nil, self.brainShelves.contains(where: { $0.id == BrainReleaseRow.id }) {
                    self.pendingBrainRows = self.brainShelves.filter { $0.id != BrainReleaseRow.id }
                }
                return
            }
            if self.brainShelves.isEmpty {
                self.brainShelves = shelves
            } else if self.brainShelves != shelves {
                self.pendingBrainRows = shelves
            }
        }
    }

    /// The brain's stored tracks were read a moment after launch: the next refresh resolves the history with them.
    func engineTracksChanged() { engineTracksRevision &+= 1 }

    /// Home came back on screen: rows rebuilt while it was away are shown now.
    func showPendingBrainRows() {
        guard let pending = pendingBrainRows else { return }
        pendingBrainRows = nil
        if brainShelves != pending { brainShelves = pending }
    }

    /// The rows as Home draws them (songs and reason lines), built off the main actor.
    @concurrent
    private nonisolated static func shelves(of rows: [BrainHomeRow], release: BrainReleaseRow?) async -> [BrainHomeShelf] {
        let now = currentTimeMillis()
        var out = BrainHomeShelf.make(rows, nowMs: now)
        if let release { out.append(BrainHomeShelf.make(release: release, nowMs: now)) }
        return out
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
        guard let greeter, facts.hasLibrary else { return }
        isLoadingInsight = true
        insightTask = Task { [weak self] in
            let text = await greeter(.insight, facts)
            guard let self, !Task.isCancelled else { return }
            self.aiInsight = text.flatMap { HomeLogic.cleanInsight($0) }
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
        guard let greeter, defaults != nil, !hasRequestedAIGreeting, facts.hasLibrary,
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
        // The brain draws another list, and the served log counts the one it replaces (8.2).
        if let mixes = brainMixes, brainEngineIsOn(), let view = await mixes.regenerateYourMix() {
            onBrainMixTracks?(view.engineTracks)
            let link = linkBrainSong ?? { $0 }
            let songs = view.songs.map(link)
            brainYour = songs
            var details = brainMixDetails
            details.ownsMixes = true
            details.your = BrainMixDetails.Part(view)
            if details != brainMixDetails { brainMixDetails = details }
            content.curatedYourMix = songs
            defaults?.set(songs.map(\.id).filter { !view.novelIds.contains($0) }, forKey: PreferenceKeys.yourMixSongIds)
            return
        }
        let snapshot = unblocked(snapshot)
        await history.ensureLoaded()
        await taste?.ensureLoaded()
        let events = history.events
        let now = history.clock.nowMs()
        let seed = Int64.random(in: Int64.min...Int64.max)
        let signals = taste?.learnedSignals ?? [:]
        let exploration = explorationFraction()
        await imported?.ensureLoaded()
        let importedAggregate = imported?.aggregate ?? .empty
        let adjustmentSet = await tasteSet()
        let mix = await Task.detached(priority: .userInitiated) { () -> [Song] in
            let songs = snapshot.songs
            guard !songs.isEmpty else { return [] }
            let inputs = HomeStore.recommendationInputs(songs: songs, events: events, signals: signals,
                                                        imported: importedAggregate)
            return DailyMix.personalizedPicks(
                allSongs: songs, favoriteSongIds: Set(songs.filter(\.isFavorite).map(\.id)),
                engagements: inputs.engagements, storedSignals: inputs.signals, exploration: exploration,
                nowMs: now, limit: 60, seed: seed, artistAffinity: inputs.artistAffinity,
                adjustments: adjustmentSet).map(\.song)
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
        regenerateBrainMixesNext = true
        await refresh(snapshot: snapshot, libraryRevision: libraryRevision, force: true)
    }

    /// Music intelligence › Preview recommendations (Android `MusicIntelligenceViewModel.preview`): ranks the real
    /// library with the real inputs — playback and the queue are untouched — and saves the report.
    func previewRecommendations(snapshot: LibrarySnapshot) async {
        let snapshot = unblocked(snapshot)
        await history.ensureLoaded()
        await taste?.ensureLoaded()
        let events = history.events
        let now = history.clock.nowMs()
        let signals = taste?.learnedSignals ?? [:]
        let exploration = explorationFraction()
        let epochDay = ZoneClock(history.clock.timeZone).localDate(at: now).epochDay
        await imported?.ensureLoaded()
        let importedAggregate = imported?.aggregate ?? .empty
        let adjustmentSet = await tasteSet()
        let report = await Task.detached(priority: .userInitiated) { () -> String in
            let songs = snapshot.songs
            let start = Date()
            let inputs = HomeStore.recommendationInputs(songs: songs, events: events, signals: signals,
                                                        imported: importedAggregate)
            let picks = DailyMix.personalizedPicks(
                allSongs: songs, favoriteSongIds: Set(songs.filter(\.isFavorite).map(\.id)),
                engagements: inputs.engagements, storedSignals: inputs.signals, exploration: exploration,
                nowMs: now, limit: 30, seed: DailyMix.dailySeed(epochDay: epochDay),
                artistAffinity: inputs.artistAffinity, adjustments: adjustmentSet)
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
    func setDailyMix(_ allSongs: [Song]) {
        var songs = blockedMatcher.allowed(allSongs)
        if let adjustments { songs = adjustments.activeSet(nowMs: history.clock.nowMs()).allowed(songs) }
        content.dailyMix = songs
        defaults?.set(songs.map(\.id), forKey: PreferenceKeys.dailyMixSongIds)
        defaults?.set(Double(history.clock.nowMs()), forKey: PreferenceKeys.lastDailyMixUpdate)
    }

    /// The recommendation inputs: the app's own engagement and learned signals, plus imported listening history
    /// (Spotify 1.0 / YouTube Music 0.35, 180-day fade) mapped to `songs`, and the artist affinity from listening
    /// outside the library and Spotify's top / followed artists.
    nonisolated static func recommendationInputs(songs: [Song], events: [PlaybackEvent],
                                                 signals: [String: MusicRecommendationEngine.Signal],
                                                 imported: ImportedHistoryAggregate)
        -> (engagements: [String: EngagementStats], signals: [String: MusicRecommendationEngine.Signal],
            artistAffinity: [String: Double])
    {
        let local = engagementStats(events)
        guard !imported.isEmpty else { return (local, signals, [:]) }
        let extra = imported.recommendationInputs(library: songs)
        return (extra.mergedEngagements(local), extra.mergedSignals(signals), extra.artistAffinity)
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
                                    exploration: Float = 0.25, importedHistory: ImportedHistoryAggregate = .empty,
                                    adjustments: TasteAdjustmentSet = .empty)
        -> (content: HomeContent, generatedMixes: Bool)
    {
        computeIfActive(snapshot: snapshot, events: events, nowMs: nowMs, timeZone: timeZone, savedDaily: savedDaily,
                        savedYourMix: savedYourMix, storedSignals: storedSignals, exploration: exploration,
                        importedHistory: importedHistory, adjustments: adjustments)
            ?? (HomeContent(), false)
    }

    /// `compute`, abandoned (nil) at the next stage boundary once the surrounding task is cancelled: a superseded
    /// computation stops instead of running to completion in the background.
    nonisolated static func computeIfActive(snapshot: LibrarySnapshot, events: [PlaybackEvent], nowMs: Int64,
                                            timeZone: TimeZone, savedDaily: [String], savedYourMix: [String],
                                            storedSignals storedLocalSignals: [String: MusicRecommendationEngine.Signal] = [:],
                                            exploration: Float = 0.25,
                                            importedHistory: ImportedHistoryAggregate = .empty,
                                            adjustments: TasteAdjustmentSet = .empty,
                                            engineSongs: [String: Song] = [:])
        -> (content: HomeContent, generatedMixes: Bool)?
    {
        let songs = snapshot.songs
        var content = HomeContent()
        let zone = ZoneClock(timeZone)
        let songsById = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Greeting + insight (all-time summary). Imported listening names the favourite artist while the app's own
        // history is still thin.
        let allTime = songs.isEmpty ? nil
            : PlaybackStats.buildSummary(range: .all, songs: songs, nowMillis: nowMs, events: events, timeZone: timeZone)
        let facts = HomeLogic.summaryFacts(nowMs: nowMs, timeZone: timeZone, songs: songs, events: events, allTime: allTime,
                                           importedTopArtist: importedHistory.artists.first?.name)
        content.greeting = HomeLogic.greeting(facts)
        content.insight = HomeSummary.insight(facts)
        content.greetingFacts = facts

        if Task.isCancelled { return nil }
        // Newest songs (`ORDER BY date_added DESC, id DESC LIMIT 48`).
        content.recentlyAdded = Array(songs.sorted { a, b in
            if a.dateAdded != b.dateAdded { return a.dateAdded > b.dateAdded }
            return b.id.utf16.lexicographicallyPrecedes(a.id.utf16)
        }.prefix(mixPreviewLimit))

        // History → recently played.
        content.history = PlaybackStats.playbackHistory(events)
        // Tracks Autoplay played from outside the library are listed too; everything else below stays library-only.
        content.recentlyPlayed = HomeLogic.mapRecentlyPlayed(
            history: content.history, songsById: HomeLogic.withEngineSongs(songsById, engineSongs), nowMs: nowMs,
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
        let recommendation = recommendationInputs(songs: songs, events: events, signals: storedLocalSignals,
                                                  imported: importedHistory)
        let engagements = recommendation.engagements
        let storedSignals = recommendation.signals
        let affinity = recommendation.artistAffinity
        let favorites = Set(songs.filter(\.isFavorite).map(\.id))
        let today = zone.localDate(at: nowMs)
        let epochDay = today.epochDay

        // Daily Mix / Your Mix: today's saved picks, else generated (`generateDailyMix` / `generateYourMix`).
        var generated = false
        let savedDailySongs = adjustments.allowed(savedDaily.compactMap { songsById[$0] })
        if !savedDailySongs.isEmpty {
            content.dailyMix = savedDailySongs
            content.curatedYourMix = adjustments.allowed(savedYourMix.compactMap { songsById[$0] })
        } else {
            content.dailyMix = DailyMix.personalizedPicks(
                allSongs: songs, favoriteSongIds: favorites, engagements: engagements, storedSignals: storedSignals,
                exploration: exploration, nowMs: nowMs, limit: 30,
                seed: DailyMix.dailySeed(epochDay: epochDay), artistAffinity: affinity,
                adjustments: adjustments).map(\.song)
            let dayOfYear = Int(epochDay - LocalDate(year: today.year, month: 1, day: 1).epochDay) + 1
            content.curatedYourMix = DailyMix.personalizedPicks(
                allSongs: songs, favoriteSongIds: favorites, engagements: engagements, storedSignals: storedSignals,
                exploration: exploration, nowMs: nowMs, limit: 60,
                seed: DailyMix.yourMixSeed(year: today.year, dayOfYear: dayOfYear), artistAffinity: affinity,
                adjustments: adjustments).map(\.song)
            generated = true
        }

        if Task.isCancelled { return nil }
        // "Made for your listening" + shelves (`HomeRecommendationPlanner.plan`, seed = today's epoch day).
        let inputs = RecommendationInputs.resolve(library: songs, storedSignals: storedSignals,
                                                  storedHistory: engagements.mapValues(\.history))
        let plan = HomeRecommendationPlanner.plan(library: songs, favorites: favorites, signals: inputs.signals,
                                                  history: inputs.history, nowMs: nowMs, seed: epochDay,
                                                  signalSources: inputs.signalSources,
                                                  historySources: inputs.historySources, artistAffinity: affinity,
                                                  adjustments: adjustments)
        content.mixes = plan.mixes
        content.shelves = plan.shelves
        return (content, generated)
    }
}
