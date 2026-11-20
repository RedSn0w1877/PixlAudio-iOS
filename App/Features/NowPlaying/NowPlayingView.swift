import PixlFoundation
import PixlModel
import PixlNet
import SwiftUI

/// The full player (Android `FullPlayerContent`, portrait), drawn inside the player sheet's card
/// (`PlayerSheetHost`) over the album's `primaryContainer`. New UI (owner decisions, 2026-11-16; mockup `iOSPlayer`):
/// - the hero: the queue's covers fill the top edge to edge (the full-bleed `AlbumCarousel`, so swiping, tapping for
///   the album, double-tap to like and the long-press quick actions all stay), about 85 % of the screen tall
///   (`ProgressiveHero.playerLayout`): sharp at the top, progressively blurred from about halfway down the screen,
///   fully blurred where the title starts, then melting to nothing at the hero's bottom edge, under the seek bar and
///   the transport, into the album colour and the ambient background (each page's pre-blurred copy behind a static
///   mask, one static veil; no live blur);
/// - over it, the top bar (64 pt): the collapse circle (42 pt), and on the right the output pill (the output's icon,
///   plus the device's name for any output other than this phone) joined to the ⋯ menu (`PlayerMoreMenu`: Spatial
///   audio, Sing, Ask Taizo and the song's actions), 6 pt apart;
/// - at the bottom: the title (SF Pro at the widest width that fits, `FitWidthTitle`) and artist with the Queue circle
///   where the like button was, the seek bar with times and the quality label, the transport (80 pt, the press-to-bounce
///   group, unchanged), and the split pills — Shuffle · Repeat · Like in the big capsule, Lyrics in the small circle
///   (`PlayerActionPills`).
/// Each section fades in at Android's thresholds as the sheet expands (top bar from 0, hero and seek bar from 8 %,
/// metadata from 20 % with a 24 pt slide, controls from 42 %). Material fills become tinted clear glass (the player sits
/// over media); colours are the album palette (`playerTheme`).
struct NowPlayingView: View {
    var safeArea: EdgeInsets
    /// The screen width the player is laid out at (0 = unknown): seeds the carousel and the transport with their
    /// final widths, so a fresh build lays out once instead of measuring first.
    var width: CGFloat
    /// The screen height the player is laid out at (0 = unknown): sizes the full-bleed hero to the screen
    /// (`ProgressiveHero.playerLayout`), with the controls over its blurred, melting bottom.
    var height: CGFloat

