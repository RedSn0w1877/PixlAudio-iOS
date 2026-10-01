import PixlLibrary
import PixlModel
import SwiftUI

/// Home (Android `HomeScreen`): the top row (Beta chip; jobs, changelog and settings circles) over a scrolling
/// column, 24 pt apart — greeting card, quick actions, "Made for your listening", Your Mix, the discovery shelves,
/// Just added, Recently Played and the listening stats card. Every Material surface is Liquid Glass with the
/// colour Android filled it with as the tint; layout and sizes are the Compose values (1 dp = 1 pt).
struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var isScrolled = false

    var body: some View {
        let home = env.home
        let content = home.content
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HomeGreetingCard(greeting: content.greeting, insight: content.insight,
                                 isExpanded: home.isInsightExpanded,
                                 onToggle: { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { home.toggleInsight() } })
                    .padding(.horizontal, HomeMetrics.greetingInset)

                HomeQuickActionsRow(
                    onShuffleAll: { shuffleAll() },
                    onRecentlyPlayed: { router.push(.recentlyPlayed) },
                    onStats: { router.push(.stats) })

                if !content.mixes.isEmpty {
                    HomeDiscoveryMixes(mixes: content.mixes, isRefreshing: home.isRefreshing,
                                       onRefresh: { Task { await home.refresh(snapshot: library.snapshot, force: true) } },
                                       onPlay: { section, song in playback.play(song, in: section.songs) })
                }

                yourMix(content: content, isPreparing: home.isPreparing)

                ForEach(content.shelves) { section in
                    HomeDiscoveryShelf(section: section, currentSongId: playback.current?.id,
                                       onPlay: { song in playback.play(song, in: section.songs) })
                }

                if !content.recentlyAdded.isEmpty {
                    RecentlyAddedSection(songs: content.recentlyAdded,
                                         onSongTap: { song in playback.play(song, in: library.songs) })
                }

                if content.recentlyPlayed.count >= HomeLogic.recentlyPlayedMinSongs {
                    let queue = content.recentlyPlayed.map(\.song)
                    RecentlyPlayedSection(items: content.recentlyPlayed, currentSongId: playback.current?.id,
                                          onSongTap: { song in playback.play(song, in: queue) },
                                          onOpenAll: { router.push(.recentlyPlayed) })
                }

                if let overview = content.statsOverview {
                    StatsOverviewCard(summary: overview, onOpen: { router.push(.stats) })
                }
            }
            .padding(.bottom, 38)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > HomeMetrics.scrolledThreshold
        } action: { _, scrolled in
            isScrolled = scrolled
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HomeTopBar(isScrolled: isScrolled,
                       jobCount: home.jobs(libraryProgress: library.lastImportProgress).count,
                       onBeta: { router.present(AppSheet.betaInfo) },
                       onJobs: { router.present(AppSheet.jobs) },
                       onChangelog: { router.present(AppSheet.changelog) },
                       onSettings: { router.push(.settings) })
        }
        .overlay(alignment: .bottom) { bottomGradient }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: HomeRefreshKey(snapshot: library.snapshot, revision: home.history.revision)) {
            await home.refresh(snapshot: library.snapshot)
        }
        .accessibilityIdentifier("screen.home")
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
                        await env.home.refresh(snapshot: library.snapshot, force: true)
                    }
                })
            }
        } else {
            let fallback = content.usesFallbackYourMix
            YourMixShelfSection(
                songs: songs,
                currentSongId: playback.current?.id,
                isPlaying: playback.isPlaying,
                isShuffleEnabled: playback.isShuffleEnabled,
                onPlayShuffled: {
                    if fallback { shuffleAll() } else { playback.play(songs.shuffled()) }
                },
                onSongTap: { song in playback.play(song, in: fallback ? library.songs : songs) },
                onMore: { song in router.present(AppSheet.songInfo(songId: song.id)) },
                onCheckOut: { router.push(.yourMix) })
        }
    }

    /// Android `shuffleAllSongs(queueName = "Shuffle All")`.
    private func shuffleAll() {
        let songs = library.songs
        guard !songs.isEmpty else { return }
        playback.play(songs.shuffled())
    }

    /// Android draws a gradient behind the bottom bar (`resolveMainScreenBottomGradientHeight`: bar 64 + mini player
    /// 64 + 8 + 8 pt) fading into `surfaceContainerLowest`, so content dims as it passes under the bars.
    private var bottomGradient: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.2),
                               .init(color: theme.surfaceContainerLowest, location: 0.8),
                               .init(color: theme.surfaceContainerLowest, location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: HomeMetrics.bottomGradientHeight)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// What Home's data depends on (the task re-runs when either changes).
private struct HomeRefreshKey: Equatable {
    var snapshot: LibrarySnapshot
    var revision: Int
}

/// Home geometry from the Compose code.
nonisolated enum HomeMetrics {
    /// `navBarEdgeInset(DEFAULT)` with a gesture-nav inset: 16 dp.
    static let greetingInset: CGFloat = 16
    /// `isScrolledPastThreshold`: the greeting card has scrolled away.
    static let scrolledThreshold: CGFloat = 110
    static let bottomGradientHeight: CGFloat = 144
    /// Home top bar (`HomeGradientTopBar`): 64 pt; Beta pill starts 20 pt in (12 + 4 + 4), actions end 18 pt in.
    static let topBarHeight: CGFloat = 64
    static let topBarLeading: CGFloat = 20
    static let topBarTrailing: CGFloat = 18
}

// MARK: - Top bar

/// Android `HomeGradientTopBar`: transparent over the list; once scrolled, a `surfaceContainerHighest` scrim fades in
/// behind it (solid to 55 %, 72 % at 80 %, clear at the bottom) reaching the top of the screen.
private struct HomeTopBar: View {
    let isScrolled: Bool
    let jobCount: Int
    let onBeta: () -> Void
    let onJobs: () -> Void
    let onChangelog: () -> Void
    let onSettings: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
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
                        GlassCircleButton(systemImage: "hourglass", accessibilityLabel: "Active jobs",
                                          tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), badge: jobCount,
                                          action: onJobs)
                            .accessibilityIdentifier("home.jobs")
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
        .background(alignment: .top) {
            let scrim = theme.surfaceContainerHighest
            LinearGradient(stops: [.init(color: scrim, location: 0), .init(color: scrim, location: 0.55),
                                   .init(color: scrim.opacity(0.72), location: 0.8),
                                   .init(color: scrim.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .opacity(isScrolled ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: isScrolled)
                .allowsHitTesting(false)
        }
    }
}
