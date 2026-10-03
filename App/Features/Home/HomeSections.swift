import PixlLibrary
import PixlModel
import SwiftUI

// Home's sections, one per Android component (presentation/components/Home*.kt, YourMixShelfSection.kt,
// RecentlyAddedSection.kt, RecentlyPlayedSection.kt, StatsOverviewCard.kt). Geometry is copied from the Compose code;
// Material surfaces are glass tinted with the role Android filled them with.

// MARK: - Greeting card (HomeGreetingCard)

/// 32 pt glass card (`navBarCornerRadius`), 20×18 padding: headline `titleLarge` bold (2 lines) with the expand
/// chevron (32 pt target, 22 pt icon), the stats line in `bodyMedium`, and the expanded insight. Android's glass
/// mode draws two static washes of the scheme's primary / tertiary (0.26 top-left, 0.16 bottom-right) instead of the
/// Material colour sweep loop — the port does the same (no animation ticking on the screen the app opens to).
struct HomeGreetingCard: View {
    let greeting: HomeGreeting
    let insight: String
    let isExpanded: Bool
    let onToggle: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Shell.navBarCornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 0) {
                Text(greeting.headline)
                    .pixlFont(.titleLarge, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.45), value: greeting.headline)
                Button(action: onToggle) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.onSurface)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .frame(width: 32, height: 32)
                        // A 44 pt touch area around the 32 pt glyph, without moving it.
                        .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.85))
                .padding(.leading, 8)
                .accessibilityLabel(isExpanded ? "Show less insight" : "Show more insight")
                .accessibilityIdentifier("home.greeting.expand")
            }
            Text(greeting.subtitle)
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
                .lineLimit(1)
            if isExpanded {
                Text(insight)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RadialGradient(colors: [theme.primary.opacity(0.26), .clear], center: UnitPoint(x: 0.08, y: 0.05),
                               startRadius: 0, endRadius: 380)
                RadialGradient(colors: [theme.tertiary.opacity(0.16), .clear], center: UnitPoint(x: 0.95, y: 0.95),
                               startRadius: 0, endRadius: 300)
            }
            .allowsHitTesting(false)
        }
        .clipShape(shape)
        .pixlGlass(in: shape, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface + 0.12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.greeting")
    }
}

// MARK: - Quick actions (HomeQuickActionsRow)

