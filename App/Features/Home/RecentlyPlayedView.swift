import PixlLibrary
import PixlModel
import SwiftUI

/// Recently Played (Android `RecentlyPlayedScreen`): a 190 pt header (secondary/primary wash, "Recently Played" at
/// 34 pt), the range chips (Today … All Time, Week to Date selected first), Play latest / Shuffle, then the songs
/// grouped under timestamp dividers ("Today", "Yesterday", dates; hours for Today). Each song once, at its latest play.
struct RecentlyPlayedView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var range: StatsTimeRange = .week
    @State private var groups: [HomeLogic.TimestampGroup] = []
    @State private var queue: [Song] = []
    @State private var isLoaded = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [theme.secondary.opacity(0.24), theme.surface.opacity(0.55), theme.surface],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6))
                .background(theme.surface)
                .ignoresSafeArea()

            if !isLoaded {
                ProgressView()
                    .controlSize(.large)
                    .tint(theme.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }

            GlassCircleButton(systemImage: "arrow.backward", accessibilityLabel: "Back",
                              tint: theme.surface.opacity(GlassTint.surface)) { router.pop() }
                .padding(.leading, 10)
                .padding(.top, 8)
                .accessibilityIdentifier("recentlyPlayed.back")
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: Key(range: range, revision: env.home.history.revision, songCount: library.songs.count)) {
            await reload()
        }
        .accessibilityIdentifier("screen.recentlyPlayed")
    }

    private struct Key: Equatable {
        var range: StatsTimeRange
        var revision: Int
        var songCount: Int
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                RecentlyPlayedHeader()
                GlassPillRow(items: StatsTimeRange.allCases.map {
                                 GlassPillRow<StatsTimeRange>.Item(id: $0, title: $0.displayName,
                                                                   systemImage: $0 == range ? "clock.arrow.circlepath" : nil)
                             },
                             selection: $range, uppercase: false, height: 44, textPadding: 16, spacing: 8,
                             edgePadding: 16, selectedTint: theme.tertiary, accessibilityIdentifierPrefix: "recentRange")
                if groups.isEmpty {
                    emptyState.padding(.horizontal, 16)
                } else {
                    MixPlayShuffleRow(playTitle: "Play latest", height: 52, verticalPadding: 0, horizontalPadding: 16,
                                      outerRadius: 52,
                                      onPlay: { if let first = queue.first { playback.play(first, in: queue) } },
                                      onShuffle: { playback.play(queue.shuffled()) })
                    ForEach(groups) { group in
                        TimestampDivider(label: group.label, isHourBucket: group.isHourBucket)
                            .padding(.horizontal, 16)
                        ForEach(group.items) { item in
                            PlaybackRowState(songId: item.song.id) { isCurrent, isPlaying in
                                SongCard(song: item.song, isCurrent: isCurrent, isPlaying: isPlaying,
                                         onTap: { playback.play(item.song, in: queue) },
                                         onMore: { router.present(AppSheet.songInfo(songId: item.song.id)) })
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
    }

    /// Android `RecentlyPlayedEmptyState`: a 26 pt `surfaceContainerLow` card.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No recent plays in \(range.displayName.lowercased())")
                .pixlFont(.titleMedium, weight: .semibold)
                .foregroundStyle(theme.onSurface)
            Text("Change the range or play more songs to fill this timeline.")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(GlassTint.surface))
    }

    private func reload() async {
        let home = env.home
        await home.history.ensureLoaded()
        let clock = home.history.clock
        let events = home.history.events
        let songsById = library.songsById
        let range = self.range
        let use24Hour = HomeLogic.uses24HourClock
        let result = await Task.detached(priority: .userInitiated) { () -> ([HomeLogic.TimestampGroup], [Song]) in
            let now = clock.nowMs()
            let items = HomeLogic.mapRecentlyPlayed(history: PlaybackStats.playbackHistory(events), songsById: songsById,
                                                    range: range, nowMs: now, timeZone: clock.timeZone)
            let groups = HomeLogic.timestampGroups(items, range: range, nowMs: now, timeZone: clock.timeZone,
                                                   use24Hour: use24Hour)
            return (groups, items.map(\.song))
        }.value
        guard !Task.isCancelled else { return }
        groups = result.0
        queue = result.1
        isLoaded = true
    }
}

/// The 190 pt header: wash (secondary 24 % → primary 10 % → surface) and the title at the bottom, 16 pt in. It
/// parallaxes (0.36×) and fades over 520 pt as the list scrolls.
private struct RecentlyPlayedHeader: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(stops: [.init(color: theme.secondary.opacity(0.24), location: 0),
                                   .init(color: theme.primary.opacity(0.10), location: 0.33),
                                   .init(color: theme.surface.opacity(0.95), location: 0.66),
                                   .init(color: theme.surface, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            Text("Recently Played")
                .fontWidth(.expanded)
                .pixlFont(.custom(size: 34, weight: .semibold, lineHeight: 38, tracking: -0.4))
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(height: 190)
        .visualEffect { content, proxy in
            let offset = max(-proxy.frame(in: .scrollView).minY, 0)
            return content
                .offset(y: offset * 0.36)
                .opacity(Double(min(max(1 - offset / 520, 0), 1)))
        }
    }
}

/// Android `RecentlyPlayedTimestampDivider`: fading 8 pt rails either side of a 22 pt chip with a dot — `primary`
/// for hour buckets, `secondary` for days. The chip is tinted glass.
private struct TimestampDivider: View {
    let label: String
    let isHourBucket: Bool

    @Environment(\.appTheme) private var theme

    var body: some View {
        let rail = isHourBucket ? theme.primary : theme.secondary
        let chip = isHourBucket ? theme.primaryContainer : theme.secondaryContainer
        let chipContent = isHourBucket ? theme.onPrimaryContainer : theme.onSecondaryContainer
        HStack(spacing: 10) {
            Capsule()
                .fill(LinearGradient(colors: [rail.opacity(0), rail.opacity(0.5)], startPoint: .leading, endPoint: .trailing))
                .frame(height: 8)
            HStack(spacing: 6) {
                Circle().fill(rail).frame(width: 6, height: 6)
                Text(label)
                    .pixlFont(.labelMedium, weight: .semibold)
                    .foregroundStyle(chipContent)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), tint: chip.opacity(0.78))
            .fixedSize()
            Capsule()
                .fill(LinearGradient(colors: [rail.opacity(0.5), rail.opacity(0)], startPoint: .leading, endPoint: .trailing))
                .frame(height: 8)
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
