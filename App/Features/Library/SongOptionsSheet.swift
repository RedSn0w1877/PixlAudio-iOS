import PixlLibrary
import PixlModel
import SwiftUI

/// The song ⋮ sheet (Android `SongInfoBottomSheet`), opened from every song row through `AppSheet.songInfo`:
/// the 80 pt cover (26 pt corners) beside the title set large, then two pages switched by the bottom tab bar
/// (OPTIONS / INFO, a capsule holding two capsule tabs):
/// - Options: Play (big, `primaryContainer`) · favourite (heart; a rounded square when liked, `primary`) · Share;
///   Add to queue (`tertiaryContainer`) · Next (`tertiary`); Playlist (`secondaryContainer`) · Delete
///   (`errorContainer`).
/// - Info: Duration, Genre, Album, Artist, Song info (sample rate · bitrate · format), File — 8 pt tiles in a 20 pt
///   group; genre / album / artist open their screens.
/// Android-only rows (set as ringtone, send to watch) and the remaster / offline cards (stages 11 and 14) are not
/// shown.
struct SongOptionsSheet: View {
    let songId: String
    /// Stage 8: the header's edit button (Android `FilledTonalIconButton` → `EditSongSheet`), shown when set.
    var onEdit: (() -> Void)?

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    @State private var showsAddToPlaylist = false
    @State private var confirmsDelete = false

    var body: some View {
        if let song = library.song(id: songId) {
            content(song)
        } else {
            LibraryEmptyState(systemImage: "music.note", title: "Song not found", subtitle: "")
                .accessibilityIdentifier("screen.songInfo")
        }
    }

