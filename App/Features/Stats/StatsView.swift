import Observation
import PixlLibrary
import PixlModel
import SwiftUI

/// Listening stats (Android `StatsScreen`): a collapsing header ("Listening Stats", back and refresh circles) with
/// the range tabs (Today / Week to Date / Month to Date / Year to Date / All Time), over the hero cards, the listening
/// timeline (Swift Charts bars styled like Android's capsule bars), top categories, listening habits, top artists,
/// top albums, track concentration (a Swift Charts donut) and the tracks in range. Cards are glass tinted with
/// the containers Android filled them with.
struct StatsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var range: StatsTimeRange = .week
    @State private var summary: PlaybackStatsSummary?
    @State private var isLoading = true
    @State private var refreshToken = 0
    @State private var metric: TimelineMetric = .listeningTime
    @State private var dimension: CategoryDimension = .song
    @State private var collapse = StatsCollapseState()

    private var stamp: ScreenDataCache.Stamp {
        ScreenDataCache.Stamp(historyRevision: env.home.history.revision, songCount: library.songs.count)
    }

    var body: some View {
        // The summary for this range: computed on this visit, else the last one computed from the same inputs (a
        // revisit opens on its content, not a spinner swapped for the whole page mid-push).
        let shown = (summary?.range == range ? summary : nil) ?? ScreenDataCache.stats(range, stamp: stamp) ?? summary
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top
            ZStack(alignment: .top) {
                theme.surface.ignoresSafeArea()
                if isLoading && shown == nil {
                    ProgressView()
                        .controlSize(.large)
                        .tint(theme.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list(topInset: topInset, summary: shown)
                }
                StatsHeader(collapse: collapse, topInset: topInset, range: $range, isBusy: isLoading,
                            onBack: { router.pop() }, onRefresh: { refreshToken += 1 })
            }
            // The stack (not the reader) spans the status bar so the header and list draw under it; a reader that
            // ignored the safe area itself would report a top inset of 0 and put the buttons under the status bar.
            .ignoresSafeArea(edges: .top)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: Key(range: range, revision: env.home.history.revision, songCount: library.songs.count,
                      token: refreshToken)) {
            await reload()
        }
        .accessibilityIdentifier("screen.stats")
    }

    private struct Key: Equatable {
        var range: StatsTimeRange
        var revision: Int
        var songCount: Int
        var token: Int
    }

    private func list(topInset: CGFloat, summary: PlaybackStatsSummary?) -> some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                Spacer().frame(height: topInset + StatsMetrics.expandedBarHeight + StatsMetrics.tabsHeight
                               + StatsMetrics.tabContentSpacing - 24)
                StatsHeroSection(summary: summary)
                ListeningTimelineSection(summary: summary, metric: $metric)
                CategoryMetricsSection(summary: summary, dimension: $dimension)
                ListeningHabitsCard(summary: summary)
                TopArtistsCard(summary: summary)
                TopAlbumsCard(summary: summary)
                TrackConcentrationCard(summary: summary)
                SongStatsCard(summary: summary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            let offset = geometry.contentOffset.y + geometry.contentInsets.top
            let span = StatsMetrics.expandedBarHeight - StatsMetrics.collapsedBarHeight
            return (min(max(offset / span, 0), 1) * 100).rounded() / 100
        } action: { _, fraction in
            collapse.fraction = fraction
        }
        .refreshable { refreshToken += 1 }
    }

    private func reload() async {
        let home = env.home
        await home.history.ensureLoaded()
        let clock = home.history.clock
        let events = home.history.events
        let songs = library.songs
        let range = self.range
        let stamp = self.stamp
        if summary?.range != range { isLoading = true }
        let result = await Task.detached(priority: .userInitiated) {
            PlaybackStats.buildSummary(range: range, songs: songs, nowMillis: clock.nowMs(), events: events,
                                       timeZone: clock.timeZone)
        }.value
        guard !Task.isCancelled else { return }
        ScreenDataCache.storeStats(result, stamp: stamp)
        summary = result
        isLoading = false
    }
}

/// Stats geometry (Android `StatsScreen` + `CollapsibleCommonTopBar`). Android's header spans 176 dp including the
/// status bar; the port keeps the part below the safe area.
nonisolated enum StatsMetrics {
    static let expandedBarHeight: CGFloat = 132
    static let collapsedBarHeight: CGFloat = 62
    static let tabsHeight: CGFloat = 62
    static let tabContentSpacing: CGFloat = 20
}

/// The header's collapse fraction, observed only by the header (scrolling never re-renders the list).
@Observable
final class StatsCollapseState {
    var fraction: CGFloat = 0
}

/// Android `CollapsibleCommonTopBar` + `RangeTabsHeader`: the title (`headlineMedium` bold, scaled 1.2 → 0.8) slides
/// from the bottom-left of the expanded bar to beside the back button; the bar's `surfaceContainerHigh` fill fades
/// in over the first half of the collapse. Back / refresh are glass circles; the range tabs a glass pill row.
private struct StatsHeader: View {
    let collapse: StatsCollapseState
    let topInset: CGFloat
    @Binding var range: StatsTimeRange
    let isBusy: Bool
    let onBack: () -> Void
    let onRefresh: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let f = collapse.fraction
        let barHeight = StatsMetrics.expandedBarHeight + (StatsMetrics.collapsedBarHeight - StatsMetrics.expandedBarHeight) * f
        let titleBox: CGFloat = 88 + (56 - 88) * f
        let titleStart: CGFloat = 20 + (68 - 20) * f
        let scale = (1.2 + (0.8 - 1.2) * f) / 1.2
        let solidAlpha = min(max(f * 2, 0), 1)
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Text("Listening Stats")
                    .pixlFont(.custom(size: 28 * 1.2, weight: .bold))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .scaleEffect(scale, anchor: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: titleBox)
                    .padding(.leading, titleStart)
                    .padding(.trailing, 24)
                    .offset(y: (barHeight - titleBox) * (1 - f))
                    .accessibilityAddTraits(.isHeader)
                HStack {
                    GlassCircleButton(systemImage: "arrow.backward", accessibilityLabel: "Back",
                                      tint: theme.surfaceContainerLow.opacity(GlassTint.surface), action: onBack)
                        .accessibilityIdentifier("stats.back")
                    Spacer()
                    GlassCircleButton(systemImage: "arrow.clockwise", accessibilityLabel: "Refresh listening stats",
                                      tint: theme.surfaceContainerLow.opacity(GlassTint.surface), action: onRefresh)
                        .opacity(isBusy ? 0.38 : 1)
                        .disabled(isBusy)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }
            .frame(height: barHeight, alignment: .top)
            .clipped()

            GlassPillRow(items: StatsTimeRange.allCases.map { GlassPillRow<StatsTimeRange>.Item(id: $0, title: $0.displayName) },
                         selection: $range, uppercase: false, accessibilityIdentifierPrefix: "statsRange")
                .frame(height: StatsMetrics.tabsHeight)
        }
        .padding(.top, topInset)
        .padding(.bottom, 8)
        .background(theme.surfaceContainerHigh.opacity(solidAlpha))
    }
}
