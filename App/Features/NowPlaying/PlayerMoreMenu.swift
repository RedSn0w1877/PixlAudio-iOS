import PixlModel
import SwiftUI

/// The full player's ⋯ menu (new UI, owner decision 2026-11-16; mockup `iOSPlayerMenu`), in the top bar where the
/// queue pill was (the queue moved to the title row). A small menu, so the system's liquid menu that morphs out of the
/// button's glass (docs/design.md › Small menus), in three groups:
/// - Listen: **Spatial audio** (opens the Spatial audio sheet over the player, as the button that sat beside the title
///   did; the subtitle names the profile) and **Sing** (vocals off / on through the song's instrumental, the same
///   request as the lyrics screen's Sing segment, with its state as the subtitle), then Ask Taizo (the sparkles circle
///   that sat beside the title);
/// - the song: Start station and Not for me (the music brain, docs/brain-spec.md 8.3 and 8.5), Add to playlist, Go to
///   album, Go to artist (the picker when there are several), Share;
/// - Sleep timer and Song details.
///
/// Its own view: the Spatial audio profile and the Sing job's progress redraw this button only, never the player.
struct PlayerMoreMenu<MenuShape: Shape>: View {
    let song: Song
    let shape: MenuShape

    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.playerTheme) private var theme
    @State private var showsAddToPlaylist = false

    var body: some View {
        let spatial = SpatialButtonUI.of(selection: env.spatial.currentSongSelection,
                                         blockedBy: env.spatial.snapshot.blockedBy)
        let sing = singState()
        let shareURL = SongQuickActions.shareURL(song)
        let inLibrary = library.song(id: song.id) != nil
        Menu {
            Section {
                Button {
                    router.present(AppSheet.spatialAudio(fromPlayer: true))
                } label: {
                    Label(L10n.spatialAudio, systemImage: SpatialAudioUI.symbol)
                    Text(spatial.accessibilityValue)
                }
                Button {
                    Task { await env.tais.instrumental.requestSing(for: song) }
                } label: {
                    Label("Sing", systemImage: "music.mic")
                    Text(LocalizedStringKey(sing.value))
                }
                .disabled(!sing.enabled)
                Button("Ask Taizo", systemImage: "sparkles") {
                    router.present(AppSheet.taisChat)
                }
            }
            Section {
                Button(BrainStrings.startStation, systemImage: "dot.radiowaves.left.and.right") {
                    env.brainActions.startSongStation(song)
                }
                Button(BrainStrings.notForMe, systemImage: "hand.thumbsdown") {
                    env.brainActions.notForMe(song)
                }
                Button("Add to playlist", systemImage: "text.badge.plus") { showsAddToPlaylist = true }
                // A song from outside the library may name an album or an artist the library has no page for.
                if library.album(id: song.albumId) != nil {
                    Button("Go to album", systemImage: "opticaldisc") { openAlbum() }
                }
                if SongQuickActions.artists(of: song).contains(where: { library.artist(id: $0.id) != nil }) {
                    Button("Go to artist", systemImage: "person") { openArtist() }
                }
                if let shareURL {
                    ShareLink(item: shareURL) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
            Section {
                Button("Sleep timer", systemImage: "moon.zzz") { router.present(AppSheet.sleepTimer) }
                if inLibrary {
                    Button("Song details", systemImage: "info.circle") {
                        router.present(AppSheet.songInfo(songId: song.id))
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(theme.primary)
                .frame(width: 50, height: 42)
                .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .playerGlass(in: shape, tint: theme.onPrimary.opacity(GlassTint.playerChrome))
        .accessibilityLabel("More options")
        .accessibilityIdentifier("player.more")
        .sheet(isPresented: $showsAddToPlaylist) {
            AddToPlaylistSheet(songIds: [song.id])
                .pixlSheet(detents: [.large])
        }
    }

    /// Sing's row, read as the lyrics screen's Sing segment reads it (`LyricsSingSegment`): the instrumental's phase,
    /// the cloud job, this phone's render; off while the player switches and while Spotify Connect plays.
    private func singState() -> (value: String, enabled: Bool) {
        let instrumental = env.tais.instrumental
        let job = env.tais.studio.state(.instrumental, songId: song.id)
        let rendering = job?.isActive == true
        let renderPercent: Int? = rendering && job?.indeterminate == false ? job?.percent : nil
        let face = SingButtonFace.make(phase: instrumental.singPhase, cloudStatus: instrumental.cloudStatus,
                                       rendering: rendering, renderPercent: renderPercent,
                                       active: instrumental.isActive)
        let remote = playback.remoteOutputName != nil
        return (face.value, !instrumental.isSwitching && !remote)
    }

    /// Android `triggerAlbumNavigationFromPlayer`: collapse, then push once the collapse is nearly done.
    private func openAlbum() {
        let router = self.router
        let albumId = song.albumId
        env.playerSheet.collapse { router.push(.albumDetail(albumId: albumId)) }
    }

    /// As the artist line: several artists open the picker, one goes straight to its page.
    private func openArtist() {
        if song.artists.count > 1 {
            router.present(AppSheet.artistPicker(songId: song.id))
        } else {
            let router = self.router
            let artistId = song.primaryArtist.id
            env.playerSheet.collapse { router.push(.artistDetail(artistId: artistId)) }
        }
    }
}