    init(safeArea: EdgeInsets = EdgeInsets(), width: CGFloat = 0, height: CGFloat = 0) {
        self.safeArea = safeArea
        self.width = width
        self.height = height
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback
    @Environment(SettingsStore.self) private var settings
    @Environment(Router.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.playerTheme) private var theme
    /// Double-tap to like: bumped per tap; `burstIsLike` says which heart the burst draws.
    @State private var burstCount = 0
    @State private var burstIsLike = true

    var body: some View {
        if let song = playback.current {
            content(song)
        } else {
            Color.clear.accessibilityIdentifier("screen.nowPlaying")
        }
    }

    private func content(_ song: Song) -> some View {
        let isVisible = env.playerSheet.isExpanded || env.playerSheet.isDragging
        // The background never takes part in layout (a filled cover is wider than the screen); the hero sits at the
        // top, under the chrome, and the content stack sits over its blurred, melting bottom.
        return ZStack(alignment: .top) {
            hero(song, isVisible: isVisible)
                .playerSectionFade(start: 0.08)
            VStack(spacing: 0) {
                PlayerTopBar(song: song)
                    .padding(.top, safeArea.top)
                    .playerSectionFade(start: 0)
                    // VoiceOver still starts at the top bar, though the hero comes first in the stack.
                    .accessibilitySortPriority(1)
                Spacer(minLength: 8)
                VStack(alignment: .leading, spacing: 4) {
                    PlayerMetadataRow(song: song)
                        .playerSectionFade(start: 0.20, slide: 24)
                    PlayerSeekBar(song: song, isPlaying: playback.isPlaying, isActive: isVisible,
                                  clock: playback.clock,
                                  onSeek: { playback.seek(toMs: $0) },
                                  onScrubbingChange: { env.playerSheet.isScrubbing = $0 })
                        .playerSectionFade(start: 0.08)
                }
                .padding(.horizontal, 24)
                controls(song)
                    .playerSectionFade(start: 0.42)
            }
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

    /// The full-bleed hero: the queue's covers (swipe, tap for the album, double-tap to like, long press for the quick
    /// actions), each page with its own progressive blur, under one veil that melts into the album colour.
    private func hero(_ song: Song, isVisible: Bool) -> some View {
        // The carousel is as tall as the whole hero; the heart pops in the middle of its sharp cover (the middle of the
        // carousel while the width is unknown).
        let sharp = ProgressiveHero.playerLayout(width: Double(width), screenHeight: Double(height),
                                                 titleClearance: Double(Self.titleClearance + safeArea.bottom))
            .sharpHeight
        let heartHeight: CGFloat? = sharp > 0 ? CGFloat(sharp) : nil
        return AlbumCarousel(queue: playback.queue, currentIndex: playback.currentIndex,
                      style: PlayerCarouselStyle(storageKey: settings.appearance.carouselStyle),
                      isPlaying: playback.isPlaying,
                      initialWidth: width,
                      allowsSwipe: settings.behavior.gesturePlayerArtworkSwipe,
                      onDoubleTap: settings.behavior.gesturePlayerArtworkDoubleTapLike && !voiceOver
                          ? { toggleLike(song) } : nil,
                      fullBleed: CarouselHero(screenHeight: height,
                                              titleClearance: Self.titleClearance + safeArea.bottom,
                                              veil: theme.primaryContainer,
                                              topScrimHeight: safeArea.top + 72,
                                              isVisible: isVisible),
                      onSelect: { index in playback.skipToQueueItem(at: index) },
                      onAlbumTap: { tapped in openAlbum(tapped) })
            .overlay(alignment: heartHeight == nil ? .center : .top) {
                HeartBurst(trigger: burstCount, isLike: burstIsLike)
                    .frame(height: heartHeight)
            }
            .songQuickActions(song: song, isEnabled: settings.behavior.gesturePlayerArtworkLongPress)
            .pixlHaptic(.success, trigger: burstCount)
            .accessibilityActions {
                Button("Next song") { playback.skipToNext() }
                Button("Previous song") { playback.skipToPrevious() }
                Button("Like or unlike") { toggleLike(song) }
            }
    }

    /// From the title's top to the bottom safe area — the metadata row under the title's top (~68), the seek bar (70),
    /// the transport with its padding (96), the 14 pt gap and the split pills with theirs (70): the hero is fully
    /// blurred where the title starts. An estimate (a larger text size lifts the title a little onto the blur band,
    /// where the veil still covers it), so the player measures nothing for it.
    private static let titleClearance: CGFloat = 320

    private func controls(_ song: Song) -> some View {
        VStack(spacing: 0) {
            // Unchanged (owner, 2026-11-16): the press-to-bounce previous / play-pause / next group.
            AnimatedPlaybackControls(isPlaying: playback.isPlaying,
                                     onPrevious: { playback.skipToPrevious() },
                                     onPlayPause: { playback.togglePlayPause() },
                                     onNext: { playback.skipToNext() },
                                     initialWidth: max(width - 72, 0))
                .padding(.horizontal, 36)
                .padding(.vertical, 8)
            Spacer().frame(height: 14)
            PlayerToggles(song: song)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        }
    }

    /// Double-tap on the artwork (and VoiceOver's "Like or unlike"): toggles the favourite and shows the heart.
    private func toggleLike(_ song: Song) {
        let wasFavorite = library.song(id: song.id)?.isFavorite ?? song.isFavorite
        env.libraryEditor.toggleFavorite(song.id)
        burstIsLike = !wasFavorite
        burstCount += 1
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
        // A song from outside the library may name an album the library has no page for.
        guard library.album(id: song.albumId) != nil else { return }
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

/// The player's top bar (Android `FullPlayerContent` `TopAppBar`), without Android's "Now Playing" title and its cloud
/// for streamed songs (Hoa, 2026-10-07): the collapse circle on the left; on the right the output pill, which names
/// the output and may grow into the freed width, joined to the ⋯ menu (new UI, 2026-11-16: the queue pill moved to the
/// title row as a circle, and the ⋯ menu took its place and shape).
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
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                outputPill
                PlayerMoreMenu(song: song,
                               shape: UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6,
                                                             bottomTrailingRadius: 21, topTrailingRadius: 21,
                                                             style: .continuous))
            }
            .padding(.trailing, 18)
            // Ahead of the Spacer, so a long name can use all the width the collapse circle leaves (about width −
            // 146 pt) instead of splitting the free width with the Spacer and truncating at half of it.
            .layoutPriority(1)
        }
        .frame(height: 64)
    }

