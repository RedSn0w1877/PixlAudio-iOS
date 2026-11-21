import Observation
import PixlLibrary
import PixlModel
import SwiftUI

/// Home (Android `HomeScreen`): the top row (Beta chip; the active-jobs capsule, changelog and settings circles) over a scrolling
/// column, 24 pt apart — greeting card, quick actions, "Made for your listening", Your Mix, the discovery shelves,
/// Just added, Recently Played and the listening stats card. Every Material surface is Liquid Glass with the
/// colour Android filled it with as the tint; layout and sizes are the Compose values (1 dp = 1 pt).
struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    /// A reference: writing the flag re-renders only the top bar that reads it, never this body (and its sections).
    @State private var scroll = HomeScrollState()
    /// Which of the new Home's views the chips pick (docs/brain-spec.md, 8.1).
    @State private var chip: HomeChip = .forYou

    var body: some View {
        let home = env.home
        let content = home.content
        // The music brain's plan (8.1): read from its file before anything else. `owned` false is the page as it was.
        let plan = env.homePlan.ui
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // After an unexpected close: heavy jobs are paused until the person reviews them (once, dismissible).
                if env.health.safeMode.showsBanner {
                    SafeModeBanner(modelBlamed: env.health.localModelBlamed, onReview: {
                        env.health.dismissBanner()
                        router.present(AppSheet.jobs)
                    }, onDismiss: { env.health.dismissBanner() })
                        .padding(.horizontal, HomeMetrics.greetingInset)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                // Once, until a data download is imported or the card is closed: the listening-history import.
                if showsHistoryCard {
                    ListeningHistoryHomeCard(onOpen: { router.push(.listeningHistory) }, onDismiss: {
                        withAnimation(PixlMotion.state) { env.importedHistory.homeCardDismissed = true }
                    })
                    .padding(.horizontal, HomeMetrics.greetingInset)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if plan.owned && !plan.dateLine.isEmpty { HomeDateLine(text: plan.dateLine) }
                HomeGreetingCard(greeting: content.greeting, insight: home.aiInsight ?? content.insight,
                                 isExpanded: home.isInsightExpanded, isLoadingInsight: home.isLoadingInsight,
                                 onToggle: { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { home.toggleInsight() } })
                    .padding(.horizontal, HomeMetrics.greetingInset)

                HomeQuickActionsRow(
                    onShuffleAll: { shuffleAll() },
                    onRecentlyPlayed: { router.push(.recentlyPlayed) },
                    onStats: { router.push(.stats) })

                // 8.10: while the first radios are fetched Home says so; it never shows a spinner or an empty state for it.
                if plan.knowingTotal > 0 { HomeKnowingStrip(done: plan.knowingDone, total: plan.knowingTotal) }
                if plan.offerPicker { HomeArtistPickerCard(onPick: { router.push(.artistPicker) }) }
                if plan.owned {
                    HomeChipsRow(selected: activeChip(plan), chips: offeredChips(plan), onSelect: { picked in
                        if picked == .spatial { router.push(.cloudProcessing) } else { chip = picked }
                    })
                }
                if plan.owned || !plan.tiles.isEmpty { planItems(plan) }

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

                // The plan's "Made for you" shelf holds Your Mix: the legacy block, its placeholders included, is not drawn.
                if !plan.owned { yourMix(content: content, isPreparing: home.isPreparing) }

                // The music brain's "Because you listened to X" rows (docs/brain-spec.md, 8.1): music the listener does
                // not have yet, in front of the legacy shelves. A card plays with the row as the queue. The plan carries
                // these rows itself when it owns Home.
                ForEach(plan.owned ? [] : home.brainShelves) { shelf in
                    CurrentSongState { currentSongId in
                        HomeDiscoveryShelf(section: shelf.section, currentSongId: currentSongId,
                                           onPlay: { song in env.brainActions.play(shelf, startingAt: song) })
                    }
                }

                ForEach(plan.owned ? [] : content.shelves) { section in
                    CurrentSongState { currentSongId in
                        HomeDiscoveryShelf(section: section, currentSongId: currentSongId,
                                           onPlay: { song in playback.play(song, in: section.songs, source: .homeShelf) })
                    }
                }

                if !content.recentlyAdded.isEmpty {
                    RecentlyAddedSection(songs: content.recentlyAdded,
                                         onSongTap: { song in playback.play(song, in: library.songs) })
                }

                if content.recentlyPlayed.count >= HomeLogic.recentlyPlayedMinSongs {
                    let items = content.recentlyPlayed
                    CurrentSongState { currentSongId in
                        RecentlyPlayedSection(items: items, currentSongId: currentSongId,
                                              onSongTap: { song in playback.play(song, in: items.map(\.song)) },
                                              onOpenAll: { router.push(.recentlyPlayed) })
                    }
                }

                if let overview = content.statsOverview {
                    StatsOverviewCard(summary: overview, onOpen: { router.push(.stats) })
                }
            }
            .padding(.bottom, 38)
            // Nothing is drawn below the top bar until the saved plan has been looked for (a frame or two): the old rows are
            // never painted and then swapped out for the plan, and the plan fades in. UI tests draw at once.
            .opacity(plan.resolved || env.launch.isUITest ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: plan.resolved)
        }
        .scrollIndicators(.hidden)
        // Only the scroll view carries the screen id. Applied after the top-bar inset below, it overwrote the
        // identifiers of the Beta, jobs, changelog and settings buttons (UI tests saw all four as `screen.home`).
        .accessibilityIdentifier("screen.home")
        .minimizesTabBarOnScroll()
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > HomeMetrics.scrolledThreshold
        } action: { _, scrolled in
            if scroll.isScrolled != scrolled { scroll.isScrolled = scrolled }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HomeTopBar(scroll: scroll,
                       onBeta: { router.present(AppSheet.betaInfo) },
                       onJobs: { router.present(AppSheet.jobs) },
                       onAskTaizo: { router.present(AppSheet.taisChat) },
                       onChangelog: { router.present(AppSheet.changelog) },
                       onSettings: { router.push(.settings) })
        }
        .background(theme.background.ignoresSafeArea())
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

    // MARK: Your Mix

    @ViewBuilder
    private func yourMix(content: HomeContent, isPreparing: Bool) -> some View {
        let songs = content.yourMix
        if songs.isEmpty {
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
                        await env.home.refresh(snapshot: library.snapshot, libraryRevision: library.songsRevision,
                                               force: true)
                    }
                })
            }
        } else {
            let fallback = content.usesFallbackYourMix
            PlaybackState { currentSongId, isPlaying, isShuffleEnabled in
                YourMixShelfSection(
                    songs: songs,
                    currentSongId: currentSongId,
                    isPlaying: isPlaying,
                    isShuffleEnabled: isShuffleEnabled,
                    onPlayShuffled: {
                        if fallback { shuffleAll() } else { playback.play(songs.shuffled()) }
                    },
                    onSongTap: { song in playback.play(song, in: fallback ? library.songs : songs) },
                    onMore: { song in router.present(AppSheet.songInfo(songId: song.id)) },
                    onCheckOut: { router.push(.yourMix) })
            }
        }
    }

    // MARK: The brain's plan (docs/brain-spec.md, 8.1)

    /// The new Home's rows: the hero, Jump back in, then the shelves of the plan in the plan's order; the chips pick what
    /// shows. Without a plan only Jump back in is drawn, and the library rows below it carry the page.
    @ViewBuilder
    private func planItems(_ plan: HomePlanUi) -> some View {
        if !plan.owned {
            HomeJumpBackIn(tiles: plan.tiles, onTile: openTile)
        } else {
            switch activeChip(plan) {
            case .mixes:
                HomeAllMixes(cards: plan.allMixes, onOpen: openMix)
            case .new:
                planShelves(plan.newShelves)
            default:
                if let hero = plan.hero { HomeHeroCard(hero: hero, onTap: { openHero(hero) }) }
                HomeJumpBackIn(tiles: plan.tiles, onTile: openTile)
                planShelves(plan.shelves)
            }
        }
    }

    /// "Mixes" and "New" are offered only when there is something behind them.
    private func offeredChips(_ plan: HomePlanUi) -> [HomeChip] {
        HomeChip.allCases.filter { chip in
            switch chip {
            case .mixes: !plan.allMixes.isEmpty
            case .new: !plan.newShelves.isEmpty
            default: true
            }
        }
    }

    /// The chip the page shows: a remembered chip whose content has gone falls back to "For you".
    private func activeChip(_ plan: HomePlanUi) -> HomeChip { offeredChips(plan).contains(chip) ? chip : .forYou }

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
                .shelfSeen(shelf.id, env.homePlan)
            case .mixes(let id, let title, let subtitle, let cards):
                HomeMixShelf(title: title, subtitle: subtitle, cards: cards, onOpen: { card in
                    env.homePlan.shelfActivated(id)
                    openMix(card)
                }, onEndlessHowItWorks: { router.present(AppCover.endlessIntro) })
                .shelfSeen(shelf.id, env.homePlan)
            case .stations(let id, let title, let subtitle, let cards):
                HomeStationShelf(title: title, subtitle: subtitle, cards: cards, onStart: { card in
                    env.homePlan.shelfActivated(id)
                    env.brainActions.startGenreStation(kind: card.kind, atlasId: card.atlasId, name: card.name)
                })
                .shelfSeen(shelf.id, env.homePlan)
            }
        }
    }

    /// A card of "Made for you" was tapped (8.2): Daily Mix 1 and Your Mix have their own screens, the others open the list.
    private func openMix(_ card: MixCardUi) {
        // Endless Listening is a station: its first open shows the introduction, every other starts it or picks it up.
        if card.kind == MixKinds.endless {
            if env.endless.isIntroSeen { env.brainActions.startEndless() } else { router.present(AppCover.endlessIntro) }
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

    private func openTile(_ tile: TileUi) {
        if !tile.mixId.isEmpty {
            openMix(id: tile.mixId)
            return
        }
        let songs = tile.songIds.compactMap { library.song(id: $0) }
        if let first = songs.first { playback.play(first, in: songs, source: .homeShelf) }
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

/// Home geometry from the Compose code.
nonisolated enum HomeMetrics {
    /// `navBarEdgeInset(DEFAULT)` with a gesture-nav inset: 16 dp.
    static let greetingInset: CGFloat = 16
    /// `isScrolledPastThreshold`: the greeting card has scrolled away.
    static let scrolledThreshold: CGFloat = 110
    /// Home top bar (`HomeGradientTopBar`): 64 pt; Beta pill starts 20 pt in (12 + 4 + 4), actions end 18 pt in.
    static let topBarHeight: CGFloat = 64
    static let topBarLeading: CGFloat = 20
    static let topBarTrailing: CGFloat = 18
}

// MARK: - Top bar

/// Whether Home is scrolled past the top bar's threshold; observed only by `HomeTopBar` (like Stats' collapse state).
@Observable
final class HomeScrollState {
    var isScrolled = false
}

/// Android `HomeGradientTopBar`: transparent over the list; once scrolled, a `surfaceContainerHighest` scrim fades in
/// behind it (solid to 55 %, 72 % at 80 %, clear at the bottom) reaching the top of the screen.
private struct HomeTopBar: View {
    let scroll: HomeScrollState
    let onBeta: () -> Void
    let onJobs: () -> Void
    /// Ask Taizo (2026-10-23): the assistant, one tap from Home.
    let onAskTaizo: () -> Void
    let onChangelog: () -> Void
    let onSettings: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme

    var body: some View {
        // The count is read here, not in HomeView: `ActiveJobs` writes it only when the number changes, so a scan or a
        // transfer reporting progress never re-runs this bar, and Home's shelves (alive under the other tabs) never
        // see it.
        let activeJobs = env.activeJobs
        let jobCount = activeJobs.badgeCount
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 0) {
                Button(action: onBeta) {
                    HStack(spacing: 8) {
                        Text(verbatim: "β").pixlFont(.titleSmall, weight: .black)
                        Text("Beta").pixlFont(.titleSmall, weight: .semibold)
                    }
                    .foregroundStyle(theme.onSurface)
                    .padding(.horizontal, 14)
                    .frame(height: Tokens.TopBar.circleButtonSize)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), interactive: true)
                .accessibilityIdentifier("home.beta")

                Spacer(minLength: Tokens.Spacing.s)

                HStack(spacing: Tokens.TopBar.actionSpacing) {
                    if jobCount > 0 {
                        ActiveJobsButton(count: jobCount, isWorking: activeJobs.isWorking, action: onJobs,
                                         onCancelAll: { activeJobs.cancelAll() })
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    GlassCircleButton(systemImage: "sparkles", accessibilityLabel: "Ask Taizo",
                                      tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), action: onAskTaizo)
                        .accessibilityIdentifier("ai.taizo.home")
                    GlassCircleButton(systemImage: "newspaper", accessibilityLabel: "Changelog",
                                      tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), action: onChangelog)
                        .accessibilityIdentifier("home.changelog")
                    GlassCircleButton(systemImage: "gearshape", accessibilityLabel: "Settings",
                                      tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), action: onSettings)
                        .accessibilityIdentifier("home.settings")
                }
            }
            .padding(.leading, HomeMetrics.topBarLeading)
            .padding(.trailing, HomeMetrics.topBarTrailing)
            .frame(height: HomeMetrics.topBarHeight)
        }
        // The jobs button appears and goes with a short spring (not while it only changes its count).
        .animation(PixlMotion.bars, value: jobCount > 0)
        .background(alignment: .top) {
            let scrim = theme.surfaceContainerHighest
            LinearGradient(stops: [.init(color: scrim, location: 0), .init(color: scrim, location: 0.55),
                                   .init(color: scrim.opacity(0.72), location: 0.8),
                                   .init(color: scrim.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .opacity(scroll.isScrolled ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: scroll.isScrolled)
                .allowsHitTesting(false)
        }
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
}
