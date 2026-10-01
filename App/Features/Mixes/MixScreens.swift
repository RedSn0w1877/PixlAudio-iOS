import PixlModel
import SwiftUI

/// Daily Mix (Android `DailyMixScreen`): today's 30 personalised picks under the expressive cover-stack header.
struct DailyMixView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        MixScreen(title: "Daily Mix", songs: env.home.content.dailyMix, playsFromLibrary: false, screenID: "dailyMix",
                  titleLeading: 22 + 6, trailingHeaderButton: .ai, topTrailingButton: nil)
    }
}

/// Your Mix (Android `YourMixScreen`): the full list the Home shelf teases, with the same curated → daily →
/// newest-songs fallback, and a regenerate button.
struct YourMixView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let content = env.home.content
        MixScreen(title: "YOUR MIX", songs: content.yourMix, playsFromLibrary: content.usesFallbackYourMix,
                  screenID: "yourMix", titleLeading: 28, trailingHeaderButton: nil, topTrailingButton: .regenerate)
    }
}

/// The structure Daily Mix and Your Mix share on Android (two screens, same layout): a gradient background
/// (`primary` 25 % → `surface`), a 340 pt header with three tilted covers (180 / 220 / 180 pt, −15° / 0° / 15°,
/// overlapping by 80 pt) that parallaxes and fades as the list scrolls, the title (44 pt bold) and "N Songs • time",
/// a 76 pt Play it / Shuffle row, then the songs as glass cards. Floating glass back (and regenerate) circles.
struct MixScreen: View {
    enum HeaderButton { case ai }
    enum TopButton { case regenerate }

    let title: LocalizedStringKey
    let songs: [Song]
    /// The fallback mix plays from the whole library (Android `showAndPlaySongFromLibrary`).
    let playsFromLibrary: Bool
    let screenID: String
    let titleLeading: CGFloat
    let trailingHeaderButton: HeaderButton?
    let topTrailingButton: TopButton?

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var isRegenerating = false

