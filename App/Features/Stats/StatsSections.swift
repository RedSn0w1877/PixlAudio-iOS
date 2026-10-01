import Charts
import PixlLibrary
import PixlModel
import SwiftUI

// The Stats screen's sections (Android StatsScreen.kt). Each Material card is a glass panel tinted with the colour
// Android filled it with; controls and rows inside a card are fills (no glass on glass).

/// Android `TimelineMetric`.
nonisolated enum TimelineMetric: String, Hashable, Sendable, CaseIterable {
    case listeningTime, playCount, averageSession

    var title: String {
        switch self {
        case .listeningTime: "Listening time"
        case .playCount: "Play count"
        case .averageSession: "Avg. session"
        }
    }

    var description: String {
        switch self {
        case .listeningTime: "Total listening captured in the selected range."
        case .playCount: "How many sessions you completed per segment."
        case .averageSession: "Average listening length for each segment."
        }
    }

    func value(_ entry: TimelineEntry) -> Double {
        switch self {
        case .listeningTime: Double(entry.totalDurationMs)
        case .playCount: Double(entry.playCount)
        case .averageSession: entry.playCount > 0 ? Double(entry.totalDurationMs) / Double(entry.playCount) : 0
        }
    }

    /// `formatEntryValue`.
    func format(_ entry: TimelineEntry) -> String {
        switch self {
        case .listeningTime: HomeLogic.listeningDurationCompact(entry.totalDurationMs)
        case .playCount: "\(entry.playCount) plays"
        case .averageSession:
            HomeLogic.listeningDurationCompact(entry.playCount > 0 ? entry.totalDurationMs / Int64(entry.playCount) : 0)
        }
    }
}

/// Android `CategoryDimension` (chips shown in reverse: Song, Album, Artist, Genre).
nonisolated enum CategoryDimension: String, Hashable, Sendable, CaseIterable {
    case genre, artist, album, song

    var title: String {
        switch self {
        case .genre: "Genre"
        case .artist: "Artist"
        case .album: "Album"
        case .song: "Song"
        }
    }

    var cardTitle: String { "Listening by \(title.lowercased())" }
}

/// `rememberStatsMetricValueStyle`: compact 10/12 pt, else 12/14 pt, heavy-ish.
private extension PixlTextStyle {
    static func metricValue(compact: Bool) -> PixlTextStyle {
        .custom(size: compact ? 10 : 12, weight: .semibold, lineHeight: compact ? 12 : 14)
    }
    /// `rememberStatsSectionTitleStyle`: 24 pt, weight 570, −0.2 tracking.
    static let statsSectionTitle = PixlTextStyle.custom(size: 24, weight: .semibold, lineHeight: 28, tracking: -0.2)
    /// `titleLargeEmphasized`.
    static let titleLargeEmphasized = PixlTextStyle.titleLarge.weight(.semibold)
}

private func statsCard<Content: View>(radius: CGFloat = Tokens.Radius.card, tint: Color,
                                      @ViewBuilder content: () -> Content) -> some View {
    content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint)
}

/// A capsule progress bar (Android `LinearProgressIndicator`).
private struct StatsProgressBar: View {
    let progress: Double
    let color: Color
    let track: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color).frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Hero (StatsHeroSection)

struct StatsHeroSection: View {
    let summary: PlaybackStatsSummary?
    @Environment(\.appTheme) private var theme

    var body: some View {
        let hasData = (summary?.totalDurationMs ?? 0) > 0 || (summary?.totalPlayCount ?? 0) > 0
        HStack(spacing: 12) {
            hero("Listening", hasData ? HomeLogic.listeningDurationCompact(summary?.totalDurationMs ?? 0) : "--",
                 container: theme.primaryContainer, content: theme.onPrimaryContainer)
            hero("Plays", hasData ? "\(summary?.totalPlayCount ?? 0)" : "--",
                 container: theme.tertiaryContainer, content: theme.onTertiaryContainer)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Android `HeroCard`: 24 pt corners, 20 pt padding, `labelLarge` medium over a 32 pt bold value.
    private func hero(_ title: LocalizedStringKey, _ value: String, container: Color, content: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .pixlFont(.labelLarge, weight: .medium)
                .foregroundStyle(content.opacity(0.85))
            Text(value)
                .pixlFont(.custom(size: 32, weight: .bold))
                .foregroundStyle(content)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: Tokens.Radius.large, style: .continuous),
                   tint: container.opacity(GlassTint.container))
    }
}

