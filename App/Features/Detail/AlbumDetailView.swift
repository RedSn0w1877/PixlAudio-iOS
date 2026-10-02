import PixlLibrary
import PixlModel
import SwiftUI

/// Album detail (Android `AlbumDetailScreen`): themed with the album's colour scheme; the collapsing artwork header
/// (title, "artist • N Songs", back, shuffle) over the track list — songs as cards without artwork, 8 pt apart,
/// 16 pt sides, grouped under "Disc N" headers when the album has several discs. Shuffle starts a random track
/// within the album order (Android `showAndPlaySong(songs.random(), songs)`).
struct AlbumDetailView: View {
    let albumId: Int64

    @Environment(LibraryStore.self) private var library

    var body: some View {
        ArtworkThemed(artUri: library.album(id: albumId)?.albumArtUriString) {
            AlbumDetailContent(albumId: albumId)
        }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("screen.albumDetail")
    }
}

private struct AlbumDetailContent: View {
    let albumId: Int64

    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var scroll = HeaderScrollState()
    /// The album's songs in play order, derived in `body` once per library revision: the push's first frame has them
    /// (the subtitle no longer reads "0 Songs" for a frame, and there is no second pass).
    @State private var memo = ViewMemo<Int, [Song]>()

    private var songs: [Song] {
        memo.value(for: library.revision) { LibrarySorting.albumPlaybackOrder(library.songs(ofAlbum: albumId)) }
    }

    var body: some View {
        let songs = self.songs
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let metrics = CollapseMetrics(maxHeight: 300, minHeight: 64 + safeTop)
            ZStack(alignment: .top) {
                theme.surface.ignoresSafeArea()
                if let album = library.album(id: albumId) {
                    list(topPadding: metrics.maxHeight - safeTop + 8)
                    CollapsingArtworkHeader(title: album.title,
                                            subtitle: "\(album.artist) • \(LibraryFormat.songCount(songs.count))",
                                            artwork: ArtworkSource(uriString: album.albumArtUriString), scroll: scroll,
                                            metrics: metrics, safeTop: safeTop,
                                            onBack: { router.pop() },
                                            onShuffle: shuffle) { EmptyView() }
                        .ignoresSafeArea(edges: .top)
                } else {
                    LibraryEmptyState(systemImage: "opticaldisc", title: "Album not found", subtitle: "")
                }
            }
        }
    }

    private func list(topPadding: CGFloat) -> some View {
        let songs = self.songs
        let byDisc = Dictionary(grouping: songs) { $0.discNumber ?? 1 }
        let discs = byDisc.keys.sorted()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(discs, id: \.self) { disc in
                    if discs.count > 1 {
                        Text("Disc \(disc)")
                            .pixlFont(.labelLarge, weight: .bold)
                            .foregroundStyle(theme.primary)
                            .padding(.top, 16)
                            .padding(.bottom, 8)
                            .padding(.leading, 8)
                    }
                    ForEach(byDisc[disc] ?? []) { song in
                        PlaybackRowState(songId: song.id) { isCurrent, isPlaying in
                            SongCard(song: song, isCurrent: isCurrent, isPlaying: isPlaying,
                                     onTap: { playback.play(song, in: songs) },
                                     onMore: { router.present(AppSheet.songInfo(songId: song.id)) },
                                     showsArtwork: false)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, topPadding)
            .padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .trackingHeaderScroll(scroll)
    }

    private func shuffle() {
        guard let start = songs.randomElement() else { return }
        playback.play(start, in: songs)
    }
}