    private func content(_ song: Song) -> some View {
        VStack(spacing: 0) {
            header(song)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.top, 12)
            Spacer().frame(height: 28)
            ZStack {
                if page == 0 {
                    ScrollView { options(song).padding(.horizontal, 16).padding(.vertical, 6).padding(.bottom, 80) }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    ScrollView { info(song).padding(.horizontal, 16).padding(.bottom, 80) }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: page)
        }
        .overlay(alignment: .bottom) { tabBar }
        .sheet(isPresented: $showsAddToPlaylist) {
            AddToPlaylistSheet(songIds: [song.id])
                .pixlSheet(detents: [.large])
        }
        .confirmationDialog("Delete \(song.title) from your library?", isPresented: $confirmsDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                env.libraryEditor.removeSongs([song.id])
                dismiss()
            }
        }
        .onAppear {
            // UI tests open the Info page straight away.
            if env.launch.screen == .songOptionsInfo { page = 1 }
        }
        .accessibilityIdentifier("screen.songInfo")
    }

    private func header(_ song: Song) -> some View {
        HStack(spacing: 14) {
            ArtworkView(song: song, size: 80, cornerRadius: 26)
            Text(song.title)
                .pixlFont(.custom(size: 40, weight: .bold, lineHeight: 44))
                .foregroundStyle(theme.onSurface)
                .lineLimit(2)
                .minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            if let onEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.onSurface)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 48, maxHeight: .infinity)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: Capsule(), tint: theme.surfaceBright.opacity(GlassTint.container), interactive: true)
                .padding(.vertical, 6)
                .accessibilityLabel("Edit song metadata")
                .accessibilityIdentifier("songInfo.edit")
            }
        }
        .frame(height: 80)
    }

    // MARK: Options page

    private func options(_ song: Song) -> some View {
        let isFavorite = song.isFavorite
        let shareURL = SongFiles.shareURL(song)
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                ActionTile(title: "Play", systemImage: "play.fill", tint: theme.primaryContainer,
                           foreground: theme.onPrimaryContainer, minHeight: 80, cornerRadius: 26, titleStyle: .titleLarge) {
                    playback.play(song)
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("songInfo.play")
                HStack(spacing: 10) {
                    ActionTile(systemImage: isFavorite ? "heart.fill" : "heart",
                               accessibilityLabel: isFavorite ? "Remove from favorites" : "Add to favorites",
                               tint: isFavorite ? theme.primary : theme.surfaceVariant,
                               foreground: isFavorite ? theme.onPrimary : theme.onSurfaceVariant,
                               minHeight: 80, cornerRadius: isFavorite ? 26 : 40, iconSize: 32) {
                        env.libraryEditor.toggleFavorite(song.id)
                    }
                    .animation(.easeInOut(duration: 0.3), value: isFavorite)
                    .accessibilityIdentifier("songInfo.favorite")
                    if let shareURL {
                        ShareLink(item: shareURL) { shareLabel }
                            .pixlGlass(in: Capsule(), tint: theme.secondaryContainer.opacity(GlassTint.prominent),
                                       interactive: true)
                    } else {
                        shareLabel
                            .opacity(0.5)
                            .pixlGlass(in: Capsule(), tint: theme.secondaryContainer.opacity(GlassTint.prominent))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 10) {
                ActionTile(title: "Add to queue", systemImage: "text.line.last.and.arrowtriangle.forward",
                           tint: theme.tertiaryContainer, foreground: theme.onTertiaryContainer) {
                    playback.addToQueue([song])
                    LibraryToast.shared.show("Added to queue")
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
                ActionTile(title: "Next", systemImage: "text.line.first.and.arrowtriangle.forward",
                           tint: theme.tertiary, foreground: theme.onTertiary) {
                    playback.playNext([song])
                    LibraryToast.shared.show("Playing next")
                    dismiss()
                }
                .frame(width: nextTileWidth)
            }
            HStack(spacing: 10) {
                ActionTile(title: "Playlist", systemImage: "text.badge.plus", tint: theme.secondaryContainer,
                           foreground: theme.onSecondaryContainer) {
                    showsAddToPlaylist = true
                }
                .accessibilityIdentifier("songInfo.playlist")
                ActionTile(title: "Delete", systemImage: "trash", tint: theme.errorContainer,
                           foreground: theme.onErrorContainer) {
                    confirmsDelete = true
                }
            }
            // Stage 14: Android's Remaster Song card (BS-RoFormer stays in Experimental, as on Android).
            TaisStudioProgressCard(song: song,
                                   onInstrumentalReady: {
                                       LibraryToast.shared.show("Instrumental ready for \(song.title) — play it from the lyrics screen.")
                                   },
                                   onLyricsReady: { LibraryToast.shared.show("Lyrics synced for \(song.title).") })
            // Stage 11: streamed songs only (Android `OfflineDownloadCard`).
            OfflineDownloadCard(song: song)
        }
    }

    /// Android weights the queue row 0.6 / 0.4.
    private var nextTileWidth: CGFloat { 140 }

    private var shareLabel: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(theme.onSecondaryContainer)
            .frame(maxWidth: .infinity, minHeight: 80)
            .contentShape(.capsule)
            .accessibilityLabel("Share song file")
    }

    // MARK: Info page

    private func info(_ song: Song) -> some View {
        VStack(spacing: 4) {
            infoRow("Duration", LibraryFormat.duration(song.duration), systemImage: "clock")
            if let genre = song.genre, !genre.isEmpty {
                infoRow("Genre", genre, systemImage: "music.note") {
                    navigate(.genreDetail(genreId: genre))
                }
            }
            infoRow("Album", song.album, systemImage: "opticaldisc") {
                navigate(.albumDetail(albumId: song.albumId))
            }
            infoRow("Artist", song.displayArtist, systemImage: "person.fill") {
                navigate(.artistDetail(artistId: song.artistId))
            }
            if let format = audioFormat(song) {
                infoRow("Song info", format, systemImage: "info.circle")
            }
            infoRow(LibrarySorting.isOnline(song) ? "Provider" : "File", song.path.isEmpty ? song.contentUriString : song.path,
                    systemImage: LibrarySorting.isOnline(song) ? "cloud.fill" : "doc.fill")
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func infoRow(_ headline: String, _ supporting: String, systemImage: String,
                         action: (() -> Void)? = nil) -> some View {
        Button { action?() } label: {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).pixlFont(.bodyLarge).foregroundStyle(theme.onSurface)
                    Text(supporting).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous),
                   tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), interactive: action != nil)
    }

    /// Android `audioMetaLabel`: "44.1 kHz · 256 kbps · M4A".
    private func audioFormat(_ song: Song) -> String? {
        var parts: [String] = []
        if let rate = song.sampleRate, rate > 0 { parts.append(String(format: "%.1f kHz", Double(rate) / 1000)) }
        if let bitrate = song.bitrate, bitrate > 0 { parts.append("\(bitrate / 1000) kbps") }
        if let mime = song.mimeType, let format = mime.split(separator: "/").last, mime != "-" {
            let name = format == "mp4" ? "M4A" : (format == "mpeg" ? "MP3" : format.uppercased())
            parts.append(name)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func navigate(_ route: AppRoute) {
        dismiss()
        router.dismissSheet()
        router.push(route)
    }

    // MARK: Bottom tabs

    /// Android `PrimaryTabRow` in a `surfaceContainerHighest` capsule (5 pt inset) with `TabAnimation` tabs.
    private var tabBar: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 0) {
                tab(0, title: "OPTIONS", systemImage: "line.3.horizontal")
                tab(1, title: "INFO", systemImage: "info.circle.fill")
            }
            .padding(5)
        }
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHighest.opacity(GlassTint.container))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .sensoryFeedback(.selection, trigger: page)
    }

    private func tab(_ index: Int, title: String, systemImage: String) -> some View {
        let selected = page == index
        return Button {
            withAnimation(PixlMotion.selection) { page = index }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 18, weight: .semibold))
                Text(title).pixlFont(.labelLarge, weight: .bold)
            }
            .foregroundStyle(selected ? theme.onPrimary : theme.onSurface.opacity(0.9))
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background {
            if selected {
                Capsule().fill(theme.primary)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("songInfo.tab.\(index)")
    }
}

