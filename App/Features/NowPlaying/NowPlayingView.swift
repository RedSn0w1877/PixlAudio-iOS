import PixlModel
import SwiftUI

/// The full player (Android `FullPlayerContent`, portrait), drawn inside the player sheet's card
/// (`PlayerSheetHost`) over the album's `primaryContainer`:
/// - top bar (64 pt): the collapse circle (42 pt), "Now Playing" (+ a cloud for streamed songs), and on the right
///   the output pill (left-rounded) and the queue pill (right-rounded), 50×42, 6 pt apart;
/// - 24 pt side margins, then — spread like Compose's `SpaceAround` — the album carousel with title / artist, the
///   lyrics and AI DJ circles (48 pt), the seek bar with times and the format chip; then the transport (80 pt) and
///   the shuffle / repeat / favourite row;
/// - the ambient background style behind it all.
/// Each section fades in at Android's thresholds as the sheet expands (top bar from 0, carousel and seek bar from
/// 8 %, metadata from 20 % with a 24 pt slide, controls from 42 %). Material fills become tinted clear glass (the
/// player sits over media); colours are the album palette (`playerTheme`).
struct NowPlayingView: View {
    var safeArea: EdgeInsets
    /// The screen width the player is laid out at (0 = unknown): seeds the carousel and the transport with their
    /// final widths, so a fresh build lays out once instead of measuring first.
    var width: CGFloat

    init(safeArea: EdgeInsets = EdgeInsets(), width: CGFloat = 0) {
        self.safeArea = safeArea
        self.width = width
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(Router.self) private var router
    @Environment(\.playerTheme) private var theme

    var body: some View {
        if let song = playback.current {
            content(song)
        } else {
            Color.clear.accessibilityIdentifier("screen.nowPlaying")
        }
    }

    private func content(_ song: Song) -> some View {
        let isVisible = env.playerSheet.isExpanded || env.playerSheet.isDragging
        // The background never takes part in layout (a filled cover is wider than the screen).
        return VStack(spacing: 0) {
            PlayerTopBar(song: song)
                .padding(.top, safeArea.top)
                .playerSectionFade(start: 0)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    AlbumCarousel(queue: playback.queue, currentIndex: playback.currentIndex,
                                  style: PlayerCarouselStyle(storageKey: settings.appearance.carouselStyle),
                                  isPlaying: playback.isPlaying,
                                  initialWidth: max(width - 48, 0),
                                  onSelect: { index in playback.skipToQueueItem(at: index) },
                                  onAlbumTap: { tapped in openAlbum(tapped) })
                        .padding(.vertical, 8)
                        .playerSectionFade(start: 0.08)
                    VStack(alignment: .leading, spacing: 4) {
                        PlayerMetadataRow(song: song)
                            .playerSectionFade(start: 0.20, slide: 24)
                        PlayerSeekBar(song: song, isPlaying: playback.isPlaying, isActive: isVisible,
                                      clock: playback.clock,
                                      onSeek: { playback.seek(toMs: $0) },
                                      onScrubbingChange: { env.playerSheet.isScrubbing = $0 })
                            .playerSectionFade(start: 0.08)
                    }
                }
                Spacer(minLength: 0)
                Spacer(minLength: 0)
                controls(song)
                    .playerSectionFade(start: 0.42)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, safeArea.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            PlayerAmbientBackground(song: song, style: PlayerAmbientStyle(storageKey: settings.playback.playerAmbientStyle),
                                    isPlaying: playback.isPlaying, isVisible: isVisible)
                .contentShape(.rect)
                .onTapGesture {
                    if settings.behavior.tapBackgroundClosesPlayer { env.playerSheet.collapse() }
                }
        }
        .environment(\.appTheme, theme)
        // The full player is built ahead of its first expand: compile the lyrics shader then, while nothing moves.
        .onAppear { LyricsShaderWarmup.prepare() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.nowPlaying")
        // A modal screen for VoiceOver while it is up: swipes stay inside the player (the shell under it is hidden as
        // well). Only while expanded — the pre-warmed player stays in the hierarchy, hidden, while collapsed, and a
        // modal element must not linger there.
        .modifier(ModalWhileExpanded())
        .accessibilityAction(.escape) { env.playerSheet.collapse() }
    }

    private func controls(_ song: Song) -> some View {
        let isFavorite = library.song(id: song.id)?.isFavorite ?? song.isFavorite
        return VStack(spacing: 0) {
            AnimatedPlaybackControls(isPlaying: playback.isPlaying,
                                     onPrevious: { playback.skipToPrevious() },
                                     onPlayPause: { playback.togglePlayPause() },
                                     onNext: { playback.skipToNext() },
                                     initialWidth: max(width - 72, 0))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Spacer().frame(height: 14)
            PlayerToggleRow(isShuffleOn: playback.isShuffleEnabled, repeatMode: playback.repeatMode,
                            isFavorite: isFavorite,
                            onShuffle: { playback.setShuffleEnabled(!playback.isShuffleEnabled) },
                            onRepeat: { playback.setRepeatMode(Self.nextRepeatMode(after: playback.repeatMode)) },
                            onFavorite: { env.libraryEditor.toggleFavorite(song.id) })
                .padding(.horizontal, 26)
                .padding(.bottom, 6)
        }
    }

    /// Android `cycleRepeatMode`: off → all → one → off.
    static func nextRepeatMode(after mode: RepeatMode) -> RepeatMode {
        switch mode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    /// Android `triggerAlbumNavigationFromPlayer`: collapse the sheet, then open the album (once the collapse is
    /// nearly done, so the push and the collapse don't share their frames).
    private func openAlbum(_ song: Song) {
        let router = self.router
        env.playerSheet.collapse { router.push(.albumDetail(albumId: song.albumId)) }
    }
}

/// `.isModal` for the full player only while the sheet is expanded. Its own small view, so the expand / collapse
/// flips re-run this modifier and not the player's body.
private struct ModalWhileExpanded: ViewModifier {
    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        content.accessibilityAddTraits(env.playerSheet.isExpanded ? .isModal : [])
    }
}

/// The player's top bar (Android `FullPlayerContent` `TopAppBar`).
private struct PlayerTopBar: View {
    let song: Song

    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.playerTheme) private var theme

