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

    var body: some View {
        let home = env.home
        let content = home.content
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
                HomeGreetingCard(greeting: content.greeting, insight: home.aiInsight ?? content.insight,
                                 isExpanded: home.isInsightExpanded, isLoadingInsight: home.isLoadingInsight,
                                 onToggle: { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { home.toggleInsight() } })
                    .padding(.horizontal, HomeMetrics.greetingInset)

                HomeQuickActionsRow(
                    onShuffleAll: { shuffleAll() },
                    onRecentlyPlayed: { router.push(.recentlyPlayed) },
                    onStats: { router.push(.stats) })

                if !content.mixes.isEmpty {
                    HomeDiscoveryMixes(mixes: content.mixes, isRefreshing: home.isRefreshing,
                                       onRefresh: {
                                           Task {
                                               await home.refresh(snapshot: library.snapshot,
                                                                  libraryRevision: library.songsRevision, force: true)
                                           }
                                       },
                                       onPlay: { section, song in playback.play(song, in: section.songs) })
                }

                yourMix(content: content, isPreparing: home.isPreparing)

                ForEach(content.shelves) { section in
                    CurrentSongState { currentSongId in
                        HomeDiscoveryShelf(section: section, currentSongId: currentSongId,
                                           onPlay: { song in playback.play(song, in: section.songs) })
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
                       onChangelog: { router.present(AppSheet.changelog) },
                       onSettings: { router.push(.settings) })
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: HomeRefreshKey(libraryRevision: library.songsRevision, revision: home.history.revision)) {
            await home.refresh(snapshot: library.snapshot, libraryRevision: library.songsRevision)
        }
        // Cloud Studio's stored jobs (read once, off the main actor): its work may have moved on while the app was closed,
        // and the jobs button should show it.
        .task { await env.cloud.loadForDisplay() }
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
