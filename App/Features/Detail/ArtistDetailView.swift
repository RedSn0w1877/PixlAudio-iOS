import PhotosUI
import PixlLibrary
import PixlModel
import SwiftUI

/// Artist detail (Android `ArtistDetailScreen`): themed with the artist image's scheme (else the first album's);
/// the collapsing artwork header (name, "N Songs", back, edit-image circle, shuffle) over:
/// - "Most played" (`titleLarge` bold + play circle) with the artist's top five songs by play count;
/// - one collapsible section per album, newest year first (header: 52 pt cover, title, "year • N Songs", play
///   circle on `tertiaryContainer`, chevron) whose songs sit in a 50 % `surfaceContainerLow` group as rows without
///   artwork (16 pt outer / 4 pt inner corners).
/// "More from this artist" (YouTube Music) arrives with stage 11.
struct ArtistDetailView: View {
    let artistId: Int64

    @Environment(LibraryStore.self) private var library

    var body: some View {
        let artist = library.artist(id: artistId)
        let firstArt = library.firstArtwork(ofArtist: artistId)
        ArtworkThemed(artUri: artist?.effectiveImageUrl ?? firstArt) {
            ArtistDetailContent(artistId: artistId)
        }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("screen.artistDetail")
    }
}

/// An album of the artist (Android `ArtistAlbumSection`).
nonisolated struct ArtistAlbumSection: Identifiable, Hashable, Sendable {
    let albumId: Int64
    let title: String
    let year: Int?
    let albumArtUriString: String?
    let songs: [Song]

    var id: String { "artist_album_\(albumId)_\(title)" }
}

