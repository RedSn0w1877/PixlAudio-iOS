import Observation
import PixlLibrary
import PixlModel
import SwiftUI

/// Home, redesign batch 3 (Android `HomeScreen` + `redesign/HomeRedesign.kt`, mockups Main and AndroidHomeScrolled): a flat page,
/// blocks 20 pt apart, 16 pt gutter. Order: the header (time chip, the wordplay greeting, Ask Taizo / Settings / jobs), the safe-mode
/// banner, the listening-history card, the knowing strip, the artist picker, Your mix, Endless Listening, Mix & match, the plan's hero,
/// Rewind replay, Fresh finds (and the other track shelves in the same style), the station shelves, the legacy adaptive mixes, Just
/// added, the Ask Taizo card, the stats card and the footer links. Once the big header scrolls away, the collapsed header slides in.
/// Material fills are Liquid Glass tinted with Android's role (`HomeRedesign.swift`).
struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    /// A reference: writing the flag re-renders only the collapsed header's slot, never this body (and its sections).
    @State private var scroll = HomeScrollState()
    /// "See all" of Mix & match (the old "Mixes" chip) and of Fresh finds (the old "New" chip).
    @State private var showAllMixes = false
    @State private var showNewShelves = false

    var body: some View {
        let home = env.home
        let content = home.content
        // The music brain's plan (8.1): read from its file before anything else. `owned` false is the page as it was.
        let plan = env.homePlan.ui
        let week = content.statsOverview.flatMap { $0.range == .week ? $0 : nil }
        let topSong = week?.topSongs.first
        let titles = HomeSectionTitles.make(now: Date(), pinned: env.launch.isUITest)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                HomeRedesignHeader(weekPlays: week?.totalPlayCount, topSong: topSong?.title, topSongPlays: topSong?.playCount ?? 0,
                                   onAskTaizo: { router.present(AppSheet.taisChat) },
                                   onSettings: { router.push(.settings) },
                                   onJobs: { router.present(AppSheet.jobs) })
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scroll.headerHeight = $0 }

                // After an unexpected close: heavy jobs are paused until the person reviews them (once, dismissible).
                if env.health.safeMode.showsBanner {
                    SafeModeBanner(modelBlamed: env.health.localModelBlamed, onReview: {
                        env.health.dismissBanner()
                        router.present(AppSheet.jobs)
                    }, onDismiss: { env.health.dismissBanner() })
                        .padding(.horizontal, Redesign.gutter)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                // Once, until a data download is imported or the card is closed: the listening-history import.
                if showsHistoryCard {
                    ListeningHistoryHomeCard(onOpen: { router.push(.listeningHistory) }, onDismiss: {
                        withAnimation(PixlMotion.state) { env.importedHistory.homeCardDismissed = true }
                    })
                    .padding(.horizontal, Redesign.gutter)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                // 8.10: while the first radios are fetched Home says so; it never shows a spinner or an empty state for it.
                if plan.knowingTotal > 0 { HomeKnowingStrip(done: plan.knowingDone, total: plan.knowingTotal) }
                if plan.offerPicker { HomeArtistPickerCard(onPick: { router.push(.artistPicker) }) }

                // Your mix: the day's hero card. Without one (and no plan) the old loading / empty states keep their place.
                if !content.yourMix.isEmpty || hasPlanYourMix(plan) {
                    HomeYourMixHero(onOpen: { router.push(.yourMix) }, onPlay: content.yourMix.isEmpty ? nil : { playYourMix(content) })
                } else if !plan.owned {
                    yourMixPlaceholder(isPreparing: home.isPreparing)
                }

                HomeEndlessEntry(onTap: openEndless, onLongPress: { router.present(AppCover.endlessIntro) })

                let tiles = mixTiles(plan: plan, content: content)
                if !tiles.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HomeSectionHeader(wide: titles.mixesA, accent: titles.mixesB,
                                          actionLabel: tiles.count > 2
                                              ? (showAllMixes ? HomeRedesignStrings.showLess : HomeRedesignStrings.seeAll) : nil,
                                          onAction: { withAnimation(PixlMotion.state) { showAllMixes.toggle() } })
                        if showAllMixes {
                            HomeMixGrid(tiles: tiles, onOpen: { openMixTile($0, plan: plan) })
                        } else {
                            HomeMixShelfRow(tiles: tiles, onOpen: { openMixTile($0, plan: plan) })
                        }
                    }
                }

                if plan.owned, let hero = plan.hero {
                    HomeHeroCard(hero: hero, onTap: { openHero(hero) })
                }

                let rewind = rewindTiles(plan: plan, content: content)
                if !rewind.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HomeSectionHeader(wide: titles.recentA, accent: titles.recentB,
                                          actionLabel: content.recentlyPlayed.isEmpty ? nil : HomeRedesignStrings.seeAll,
                                          onAction: { router.push(.recentlyPlayed) })
                        HomeRewindGrid(tiles: rewind, onTap: { openRewind($0, plan: plan, content: content) })
                    }
                }

                trackShelves(plan: plan, content: content, titles: titles)

                if plan.owned {
                    ForEach(stationShelves(plan)) { shelf in
                        if case .stations(let id, let title, let subtitle, let cards) = shelf {
                            HomeStationShelf(title: title, subtitle: subtitle, cards: cards, onStart: { card in
                                env.homePlan.shelfActivated(id)
                                env.brainActions.startGenreStation(kind: card.kind, atlasId: card.atlasId, name: card.name)
                            })
                            .shelfSeen(id, env.homePlan)
                        }
                    }
                }

                if !plan.owned, !content.mixes.isEmpty {
                    HomeDiscoveryMixes(mixes: content.mixes, isRefreshing: home.isRefreshing,
                                       onRefresh: {
                                           Task {
                                               await home.refresh(snapshot: library.snapshot,
                                                                  libraryRevision: library.songsRevision, force: true)
                                           }
                                       },
                                       onPlay: { section, song in playback.play(song, in: section.songs, source: .homeShelf) })
                }

                if !content.recentlyAdded.isEmpty {
                    RecentlyAddedSection(songs: content.recentlyAdded,
                                         onSongTap: { song in playback.play(song, in: library.songs) })
                }

                HomeAskTaizoCard(exampleSong: topSong?.title ?? playback.current?.title,
                                 onTap: { router.present(AppSheet.taisChat) })

                if let overview = content.statsOverview {
                    StatsOverviewCard(summary: overview, onOpen: { router.push(.stats) })
                }

                HomeFooterLinks(links: footerLinks)
            }
            .padding(.bottom, 38)
            // Nothing is drawn until the saved plan has been looked for (a frame or two): the old rows are never painted and then
            // swapped out for the plan, and the plan fades in. UI tests draw at once.
            .opacity(plan.resolved || env.launch.isUITest ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: plan.resolved)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("screen.home")
        .minimizesTabBarOnScroll()
        // The collapsed header shows once the big header has scrolled off (Android `firstVisibleItemIndex > 0`).
        .onScrollGeometryChange(for: Bool.self) { [scroll] geometry in
            let header = scroll.headerHeight > 0 ? scroll.headerHeight : HomeMetrics.scrolledThreshold
            return geometry.contentOffset.y + geometry.contentInsets.top > header
        } action: { _, scrolled in
            if scroll.isScrolled != scrolled { scroll.isScrolled = scrolled }
        }
        .overlay(alignment: .top) {
            HomeCollapsedSlot(scroll: scroll, weekPlays: week?.totalPlayCount, topSong: topSong?.title,
                              topSongPlays: topSong?.playCount ?? 0,
                              onAskTaizo: { router.present(AppSheet.taisChat) },
                              onSettings: { router.push(.settings) },
                              onJobs: { router.present(AppSheet.jobs) })
        }
        .background(theme.surface.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: HomeRefreshKey(libraryRevision: library.songsRevision, revision: home.history.revision,
                                 importedRevision: env.importedHistory.revision,
                                 adjustmentsRevision: env.tasteAdjustments.revision)) {
            await home.refresh(snapshot: library.snapshot, libraryRevision: library.songsRevision)
        }
        // Rows the music brain rebuilt while Home was away are shown when Home is back on screen, never under the thumb.
        .onChange(of: router.selection) { _, tab in
            if tab == .home {
                home.showPendingBrainRows()
                env.homePlan.onHomeShown()
            }
        }
        // The first appearance reads the saved plan, then plans again when the day, the daypart or the taste moved.
        .task { env.homePlan.onHomeShown() }
        .onChange(of: env.tasteAdjustments.revision) { _, _ in env.homePlan.invalidate() }
        // "Import your listening history" from the setup page: the existing import opens once, when Home is on screen with no
        // cover over it. Home is already mounted behind the setup, so this also watches the cover close.
        .task { openPendingHistoryImport() }
        .onChange(of: router.cover == nil) { _, closed in
            if closed { openPendingHistoryImport() }
        }
        // Cloud Studio's stored jobs (read once, off the main actor): its work may have moved on while the app was closed,
        // and the jobs button should show it.
        .task { await env.cloud.loadForDisplay() }
    }

    /// The import the setup page asked for opens once; never under a cover (the setup itself), where it would be pushed unseen.
    private func openPendingHistoryImport() {
        guard router.cover == nil, UserDefaults.standard.bool(forKey: PreferenceKeys.pendingHistoryImport) else { return }
        UserDefaults.standard.removeObject(forKey: PreferenceKeys.pendingHistoryImport)
        router.push(.listeningHistory)
    }

    /// Not in UI tests (screenshots stay as they were), and only once there is a library to make mixes from.
    private var showsHistoryCard: Bool {
        let history = env.importedHistory
        return !env.launch.isUITest && !history.homeCardDismissed && !history.hasFileImport && !library.songs.isEmpty
    }

    // MARK: Your mix

    @ViewBuilder
    private func yourMixPlaceholder(isPreparing: Bool) -> some View {
        if isPreparing {
            ProgressView()
                .controlSize(.large)
                .tint(theme.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 256)
        } else if env.accounts.needsSpotifyConnection {
            // No account linked: nothing will ever sync, so Home asks to connect (as Library does).
            ConnectSpotifyEmptyState()
        } else {
            YourMixEmptyPlaceholder(onRefresh: {
                Task {
                    try? await library.refresh()
                    await env.home.refresh(snapshot: library.snapshot, libraryRevision: library.songsRevision, force: true)
                }
            })
        }
    }

    private func hasPlanYourMix(_ plan: HomePlanUi) -> Bool {
        plan.allMixes.contains { $0.mixId == "your" } || plan.shelves.contains { shelf in
            if case .mixes(_, _, _, let cards) = shelf { return cards.contains { $0.mixId == "your" } }
            return false
        }
    }

    /// Android: the fallback mix shuffles the whole library; otherwise the mix plays from its first song.
    private func playYourMix(_ content: HomeContent) {
        let songs = content.yourMix
        guard let first = songs.first else { return }
        if content.usesFallbackYourMix { shuffleAll() } else { playback.play(first, in: songs, source: .yourMix) }
    }

    // MARK: Endless Listening

    /// First open shows the introduction; every other starts (or picks up) the station and opens its screen.
    private func openEndless() {
        env.homePlan.shelfActivated("made_for_you")
        if env.endless.isIntroSeen {
            if !env.endless.isActive { env.brainActions.startEndless() }
            router.present(AppCover.endlessStation)
        } else {
            router.present(AppCover.endlessIntro)
        }
    }

    // MARK: Mix & match

    /// Every made-for-you card except Your Mix (the hero) and Endless Listening (its own pill), in the plan's order.
    private func planMixCards(_ plan: HomePlanUi) -> [MixCardUi] {
        var seen = Set<String>()
        var out: [MixCardUi] = []
        for shelf in plan.shelves {
            if case .mixes(_, _, _, let cards) = shelf {
                for card in cards where seen.insert(card.mixId).inserted { out.append(card) }
            }
        }
        for card in plan.allMixes where seen.insert(card.mixId).inserted { out.append(card) }
        return out.filter { $0.mixId != "your" && $0.kind != MixKinds.endless }
    }

    private func mixTiles(plan: HomePlanUi, content: HomeContent) -> [HomeMixTile] {
        let cards = planMixCards(plan)
        if plan.owned || !cards.isEmpty {
            return cards.map { HomeMixTile(key: $0.mixId, title: $0.title, subtitle: $0.subtitle) }
        }
        guard !content.dailyMix.isEmpty else { return [] }
        var seen = Set<String>()
        var artists: [String] = []
        for song in content.dailyMix where artists.count < 3 {
            let name = song.displayArtist
            if !name.isEmpty, seen.insert(name).inserted { artists.append(name) }
        }
        return [HomeMixTile(key: "daily", title: BrainStrings.mixDaily, subtitle: artists.joined(separator: ", "))]
    }

    private func openMixTile(_ tile: HomeMixTile, plan: HomePlanUi) {
        if let card = planMixCards(plan).first(where: { $0.mixId == tile.key }) {
            env.homePlan.shelfActivated("made_for_you")
            openMix(card)
        } else {
            openMix(id: tile.key)
        }
    }

    /// A card of "Made for you" was tapped (8.2): Daily Mix 1 and Your Mix have their own screens, the others open the list.
    private func openMix(_ card: MixCardUi) {
        if card.kind == MixKinds.endless {
            openEndless()
            return
        }
        openMix(id: card.mixId, isFirstDaily: card.kind == MixKinds.daily && card.number == 1)
    }

    private func openMix(id: String, isFirstDaily: Bool = false) {
        if id.isEmpty { return }
        if id == "your" {
            router.push(.yourMix)
        } else if id == "daily" || isFirstDaily {
            router.push(.dailyMix)
        } else {
            router.push(.mixDetail(mixId: id))
        }
    }

    private func openHero(_ hero: HeroUi) {
        if let release = hero.release, let song = release.section.songs.first {
            env.brainActions.play(release, startingAt: song)
        } else {
            openMix(id: hero.mixId)
        }
    }

    // MARK: Rewind, replay

    /// The places played from (the plan's tiles), or the last six songs when there are none.
    private func rewindTiles(plan: HomePlanUi, content: HomeContent) -> [HomeRewindTile] {
        if !plan.tiles.isEmpty {
            return plan.tiles.map { HomeRewindTile(key: $0.key, title: $0.title, art: $0.art) }
        }
        return content.recentlyPlayed.prefix(6).map {
            HomeRewindTile(key: "song:" + $0.song.id, title: $0.song.title, art: $0.song.albumArtUriString)
        }
    }

    private func openRewind(_ tile: HomeRewindTile, plan: HomePlanUi, content: HomeContent) {
        if let planTile = plan.tiles.first(where: { $0.key == tile.key }) {
            if !planTile.mixId.isEmpty {
                openMix(id: planTile.mixId)
                return
            }
            let songs = planTile.songIds.compactMap { library.song(id: $0) }
            if let first = songs.first { playback.play(first, in: songs, source: .homeShelf) }
            return
        }
        let queue = content.recentlyPlayed.map(\.song)
        if let song = queue.first(where: { "song:" + $0.id == tile.key }) { playback.play(song, in: queue) }
    }

    // MARK: Track shelves

    /// "Fresh finds" is the first track shelf; the others follow it in the same style. "See all" of Fresh finds shows the plan's
    /// "New" shelves under it.
    @ViewBuilder
    private func trackShelves(plan: HomePlanUi, content: HomeContent, titles: HomeSectionTitles) -> some View {
        let shelves = trackSections(plan: plan, content: content)
        ForEach(Array(shelves.enumerated()), id: \.element.id) { index, shelf in
            VStack(alignment: .leading, spacing: 12) {
                if index == 0 {
                    HomeSectionHeader(wide: titles.freshA, accent: titles.freshB, subtitle: HomeRedesignStrings.freshSubtitle,
                                      actionLabel: plan.newShelves.isEmpty ? nil
                                          : (showNewShelves ? HomeRedesignStrings.showLess : HomeRedesignStrings.seeAll),
                                      onAction: { withAnimation(PixlMotion.state) { showNewShelves.toggle() } })
                } else {
                    HomeSectionHeader(wide: shelf.section.title, accent: "", subtitle: shelf.section.subtitle)
                }
                HomeFreshRow(songs: shelf.section.songs, onPlay: { song in playShelf(shelf, song: song, owned: plan.owned) })
            }
            .shelfSeenIf(plan.owned, shelf.id, env.homePlan)
            if index == 0 && showNewShelves {
                planShelves(plan.newShelves)
            }
        }
    }

    /// One track shelf of the page: the plan's (owned) or the library's (brain rows first, then the discovery shelves).
    private struct TrackShelf: Identifiable {
        let id: String
        let section: HomeMusicSection
        let brain: BrainHomeShelf?
    }

    private func trackSections(plan: HomePlanUi, content: HomeContent) -> [TrackShelf] {
        if plan.owned {
            return plan.shelves.compactMap { shelf in
                if case .tracks(let tracks) = shelf { return TrackShelf(id: tracks.id, section: tracks.section, brain: tracks) }
                return nil
            }
        }
        return env.home.brainShelves.map { TrackShelf(id: "brain." + $0.id, section: $0.section, brain: $0) }
            + content.shelves.map { TrackShelf(id: "lib." + $0.id, section: $0, brain: nil) }
    }

    private func playShelf(_ shelf: TrackShelf, song: Song, owned: Bool) {
        if let brain = shelf.brain {
            if owned { env.homePlan.shelfActivated(brain.id) }
            env.brainActions.play(brain, startingAt: song)
        } else {
            playback.play(song, in: shelf.section.songs, source: .homeShelf)
        }
    }

    private func stationShelves(_ plan: HomePlanUi) -> [HomeShelfUi] {
        plan.shelves.filter { if case .stations = $0 { return true } else { return false } }
    }

    /// The plan's "New" shelves in their old look (the old "New" chip).
    @ViewBuilder
    private func planShelves(_ shelves: [HomeShelfUi]) -> some View {
        ForEach(shelves) { shelf in
            switch shelf {
            case .tracks(let tracks):
                CurrentSongState { currentSongId in
                    HomeDiscoveryShelf(section: tracks.section, currentSongId: currentSongId,
                                       onPlay: { song in
                                           env.homePlan.shelfActivated(tracks.id)
                                           env.brainActions.play(tracks, startingAt: song)
                                       })
                }
            case .mixes(let id, let title, let subtitle, let cards):
                HomeMixShelf(title: title, subtitle: subtitle, cards: cards, onOpen: { card in
                    env.homePlan.shelfActivated(id)
                    openMix(card)
                }, onEndlessHowItWorks: { router.present(AppCover.endlessIntro) })
            case .stations(let id, let title, let subtitle, let cards):
                HomeStationShelf(title: title, subtitle: subtitle, cards: cards, onStart: { card in
                    env.homePlan.shelfActivated(id)
                    env.brainActions.startGenreStation(kind: card.kind, atlasId: card.atlasId, name: card.name)
                })
            }
        }
    }

    // MARK: Footer

    private var footerLinks: [HomeFooterLink] {
        [
            HomeFooterLink(id: "spatial", label: HomeRedesignStrings.spatialEntry) { router.push(.cloudProcessing) },
            HomeFooterLink(id: "shuffleAll", label: HomeRedesignStrings.shuffleAllLink) { shuffleAll() },
            HomeFooterLink(id: "stats", label: HomeRedesignStrings.statsLink) { router.push(.stats) },
            HomeFooterLink(id: "whatsNew", label: HomeRedesignStrings.whatsNew) { router.present(AppSheet.changelog) },
            HomeFooterLink(id: "beta", label: HomeRedesignStrings.betaInfo) { router.present(AppSheet.betaInfo) },
        ]
    }

    /// Android `shuffleAllSongs(queueName = "Shuffle All")`.
    private func shuffleAll() {
        let songs = library.songs
        guard !songs.isEmpty else { return }
        playback.play(songs.shuffled())
    }
}