    private var route: AudioRouteMonitor { AudioRouteMonitor.shared }

    var body: some View {
        // The three glass shapes render together (spacing below the pills' 6 pt gap: nothing blends at rest).
        GlassEffectContainer(spacing: 3) {
            topBar
        }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            // Navigation slot: 56 pt wide, the 42 pt circle at its end (after TopAppBar's 4 pt inset).
            ZStack(alignment: .trailing) {
                Button { env.playerSheet.collapse() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(theme.primary)
                        .frame(width: 42, height: 42)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .playerGlass(in: Circle(), tint: theme.onPrimary.opacity(GlassTint.playerChrome))
                .accessibilityLabel("Collapse player")
                .accessibilityIdentifier("player.collapse")
            }
            .frame(width: 56, height: 42)
            .padding(.leading, 4)
            HStack(spacing: 8) {
                Text("Now Playing")
                    .pixlFont(.labelLarge, weight: .semibold)
                    .foregroundStyle(theme.onPrimaryContainer)
                    .lineLimit(1)
                if Self.isStreamed(song) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.onPrimaryContainer.opacity(0.6))
                        .accessibilityLabel("Cloud stream")
                }
            }
            .padding(.leading, 18)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                outputPill
                Button { router.present(AppSheet.queue) } label: {
                    Image(systemName: "music.note.list") // Android rounded_queue_music_24
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(theme.primary)
                        .frame(width: 50, height: 42)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .playerGlass(in: UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6,
                                                        bottomTrailingRadius: 21, topTrailingRadius: 21,
                                                        style: .continuous),
                             tint: theme.onPrimary.opacity(GlassTint.playerChrome))
                .accessibilityLabel("Open Queue")
                .accessibilityIdentifier("player.queue")
            }
            .padding(.trailing, 18)
        }
        .frame(height: 64)
    }

    /// The output pill (Android's cast button): the current output's icon, with its name while playing over AirPlay —
    /// or "Playing on <device>" while Spotify Connect plays (long press: stop playing there).
    private var outputPill: some View {
        let connect = env.spotifyConnect.active
        // The device's name, as AirPlay's route name (the pill shares the top bar with "Now Playing"); VoiceOver
        // says "Playing on <device>".
        let label: String? = connect?.name ?? (route.isRemote && !route.name.isEmpty ? route.name : nil)
        let showsLabel = label != nil
        let trailing: CGFloat = showsLabel ? 21 : 6
        return Button { router.present(AppSheet.devices) } label: {
            HStack(spacing: 8) {
                Image(systemName: connect?.symbolName ?? route.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                if let label {
                    Text(label)
                        .pixlFont(.labelMedium)
                        .lineLimit(1)
                    Circle().fill(theme.onTertiaryContainer).frame(width: 8, height: 8)
                }
            }
            .foregroundStyle(theme.primary)
            .padding(.leading, 14)
            .padding(.trailing, showsLabel ? 16 : 14)
            .frame(minWidth: 50, maxWidth: showsLabel ? 190 : 58, minHeight: 42, maxHeight: 42,
                   alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .playerGlass(in: UnevenRoundedRectangle(topLeadingRadius: 21, bottomLeadingRadius: 21,
                                                bottomTrailingRadius: trailing, topTrailingRadius: trailing,
                                                style: .continuous),
                     tint: theme.onPrimary.opacity(GlassTint.playerChrome))
        .contextMenu {
            if let connect {
                Button(String(localized: "Stop playing on \(connect.name)"), systemImage: "stop.circle") {
                    env.spotifyConnect.disconnect()
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: showsLabel)
        .accessibilityLabel(connect.map { String(localized: "Playing on \($0.name)") }
                            ?? (route.kind == .airPlay ? "AirPlay" : (route.kind == .bluetooth ? "Bluetooth" : "Local playback")))
        .accessibilityIdentifier("player.devices")
    }

    /// Spotify / YouTube songs stream (Android: `contentUriString` starting with `spotify:`).
    static func isStreamed(_ song: Song) -> Bool {
        song.spotifyId != nil || song.id.hasPrefix("yt:") || song.id.hasPrefix("sp:")
    }
}

/// Title, artist and the lyrics / AI DJ circles (Android `SongMetadataDisplaySection` + `PlayerSongInfo`).
private struct PlayerMetadataRow: View {
    let song: Song

    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.playerTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .pixlFont(.headlineSmall, weight: .bold)
                    .foregroundStyle(theme.onPrimaryContainer)
                    .lineLimit(1)
                Text(song.displayArtist)
                    .pixlFont(PixlTextStyle.titleMedium.tracking(0))
                    .foregroundStyle(theme.onPrimaryContainer.opacity(0.7))
                    .lineLimit(1)
                    .contentShape(.rect)
                    .onTapGesture { openArtist() }
                    .onLongPressGesture(minimumDuration: 0.5) { navigateToArtist(song.primaryArtist.id) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens the artist")
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The loading chip and the two circles render together (spacing below their 12 pt / 20 pt gaps: they never
            // blend at rest).
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 12) {
                    if playback.isPreparing {
                        // Android's chip is a Material circle `Surface` (FullPlayerContent.kt:1630-1644): clear glass
                        // over the player's background like its neighbours (decision 10), not interactive (no button).
                        ProgressView()
                            .controlSize(.regular)
                            .tint(theme.primary)
                            .frame(width: 28, height: 28)
                            .padding(10)
                            .glassEffect(Glass.clear.tint(theme.onPrimary.opacity(GlassTint.playerChrome)),
                                         in: Circle())
                            .padding(.trailing, 8)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    circle(systemImage: "quote.bubble", label: "Lyrics", identifier: "player.lyrics") {
                        router.present(AppCover.lyrics)
                    }
                    circle(systemImage: "sparkles", label: "Ask the AI DJ", identifier: "player.aiDJ", iconSize: 20) {
                        router.present(AppSheet.taisChat)
                    }
                }
            }
        }
        .frame(minHeight: 70)
        .animation(.easeOut(duration: 0.3), value: playback.isPreparing)
    }

    private func circle(systemImage: String, label: LocalizedStringKey, identifier: String, iconSize: CGFloat = 22,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(theme.primary)
                .frame(width: 48, height: 48)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .playerGlass(in: Circle(), tint: theme.onPrimary.opacity(GlassTint.playerChrome))
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// Android `onSongMetadataArtistClick`: several artists open the picker, one goes straight to its page.
    private func openArtist() {
        if song.artists.count > 1 {
            router.present(AppSheet.artistPicker(songId: song.id))
        } else {
            navigateToArtist(song.primaryArtist.id)
        }
    }

    /// Android `triggerArtistNavigationFromPlayer`: collapse, then push once the collapse is nearly done.
    private func navigateToArtist(_ artistId: Int64) {
        let router = self.router
        env.playerSheet.collapse { router.push(.artistDetail(artistId: artistId)) }
    }
}

extension View {
    /// Glass for the player's controls: the clear variant (the player sits over media), tinted with the palette role
    /// Android filled the control with, interactive.
    func playerGlass<S: Shape>(in shape: S, tint: Color) -> some View {
        glassEffect(Glass.clear.tint(tint).interactive(), in: shape)
    }
}
