import PixlFoundation
import PixlLibrary
import PixlModel
import SwiftUI

// Home, redesign batch 3: the port of Android `presentation/components/redesign/HomeRedesign.kt` (mockups Main.dc.html and
// AndroidHomeScrolled.dc.html, 390 × 844, 1 dp = 1 pt). Android's layout, sizes, order and copy; every Material fill becomes Liquid
// Glass tinted with Android's role (docs/design.md › Redesign batch 3), controls sitting on a glass card are fills.
//
//   header     safe area + 12 pt, 16 pt gutter. Left column 8 pt apart: time chip (28 pt, surfaceContainerHigh glass, 10/12 pt
//              padding, 16 dp icon, 6 pt gap, 13/18 medium onSurfaceVariant), the greeting on two lines (60 pt heavy: line one SF Pro
//              expanded −1.8, line two compressed −0.8 in primary; both fitted to the width), the sub line 14/20 onSurfaceVariant
//              (only with a real play count). Right column 8 pt apart: Ask Taizo (48 pt secondaryContainer glass circle, a 34 pt
//              Sunny in onSecondaryContainer with the sparkle), Settings (48 pt glass circle), the jobs circle while jobs run.
//   your mix   164 pt, 32 pt corners, primaryContainer glass; 230 pt Clover4 (primary) at right −46 / top −50; 104 pt Cookie9
//              (tertiary) at right 92 / top 84; tag pill, title 38/40 expanded −1 and line 14/20 at 16 / bottom 16; 64 pt play fill.
//   endless    72 pt pill, tertiaryContainer glass, 10/14 pt padding, 14 pt gap; 52 pt circle with the infinity; title + line; chevron.
//   sections   title 30/32 heavy −0.6 (expanded + compressed accent in primary); "See all" 14/20 medium primary; 12 pt to the content.
//   mixes      148 pt squares, 28 pt corners, 10 pt apart; the expressive shape top right; title 20/24 heavy, line 12/16.
//   rewind     2 columns, 8 pt gaps; 64 pt tiles, 16 pt corners, surfaceContainer glass; 64 pt art 16/4/4/16; title 14/18 medium.
//   fresh      124 pt items 12 pt apart: art clipped to Sunny / Clover4 / Flower, 8 pt, title 14/20 medium, artist 13/18.
//   taizo      28 pt corners, secondaryContainer glass, 16/14 pt padding, 40 pt Sunny, 14 pt; title 16/24 medium, example 14/20.
//   collapsed  safe area + 72 pt, surface at 94 % (Android: no blur), the greeting on one line 26/32, the buttons 8 pt apart.
//
// Performance: no view here animates by itself; the header re-renders once a minute (the time chip), the collapsed header only while
// it is shown. Shapes are `ExpressiveBadgeShape` (sampled once), lazy stacks for the rows, one glass layer per card.

// MARK: - Faces

/// The house cuts of the wordplay: Android's Google Sans Flex wdth 125 / 75 at w800 are SF Pro expanded / compressed, heavy.
nonisolated enum HomeFaces {
    static func wide(_ size: CGFloat, tracking: CGFloat = 0) -> ExpressiveFace {
        ExpressiveFace(size: size, weight: .heavy, width: .expanded, tracking: tracking)
    }

    static func narrow(_ size: CGFloat, tracking: CGFloat = 0) -> ExpressiveFace {
        ExpressiveFace(size: size, weight: .heavy, width: .compressed, tracking: tracking)
    }

    /// Android `MixTitleSpec` (w800, wdth 110) and `EndlessTitleSpec` (w750, wdth 112): just past standard.
    static func standardHeavy(_ size: CGFloat, weight: TypeWeightStop = .heavy) -> ExpressiveFace {
        ExpressiveFace(size: size, weight: weight, width: .standard)
    }
}

// MARK: - Two-tone title

/// A title in two cuts on one line of text (Android `TwoToneTitle`): `wide` in SF Pro expanded, `accent` compressed in
/// `accentColor`. One `AttributedString`, so it wraps and truncates as one text.
struct TwoToneTitle: View {
    let wide: String
    let accent: String
    var size: CGFloat = 30
    var tracking: CGFloat = -0.6
    var color: Color?
    var accentColor: Color?
    var lines = 2