/// Shuffle All / Recently Played / Stats: `secondaryContainer` chips (14×10 padding, 18 pt icon, `labelLarge`),
/// 10 pt apart, 16 pt edge padding, scrolling horizontally — glass capsules tinted `secondaryContainer`.
struct HomeQuickActionsRow: View {
    let onShuffleAll: () -> Void
    let onRecentlyPlayed: () -> Void
    let onStats: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView(.horizontal) {
            // Container spacing below the 10 pt gap: one render pass, no blending at rest.
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 10) {
                    pill("Shuffle All", "shuffle", onShuffleAll)
                    pill("Recently Played", "clock", onRecentlyPlayed)
                    pill("Stats", "chart.line.uptrend.xyaxis", onStats)
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func pill(_ title: LocalizedStringKey, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        GlassPillButton(title: title, systemImage: symbol,
                        tint: theme.secondaryContainer.opacity(GlassTint.container),
                        foreground: theme.onSecondaryContainer, action: action)
    }
}

// MARK: - "Made for your listening" (HomeDiscoveryMixes)

/// Header (20 pt sides, `headlineSmall` bold + `bodyMedium`, a tonal refresh circle), then 236 pt mix cards, 32 pt
/// corners, cycling primary / secondary / tertiary containers: three 60 pt covers (18 pt corners), title, two-line
/// subtitle, "N songs" and a play icon.
struct HomeDiscoveryMixes: View {
    let mixes: [HomeMusicSection]
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onPlay: (HomeMusicSection, Song) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Made for your listening", subtitle: "Mixes that change with your taste") {
                Button(action: onRefresh) {
                    Group {
                        if isRefreshing {
                            ProgressView().tint(theme.onSecondaryContainer)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .semibold))
                        }
                    }
                    .foregroundStyle(theme.onSecondaryContainer)
                    .frame(width: Tokens.TopBar.circleButtonSize, height: Tokens.TopBar.circleButtonSize)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .pixlGlass(in: Circle(), tint: theme.secondaryContainer.opacity(GlassTint.container), interactive: true)
                .accessibilityLabel("Refresh Home recommendations")
            }
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 12) {
                        ForEach(Array(mixes.enumerated()), id: \.element.id) { index, mix in
                            card(mix, index: index)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func card(_ mix: HomeMusicSection, index: Int) -> some View {
        let (container, content): (Color, Color) = switch index % 3 {
        case 0: (theme.primaryContainer, theme.onPrimaryContainer)
        case 1: (theme.secondaryContainer, theme.onSecondaryContainer)
        default: (theme.tertiaryContainer, theme.onTertiaryContainer)
        }
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.mixCard, style: .continuous)
        return Button {
            if let first = mix.songs.first { onPlay(mix, first) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(mix.songs.prefix(3)) { song in
                        ArtworkView(song: song, size: 60, cornerRadius: 18)
                    }
                }
                Text(mix.title)
                    .pixlFont(.titleLarge, weight: .bold)
                    .lineLimit(1)
                Text(mix.subtitle)
                    .pixlFont(.bodyMedium)
                    .lineLimit(2, reservesSpace: true)
                HStack(spacing: 0) {
                    Text("\(mix.songs.count) songs")
                        .pixlFont(.labelLarge)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(content)
            .padding(18)
            .frame(width: 236, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: container.opacity(GlassTint.container), interactive: true)
        .accessibilityLabel("Play \(mix.title)")
        .accessibilityIdentifier("home.mix.\(mix.id)")
    }
}

// MARK: - Discovery shelf (HomeDiscoveryShelf)

/// Title `titleLarge` bold + subtitle (start 20, end 12) with a "Play all" text button, then 156 pt song cards
/// (24 pt corners, 10 pt padding): 136 pt cover (18 pt corners), two-line title, artist, and why it was picked in
/// `primary` (two lines reserved so cards in a row share a height). The current song's card is `secondaryContainer`.
struct HomeDiscoveryShelf: View {
    let section: HomeMusicSection
    let currentSongId: String?
    let onPlay: (Song) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(section.title)
                        .pixlFont(.titleLarge, weight: .bold)
                        .foregroundStyle(theme.onSurface)
                        .accessibilityAddTraits(.isHeader)
                    Text(section.subtitle)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    if let first = section.songs.first { onPlay(first) }
                } label: {
                    Text("Play all")
                        .pixlFont(.labelLarge)
                        .foregroundStyle(theme.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .contentShape(.capsule)
                }
                .buttonStyle(PressScaleButtonStyle())
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(section.songs) { song in
                        card(song)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func card(_ song: Song) -> some View {
        let isCurrent = song.id == currentSongId
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.large, style: .continuous)
        return Button { onPlay(song) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ArtworkView(song: song, size: 136, cornerRadius: 18)
                Spacer().frame(height: 10)
                Text(song.title)
                    .pixlFont(.titleSmall)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2, reservesSpace: true)
                Text(song.artist)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                Spacer().frame(height: 4)
                Text(section.reasons[song.id] ?? "")
                    .pixlFont(.labelSmall)
                    .foregroundStyle(theme.primary)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(10)
            .frame(width: 156, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape,
                   tint: isCurrent ? theme.secondaryContainer.opacity(GlassTint.container)
                                   : theme.surfaceContainer.opacity(GlassTint.surface),
                   interactive: true)
        .animation(PixlMotion.state, value: isCurrent)
    }
}

// MARK: - Your Mix (YourMixShelfSection)

/// The YOUR MIX shelf: a 32 pt glass card (`surfaceContainer`) with a 96 pt primary→tertiary header (title, "Picked
/// for you today", three overlapping round covers), a 56 pt shuffle button on the header's right (20 pt in), four
/// rows without art (10 pt corners, 3 pt apart, inside an 8 pt inset clipped to 24 pt) and "Check out your mix".
struct YourMixShelfSection: View {
    let songs: [Song]
    let currentSongId: String?
    let isPlaying: Bool
    let isShuffleEnabled: Bool
    let onPlayShuffled: () -> Void
    let onSongTap: (Song) -> Void
    let onMore: (Song) -> Void
    let onCheckOut: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.mixCard, style: .continuous)
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                header
                Spacer().frame(height: 28)
                VStack(spacing: 3) {
                    ForEach(songs.prefix(4)) { song in
                        YourMixRow(song: song, isCurrent: song.id == currentSongId, isPlaying: isPlaying,
                                   onTap: { onSongTap(song) }, onMore: { onMore(song) })
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(8)
                Button(action: onCheckOut) {
                    HStack {
                        Text("Check out your mix")
                            .pixlFont(.bodyLarge, weight: .medium)
                        Spacer()
                        Image(systemName: "arrow.forward")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(theme.onSurface)
                    .padding(.horizontal, 24)
                    .frame(height: 40)
                    .contentShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 60,
                                                         bottomTrailingRadius: 60, topTrailingRadius: 10))
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .accessibilityIdentifier("home.yourMix.checkOut")
            }
            .clipShape(shape)
            .pixlGlass(in: shape, tint: theme.surfaceContainer.opacity(GlassTint.surface))

            GlassCircleButton(systemImage: "shuffle", accessibilityLabel: "Shuffle your mix", size: 56, iconSize: 22,
                              tint: (isShuffleEnabled ? theme.primary : theme.tertiaryContainer).opacity(GlassTint.prominent),
                              foreground: isShuffleEnabled ? theme.onPrimary : theme.onTertiaryContainer,
                              action: onPlayShuffled)
                .padding(.trailing, 20)
                .offset(y: 20)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.yourMix")
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("YOUR MIX")
                    .fontWidth(.expanded)
                    .pixlFont(.custom(size: 20, weight: .semibold, lineHeight: 22, tracking: -0.35))
                    .foregroundStyle(theme.onPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("Picked for you today")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onPrimary.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85) // SF Pro runs a little wider than Android's font here
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: -16) {
                ForEach(Array(songs.prefix(3).enumerated()), id: \.element.id) { index, song in
                    let size: CGFloat = index == 0 ? 48 : (index == 1 ? 42 : 50)
                    ArtworkView(song: song, size: size, cornerRadius: size / 2)
                        .overlay(Circle().stroke(theme.surface, lineWidth: 2))
                        .offset(y: index == 0 ? 2 : (index == 1 ? -2 : 0))
                }
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 100)
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .background(LinearGradient(colors: [theme.primary, theme.tertiary], startPoint: .leading, endPoint: .trailing))
    }
}