// MARK: - Add to playlist

/// Android `PlaylistBottomSheet`: "Select playlists" / "Add N songs to…" (`displaySmall`), the playlist search
/// field (capsule), the New pill, the playlists with check boxes, and the Save / Add pill at the bottom end. With one
/// song the playlists that already hold it start checked and unchecking removes it; with several songs it only adds.
struct AddToPlaylistSheet: View {
    let songIds: [String]

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var checked: Set<String> = []
    @State private var initial: Set<String> = []
    @State private var showsCreate = false
    @State private var newName = ""

    private var playlists: [Playlist] {
        let all = library.playlists.filter { FolderPlaylist.path(from: $0.id) == nil }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let isBatch = songIds.count > 1
        VStack(alignment: .leading, spacing: 0) {
            Text(isBatch ? "Add \(songIds.count) songs to…" : "Select playlists")
                .pixlFont(.displaySmall)
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 26)
                .padding(.vertical, 8)
                .padding(.top, 16)
            searchField
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            SegmentedGlassButton(title: "New", systemImage: "text.badge.plus", accessibilityLabel: "Create new playlist",
                                 tint: theme.tertiaryContainer.opacity(GlassTint.prominent),
                                 foreground: theme.onTertiaryContainer) {
                showsCreate = true
            }
            .padding(.top, 10)
            .padding(.horizontal, 14)
            Spacer().frame(height: 8)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(playlists) { playlist in
                        PlaylistRow(playlist: playlist,
                                    songs: playlist.songIds.prefix(4).compactMap { library.song(id: $0) },
                                    isChecked: checked.contains(playlist.id),
                                    onTap: { toggle(playlist.id) })
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 100)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: save) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 18, weight: .semibold))
                    Text(isBatch ? "Add" : "Save").pixlFont(.labelLarge)
                }
                .foregroundStyle(theme.onPrimaryContainer)
                .padding(.horizontal, 20)
                .frame(height: 56)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .pixlGlass(in: Capsule(), tint: theme.primaryContainer.opacity(GlassTint.prominent), interactive: true)
            .opacity(checked.isEmpty && initial.isEmpty ? 0.4 : 1)
            .padding(.bottom, 18)
            .padding(.trailing, 16)
            .accessibilityIdentifier("addToPlaylist.save")
        }
        .onAppear {
            guard songIds.count == 1, let id = songIds.first else { return }
            initial = Set(library.playlists.filter { $0.songIds.contains(id) }.map(\.id))
            checked = initial
        }
        .alert("New playlist", isPresented: $showsCreate) {
            TextField("My playlist", text: $newName)
            Button("Create") {
                guard !newName.isEmpty else { return }
                env.libraryEditor.createPlaylist(name: newName, songIds: songIds)
                LibraryToast.shared.show("Playlist created and songs added")
                newName = ""
                dismiss()
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .accessibilityIdentifier("sheet.addToPlaylist")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.onSurfaceVariant)
            TextField("Search for playlists…", text: $query)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurface)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.onSurfaceVariant)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
    }

    private func toggle(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    private func save() {
        guard !(checked.isEmpty && initial.isEmpty) else { return }
        let editor = env.libraryEditor
        for id in checked where !initial.contains(id) { editor.addSongs(songIds, toPlaylist: id) }
        if songIds.count == 1, let songId = songIds.first {
            for id in initial where !checked.contains(id) { editor.removeSong(songId, fromPlaylist: id) }
        }
        LibraryToast.shared.show(songIds.count > 1 ? "Songs added to playlists" : "Saved")
        dismiss()
    }
}