// MARK: - Shared pieces

/// Android `StatsEmptyState`: a 28 pt `surfaceContainer` card, a 72 pt `primaryContainer` badge with the icon,
/// title and subtitle centred.
private struct StatsEmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(theme.primary)
                .frame(width: 72, height: 72)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(theme.primaryContainer))
            VStack(spacing: 4) {
                Text(title)
                    .pixlFont(.titleMedium, weight: .semibold)
                    .foregroundStyle(theme.onSurface)
                Text(subtitle)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .pixlGlass(in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous),
                   tint: theme.surfaceContainer.opacity(GlassTint.surface))
    }
}

/// Android `StatsHighlightRow`: a 40 pt `primary` 12 % circle with the icon, then title / value / supporting.
private struct StatsHighlightRow: View {
    let title: LocalizedStringKey
    let value: String
    let supporting: String
    let symbol: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.primary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(theme.primary.opacity(0.12)))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).pixlFont(.labelMedium).foregroundStyle(theme.onSurfaceVariant)
                Text(value).pixlFont(.titleMedium, weight: .medium).foregroundStyle(theme.onSurface)
                Text(supporting).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Section heading (24 pt title + `bodyMedium` supporting copy, 4 pt in).
private struct StatsSectionHeading: View {
    let title: LocalizedStringKey
    let subtitle: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .pixlFont(.statsSectionTitle)
                .foregroundStyle(theme.onSurface)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Android's `FilterChip` rows: glass capsules (32 pt), the selected one tinted with its accent.
private struct StatsChipRow<ID: Hashable & Sendable>: View {
    let items: [(id: ID, title: String, accent: Color, onAccent: Color)]
    @Binding var selection: ID
    @Environment(\.appTheme) private var theme