/// A Your Mix row (`EnhancedSongListItem` with `showAlbumArt = false`, 10 pt corners, `surfaceContainerLow`). It
/// sits on the shelf's glass, so it is a fill, not another glass layer.
private struct YourMixRow: View {
    let song: Song
    let isCurrent: Bool
    let isPlaying: Bool
    let onTap: () -> Void
    let onMore: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let t = Tokens.SongCard.self
        let content = isCurrent ? theme.onPrimaryContainer : theme.onSurface
        HStack(spacing: 0) {
            // Title, artist and indicator read as one button (the ⋮ stays its own element).
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: t.titleArtistSpacing) {
                    Text(song.title).pixlFont(.bodyLarge, weight: .semibold).lineLimit(1)
                    Text(song.displayArtist).pixlFont(.bodyMedium).opacity(0.7).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent {
                    PlayingIndicator(isPlaying: isPlaying, color: content)
                        .padding(.leading, Tokens.Spacing.s)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onTap)
            Spacer().frame(width: t.trailingSpacing)
            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .bold))
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(isCurrent ? theme.primaryContainer : theme.onSurface)
                    .frame(width: t.moreButtonSize - t.moreButtonEndPadding, height: t.moreButtonSize - t.moreButtonEndPadding)
                    .background(Circle().fill(isCurrent ? theme.onPrimaryContainer : theme.surfaceContainerHigh.opacity(0.85)))
                    .contentShape(Rectangle().inset(by: -6))
            }
            .buttonStyle(PressScaleButtonStyle())
            .padding(.trailing, t.moreButtonEndPadding)
            .accessibilityLabel("More options for \(song.title)")
        }
        .foregroundStyle(content)
        .padding(.horizontal, t.horizontalPadding)
        .padding(.vertical, t.verticalPadding)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isCurrent ? theme.primaryContainer.opacity(0.85) : theme.surfaceContainerLow.opacity(0.7)))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: onTap)
        .animation(PixlMotion.state, value: isCurrent)
        .accessibilityElement(children: .contain)
    }
}