    var body: some View {
        ZStack(alignment: .top) {
            background
            if songs.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .tint(theme.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            edgeGradients
            topButtons
        }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("screen.\(screenID)")
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                MixHeader(title: title, songs: songs, titleLeading: titleLeading,
                          showsAIButton: trailingHeaderButton == .ai)
                MixPlayShuffleRow(
                    playTitle: "Play it",
                    height: 76, verticalPadding: 8, horizontalPadding: 20, outerRadius: 60,
                    onPlay: { play(from: songs[0]); if playback.isShuffleEnabled { playback.setShuffleEnabled(false) } },
                    onShuffle: {
                        if playsFromLibrary { playback.play(library.songs.shuffled()) } else { playback.play(songs.shuffled()) }
                    })
                ForEach(songs) { song in
                    SongCard(song: song, isCurrent: playback.current?.id == song.id,
                             isPlaying: playback.current?.id == song.id && playback.isPlaying,
                             onTap: { play(from: song) },
                             onMore: { router.present(AppSheet.songInfo(songId: song.id)) })
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
    }

    private func play(from song: Song) {
        playback.play(song, in: playsFromLibrary ? library.songs : songs)
    }

    /// `Brush.verticalGradient(primary 25 %, surface 50 %, surface, endY = 1200 px)`.
    private var background: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [theme.primary.opacity(0.25), theme.surface.opacity(0.5), theme.surface],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 460)
            theme.surface
        }
        .background(theme.surface)
        .ignoresSafeArea()
    }

    /// Android's top (50 pt, `surfaceContainerLowest` 50 % → clear) and bottom (80 pt) fades.
    private var edgeGradients: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [theme.surfaceContainerLowest.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 50)
                .ignoresSafeArea(edges: .top)
            Spacer()
            LinearGradient(colors: [.clear, theme.surfaceContainerLowest.opacity(0.5), theme.surfaceContainerLowest],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 80)
                .ignoresSafeArea(edges: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Back (and regenerate) as glass circles, 10 pt in and 8 pt below the status bar.
    private var topButtons: some View {
        HStack {
            GlassCircleButton(systemImage: "arrow.backward", accessibilityLabel: "Back",
                              tint: theme.surface.opacity(GlassTint.surface)) { router.pop() }
                .accessibilityIdentifier("\(screenID).back")
            Spacer()
            if topTrailingButton == .regenerate {
                GlassCircleButton(systemImage: "arrow.clockwise", accessibilityLabel: "Regenerate your mix",
                                  tint: theme.surface.opacity(GlassTint.surface)) {
                    guard !isRegenerating else { return }
                    isRegenerating = true
                    Task {
                        await env.home.regenerateYourMix(snapshot: library.snapshot)
                        isRegenerating = false
                    }
                }
                .opacity(isRegenerating ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }
}

/// The 340 pt cover stack with parallax: translates by half the scroll offset and fades out over 600 pt (read with
/// `visualEffect`, so scrolling never re-renders the screen).
private struct MixHeader: View {
    let title: LocalizedStringKey
    let songs: [Song]
    let titleLeading: CGFloat
    let showsAIButton: Bool

    @Environment(\.appTheme) private var theme

    var body: some View {
        let arts = distinctArt(songs)
        let totalDuration = songs.reduce(Int64(0)) { $0 + $1.duration }
        ZStack(alignment: .bottom) {
            HStack(spacing: -80) {
                ForEach(Array(arts.enumerated()), id: \.offset) { index, song in
                    let size: CGFloat = index == 1 ? 220 : 180
                    // Android's Material shapes (star / circle / rounded square) become a rounded square, a circle
                    // and a rounded square.
                    let radius: CGFloat = index == 1 ? size / 2 : (index == 0 ? 52 : 30)
                    ArtworkView(song: song, size: size, cornerRadius: radius)
                        .rotationEffect(.degrees(index == 0 ? -15 : (index == 2 ? 15 : 0)))
                        .zIndex(index == 1 ? 0 : Double(index))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            LinearGradient(stops: [.init(color: theme.surface.opacity(0.1), location: 0),
                                   .init(color: .clear, location: 0.25),
                                   .init(color: theme.surface.opacity(0.5), location: 0.5),
                                   .init(color: theme.surface.opacity(0.9), location: 0.75),
                                   .init(color: theme.surface, location: 1)],
                           startPoint: .top, endPoint: .bottom)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .pixlFont(.custom(size: 44, weight: .bold))
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(HomeLogic.songsDotDuration(count: songs.count, durationMs: totalDuration))
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurface.opacity(0.8))
                        .padding(.leading, 3)
                }
                Spacer()
                if showsAIButton {
                    // Android: a large star-shaped FAB opening the AI playlist sheet (stage 13 wires it).
                    GlassCircleButton(systemImage: "sparkles", accessibilityLabel: "AI Playlist Generator", size: 96,
                                      iconSize: 22, tint: theme.primaryContainer.opacity(GlassTint.prominent),
                                      foreground: theme.onPrimaryContainer) {}
                }
            }
            .padding(.leading, titleLeading)
            .padding(.trailing, 22)
        }
        .frame(height: 340) // not clipped: Android's header box isn't, so the 96 pt button keeps its full glass
        .visualEffect { content, proxy in
            let offset = max(-proxy.frame(in: .scrollView).minY, 0)
            return content
                .offset(y: offset * 0.5)
                .opacity(Double(min(max(1 - offset / 600, 0), 1)))
        }
    }

    private func distinctArt(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        var result: [Song] = []
        for song in songs where result.count < 3 {
            let key = song.albumArtUriString ?? ""
            if seen.insert(key).inserted { result.append(song) }
        }
        return result
    }
}

/// Play / Shuffle (Android `Button` + `FilledTonalButton`, mirrored asymmetric corners, 18 pt icons): the primary
/// one is the strongest glass tint (`primary`), the other `secondaryContainer`.
struct MixPlayShuffleRow: View {
    let playTitle: LocalizedStringKey
    let height: CGFloat
    let verticalPadding: CGFloat
    let horizontalPadding: CGFloat
    let outerRadius: CGFloat
    let onPlay: () -> Void
    let onShuffle: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let inner: CGFloat = 14
        let buttonHeight = height - 2 * verticalPadding
        let outer = min(outerRadius, buttonHeight / 2)
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 8) {
                button(playTitle, "play.fill", foreground: theme.onPrimary,
                       tint: theme.primary.opacity(GlassTint.prominent),
                       shape: UnevenRoundedRectangle(topLeadingRadius: outer, bottomLeadingRadius: outer,
                                                     bottomTrailingRadius: inner, topTrailingRadius: inner,
                                                     style: .continuous),
                       height: buttonHeight, action: onPlay)
                button("Shuffle", "shuffle", foreground: theme.onSecondaryContainer,
                       tint: theme.secondaryContainer.opacity(GlassTint.container),
                       shape: UnevenRoundedRectangle(topLeadingRadius: inner, bottomLeadingRadius: inner,
                                                     bottomTrailingRadius: outer, topTrailingRadius: outer,
                                                     style: .continuous),
                       height: buttonHeight, action: onShuffle)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(height: height)
    }

    private func button(_ title: LocalizedStringKey, _ symbol: String, foreground: Color, tint: Color,
                        shape: UnevenRoundedRectangle, height: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(title)
                    .pixlFont(.labelLarge)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassEffect(Glass.regular.tint(tint).interactive(), in: shape)
    }
}
