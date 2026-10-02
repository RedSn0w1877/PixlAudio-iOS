import PixlLibrary
import PixlModel
import SwiftUI

/// Folder browser pushed at a path (Android's `FolderExplorerScreen` is retired there; its job lives in the Library's
/// Folders tab). Same rows as the Folders tab — subfolders, then the folder's songs — under PixlAudio's detail top bar.
struct FolderExplorerView: View {
    let path: String?

    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    var body: some View {
        let tree = LibraryModel.folderTree(library.songs)
        let folder = path.flatMap { LibraryModel.folder(at: $0, in: tree) }
        let subfolders = folder?.subFolders ?? tree
        let songs = LibraryModel.folderSongs(folder?.songs ?? [], sort: .folderNameAZ)
        VStack(spacing: 0) {
            DetailTopBar(title: folder?.name ?? "Folders", subtitle: folder.map { LibraryFormat.songCount($0.totalSongCount) },
                         onBack: { router.pop() })
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(subfolders, id: \.path) { sub in
                        FolderRow(folder: sub, asPlaylist: false) { router.push(.folderExplorer(path: sub.path)) }
                    }
                    ForEach(songs) { song in
                        PlaybackRowState(songId: song.id) { isCurrent, isPlaying in
                            SongCard(song: song, isCurrent: isCurrent, isPlaying: isPlaying,
                                     onTap: { playback.play(song, in: songs) },
                                     onMore: { router.present(AppSheet.songInfo(songId: song.id)) })
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, libraryListExtraBottomGap)
            }
        }
        .background(theme.surface.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("screen.folderExplorer")
    }
}