    @Environment(\.appTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let scale = DynamicTypeScale.factor(dynamicTypeSize)
        var first = AttributedString(wide)
        first.font = HomeFaces.wide(size).font(scale: scale)
        var second = AttributedString(accent)
        second.font = HomeFaces.narrow(size).font(scale: scale)
        second.foregroundColor = accentColor ?? theme.primary
        return Text(first + second)
            .tracking(tracking)
            .foregroundStyle(color ?? theme.onSurface)
            .lineLimit(lines)
            .truncationMode(.tail)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Greeting words

/// One greeting's resolved words (Android `HomeGreetingWords`).
struct HomeGreetingWords: Equatable {
    let first: String
    let second: String
    let sub: String?
    let chip: String
    let hour: Int

    private static let timeFormat = Date.FormatStyle(date: .omitted, time: .shortened)

    /// The words for `now` (Android `rememberHomeGreeting`): the set and line come from `HomeWordplay`; `weekPlays`, `topSong` and
    /// `topSongPlays` are the listener's real counts (nil = unknown, then no sub line). UI tests pin the clock (18:30, day 20 000).
    static func make(now: Date, pinned: Bool, weekPlays: Int?, topSong: String?, topSongPlays: Int) -> HomeGreetingWords {
        let hour = pinned ? 18 : Calendar.current.component(.hour, from: now)
        let day = pinned ? Int64(20_000) : HomeWordplay.epochDay(now)
        let streakPlays = (topSong?.isEmpty ?? true) ? 0 : topSongPlays
        let pick = HomeWordplay.greeting(epochDay: day, hour: hour, topSongPlaysThisWeek: streakPlays) { set in
            let lines = HomeRedesignStrings.lines(set)
            return min(lines.a.count, lines.b.count)
        }
        let lines = HomeRedesignStrings.lines(pick.set)
        let first = lines.a.indices.contains(pick.index) ? lines.a[pick.index] : lines.a[0]
        let second = lines.b.indices.contains(pick.index) ? lines.b[pick.index] : lines.b[0]
        let sub = weekPlays.flatMap { $0 > 0 ? HomeRedesignStrings.plays(HomeWordplay.subLine(epochDay: day, size: 3), $0) : nil }
        let time = pinned ? "6:30 PM" : now.formatted(timeFormat)
        let chip: String
        if pick.set == .streak, let topSong, !topSong.isEmpty {
            chip = HomeRedesignStrings.chipRepeat(time, topSong)
        } else {
            chip = time
        }
        return HomeGreetingWords(first: first, second: second, sub: sub, chip: chip, hour: hour)
    }

    /// The time chip's icon: sun by day, twilight in the evening, moon late.
    var timeSymbol: String {
        switch HomeWordplay.timeBucket(hour: hour) {
        case .morning, .afternoon: "sun.max.fill"
        case .evening: "sun.horizon.fill"
        case .lateNight: "moon.fill"
        }
    }
}

/// Today's rotating section titles (Android `rememberHomeSectionTitles`).
struct HomeSectionTitles: Equatable {
    let mixesA: String, mixesB: String
    let recentA: String, recentB: String
    let freshA: String, freshB: String

    static func make(now: Date, pinned: Bool) -> HomeSectionTitles {
        let day = pinned ? Int64(20_000) : HomeWordplay.epochDay(now)
        let s = HomeRedesignStrings.self
        let m = HomeWordplay.section(epochDay: day, .mixes, size: min(s.mixesA.count, s.mixesB.count))
        let r = HomeWordplay.section(epochDay: day, .recent, size: min(s.recentA.count, s.recentB.count))
        let f = HomeWordplay.section(epochDay: day, .fresh, size: min(s.freshA.count, s.freshB.count))
        return HomeSectionTitles(mixesA: s.mixesA[m], mixesB: s.mixesB[m], recentA: s.recentA[r], recentB: s.recentB[r],
                                 freshA: s.freshA[f], freshB: s.freshB[f])
    }
}

// MARK: - Header

/// The buttons of the header (both states): Ask Taizo, Settings, and the jobs circle while jobs run.
struct HomeHeaderButtons: View {
    let onAskTaizo: () -> Void
    let onSettings: () -> Void
    let onJobs: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme

    var body: some View {
        // The count is read here: `ActiveJobs` writes it only when the number changes, so progress never re-runs Home.
        let jobs = env.activeJobs
        let count = jobs.badgeCount
        TaizoCircleButton(action: onAskTaizo)
            .accessibilityIdentifier("ai.taizo.home")
        GlassCircleButton(systemImage: "gearshape", accessibilityLabel: LocalizedStringKey(HomeRedesignStrings.settings),
                          size: 48, iconSize: 20, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface),
                          action: onSettings)
            .accessibilityIdentifier("home.settings")
        if count > 0 {
            GlassCircleButton(systemImage: "hourglass", accessibilityLabel: LocalizedStringKey(HomeRedesignStrings.activeJobs),
                              size: 48, iconSize: 20, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface),
                              badge: count, action: onJobs)
                .contextMenu {
                    Button("Cancel all", systemImage: "xmark.circle", role: .destructive) { jobs.cancelAll() }
                }
                .accessibilityIdentifier("home.jobs")
                .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }
}

/// Ask Taizo: a 48 pt `secondaryContainer` glass circle, a 34 pt Sunny in `onSecondaryContainer`, the sparkle in the container
/// colour (a fill on the glass).
private struct TaizoCircleButton: View {
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.secondaryContainer)
                .frame(width: 34, height: 34)
                .background(ExpressiveBadgeShape(.sunny).fill(theme.onSecondaryContainer))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Circle(), tint: theme.secondaryContainer.opacity(GlassTint.prominent), interactive: true)
        .accessibilityLabel(Text(verbatim: HomeRedesignStrings.askTaizo))
    }
}