/// Android `YourMixEmptyPlaceholder`: a 76 pt `secondaryContainer` tile with a note, "No data to show yet", the
/// explanation and a tonal Refresh button.
struct YourMixEmptyPlaceholder: View {
    let onRefresh: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(theme.onSecondaryContainer)
                .frame(width: 76, height: 76)
                .pixlGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                           tint: theme.secondaryContainer.opacity(GlassTint.container))
            VStack(spacing: 6) {
                Text("No data to show yet")
                    .pixlFont(.titleLarge)
                    .foregroundStyle(theme.onSurface)
                Text("Your mix will appear here when PixlAudio finds songs or syncs a source.")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
            GlassPillButton(title: "Refresh", systemImage: "arrow.clockwise",
                            tint: theme.secondaryContainer.opacity(GlassTint.container),
                            foreground: theme.onSecondaryContainer, style: .labelLarge, action: onRefresh)
        }
        .frame(maxWidth: .infinity, minHeight: 256 - 32)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

// MARK: - Just added (RecentlyAddedSection)

/// "Just added" (`titleMedium` bold, 16 pt in), then 120 pt tiles 12 pt apart: cover (16 pt corners), title
/// (`bodyMedium` medium) and artist (`bodySmall`).
struct RecentlyAddedSection: View {
    let songs: [Song]
    let onSongTap: (Song) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Just added")
                .pixlFont(.titleMedium, weight: .bold)
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(songs) { song in
                        Button { onSongTap(song) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(song: song, size: 120, cornerRadius: Tokens.Radius.medium)
                                Text(song.title)
                                    .pixlFont(.bodyMedium, weight: .medium)
                                    .foregroundStyle(theme.onSurface)
                                    .lineLimit(1)
                                Text(song.displayArtist)
                                    .pixlFont(.bodySmall)
                                    .foregroundStyle(theme.onSurfaceVariant)
                                    .lineLimit(1)
                            }
                            .frame(width: 120, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - Recently Played (RecentlyPlayedSection)

/// "Recently Played" (`titleLarge` semibold) with a 64×40 arrow capsule, then up to ten 58 pt pills in three
/// staggered rows that scroll together. Each pill is glass tinted with its own album's `primaryContainer`
/// (Android reads each cover's scheme), 38 pt round cover, title / artist; the current song's pill squares to 14 pt.
struct RecentlyPlayedSection: View {
    let items: [RecentlyPlayedItem]
    let currentSongId: String?
    let onSongTap: (Song) -> Void
    let onOpenAll: () -> Void

    @Environment(\.appTheme) private var theme

    private static let startPadding: CGFloat = 8
    private static let endPadding: CGFloat = 24

    var body: some View {
        let visible = Array(items.prefix(HomeLogic.pillsLimit))
        let rows = HomeLogic.pillRows(visible, width: { HomeLogic.pillWidth(title: $0.song.title, artist: $0.song.displayArtist) },
                                      startPadding: Self.startPadding, endPadding: Self.endPadding)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recently Played")
                    .pixlFont(.titleLarge, weight: .semibold)
                    .foregroundStyle(theme.onSurface)
                    .padding(.leading, 6)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: onOpenAll) {
                    Image(systemName: "arrow.forward")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.secondary)
                        .frame(width: 64, height: 40)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), interactive: true)
                .accessibilityLabel("All recently played")
                .accessibilityIdentifier("home.recentlyPlayed.all")
            }
            .padding(.horizontal, 14)

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: HomeLogic.pillSpacing) {
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        HStack(spacing: HomeLogic.pillSpacing) {
                            ForEach(rows[rowIndex].cells, id: \.item.id) { cell in
                                RecentlyPlayedPill(song: cell.item.song, isCurrent: cell.item.song.id == currentSongId,
                                                   width: cell.width, onTap: { onSongTap(cell.item.song) })
                            }
                        }
                        .frame(height: HomeLogic.pillHeight)
                    }
                }
                .padding(.leading, Self.startPadding)
                .padding(.trailing, Self.endPadding)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