nonisolated enum ArtistDetailGrouping {
    /// Android `songDisplayComparator`: disc (missing = 1), track (0 = last), lower-cased title.
    static func displayOrder(_ songs: [Song]) -> [Song] { LibrarySorting.albumPlaybackOrder(songs) }

    /// Android `buildAlbumSections`: songs grouped by album; albums with a year newest first (then title), then the
    /// rest by title.
    static func albumSections(_ songs: [Song]) -> [ArtistAlbumSection] {
        var order: [String] = []
        var groups: [String: [Song]] = [:]
        for song in songs {
            let key = "\(song.albumId)|\(song.album)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(song)
        }
        let sections = order.compactMap { key -> ArtistAlbumSection? in
            guard let albumSongs = groups[key], let first = albumSongs.first else { return nil }
            let year = albumSongs.map(\.year).filter { $0 > 0 }.max()
            return ArtistAlbumSection(albumId: first.albumId,
                                      title: first.album.trimmingCharacters(in: .whitespaces).isEmpty ? "Unknown Album" : first.album,
                                      year: year, albumArtUriString: albumSongs.first { $0.albumArtUriString != nil }?.albumArtUriString,
                                      songs: displayOrder(albumSongs))
        }
        let withYear = sections.filter { $0.year != nil }.sorted { a, b in
            if a.year != b.year { return (a.year ?? .min) > (b.year ?? .min) }
            return a.title.lowercased() < b.title.lowercased()
        }
        let withoutYear = sections.filter { $0.year == nil }.sorted { $0.title.lowercased() < $1.title.lowercased() }
        return withYear + withoutYear
    }

    /// Android `loadTopSongs`: the five most played of the artist's songs (play count, descending).
    static func topSongs(_ songs: [Song], engagements: [EngagementEntry], limit: Int = 5) -> [Song] {
        let counts = Dictionary(engagements.map { ($0.songId, $0.stats.playCount) }, uniquingKeysWith: { first, _ in first })
        return songs.filter { (counts[$0.id] ?? 0) > 0 }
            .enumerated()
            .sorted { a, b in
                let ca = counts[a.element.id] ?? 0, cb = counts[b.element.id] ?? 0
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            .prefix(limit)
            .map(\.element)
    }
}

private struct ArtistDetailContent: View {
    let artistId: Int64

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var scroll = HeaderScrollState()
    @State private var collapsed: Set<String> = []
    /// The album sections and "Most played", derived in `body` once per (library revision, play counts): the push's
    /// first frame has them. Play counts come from a long-lived cache (`PlayCountStore`), so "Most played" is there
    /// from the first frame on later visits instead of being inserted above the albums mid-push.
    @State private var memo = ViewMemo<ArtistContentKey, ArtistContent>()
    /// The edit-image circle (Android: the pencil opens the photo picker; "clear custom image" once one is set).
    @State private var showsPhotoPicker = false
    @State private var showsImageOptions = false
    @State private var photoItem: PhotosPickerItem?

    private var content: ArtistContent {
        let counts = env.playCounts
        return memo.value(for: ArtistContentKey(revision: library.revision, playCounts: counts.version)) {
            let sections = ArtistDetailGrouping.albumSections(library.songs(ofArtist: artistId))
            let topSongs = ArtistDetailGrouping.topSongs(sections.flatMap(\.songs), engagements: counts.entries ?? [])
            return ArtistContent(sections: sections, topSongs: topSongs)
        }
    }

    private var sections: [ArtistAlbumSection] { content.sections }
    private var topSongs: [Song] { content.topSongs }

    var body: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let metrics = CollapseMetrics(maxHeight: 300, minHeight: 64 + safeTop)
            ZStack(alignment: .top) {
                theme.surface.ignoresSafeArea()
                if let artist = library.artist(id: artistId) {
                    let allSongs = sections.flatMap(\.songs)
                    list(topPadding: metrics.maxHeight - safeTop + 8)
                    CollapsingArtworkHeader(title: artist.name, subtitle: LibraryFormat.songCount(allSongs.count),
                                            artwork: artist.effectiveImageUrl.flatMap { ArtworkSource(uriString: $0) },
                                            scroll: scroll, metrics: metrics, safeTop: safeTop, collapsedTitleEnd: 88,
                                            placeholderSymbol: "music.mic",
                                            onBack: { router.pop() },
                                            onShuffle: { playback.playShuffled(allSongs) }) {
                        GlassCircleButton(systemImage: "pencil", accessibilityLabel: "Edit artist image",
                                          tint: theme.surfaceContainerLow.opacity(GlassTint.container),
                                          foreground: theme.onSurface) {
                            if (artist.customImageUri ?? "").isEmpty { showsPhotoPicker = true } else { showsImageOptions = true }
                        }
                        .accessibilityIdentifier("artist.editImage")
                    }
                    .ignoresSafeArea(edges: .top)
                } else {
                    LibraryEmptyState(systemImage: "music.mic", title: "Artist not found", subtitle: "")
                }
            }
        }
        .task(id: env.home.history.revision) {
            await env.playCounts.refresh(editor: env.libraryEditor, revision: env.home.history.revision)
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await setCustomImage(from: item) }
        }
        .confirmationDialog("Artist image", isPresented: $showsImageOptions, titleVisibility: .visible) {
            Button("Choose a new image") { showsPhotoPicker = true }
            Button("Remove custom image", role: .destructive) { setCustomImageURI(nil) }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Android `setCustomArtistImage`: the picked photo is copied into the app's storage (the picker's item does not
    /// outlive it) and becomes the artist's `customImageUri`, which wins over the Deezer picture.
    private func setCustomImage(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let isUITest = env.launch.isUITest
        let url = await Task.detached(priority: .userInitiated) { ArtistImageStore.save(data, temporary: isUITest) }.value
        guard let url else { return }
        setCustomImageURI(url.absoluteString)
    }

    private func setCustomImageURI(_ uri: String?) {
        guard var artist = library.artist(id: artistId) else { return }
        let previous = artist.customImageUri
        artist.customImageUri = uri
        library.updateArtists([artist])
        library.writeSnapshotCache()
        if let persistence = env.persistence {
            let saved = artist
            Task.detached(priority: .utility) { try? await persistence.setArtistImages([saved]) }
        }
        // The replaced copy is ours (Application Support/ArtistImages): remove it.
        if let previous, previous != uri { ArtistImageStore.removeIfOwned(previous) }
    }

    private func list(topPadding: CGFloat) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !topSongs.isEmpty {
                    sectionTitle("Most played") {
                        if let first = topSongs.first { playback.play(first, in: topSongs) }
                    }
                    ForEach(Array(topSongs.enumerated()), id: \.offset) { index, song in
                        groupedRow(song, index: index, count: topSongs.count, context: topSongs)
                    }
                    Spacer().frame(height: 24)
                }
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    let expanded = !collapsed.contains(section.id)
                    AlbumSectionHeader(section: section, isExpanded: expanded,
                                       onToggle: {
                                           withAnimation(.easeInOut(duration: 0.26)) {
                                               if expanded { collapsed.insert(section.id) } else { collapsed.remove(section.id) }
                                           }
                                       },
                                       onPlay: { if let first = section.songs.first { playback.play(first, in: section.songs) } })
                    if expanded {
                        theme.surfaceContainerLow.opacity(0.5).frame(height: 10)
                        ForEach(Array(section.songs.enumerated()), id: \.element.id) { songIndex, song in
                            groupedRow(song, index: songIndex, count: section.songs.count, context: section.songs)
                        }
                    }
                    Spacer().frame(height: index == sections.count - 1 ? 24 : 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, topPadding)
            // Android pads `MiniPlayerHeight + 16` while a song is loaded: the mini player's room now comes from the
            // route's safe area (`BottomBarsClearance`), so only the 16 pt (and a little air) stay here.
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .trackingHeaderScroll(scroll)
    }

    /// Android `ArtistSectionTitle`: `titleLarge` bold and a `primaryContainer` play circle.
    private func sectionTitle(_ title: String, onPlay: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .pixlFont(.titleLarge, weight: .bold)
                .foregroundStyle(theme.onSurface)
            Spacer()
            GlassCircleButton(systemImage: "play.fill", accessibilityLabel: "Play \(title)",
                              tint: theme.primaryContainer.opacity(GlassTint.prominent),
                              foreground: theme.onPrimaryContainer, action: onPlay)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    /// Android `ArtistAlbumSectionSongItem`: a row in the 50 % `surfaceContainerLow` group (8 pt inset, 2 pt between
    /// rows, the last one closing the group with 24 pt corners).
    private func groupedRow(_ song: Song, index: Int, count: Int, context: [Song]) -> some View {
        let isLast = index == count - 1
        return VStack(spacing: 0) {
            if index > 0 { Spacer().frame(height: 2) }
            PlaybackRowState(songId: song.id) { isCurrent, isPlaying in
                SongCard(song: song, isCurrent: isCurrent, isPlaying: isPlaying,
                         onTap: { playback.play(song, in: context) },
                         onMore: { router.present(AppSheet.songInfo(songId: song.id)) },
                         showsArtwork: false, corners: .grouped(index: index, count: count))
            }
            if isLast { Spacer().frame(height: 8) }
        }
        .padding(.horizontal, 8)
        .background(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: isLast ? 24 : 0,
                                           bottomTrailingRadius: isLast ? 24 : 0, topTrailingRadius: 0,
                                           style: .continuous)
            .fill(theme.surfaceContainerLow.opacity(0.5)))
    }
}