/// The expanded header (see the file comment).
struct HomeRedesignHeader: View {
    let weekPlays: Int?
    let topSong: String?
    let topSongPlays: Int
    let onAskTaizo: () -> Void
    let onSettings: () -> Void
    let onJobs: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme

    var body: some View {
        let pinned = env.launch.isUITest
        // One re-render a minute, aligned to the minute (the time chip), nothing in between.
        TimelineView(.everyMinute) { context in
            let words = HomeGreetingWords.make(now: context.date, pinned: pinned, weekPlays: weekPlays, topSong: topSong,
                                               topSongPlays: topSongPlays)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    timeChip(words)
                    VStack(alignment: .leading, spacing: 0) {
                        FitWidthTitle(text: words.first, face: HomeFaces.wide(60, tracking: -1.8), narrowest: .compressed,
                                      lines: 2)
                            .foregroundStyle(theme.onSurface)
                        FitWidthTitle(text: words.second, face: HomeFaces.narrow(60, tracking: -0.8), narrowest: .compressed,
                                      lines: 2)
                            .foregroundStyle(theme.primary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: words.first + " " + words.second))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home.greeting")
                    if let sub = words.sub {
                        Text(verbatim: sub)
                            .pixlFont(.custom(size: 14, lineHeight: 20))
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                GlassEffectContainer(spacing: 6) {
                    VStack(spacing: 8) {
                        HomeHeaderButtons(onAskTaizo: onAskTaizo, onSettings: onSettings, onJobs: onJobs)
                    }
                }
            }
            .padding(.horizontal, Redesign.gutter)
            .padding(.top, 12)
        }
        .animation(PixlMotion.bars, value: env.activeJobs.badgeCount > 0)
    }

    private func timeChip(_ words: HomeGreetingWords) -> some View {
        HStack(spacing: 6) {
            Image(systemName: words.timeSymbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(verbatim: words.chip)
                .pixlFont(.custom(size: 13, weight: .medium, lineHeight: 18))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(theme.onSurfaceVariant)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 28)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                   tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
        .accessibilityElement(children: .combine)
    }
}

/// The collapsed header drawn over the list once the big greeting scrolled away (Android `HomeCollapsedHeader`).
struct HomeCollapsedHeader: View {
    let weekPlays: Int?
    let topSong: String?
    let topSongPlays: Int
    let onAskTaizo: () -> Void
    let onSettings: () -> Void
    let onJobs: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme

    var body: some View {
        let words = HomeGreetingWords.make(now: Date(), pinned: env.launch.isUITest, weekPlays: weekPlays, topSong: topSong,
                                           topSongPlays: topSongPlays)
        HStack(spacing: 12) {
            TwoToneTitle(wide: words.first, accent: " " + words.second, size: 26, tracking: -0.4, lines: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 8) {
                    HomeHeaderButtons(onAskTaizo: onAskTaizo, onSettings: onSettings, onJobs: onJobs)
                }
            }
        }
        .padding(.horizontal, Redesign.gutter)
        .frame(height: 72)
        .frame(maxWidth: .infinity)
        .background(theme.surface.opacity(0.94).ignoresSafeArea(edges: .top))
    }
}

// MARK: - Section header

/// A section header (Android `HomeSectionHeader`): two-tone title, optional "See all" / "Show less", optional line under it.
struct HomeSectionHeader: View {
    let wide: String
    let accent: String
    var subtitle: String?
    var actionLabel: String?
    var onAction: (() -> Void)?

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 0) {
                TwoToneTitle(wide: wide, accent: accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let actionLabel, let onAction {
                    Button(action: onAction) {
                        Text(verbatim: actionLabel)
                            .pixlFont(.redesignLabel)
                            .foregroundStyle(theme.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                            .contentShape(.rect(cornerRadius: 12))
                    }
                    .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
                }
            }
            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .pixlFont(.custom(size: 14, lineHeight: 20))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        }
        .padding(.horizontal, Redesign.gutter)
    }
}

// MARK: - Your mix

/// The day's mix as the hero card (Android `HomeYourMixHero`). `onPlay` nil hides the play button (nothing to play yet).
struct HomeYourMixHero: View {
    let onOpen: () -> Void
    let onPlay: (() -> Void)?

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        ZStack(alignment: .bottomTrailing) {
            Button(action: onOpen) {
                ZStack(alignment: .topLeading) {
                    ZStack(alignment: .topTrailing) {
                        Color.clear
                        ExpressiveBadgeShape(.clover4).fill(theme.primary)
                            .frame(width: 230, height: 230)
                            .offset(x: 46, y: -50)
                        ExpressiveBadgeShape(.cookie9).fill(theme.tertiary)
                            .frame(width: 104, height: 104)
                            .offset(x: -92, y: 84)
                    }
                    .accessibilityHidden(true)
                    Text(verbatim: HomeRedesignStrings.yourMixTag)
                        .pixlFont(.custom(size: 12, weight: .semibold, lineHeight: 16, tracking: 0.3))
                        .foregroundStyle(theme.onPrimaryContainer)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(theme.onPrimary, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .padding(16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: HomeRedesignStrings.yourMixName)
                            .font(HomeFaces.wide(38).font())
                            .tracking(-1)
                            .lineLimit(1)
                        Text(verbatim: HomeRedesignStrings.yourMixLine)
                            .pixlFont(.custom(size: 14, lineHeight: 20))
                            .lineLimit(1)
                    }
                    .foregroundStyle(theme.onPrimaryContainer)
                    .padding(.leading, 16)
                    .padding(.trailing, onPlay == nil ? 16 : 96)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .frame(height: 164)
                .clipShape(shape)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: HomeRedesignStrings.yourMixName + ", " + HomeRedesignStrings.yourMixLine))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("home.yourMix")
            if let onPlay {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(theme.onPrimary)
                        .frame(width: 64, height: 64)
                        .background(theme.primary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.92))
                .padding(16)
                .accessibilityLabel(Text(verbatim: HomeRedesignStrings.yourMixPlay))
                .accessibilityIdentifier("home.yourMix.play")
            }
        }
        .frame(height: 164)
        .pixlGlass(in: shape, tint: theme.primaryContainer.opacity(GlassTint.container), interactive: true)
        .padding(.horizontal, Redesign.gutter)
    }
}

// MARK: - Endless entry