private struct RecentlyPlayedPill: View {
    let song: Song
    let isCurrent: Bool
    let width: CGFloat
    let onTap: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        HomeAlbumThemed(song: song) { album in
            let radius = isCurrent ? 14 : HomeLogic.pillHeight / 2
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            Button(action: onTap) {
                HStack(spacing: 10) {
                    ArtworkView(song: song, size: HomeLogic.pillArtSize, cornerRadius: HomeLogic.pillArtSize / 2)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(song.title)
                            .pixlFont(.titleSmall)
                            .foregroundStyle(album.onPrimaryContainer)
                            .lineLimit(1)
                        Text(song.displayArtist)
                            .pixlFont(.bodySmall)
                            .foregroundStyle(album.onPrimaryContainer.opacity(0.8))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, (HomeLogic.pillHeight - HomeLogic.pillArtSize) / 2)
                .padding(.trailing, 12)
                .frame(width: width, height: HomeLogic.pillHeight)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .pixlGlass(in: shape, tint: album.primaryContainer.opacity(GlassTint.container), interactive: true)
            .animation(.easeInOut(duration: 0.28), value: isCurrent)
            .animation(.easeInOut(duration: 0.28), value: album)
        }
    }
}

/// Supplies a song's album-art scheme (light/dark per the current appearance) to its content, falling back to the
/// app theme until the scheme is ready (Android `ThemeStateHolder.getAlbumColorSchemeFlow`). Extraction runs on the
/// `ColorExtractor` actor and is cached there.
struct HomeAlbumThemed<Content: View>: View {
    let song: Song
    @ViewBuilder var content: (ThemeColors) -> Content

    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var pair: ColorRolesPair?

    var body: some View {
        // A scheme already in memory is used from the first frame (no brand-tint flash, no tint animation).
        let resolved = cachedPair ?? pair
        let colors = resolved.map { ThemeColors(roles: $0.roles(dark: colorScheme == .dark), isDark: colorScheme == .dark) }
            ?? theme
        content(colors)
            .task(id: song.albumArtUriString) {
                guard let source = ArtworkSource(song: song) else { pair = nil; return }
                let appearance = env.settings.appearance
                if let hit = env.colorExtractor.peek(source, style: appearance.paletteStyle,
                                                     accuracyLevel: appearance.colorAccuracy) {
                    if pair != hit { pair = hit }
                    return
                }
                let loaded = await env.colorExtractor.schemePair(for: source, style: appearance.paletteStyle,
                                                                 accuracyLevel: appearance.colorAccuracy)
                if !Task.isCancelled, loaded != pair { pair = loaded }
            }
    }

    private var cachedPair: ColorRolesPair? {
        guard let source = ArtworkSource(song: song) else { return nil }
        let appearance = env.settings.appearance
        return env.colorExtractor.peek(source, style: appearance.paletteStyle, accuracyLevel: appearance.colorAccuracy)
    }
}

// MARK: - Listening stats (StatsOverviewCard)

