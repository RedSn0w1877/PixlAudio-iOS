import PixlModel
import SwiftUI

/// Home — placeholder until stage 7b ports PixlAudio's Home (`HomeScreen.kt`). Kept trivially simple, but already
/// in PixlAudio's layout so the shell screenshots read right: the top row (Beta chip; jobs, changelog and settings
/// circles), the greeting card, the quick-action pills, and a recently-played list.
struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
                topRow
                GlassCard(cornerRadius: Tokens.Shell.navBarCornerRadius, tint: theme.primaryContainer) {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        Text("Good evening — your library is ready")
                            .pixlFont(.titleLarge, weight: .bold)
                            .foregroundStyle(theme.onPrimaryContainer)
                            .lineLimit(2)
                        Text("\(library.songs.count) songs in your library")
                            .pixlFont(.bodyMedium, weight: .semibold)
                            .foregroundStyle(theme.onPrimaryContainer.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.Spacing.xl)
                    .padding(.vertical, 18)
                }
                .padding(.horizontal, Tokens.Spacing.l)
                quickActions
                SectionHeader("Recently Played", subtitle: "Placeholder — Home arrives in stage 7b")
                LazyVStack(spacing: Tokens.SongCard.listSpacing) {
                    ForEach(library.songs.prefix(8)) { song in
                        SongCard(song: song, isCurrent: playback.current?.id == song.id,
                                 isPlaying: playback.isPlaying,
                                 onTap: { playback.play(song, in: library.songs) })
                    }
                }
                .padding(.horizontal, Tokens.Spacing.l)
            }
            .padding(.bottom, Tokens.Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("screen.home")
    }

    private var topRow: some View {
        HStack(spacing: Tokens.TopBar.actionSpacing) {
            GlassPillButton(title: "Beta", systemImage: "b.circle", style: .titleSmall.weight(.semibold)) {
                router.present(AppSheet.betaInfo)
            }
            .accessibilityIdentifier("home.beta")
            Spacer()
            GlassCircleButton(systemImage: "hourglass", accessibilityLabel: "Jobs") {
                router.present(AppSheet.jobs)
            }
            GlassCircleButton(systemImage: "newspaper", accessibilityLabel: "Changelog") {
                router.present(AppSheet.changelog)
            }
            GlassCircleButton(systemImage: "gearshape", accessibilityLabel: "Settings") {
                router.push(.settings)
            }
            .accessibilityIdentifier("home.settings")
        }
        .padding(.leading, Tokens.Spacing.l)
        .padding(.trailing, Tokens.TopBar.actionTrailing)
        .frame(height: Tokens.TopBar.height)
    }

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Container spacing below the 10 pt gap: the pills share one render pass but never blend at rest.
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 10) {
                    GlassPillButton(title: "Shuffle All", systemImage: "shuffle", tint: theme.primaryContainer.opacity(GlassTint.container),
                                    foreground: theme.onPrimaryContainer) {
                        playback.play(library.songs.shuffled())
                    }
                    GlassPillButton(title: "Recently Played", systemImage: "clock", tint: theme.primaryContainer.opacity(GlassTint.container),
                                    foreground: theme.onPrimaryContainer) {
                        router.push(.recentlyPlayed)
                    }
                    GlassPillButton(title: "Stats", systemImage: "chart.bar.xaxis", tint: theme.primaryContainer.opacity(GlassTint.container),
                                    foreground: theme.onPrimaryContainer) {
                        router.push(.stats)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.l)
            }
        }
        .scrollClipDisabled()
    }
}

/// Daily Mix (Android `DailyMixScreen`) — stage 7b.
struct DailyMixView: View {
    var body: some View {
        PlaceholderScreen(title: "Daily Mix", systemImage: "sparkles", owner: "Stage 7b — Home, Stats, mixes",
                          screenID: "dailyMix")
    }
}

/// Your Mix (Android `YourMixScreen`) — stage 7b.
struct YourMixView: View {
    var body: some View {
        PlaceholderScreen(title: "Your Mix", systemImage: "shuffle", owner: "Stage 7b — Home, Stats, mixes",
                          screenID: "yourMix")
    }
}

/// Recently played (Android `RecentlyPlayedScreen`) — stage 7b.
struct RecentlyPlayedView: View {
    var body: some View {
        PlaceholderScreen(title: "Recently Played", systemImage: "clock", owner: "Stage 7b — Home, Stats, mixes",
                          screenID: "recentlyPlayed")
    }
}

/// Listening stats (Android `StatsScreen`) — stage 7b.
struct StatsView: View {
    var body: some View {
        PlaceholderScreen(title: "Stats", systemImage: "chart.bar.xaxis", owner: "Stage 7b — Home, Stats, mixes",
                          screenID: "stats")
    }
}

/// Home's sheets (Android `BetaInfoBottomSheet`, `ChangelogBottomSheet`, `JobsBottomSheet`) — stage 7b.
struct HomeInfoSheet: View {
    let sheet: AppSheet

    var body: some View {
        SheetScaffold(title) {
            Text("Placeholder — stage 7b")
                .pixlFont(.bodyMedium)
                .padding(.horizontal, Tokens.Spacing.xxl)
        }
        .accessibilityIdentifier("screen.\(sheet.id)")
    }

    private var title: LocalizedStringKey {
        switch sheet {
        case .changelog: "What's new"
        case .jobs: "Jobs"
        default: "PixlAudio Beta"
        }
    }
}