    var body: some View {
        GlassEffectContainer(spacing: 3) {
            HStack(spacing: 8) {
                ForEach(items, id: \.id) { item in
                    let isSelected = item.id == selection
                    Button {
                        withAnimation(PixlMotion.selection) { selection = item.id }
                    } label: {
                        Text(item.title)
                            .pixlFont(.labelLarge, weight: isSelected ? .bold : .medium)
                            .foregroundStyle(isSelected ? item.onAccent : theme.onSurface)
                            .lineLimit(1)
                            .padding(.horizontal, 16)
                            .frame(height: 32)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(isSelected ? Glass.regular.tint(item.accent.opacity(GlassTint.prominent)).interactive()
                                            : Glass.regular.tint(theme.surfaceContainer.opacity(GlassTint.surface)).interactive(),
                                 in: Capsule())
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Android `CategoryRankBadge`: 16 pt corners, ≥ 34 pt, the top rank filled with the accent.
private struct RankBadge: View {
    let rank: Int
    let accent: Color
    let onAccent: Color
    let highlighted: Bool

    var body: some View {
        Text("\(rank)")
            .pixlFont(.custom(size: 12, weight: .bold, lineHeight: 14))
            .foregroundStyle(highlighted ? onAccent : accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 34, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(highlighted ? accent : accent.opacity(0.24)))
    }
}

// MARK: - Listening timeline (ListeningTimelineSection)

struct ListeningTimelineSection: View {
    let summary: PlaybackStatsSummary?
    @Binding var metric: TimelineMetric
    @Environment(\.appTheme) private var theme

    var body: some View {
        let range = summary?.range ?? .week
        let timeline = summary?.timeline ?? []
        let hasTimeline = timeline.contains { $0.totalDurationMs > 0 || $0.playCount > 0 }
        let use24Hour = HomeLogic.uses24HourClock
        VStack(alignment: .leading, spacing: 16) {
            StatsSectionHeading(title: "Listening timeline", subtitle: metric.description + " " + supportCopy(range))
            StatsChipRow(items: TimelineMetric.allCases.map { (id: $0, title: $0.title, accent: theme.primary, onAccent: theme.onPrimary) },
                         selection: $metric)
            if !hasTimeline {
                StatsEmptyState(symbol: "play.circle", title: "No listening data yet",
                                subtitle: "Press play to start building your listening timeline")
            } else {
                statsCard(tint: cardColor(range)) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rhythmTitle(range))
                                    .pixlFont(.titleSmall, weight: .semibold)
                                    .foregroundStyle(theme.onSurface)
                                Text(groupedCopy(range))
                                    .pixlFont(.bodySmall)
                                    .foregroundStyle(theme.onSurfaceVariant)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            metricBadge
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                        TimelineBarChart(entries: timeline, metric: metric, range: range, use24Hour: use24Hour)
                    }
                    .padding(.vertical, 20)
                }
                if let peak = summary?.peakTimeline {
                    StatsHighlightRow(title: "Peak segment",
                                 value: HomeLogic.timelineLabel(peak.label, range: range, use24Hour: use24Hour),
                                 supporting: metric.format(peak), symbol: "chart.line.uptrend.xyaxis")
                }
            }
        }
    }

    /// Android `TimelineMetricBadge`.
    private var metricBadge: some View {
        let (container, content): (Color, Color) = switch metric {
        case .listeningTime: (theme.primaryContainer, theme.onPrimaryContainer)
        case .playCount: (theme.secondaryContainer, theme.onSecondaryContainer)
        case .averageSession: (theme.tertiaryContainer, theme.onTertiaryContainer)
        }
        return Text(metric.title)
            .pixlFont(.labelMedium, weight: .semibold)
            .foregroundStyle(content)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(container))
    }

    private func cardColor(_ range: StatsTimeRange) -> Color {
        switch range {
        case .day, .week: theme.primaryContainer.opacity(0.45)
        case .month, .year: theme.secondaryContainer.opacity(0.42)
        case .all: theme.tertiaryContainer.opacity(0.40)
        }
    }

    private func supportCopy(_ range: StatsTimeRange) -> String {
        switch range {
        case .day: "Split into 4-hour windows to reveal your daily rhythm."
        case .week: "Daily bars make week-to-week habits easy to compare."
        case .month: "Weekly bars show how the month is trending."
        case .year: "Monthly bars show seasonality across the year."
        case .all: "Yearly bars summarize your full history."
        }
    }

    private func rhythmTitle(_ range: StatsTimeRange) -> String {
        switch range {
        case .day: "Daily rhythm"
        case .week: "Weekly rhythm"
        case .month: "Monthly rhythm"
        case .year: "Year at a glance"
        case .all: "All-time progression"
        }
    }

    private func groupedCopy(_ range: StatsTimeRange) -> String {
        switch range {
        case .day: "Grouped into 4-hour segments"
        case .week: "Grouped by day of week"
        case .month: "Grouped by week of month"
        case .year: "Grouped by month"
        case .all: "Grouped by year"
        }
    }
}

/// Android `TimelineChartSpec`.
nonisolated struct TimelineChartSpec: Sendable, Equatable {
    var minItemWidth: CGFloat
    var maxItemWidth: CGFloat
    var maxVisibleItems: Int
    var chartHeight: CGFloat
    var labelMaxLines: Int
    var horizontalPadding: CGFloat

    static func forRange(_ range: StatsTimeRange, entryCount: Int) -> TimelineChartSpec {
        switch range {
        case .day: TimelineChartSpec(minItemWidth: 52, maxItemWidth: 72, maxVisibleItems: 5, chartHeight: 224, labelMaxLines: 1, horizontalPadding: 20)
        case .week: TimelineChartSpec(minItemWidth: 50, maxItemWidth: 68, maxVisibleItems: 6, chartHeight: 224, labelMaxLines: 1, horizontalPadding: 20)
        case .month: TimelineChartSpec(minItemWidth: 62, maxItemWidth: 82, maxVisibleItems: 4, chartHeight: 232, labelMaxLines: 1, horizontalPadding: 16)
        case .year: TimelineChartSpec(minItemWidth: 56, maxItemWidth: 68, maxVisibleItems: 5, chartHeight: 236, labelMaxLines: 2, horizontalPadding: 16)
        case .all:
            entryCount <= 4
                ? TimelineChartSpec(minItemWidth: 62, maxItemWidth: 78, maxVisibleItems: 4, chartHeight: 228, labelMaxLines: 1, horizontalPadding: 16)
                : TimelineChartSpec(minItemWidth: 56, maxItemWidth: 66, maxVisibleItems: 6, chartHeight: 228, labelMaxLines: 1, horizontalPadding: 16)
        }
    }

    /// `VerticalTimelineBarChart` sizing: fitted bars between min and max width, or min width and horizontal scroll
    /// when they don't fit (or there are more than `maxVisibleItems`).
    func layout(count: Int, width: CGFloat, spacing: CGFloat = 10) -> (itemWidth: CGFloat, scrolls: Bool) {
        let n = max(count, 1)
        let inner = max(width - horizontalPadding * 2, 0)
        let spacingTotal = spacing * CGFloat(max(n - 1, 0))
        let scrolls = minItemWidth * CGFloat(n) + spacingTotal > inner || count > maxVisibleItems
        let fitted = min(max((inner - spacingTotal) / CGFloat(n), minItemWidth), maxItemWidth)
        return (scrolls ? minItemWidth : fitted, scrolls)
    }
}

/// The timeline bars, drawn with Swift Charts in Android's style: one capsule track per segment (`onSurface` 10 %)
/// with the value as a capsule bar inside it (the peak in the range colour, others at 72 %), the value above and
/// the segment label below. Segments sit `itemWidth + 10` apart, so labels line up with the bars exactly.
private struct TimelineBarChart: View {
    let entries: [TimelineEntry]
    let metric: TimelineMetric
    let range: StatsTimeRange
    let use24Hour: Bool

    @Environment(\.appTheme) private var theme
    private let spacing: CGFloat = 10

    var body: some View {
        let spec = TimelineChartSpec.forRange(range, entryCount: entries.count)
        GeometryReader { proxy in
            let layout = spec.layout(count: entries.count, width: proxy.size.width, spacing: spacing)
            ScrollView(.horizontal) {
                content(spec: spec, itemWidth: layout.itemWidth)
                    .padding(.horizontal, spec.horizontalPadding - spacing / 2)
                    .frame(minWidth: proxy.size.width, alignment: layout.scrolls ? .leading : .center)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(!layout.scrolls)
        }
        .frame(height: spec.chartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func content(spec: TimelineChartSpec, itemWidth: CGFloat) -> some View {
        let values = entries.map { max(metric.value($0), 0) }
        let maxValue = values.max() ?? 0
        let slot = itemWidth + spacing
        let highlight: Color = switch range {
        case .day, .week: theme.primary
        case .month, .year: theme.secondary
        case .all: theme.tertiary
        }
        let labelSize: CGFloat = range == .month || range == .all ? 11 : 10
        return VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(entries.indices, id: \.self) { index in
                    Text(metric.format(entries[index]))
                        .pixlFont(.metricValue(compact: true))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: slot)
                }
            }
            Chart {
                ForEach(values.indices, id: \.self) { index in
                    BarMark(x: .value("Segment", Double(index)),
                            yStart: .value("Track", 0.0), yEnd: .value("Track", max(maxValue, 1)),
                            width: .fixed(itemWidth))
                        .foregroundStyle(theme.onSurface.opacity(0.10))
                        .cornerRadius(itemWidth / 2)
                    if values[index] > 0 {
                        let isPeak = maxValue > 0 && (maxValue - values[index]) <= maxValue * 0.01
                        BarMark(x: .value("Segment", Double(index)),
                                yStart: .value("Value", 0.0), yEnd: .value("Value", values[index]),
                                width: .fixed(itemWidth))
                            .foregroundStyle(isPeak ? highlight : highlight.opacity(0.72))
                            .cornerRadius(itemWidth / 2)
                    }
                }
            }
            .chartXScale(domain: -0.5...(Double(entries.count) - 0.5))
            .chartYScale(domain: 0...max(maxValue, 1))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(width: slot * CGFloat(entries.count))
            HStack(spacing: 0) {
                ForEach(entries.indices, id: \.self) { index in
                    Text(HomeLogic.timelineLabel(entries[index].label, range: range, use24Hour: use24Hour))
                        .pixlFont(.custom(size: labelSize, weight: .medium, lineHeight: range == .year ? 12 : 11))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(spec.labelMaxLines)
                        .multilineTextAlignment(.center)
                        .frame(width: slot)
                }
            }
        }
    }

    private var accessibilitySummary: String {
        entries.map { "\(HomeLogic.timelineLabel($0.label, range: range, use24Hour: use24Hour)): \(metric.format($0))" }
            .joined(separator: ", ")
    }
}

// MARK: - Top categories (CategoryMetricsSection)

private struct CategoryEntry: Identifiable {
    var id: Int
    var label: String
    var durationMs: Int64
    var supporting: String
}

struct CategoryMetricsSection: View {
    let summary: PlaybackStatsSummary?
    @Binding var dimension: CategoryDimension
    @Environment(\.appTheme) private var theme

    var body: some View {
        let colors = palette(dimension)
        let rows = entries(dimension)
        VStack(alignment: .leading, spacing: 16) {
            StatsSectionHeading(title: "Top categories",
                                subtitle: "Compare how you listen across genres, artists, albums, and songs.")
            StatsChipRow(items: CategoryDimension.allCases.reversed().map { item in
                (id: item, title: item.title, accent: accentColors(item).accent, onAccent: accentColors(item).onAccent)
            }, selection: $dimension)
            if rows.isEmpty {
                StatsEmptyState(symbol: "music.note", title: "No category data yet",
                                subtitle: "Press play to surface your listening highlights")
            } else {
                statsCard(tint: colors.container.opacity(GlassTint.container)) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(dimension.cardTitle)
                            .pixlFont(.titleLargeEmphasized)
                            .foregroundStyle(colors.content)
                        let maxDuration = max(rows.map(\.durationMs).max() ?? 1, 1)
                        VStack(spacing: 12) {
                            ForEach(rows) { entry in
                                row(entry, isTop: entry.id == 0, maxDuration: maxDuration, palette: colors)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
            }
        }
    }

    private func row(_ entry: CategoryEntry, isTop: Bool, maxDuration: Int64,
                     palette: (container: Color, content: Color, accent: Color, onAccent: Color)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RankBadge(rank: entry.id + 1, accent: palette.accent, onAccent: palette.onAccent, highlighted: isTop)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.label)
                        .pixlFont(.titleSmall)
                        .foregroundStyle(palette.content)
                        .lineLimit(2)
                    if !entry.supporting.isEmpty {
                        Text(entry.supporting)
                            .pixlFont(.bodySmall)
                            .foregroundStyle(palette.content.opacity(0.76))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(HomeLogic.listeningDurationCompact(entry.durationMs))
                    .pixlFont(.metricValue(compact: false).weight(isTop ? .semibold : .medium))
                    .foregroundStyle(palette.content)
            }
            StatsProgressBar(progress: Double(entry.durationMs) / Double(maxDuration),
                        color: isTop ? palette.accent : palette.accent.opacity(0.74),
                        track: palette.content.opacity(0.18), height: 8)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(isTop ? palette.accent.opacity(0.16) : palette.content.opacity(0.06)))
    }

    private func entries(_ dimension: CategoryDimension) -> [CategoryEntry] {
        guard let summary else { return [] }
        let raw: [(String, Int64, String)]
        switch dimension {
        case .genre:
            raw = summary.topGenres.map { ($0.genre, $0.totalDurationMs, "\($0.playCount) plays • \($0.uniqueArtists) artists") }
        case .artist:
            raw = summary.topArtists.map { ($0.artist, $0.totalDurationMs, "\($0.playCount) plays • \($0.uniqueSongs) tracks") }
        case .album:
            raw = summary.topAlbums.map { ($0.album, $0.totalDurationMs, "\($0.playCount) plays • \($0.uniqueSongs) tracks") }
        case .song:
            raw = summary.topSongs.map { song in
                let parts = ["\(song.playCount) plays"] + (song.artist.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [song.artist])
                return (song.title, song.totalDurationMs, parts.joined(separator: " • "))
            }
        }
        return raw.filter { $0.1 > 0 }.enumerated().map { CategoryEntry(id: $0.offset, label: $0.element.0,
                                                                         durationMs: $0.element.1, supporting: $0.element.2) }
    }

    private func accentColors(_ dimension: CategoryDimension) -> (accent: Color, onAccent: Color) {
        let p = palette(dimension)
        return (p.accent, p.onAccent)
    }

    /// Android `categoryPaletteFor`.
    private func palette(_ dimension: CategoryDimension) -> (container: Color, content: Color, accent: Color, onAccent: Color) {
        switch dimension {
        case .genre: (theme.tertiaryContainer, theme.onTertiaryContainer, theme.tertiary, theme.onTertiary)
        case .artist: (theme.primaryContainer, theme.onPrimaryContainer, theme.primary, theme.onPrimary)
        case .album: (theme.secondaryContainer, theme.onSecondaryContainer, theme.secondary, theme.onSecondary)
        case .song: (theme.surfaceContainerHigh, theme.onSurface, theme.primary, theme.onPrimary)
        }
    }
}

// MARK: - Listening habits (ListeningHabitsCard)

struct ListeningHabitsCard: View {
    let summary: PlaybackStatsSummary?
    @Environment(\.appTheme) private var theme

    var body: some View {
        statsCard(tint: theme.surfaceContainer.opacity(GlassTint.surface)) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Listening habits")
                    .pixlFont(.titleLargeEmphasized)
                    .foregroundStyle(theme.onSurface)
                if let summary {
                    VStack(spacing: 16) {
                        metric("clock.arrow.circlepath", "Total sessions", "\(summary.totalSessions)")
                        metric("ear", "Avg session", HomeLogic.listeningDurationCompact(summary.averageSessionDurationMs))
                        metric("bolt", "Longest session", summary.longestSessionDurationMs > 0
                               ? HomeLogic.listeningDurationCompact(summary.longestSessionDurationMs) : "—")
                        metric("chart.line.uptrend.xyaxis", "Sessions/day",
                               String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), summary.averageSessionsPerDay))
                    }
                    Rectangle().fill(theme.outlineVariant.opacity(0.3)).frame(height: 1)
                    StatsHighlightRow(title: "Most active day", value: summary.peakDayLabel ?? "—",
                                 supporting: summary.peakDayDurationMs > 0
                                    ? HomeLogic.listeningDurationCompact(summary.peakDayDurationMs) : "No playback yet",
                                 symbol: "calendar")
                    if let peak = summary.peakTimeline {
                        StatsHighlightRow(title: "Peak timeline slot",
                                     value: HomeLogic.timelineLabel(peak.label, range: summary.range,
                                                                    use24Hour: HomeLogic.uses24HourClock),
                                     supporting: HomeLogic.listeningDurationCompact(peak.totalDurationMs),
                                     symbol: "chart.line.uptrend.xyaxis")
                    }
                } else {
                    StatsEmptyState(symbol: "clock.arrow.circlepath", title: "No habits yet",
                                    subtitle: "We will surface your listening habits once we know you better.")
                }
            }
            .padding(24)
        }
    }

    /// Android `HabitMetric`: an 18 pt `surfaceContainerLowest` row.
    private func metric(_ symbol: String, _ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(theme.primary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).pixlFont(.labelSmall).foregroundStyle(theme.onSurfaceVariant)
                Text(value).pixlFont(.titleSmall, weight: .medium).foregroundStyle(theme.onSurface)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.surfaceContainerLowest.opacity(0.75)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Top artists / albums

struct TopArtistsCard: View {
    let summary: PlaybackStatsSummary?
    @Environment(\.appTheme) private var theme

    var body: some View {
        let content = theme.onSecondaryContainer
        statsCard(tint: theme.secondaryContainer.opacity(GlassTint.container)) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Top artists").pixlFont(.titleLargeEmphasized).foregroundStyle(content)
                let artists = summary?.topArtists ?? []
                if artists.isEmpty {
                    StatsEmptyState(symbol: "music.note", title: "No top artists",
                                    subtitle: "Keep listening and your favorite artists will show up here.")
                } else {
                    let maxDuration = max(artists.map(\.totalDurationMs).max() ?? 1, 1)
                    VStack(spacing: 16) {
                        ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                            VStack(spacing: 8) {
                                HStack(spacing: 16) {
                                    Text(HomeLogic.initials(artist.artist))
                                        .pixlFont(.titleMedium, weight: .bold)
                                        .foregroundStyle(theme.secondary)
                                        .frame(width: 48, height: 48)
                                        .background(Circle().fill(theme.secondary.opacity(0.18)))
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text("\(index + 1). \(artist.artist)")
                                            .pixlFont(.titleMedium).foregroundStyle(content).lineLimit(1)
                                        Text("\(artist.playCount) plays • \(artist.uniqueSongs) tracks")
                                            .pixlFont(.bodySmall).foregroundStyle(content.opacity(0.76)).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(HomeLogic.listeningDurationCompact(artist.totalDurationMs))
                                        .pixlFont(.labelMedium).foregroundStyle(content.opacity(0.76))
                                }
                                StatsProgressBar(progress: Double(artist.totalDurationMs) / Double(maxDuration),
                                            color: theme.secondary, track: content.opacity(0.18))
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct TopAlbumsCard: View {
    let summary: PlaybackStatsSummary?
    @Environment(\.appTheme) private var theme

    var body: some View {
        let content = theme.onTertiaryContainer
        statsCard(tint: theme.tertiaryContainer.opacity(GlassTint.container)) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Top albums").pixlFont(.titleLargeEmphasized).foregroundStyle(content)
                let albums = summary?.topAlbums ?? []
                if albums.isEmpty {
                    StatsEmptyState(symbol: "square.stack", title: "No top albums",
                                    subtitle: "Albums you revisit often will appear here.")
                } else {
                    let maxDuration = max(albums.map(\.totalDurationMs).max() ?? 1, 1)
                    VStack(spacing: 16) {
                        ForEach(Array(albums.enumerated()), id: \.offset) { index, album in
                            VStack(spacing: 8) {
                                HStack(spacing: 16) {
                                    ArtworkView(source: ArtworkSource(uriString: album.albumArtUri), size: 56,
                                                cornerRadius: Tokens.Radius.medium)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text("\(index + 1). \(album.album)")
                                            .pixlFont(.titleMedium).foregroundStyle(content).lineLimit(1)
                                        Text("\(album.playCount) plays • \(album.uniqueSongs) tracks")
                                            .pixlFont(.bodySmall).foregroundStyle(content.opacity(0.76)).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(HomeLogic.listeningDurationCompact(album.totalDurationMs))
                                        .pixlFont(.labelMedium).foregroundStyle(content.opacity(0.76))
                                }
                                StatsProgressBar(progress: Double(album.totalDurationMs) / Double(maxDuration),
                                            color: theme.tertiary, track: content.opacity(0.18))
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Track concentration (TrackConcentrationCard)

struct TrackConcentrationCard: View {
    let summary: PlaybackStatsSummary?
    @Environment(\.appTheme) private var theme

    private struct Slice: Identifiable {
        var id: String { label }
        var label: String
        var durationMs: Int64
        var color: Color
    }

    var body: some View {
        let songs = summary?.songs ?? []
        statsCard(radius: 26, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface)) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Track concentration")
                        .pixlFont(.titleLargeEmphasized)
                        .foregroundStyle(theme.onSurface)
                    Text("How your listening time is distributed across your top tracks.")
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurface.opacity(0.78))
                }
                .padding(.leading, 6)
                if songs.isEmpty {
                    StatsEmptyState(symbol: "chart.line.uptrend.xyaxis", title: "No concentration data yet",
                                    subtitle: "Play more tracks to see how focused your listening is.")
                } else {
                    overview(songs)
                }
            }
            .padding(12)
        }
    }

    private func overview(_ songs: [SongPlaybackSummary]) -> some View {
        let total = max(songs.reduce(Int64(0)) { $0 + $1.totalDurationMs }, 1)
        let topOne = songs.first?.totalDurationMs ?? 0
        let topThree = songs.prefix(3).reduce(Int64(0)) { $0 + $1.totalDurationMs }
        let share = min(max(Double(topThree) / Double(total), 0), 1)
        let plays = summary?.totalPlayCount ?? songs.reduce(0) { $0 + $1.playCount }
        let averagePlays = Double(plays) / Double(max(songs.count, 1))
        var slices: [Slice] = []
        if topOne > 0 { slices.append(Slice(label: "Top 1", durationMs: topOne, color: theme.primary)) }
        if topThree - topOne > 0 { slices.append(Slice(label: "Top 2-3", durationMs: topThree - topOne, color: theme.secondary)) }
        if total - topThree > 0 { slices.append(Slice(label: "Others", durationMs: total - topThree, color: theme.tertiary)) }
        return VStack(spacing: 12) {
            VStack(spacing: 12) {
                donut(slices, share: share)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Listening concentration")
                        .pixlFont(.titleSmall)
                        .foregroundStyle(theme.onSurface)
                    Text("Top 3 tracks account for \(Int((share * 100).rounded()))% of your listening time.")
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                    HStack(spacing: 8) {
                        tile(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), averagePlays),
                             "Avg plays/track", fill: theme.primaryContainer.opacity(0.55), content: theme.onPrimaryContainer)
                        tile("\(songs.count)", "Unique tracks", fill: theme.secondaryContainer.opacity(0.52),
                             content: theme.onSecondaryContainer)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(theme.surfaceContainerLowest.opacity(0.75)))

            VStack(spacing: 8) {
                ForEach(slices) { slice in
                    HStack(spacing: 10) {
                        Circle().fill(slice.color).frame(width: 10, height: 10)
                        Text(slice.label)
                            .pixlFont(.bodySmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(Int((Double(slice.durationMs) / Double(total) * 100).rounded()))%")
                            .pixlFont(.labelMedium)
                            .foregroundStyle(theme.onSurface)
                        Text(HomeLogic.listeningDurationCompact(slice.durationMs))
                            .pixlFont(.labelSmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(theme.surfaceContainerLowest.opacity(0.75)))
                }
            }
        }
    }

    /// Android `TrackDistributionDonut` with Swift Charts: an 18 pt ring of rounded sectors (4 pt gaps) in a
    /// 158 pt box, the top-3 share in the middle.
    private func donut(_ slices: [Slice], share: Double) -> some View {
        ZStack {
            Chart(slices) { slice in
                SectorMark(angle: .value("Listening", Double(slice.durationMs)), innerRadius: .ratio(0.74),
                           outerRadius: .inset(1), angularInset: slices.count > 1 ? 2 : 0)
                    .foregroundStyle(slice.color)
                    .cornerRadius(9)
            }
            .chartLegend(.hidden)
            .padding(8)
            VStack(spacing: 2) {
                Text("\(Int((share * 100).rounded()))%")
                    .pixlFont(.custom(size: 24, weight: .semibold, lineHeight: 26))
                    .foregroundStyle(theme.onSurface)
                Text("Top 3 share")
                    .pixlFont(.labelSmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        }
        .frame(width: 158, height: 158)
    }

    private func tile(_ value: String, _ label: LocalizedStringKey, fill: Color, content: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).pixlFont(.metricValue(compact: false)).foregroundStyle(content)
            Text(label).pixlFont(.labelSmall).foregroundStyle(content.opacity(0.76))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill))
    }
}

// MARK: - Tracks in this range (SongStatsCard)

struct SongStatsCard: View {
    let summary: PlaybackStatsSummary?
    @Environment(\.appTheme) private var theme
    @State private var showAll = false

    var body: some View {
        let songs = summary?.songs ?? []
        statsCard(tint: theme.surfaceContainerHigh.opacity(GlassTint.surface)) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tracks in this range")
                        .pixlFont(.titleLargeEmphasized)
                        .foregroundStyle(theme.onSurface)
                    Text("Most played tracks for the selected time range.")
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                if songs.isEmpty {
                    StatsEmptyState(symbol: "music.note", title: "No top tracks",
                                    subtitle: "Listen to your favorites to see them highlighted here.")
                } else {
                    let maxDuration = max(songs.map(\.totalDurationMs).max() ?? 1, 1)
                    let shown = showAll || songs.count <= 8 ? songs : Array(songs.prefix(8))
                    VStack(spacing: 12) {
                        ForEach(Array(shown.enumerated()), id: \.element.songId) { position, song in
                            row(song, position: position, maxDuration: maxDuration)
                        }
                    }
                    if songs.count > 8 {
                        Button {
                            withAnimation(PixlMotion.state) { showAll.toggle() }
                        } label: {
                            Text(showAll ? "Collapse tracks" : "Show all tracks")
                                .pixlFont(.labelLarge, weight: .semibold)
                                .foregroundStyle(theme.primary)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(theme.surfaceContainerLow.opacity(0.8)))
                                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }

    private func row(_ song: SongPlaybackSummary, position: Int, maxDuration: Int64) -> some View {
        let (accent, onAccent, fill): (Color, Color, Color) = position == 0
            ? (theme.primary, theme.onPrimary, theme.primaryContainer.opacity(0.45))
            : position < 3 ? (theme.secondary, theme.onSecondary, theme.secondaryContainer.opacity(0.36))
            : (theme.tertiary, theme.onTertiary, theme.surfaceContainerLow.opacity(0.75))
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                RankBadge(rank: position + 1, accent: accent, onAccent: onAccent, highlighted: position == 0)
                ArtworkView(source: ArtworkSource(uriString: song.albumArtUri), size: 52, cornerRadius: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(song.title).pixlFont(.titleSmall).foregroundStyle(theme.onSurface)
                    Text(song.artist).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant).lineLimit(1)
                    Text("\(song.playCount) plays").pixlFont(.labelSmall).foregroundStyle(theme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(HomeLogic.listeningDurationCompact(song.totalDurationMs))
                    .pixlFont(.metricValue(compact: true))
                    .foregroundStyle(theme.onSurface)
            }
            StatsProgressBar(progress: Double(song.totalDurationMs) / Double(maxDuration), color: accent,
                        track: theme.onSurfaceVariant.opacity(0.20), height: 7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(fill))
    }
}