private struct ArtistContentKey: Equatable {
    let revision: Int
    let playCounts: Int
}

private struct ArtistContent {
    let sections: [ArtistAlbumSection]
    let topSongs: [Song]
}

/// Android `CollapsibleAlbumSectionHeader`.
private struct AlbumSectionHeader: View {
    let section: ArtistAlbumSection
    let isExpanded: Bool
    let onToggle: () -> Void
    let onPlay: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: isExpanded ? 0 : 24,
                                           bottomTrailingRadius: isExpanded ? 0 : 24, topTrailingRadius: 24,
                                           style: .continuous)
        HStack(spacing: 12) {
            // The art and the two lines are the section's expand / collapse button for VoiceOver (with its state);
            // Play stays its own button and the chevron is decoration.
            HStack(spacing: 12) {
                ArtworkView(source: ArtworkSource(uriString: section.albumArtUriString), size: 52, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .pixlFont(.titleMedium, weight: .semibold)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(subtitle)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAction(.default, onToggle)
            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.onTertiaryContainer)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(theme.tertiaryContainer))
                    .contentShape(.circle)
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel("Play \(section.title)")
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .accessibilityHidden(true)
        }
        .padding(14)
        .contentShape(shape)
        .onTapGesture(perform: onToggle)
        .pixlGlass(in: shape, tint: theme.surfaceContainerLow.opacity(GlassTint.surface), interactive: true)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let year = section.year, year > 0 { parts.append("\(year)") }
        parts.append(LibraryFormat.songCount(section.songs.count))
        return parts.joined(separator: " • ")
    }
}

/// Custom artist images (Android writes `artist_art_<id>.jpg` to its files dir): copies in Application Support.
nonisolated enum ArtistImageStore {
    static func directory(temporary: Bool) -> URL? {
        let base = temporary ? FileManager.default.temporaryDirectory
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("ArtistImages", isDirectory: true)
    }

    static func save(_ data: Data, temporary: Bool) -> URL? {
        guard let directory = directory(temporary: temporary) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".img")
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }

    /// Deletes a custom image this store wrote (never a file elsewhere, such as one restored from a backup).
    static func removeIfOwned(_ uri: String) {
        guard let url = URL(string: uri), url.isFileURL,
              url.deletingLastPathComponent().lastPathComponent == "ArtistImages" else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