/// The Endless Listening entry pill (Android `HomeEndlessEntry`); a long press replays the introduction.
struct HomeEndlessEntry: View {
    let onTap: () -> Void
    let onLongPress: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var longPressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 36, style: .continuous)
        Button {
            if longPressed { longPressed = false } else { onTap() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "infinity")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(theme.tertiaryContainer)
                    .frame(width: 52, height: 52)
                    .background(theme.onTertiaryContainer, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: EndlessStrings.title)
                        .font(HomeFaces.standardHeavy(19, weight: .bold).font())
                        .lineLimit(1)
                    Text(verbatim: HomeRedesignStrings.endlessLine)
                        .pixlFont(.redesignRowSubtitle)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .foregroundStyle(theme.onTertiaryContainer)
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(height: 72)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            longPressed = true
            onLongPress()
        })
        .pixlGlass(in: shape, tint: theme.tertiaryContainer.opacity(GlassTint.prominent), interactive: true)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(verbatim: HomeRedesignStrings.endlessHow), onLongPress)
        .accessibilityIdentifier("home.endless")
        .padding(.horizontal, Redesign.gutter)
    }
}

// MARK: - Mix & match

/// One mix card's words (a plan card or the legacy Daily Mix).
struct HomeMixTile: Identifiable, Equatable {
    let key: String
    let title: String
    let subtitle: String
    var id: String { key }
}

/// A 148 pt square mix card (Android `HomeMixSquareCard`); `size` nil fills the grid cell.
struct HomeMixSquareCard: View {
    let tile: HomeMixTile
    let index: Int
    var size: CGFloat? = 148
    let onTap: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let tone = index % 3
        let container = tone == 0 ? theme.tertiaryContainer : (tone == 1 ? theme.secondaryContainer : theme.primaryContainer)
        let content = tone == 0 ? theme.onTertiaryContainer : (tone == 1 ? theme.onSecondaryContainer : theme.onPrimaryContainer)
        let deco = tone == 0 ? theme.tertiary : (tone == 1 ? theme.secondary : theme.primary)
        let kind: BadgeShapeKind = tone == 0 ? .flower : (tone == 1 ? .softBurst : .cookie9)
        let decoSize: CGFloat = tone == 0 ? 130 : 120
        let decoX: CGFloat = tone == 0 ? 34 : 24
        let decoY: CGFloat = tone == 0 ? -30 : -28
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                    ExpressiveBadgeShape(kind).fill(deco)
                        .frame(width: decoSize, height: decoSize)
                        .offset(x: decoX, y: decoY)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: tile.title)
                        .font(HomeFaces.standardHeavy(20).font())
                        .lineLimit(2)
                    if !tile.subtitle.isEmpty {
                        Text(verbatim: tile.subtitle)
                            .pixlFont(.custom(size: 12, lineHeight: 16))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(content)
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: size == nil ? .infinity : nil, maxHeight: size == nil ? .infinity : nil)
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: container.opacity(GlassTint.container), interactive: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.mix.\(tile.key)")
    }
}

/// "Mix & match": the mixes sideways, 10 pt apart.
struct HomeMixShelfRow: View {
    let tiles: [HomeMixTile]
    let onOpen: (HomeMixTile) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(Array(tiles.enumerated()), id: \.element.key) { index, tile in
                    HomeMixSquareCard(tile: tile, index: index, onTap: { onOpen(tile) })
                }
            }
            .padding(.horizontal, Redesign.gutter)
        }
        .scrollIndicators(.hidden)
        .frame(height: 148)
    }
}

/// "See all" of the mixes: the same cards two to a row.
struct HomeMixGrid: View {
    let tiles: [HomeMixTile]
    let onOpen: (HomeMixTile) -> Void

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(tiles.enumerated()), id: \.element.key) { index, tile in
                HomeMixSquareCard(tile: tile, index: index, size: nil, onTap: { onOpen(tile) })
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .padding(.horizontal, Redesign.gutter)
    }
}

// MARK: - Rewind, replay

/// One "Rewind, replay" tile.
struct HomeRewindTile: Identifiable, Equatable {
    let key: String
    let title: String
    let art: String?
    var id: String { key }
}

/// "Rewind, replay": two columns of 64 pt tiles (Android `HomeRewindGrid`).
struct HomeRewindGrid: View {
    let tiles: [HomeRewindTile]
    let onTap: (HomeRewindTile) -> Void