/// What Home's data depends on (the task re-runs when either changes): the library by its revision, not the whole
/// snapshot (comparing two snapshots walked every song on the main actor after each edit or rescan).
private struct HomeRefreshKey: Equatable {
    var libraryRevision: Int
    var revision: Int
    /// Imported listening history (Spotify / YouTube Music) changed.
    var importedRevision = 0
    /// Ask Taizo's taste changes were made or undone.
    var adjustmentsRevision = 0
}

/// Home geometry.
nonisolated enum HomeMetrics {
    /// The side gutter (redesign: 16 pt).
    static let greetingInset: CGFloat = 16
    /// Until the header was measured: how far Home scrolls before the collapsed header shows.
    static let scrolledThreshold: CGFloat = 200
}

/// Whether Home is scrolled past its big header; observed only by the collapsed header's slot. `headerHeight` is read by the scroll
/// geometry's transform, never by a body.
@Observable
final class HomeScrollState {
    var isScrolled = false
    @ObservationIgnored var headerHeight: CGFloat = 0
}

/// The slot of the collapsed header: it alone reads the scroll flag, and draws the header only while it is shown (a spring in and out:
/// fade and 24 pt slide, Android's medium-low stiffness).
private struct HomeCollapsedSlot: View {
    let scroll: HomeScrollState
    let weekPlays: Int?
    let topSong: String?
    let topSongPlays: Int
    let onAskTaizo: () -> Void
    let onSettings: () -> Void
    let onJobs: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if scroll.isScrolled {
                HomeCollapsedHeader(weekPlays: weekPlays, topSong: topSong, topSongPlays: topSongPlays,
                                    onAskTaizo: onAskTaizo, onSettings: onSettings, onJobs: onJobs)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -24)))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 1), value: scroll.isScrolled)
    }
}

private extension View {
    /// The shelf was on screen for a second (the shelf bandit, 5.10): a task that starts when the shelf appears and is cancelled when it
    /// goes, so a shelf scrolled past counts for nothing. One sleep and one call, off the main actor; nothing per frame.
    func shelfSeen(_ id: String, _ plan: HomePlanState) -> some View {
        task(id: id) {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { await MainActor.run { plan.shelfSeen(id) } }
        }
    }

    /// `shelfSeen` for the plan's shelves only (the library's rows are not the bandit's).
    func shelfSeenIf(_ on: Bool, _ id: String, _ plan: HomePlanState) -> some View {
        task(id: on ? id : "") {
            guard on else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { await MainActor.run { plan.shelfSeen(id) } }
        }
    }
}