    /// The output pill (Android's cast button): the output's icon, plus its name for any output other than this
    /// phone's speaker — a Spotify Connect device, AirPlay, Bluetooth, wired headphones, a car (Hoa, 2026-10-07; Android
    /// names only a cast device). It hugs its content (icon only: 50 pt, like the ⋯ pill) and grows with the name
    /// up to the collapse circle, truncating at the tail. A dot marks an output that plays elsewhere (Connect,
    /// AirPlay), as Android's does while casting; "Connecting…" and a spinner while a Connect session starts. Long
    /// press while Connect plays: stop playing there.
    private var outputPill: some View {
        let connect = env.spotifyConnect.active
        let connectingId = connect == nil ? env.spotifyConnect.connectingDeviceId : nil
        let connecting = connectingId.flatMap { id in env.spotifyConnect.devices.first { $0.deviceId == id } }
        let name: String? = connect?.name ?? route.deviceName
        let label: String? = connectingId != nil ? String(localized: "Connecting…") : name
        let isRemote = connect != nil || route.isRemote
        let trailing: CGFloat = label != nil ? 21 : 6
        let spoken: String = if connectingId != nil {
            String(localized: "Connecting to a Spotify Connect device")
        } else if let name {
            String(localized: "Playing on \(name)")
        } else {
            String(localized: "Playing on this phone")
        }
        return Button { router.present(AppSheet.devices) } label: {
            HStack(spacing: 8) {
                Image(systemName: connect?.symbolName ?? connecting?.symbolName ?? route.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                if let label {
                    Text(label)
                        .pixlFont(.labelMedium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.opacity)
                    if connectingId != nil {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(theme.primary)
                    } else if isRemote {
                        Circle().fill(theme.onTertiaryContainer).frame(width: 8, height: 8)
                    }
                }
            }
            .foregroundStyle(theme.primary)
            .padding(.leading, 14)
            .padding(.trailing, label != nil ? 16 : 14)
            // Only a minimum: the pill hugs its content instead of taking the offered width.
            .frame(minWidth: 50, minHeight: 42, maxHeight: 42, alignment: .leading)
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
        // On the name itself, so a switch from one device to another re-sizes smoothly too.
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: label)
        .accessibilityLabel(spoken)
        .accessibilityHint("Opens the devices sheet")
        .accessibilityIdentifier("player.devices")
    }
}

/// The bottom split pills (shuffle · repeat · favourite, and lyrics) with their state read here, so a favourite edit or
/// a shuffle / repeat change redraws these pills only, not the whole full player. The favourite goes through `observedSong(id:)`: the library's song
/// lookup is not observed, and reading it in the player's body left the heart stale until something else (shuffle,
/// repeat, play / pause) redrew the player.
private struct PlayerToggles: View {
    let song: Song

    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router

    var body: some View {
        let isFavorite = library.observedSong(id: song.id)?.isFavorite ?? song.isFavorite
        PlayerActionPills(isShuffleOn: playback.isShuffleEnabled, repeatMode: playback.repeatMode,
                          isFavorite: isFavorite,
                          onShuffle: { playback.setShuffleEnabled(!playback.isShuffleEnabled) },
                          onRepeat: { playback.setRepeatMode(NowPlayingView.nextRepeatMode(after: playback.repeatMode)) },
                          onFavorite: { env.libraryEditor.toggleFavorite(song.id) },
                          onLyrics: { router.present(AppCover.lyrics) })
    }
}

/// Title, artist and the Queue circle (Android `SongMetadataDisplaySection` + `PlayerSongInfo`; new UI, 2026-11-16: the
/// Queue circle sits where the like button was, Lyrics moved to the bottom pills, and Ask Taizo, Spatial audio and Sing
/// to the ⋯ menu). The title is SF Pro at the widest width that fits one line (`FitWidthTitle`, `.playerTitle`: heavy,
/// expanded down to compressed), re-measured only when the song or the width changes.
private struct PlayerMetadataRow: View {
    let song: Song

    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.playerTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                FitWidthTitle(text: song.title, face: .playerTitle, narrowest: .compressed, lines: 1)
                    .foregroundStyle(theme.onPrimaryContainer)
                Text(song.displayArtist)
                    .pixlFont(.custom(size: 18, weight: .medium, lineHeight: 24))
                    .foregroundStyle(theme.onPrimaryContainer.opacity(0.7))
                    .lineLimit(1)
                    .contentShape(.rect)
                    .onTapGesture { openArtist() }
                    .onLongPressGesture(minimumDuration: 0.5) { navigateToArtist(song.primaryArtist.id) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens the artist")
                PlayerSetNoteLine(color: theme.onPrimaryContainer.opacity(0.7))
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Android's loading chip (a circle beside the queue button) became the Queue circle's own spinner: a chip
            // inserted next to the title changed the title's width as each song started and finished preparing, and
            // re-fitted it twice per song. The title's width now depends on the song and the screen only.
            // Android rounded_queue_music_24.
            circle(systemImage: "music.note.list", label: "Open Queue", identifier: "player.queue",
                   isBusy: playback.isPreparing) {
                router.present(AppSheet.queue)
            }
        }
        .frame(minHeight: 70)
        .animation(.easeOut(duration: 0.3), value: playback.isPreparing)
    }

    /// `isBusy`: the song is still being prepared — the icon gives way to a spinner (the button still works).
    private func circle(systemImage: String, label: LocalizedStringKey, identifier: String, iconSize: CGFloat = 22,
                        isBusy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(theme.primary)
                    .opacity(isBusy ? 0 : 1)
                    .scaleEffect(isBusy ? 0.85 : 1)
                if isBusy {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(theme.primary)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .frame(width: 48, height: 48)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .playerGlass(in: Circle(), tint: theme.onPrimary.opacity(GlassTint.playerChrome))
        .accessibilityLabel(label)
        .accessibilityValue(isBusy ? Text("Preparing") : Text(""))
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
        // A song from outside the library may name an artist the library has no page for.
        guard env.library.artist(id: artistId) != nil else { return }
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