    @Environment(\.appTheme) private var theme
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let artShape = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4,
                                              topTrailingRadius: 4, style: .continuous)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(tiles) { tile in
                Button { onTap(tile) } label: {
                    HStack(spacing: 12) {
                        ArtworkView(source: ArtworkSource(uriString: tile.art), size: 64, cornerRadius: 0)
                            .clipShape(artShape)
                        Text(verbatim: tile.title)
                            .pixlFont(.custom(size: 14, weight: .medium, lineHeight: 18))
                            .foregroundStyle(theme.onSurface)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.trailing, 10)
                    .frame(height: 64)
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: shape, tint: theme.surfaceContainer.opacity(GlassTint.surface), interactive: true)
            }
        }
        .padding(.horizontal, Redesign.gutter)
    }
}

// MARK: - Fresh finds

/// "Fresh finds" (Android `HomeFreshRow`): songs sideways, art clipped to expressive shapes.
struct HomeFreshRow: View {
    let songs: [Song]
    let onPlay: (Song) -> Void

    @Environment(\.appTheme) private var theme
    private static let shapes: [BadgeShapeKind] = [.sunny, .clover4, .flower]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    Button { onPlay(song) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ArtworkView(song: song, size: 124, cornerRadius: 0)
                                .clipShape(ExpressiveBadgeShape(Self.shapes[index % Self.shapes.count]))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: song.title)
                                    .pixlFont(.redesignLabel)
                                    .foregroundStyle(theme.onSurface)
                                    .lineLimit(1)
                                Text(verbatim: song.displayArtist)
                                    .pixlFont(.redesignRowSubtitle)
                                    .foregroundStyle(theme.onSurfaceVariant)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 124, alignment: .leading)
                        .contentShape(.rect(cornerRadius: 16))
                    }
                    .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, Redesign.gutter)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Ask Taizo card

/// "Can't find the vibe? Ask Taizo" with an example made from a real song, or a plain one (Android `HomeAskTaizoCard`).
struct HomeAskTaizoCard: View {
    let exampleSong: String?
    let onTap: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let example = exampleSong.flatMap { $0.isEmpty ? nil : HomeRedesignStrings.taizoCardExample($0) }
            ?? HomeRedesignStrings.taizoCardExamplePlain
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.secondaryContainer)
                    .frame(width: 40, height: 40)
                    .background(ExpressiveBadgeShape(.sunny).fill(theme.onSecondaryContainer))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: HomeRedesignStrings.taizoCardTitle)
                        .pixlFont(.custom(size: 16, weight: .medium, lineHeight: 24))
                        .foregroundStyle(theme.onSecondaryContainer)
                    Text(verbatim: example)
                        .pixlFont(.custom(size: 14, lineHeight: 20))
                        .foregroundStyle(theme.onSecondaryContainer.opacity(0.86))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: theme.secondaryContainer.opacity(GlassTint.prominent), interactive: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.askTaizoCard")
        .padding(.horizontal, Redesign.gutter)
    }
}

// MARK: - Footer links

/// One quiet outlined link at the bottom of Home.
struct HomeFooterLink: Identifiable {
    let id: String
    let label: String
    let action: () -> Void
}

/// The bottom row (Android `HomeFooterLinks`): the old quick actions and chips that have no place of their own any more. Outlined
/// 40 pt chips, 12 pt corners: clear glass with a 1 pt `outline` border, 8 pt apart, wrapping.
struct HomeFooterLinks: View {
    let links: [HomeFooterLink]

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        GlassEffectContainer(spacing: 6) {
            AIFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(links) { link in
                    Button(action: link.action) {
                        Text(verbatim: link.label)
                            .pixlFont(.redesignLabel)
                            .foregroundStyle(theme.onSurface)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .contentShape(shape)
                    }
                    .buttonStyle(.plain)
                    .overlay { shape.strokeBorder(theme.outline, lineWidth: 1).allowsHitTesting(false) }
                    .pixlGlass(in: shape, interactive: true)
                    .accessibilityIdentifier("home.link.\(link.id)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Redesign.gutter)
    }
}