/// A 28 pt glass card (`surfaceContainerHigh` with a 7 % primary wash) 16 pt in: a header band (`surfaceContainer`)
/// with "Listening stats" / the range and a 40 pt `primaryContainer` arrow, then (24 pt padding) the total time
/// (`headlineLarge` bold), total plays / average per day, the top track and the mini timeline.
struct StatsOverviewCard: View {
    let summary: PlaybackStatsSummary
    let onOpen: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Listening stats")
                            .pixlFont(.titleMedium)
                            .foregroundStyle(theme.onSurface)
                        Text(summary.range.displayName)
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                    Spacer()
                    Image(systemName: "arrow.forward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.onPrimaryContainer)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(theme.primaryContainer))
                        .padding(.trailing, 24)
                }
                .padding(.leading, 24)
                .padding(.vertical, 24)
                .background(theme.surfaceContainer.opacity(0.55))

                content
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
            .background(theme.primary.opacity(0.07))
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), interactive: true)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("home.statsOverview")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(HomeLogic.listeningDurationLong(summary.totalDurationMs))
                .pixlFont(.headlineLarge, weight: .bold)
                .foregroundStyle(theme.onSurface)
            HStack(alignment: .top, spacing: 24) {
                metric("Total plays", "\(summary.totalPlayCount)")
                metric("Avg per day", HomeLogic.listeningDurationCompact(summary.averageDailyDurationMs))
            }
            if let top = summary.topSongs.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top track")
                        .pixlFont(.labelLarge)
                        .foregroundStyle(theme.onSurfaceVariant)
                    Text(top.title)
                        .pixlFont(.titleMedium)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text("\(top.artist) • \(top.playCount) plays")
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            MiniListeningTimeline(summary: summary)
        }
    }

    private func metric(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .pixlFont(.labelLarge)
                .foregroundStyle(theme.onSurfaceVariant)
            Text(value)
                .pixlFont(.titleLarge, weight: .medium)
                .foregroundStyle(theme.onSurface)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `MiniListeningTimeline`: the last (up to) seven buckets as `primary` capsules (≤ 70 pt, ≥ 10 pt) in a 96 pt row,
/// 12 pt apart, labels in `labelSmall`; month ranges draw horizontal 12 pt bars instead.
private struct MiniListeningTimeline: View {
    let summary: PlaybackStatsSummary

    @Environment(\.appTheme) private var theme

    var body: some View {
        let timeline = summary.timeline
        if summary.range == .month && !timeline.isEmpty {
            monthly(timeline)
        } else {
            let entries = Array(timeline.suffix(7))
            let maxDuration = max(entries.map(\.totalDurationMs).max() ?? 0, 1)
            let use24Hour = HomeLogic.uses24HourClock
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    let fraction = min(max(Double(entry.totalDurationMs) / Double(maxDuration), 0), 1)
                    VStack(spacing: 8) {
                        Capsule()
                            .fill(theme.primary)
                            .frame(height: max(70 * fraction, 10))
                        Text(summary.range == .day ? HomeLogic.convertHourLabel(entry.label, use24Hour: use24Hour) : entry.label)
                            .pixlFont(.labelSmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 96, alignment: .bottom)
            .accessibilityElement(children: .combine)
        }
    }

    private func monthly(_ timeline: [TimelineEntry]) -> some View {
        let maxDuration = max(timeline.map(\.totalDurationMs).max() ?? 0, 1)
        return VStack(spacing: 8) {
            ForEach(Array(timeline.enumerated()), id: \.offset) { _, entry in
                let raw = min(max(Double(entry.totalDurationMs) / Double(maxDuration), 0), 1)
                let fraction = raw > 0 ? raw : 0.06
                HStack(spacing: 12) {
                    Text(entry.label)
                        .pixlFont(.labelSmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                        .frame(width: 56, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.surfaceVariant.opacity(0.45))
                            Capsule().fill(theme.primary).frame(width: proxy.size.width * fraction)
                        }
                    }
                    .frame(height: 12)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(height: 108)
    }
}
