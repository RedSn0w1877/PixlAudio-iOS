import PhotosUI
import PixlFoundation
import PixlLibrary
import PixlModel
import SwiftUI

/// Artist detail, new UI (2026-11-16, mockup `iOSArtist`; owner decisions over the mockup): themed with the artist
/// image's scheme (else the first album's).
/// - The artist image fills the top edge to edge, sharp at the top and progressively blurred into the page
///   (`ProgressiveBlurHero`, `HeroGradients.header`; the first song's cover when the artist has no image). Over its
///   blurred part: the name very large (`FitWidthTitle(.artistHero)`: SF Pro black at the widest width that fits two
///   lines, morphing narrower and lighter as it scrolls under the bar, where `CollapsedBarTitle` takes over), the song
///   and album counts, and Play (prominent glass capsule) + Shuffle (glass circle). No listener counts or Follow: the
///   app has neither.
/// - A pinned bar: back, the collapsed name, and the ⋯ menu (artist image: choose / remove — Android's pencil; Block /
///   Unblock).
/// - "Most played" (play circle) with the artist's top five songs by play count, their counts as the second line;
///   "Albums" as a shelf of covers (tap: the album; context menu: play); "All songs": one collapsible section per
///   album, newest year first (header: 52 pt cover, title, "year • N Songs", play circle on `tertiaryContainer`,
///   chevron) whose songs sit in a 50 % `surfaceContainerLow` group as rows without artwork.
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

    /// "12 plays" for each of `songs` that has plays (the first engagement per song counts, as in `topSongs`).
    static func playLabels(for songs: [Song], engagements: [EngagementEntry]) -> [String: String] {
        let wanted = Set(songs.map(\.id))
        var seen = Set<String>()
        var labels: [String: String] = [:]
        for entry in engagements where wanted.contains(entry.songId) && seen.insert(entry.songId).inserted {
            if let label = HeroHeader.plays(entry.stats.playCount) { labels[entry.songId] = label }
        }
        return labels
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
    @Environment(BlockedArtistsStore.self) private var blocked
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var collapsed: Set<String> = []
    /// The hero name's collapse stop: only the name and the bar title read it, so scrolling never re-renders the page.
    @State private var titleState = CollapsingTitleState()
    /// The title block's and the name's heights, measured once per text / size (they don't change while scrolling):
    /// they place the collapse window.
    @State private var overlayHeight: CGFloat = 0
    @State private var titleHeight: CGFloat = 0
    /// The album sections, "Most played" and its play counts, derived in `body` once per (library revision, play
    /// counts): the push's first frame has them. Play counts come from a long-lived cache (`PlayCountStore`), so "Most
    /// played" is there from the first frame on later visits instead of being inserted above the albums mid-push.
    @State private var memo = ViewMemo<ArtistContentKey, ArtistContent>()
    /// The ⋯ menu's "Choose artist image" (Android: the pencil opens the photo picker).
    @State private var showsPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?

    private var content: ArtistContent {
        let counts = env.playCounts
        return memo.value(for: ArtistContentKey(revision: library.revision, playCounts: counts.version)) {
            let sections = ArtistDetailGrouping.albumSections(library.songs(ofArtist: artistId))
            let allSongs = sections.flatMap(\.songs)
            let engagements = counts.entries ?? []
            let topSongs = ArtistDetailGrouping.topSongs(allSongs, engagements: engagements)
            return ArtistContent(sections: sections, allSongs: allSongs, topSongs: topSongs,
                                 plays: ArtistDetailGrouping.playLabels(for: topSongs, engagements: engagements),
                                 fallbackArt: library.firstArtwork(ofArtist: artistId))
        }
    }

    private var sections: [ArtistAlbumSection] { content.sections }
    private var topSongs: [Song] { content.topSongs }

    var body: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let width = proxy.size.width
            let viewport = proxy.size.height + safeTop + proxy.safeAreaInsets.bottom
            let heroHeight = CGFloat(HeroHeader.height(width: Double(width), viewportHeight: Double(viewport),
                                                       aspect: Double(Tokens.PageHero.aspect)))
            ZStack(alignment: .top) {
                theme.surface.ignoresSafeArea()
                if let artist = library.artist(id: artistId) {
                    page(artist, width: width, heroHeight: heroHeight, safeTop: safeTop)
                    HeroTopBar(title: artist.name, titleState: titleState, safeTop: safeTop,
                               onBack: { router.pop() }) {
                        moreMenu(artist)
                    }
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
    }

    // MARK: Page

    private func page(_ artist: Artist, width: CGFloat, heroHeight: CGFloat, safeTop: CGFloat) -> some View {
        let titleTop = HeroHeader.overlayTop(heroHeight: Double(heroHeight), overlayHeight: Double(overlayHeight))
        let window = HeroHeader.titleCollapse(titleTop: titleTop, titleHeight: Double(titleHeight),
                                              barBottom: Double(safeTop + Tokens.PageHero.barHeight))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                hero(artist, width: width, height: heroHeight, safeTop: safeTop)
                if !topSongs.isEmpty {
                    sectionTitle("Most played") {
                        if let first = topSongs.first { blocked.playTapped(first, in: topSongs, using: playback) }
                    }
                    ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, song in
                        topSongRow(song, index: index)
                    }
                }
                if !sections.isEmpty {
                    sectionTitle("Albums")
                    albumShelf
                    sectionTitle("All songs")
                    albumSectionsList
                }
            }
            // The mini player's and the bar's room comes from the route's safe area (`BottomBarsClearance`).
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .trackingTitleCollapse(titleState, start: CGFloat(window.start), distance: CGFloat(window.distance))
    }

    /// The artist image filling the top edge to edge, sharp at the top and progressively blurred into the page under
    /// the title block (`ProgressiveBlurHero`, one pre-blurred layer). It stretches from its bottom edge when the page
    /// is pulled down and trails the page a little as it scrolls away — both in `visualEffect` (render phase).
    private func hero(_ artist: Artist, width: CGFloat, height: CGFloat, safeTop: CGFloat) -> some View {
        let source = ArtworkSource(uriString: artist.effectiveImageUrl ?? content.fallbackArt)
        return ZStack(alignment: .bottomLeading) {
            ProgressiveBlurHero(source: source, gradients: .header, veil: theme.surface,
                                topScrimHeight: safeTop + Tokens.PageHero.barHeight + 16,
                                size: CGSize(width: width, height: height)) {
                heroArt(source, width: width, height: height)
            }
            .frame(width: width, height: height)
            .visualEffect { content, proxy in
                let effect = HeroHeader.scrollEffect(minY: Double(proxy.frame(in: .scrollView).minY),
                                                     height: Double(proxy.size.height))
                return content
                    .scaleEffect(CGFloat(effect.scale), anchor: .bottom)
                    .offset(y: CGFloat(effect.offset))
            }
            heroOverlay(artist)
                .padding(.horizontal, Tokens.PageHero.sidePadding)
                .padding(.bottom, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { overlayHeight = $0 }
        }
    }

    @ViewBuilder
    private func heroArt(_ source: ArtworkSource?, width: CGFloat, height: CGFloat) -> some View {
        if let source {
            // A square at the hero's larger side, centre-cropped to the hero (decoded once at that size).
            ArtworkView(source: source, size: max(width, height), cornerRadius: 0)
                .frame(width: width, height: height)
                .clipped()
        } else {
            Image(systemName: "music.mic")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.2))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surfaceVariant)
                .accessibilityHidden(true)
        }
    }

    /// Over the blurred part (mockup `iOSArtist`): the name very large (SF Pro black at the widest width that fits two
    /// lines, morphing narrower and lighter as it scrolls under the bar), the song and album counts (the app has no
    /// listener counts), then Play and Shuffle.
    private func heroOverlay(_ artist: Artist) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FitWidthTitle(text: artist.name, face: .artistHero, narrowest: .compressed, lines: 2,
                          collapse: titleState)
                .foregroundStyle(theme.onSurface)
                .shadow(color: theme.surface.opacity(0.35), radius: 7, y: 1)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { titleHeight = $0 }
            Text(HeroHeader.summary(songs: content.allSongs.count, albums: sections.count))
                .pixlFont(.custom(size: 15, weight: .light))
                .foregroundStyle(theme.onSurface.opacity(0.8))
                .lineLimit(1)
                .padding(.top, 2)
            heroActions
                .padding(.top, 12)
        }
    }

    /// Play (the one prominent glass capsule) and Shuffle (a clear glass circle), sharing one glass container.
    private var heroActions: some View {
        let allSongs = content.allSongs
        let h = Tokens.PageHero.actionHeight
        return GlassEffectContainer(spacing: Tokens.PageHero.actionSpacing / 2) {
            HStack(spacing: Tokens.PageHero.actionSpacing) {
                Button {
                    guard let first = allSongs.first else { return }
                    blocked.playTapped(first, in: allSongs, using: playback)
                    if playback.isShuffleEnabled { playback.setShuffleEnabled(false) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .accessibilityHidden(true)
                        Text("Play")
                            .pixlFont(.custom(size: 17, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(theme.onPrimary)
                    .padding(.horizontal, 26)
                    .frame(minWidth: 112, minHeight: h)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: Capsule(), tint: theme.primary.opacity(GlassTint.prominent), interactive: true)
                .disabled(allSongs.isEmpty)
                .accessibilityLabel("Play")
                .accessibilityIdentifier("artist.play")
                GlassCircleButton(systemImage: "shuffle", accessibilityLabel: "Shuffle play", size: h,
                                  iconSize: 20, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface),
                                  foreground: theme.onSurface) {
                    playback.playShuffled(allSongs)
                }
                .disabled(allSongs.isEmpty)
                .accessibilityIdentifier("detail.shuffle")
                Spacer(minLength: 0)
            }
        }
    }

    /// The ⋯ menu (system liquid menu): the artist image (Android's pencil: pick a photo; remove a custom one) and
    /// Block / Unblock.
    @ViewBuilder
    private func moreMenu(_ artist: Artist) -> some View {
        let isBlocked = blocked.isBlocked(artistId: artist.id, name: artist.name)
        let hasCustomImage = !(artist.customImageUri ?? "").isEmpty
        let imageTitle: LocalizedStringKey = hasCustomImage ? "Choose a new image" : "Choose artist image"
        GlassCircleMenu(systemImage: "ellipsis", accessibilityLabel: "More options") {
            Button(imageTitle, systemImage: "photo") {
                showsPhotoPicker = true
            }
            .accessibilityIdentifier("artist.editImage")
            if hasCustomImage {
                Button("Remove custom image", systemImage: "trash", role: .destructive) { setCustomImageURI(nil) }
            }
            Divider()
            if isBlocked {
                Button("Unblock artist", systemImage: "checkmark.circle") {
                    blocked.unblock(artistId: artist.id, name: artist.name)
                    LibraryToast.shared.show("\(artist.name) unblocked")
                }
            } else {
                Button("Block artist", systemImage: "nosign", role: .destructive) {
                    blocked.block(artistId: artist.id, name: artist.name)
                    LibraryToast.shared.show("\(artist.name) blocked. Their songs won't play by themselves.")
                }
            }
        }
        .accessibilityIdentifier("artist.more")
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

    // MARK: Sections

    /// A section title (mockup: 20 pt bold), with Android's `primaryContainer` play circle when it plays something.
    private func sectionTitle(_ title: String, onPlay: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
                .pixlFont(.custom(size: 20, weight: .medium))
                .foregroundStyle(theme.onSurface)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let onPlay {
                GlassCircleButton(systemImage: "play.fill", accessibilityLabel: "Play \(title)",
                                  tint: theme.primaryContainer.opacity(GlassTint.prominent),
                                  foreground: theme.onPrimaryContainer, action: onPlay)
            }
        }
        .frame(minHeight: 40)
        .padding(.leading, Tokens.PageHero.sidePadding + 6)
        .padding(.trailing, Tokens.PageHero.sidePadding + 4)
        .padding(.top, Tokens.PageHero.sectionSpacing)
        .padding(.bottom, 10)
    }

    /// "Most played" rows: the grouped song cards with their art; the second line is the play count (the artist is
    /// the page's).
    private func topSongRow(_ song: Song, index: Int) -> some View {
        PlaybackRowState(songId: song.id) { isCurrent, isPlaying in
            SongCard(song: song, isCurrent: isCurrent, isPlaying: isPlaying,
                     onTap: { blocked.playTapped(song, in: topSongs, using: playback) },
                     onMore: { router.present(AppSheet.songInfo(songId: song.id)) },
                     corners: .grouped(index: index, count: topSongs.count),
                     subtitle: content.plays[song.id])
                .swipeToQueue(song: song)
        }
        .padding(.top, index > 0 ? 2 : 0)
        .padding(.horizontal, Tokens.PageHero.sidePadding)
    }

    /// The artist's albums as a horizontal shelf of covers (mockup `iOSArtist`): tap opens the album, the context menu
    /// plays it.
    private var albumShelf: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Tokens.PageHero.albumSpacing) {
                ForEach(sections) { section in
                    ArtistAlbumTile(section: section,
                                    onOpen: { openAlbum(section) },
                                    onPlay: { playSection(section) })
                }
            }
            .padding(.horizontal, Tokens.PageHero.sidePadding)
        }
        .scrollIndicators(.hidden)
    }

    /// Every song, one collapsible section per album, newest year first (the page's original list).
    private var albumSectionsList: some View {
        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
            let expanded = !collapsed.contains(section.id)
            VStack(spacing: 0) {
                AlbumSectionHeader(section: section, isExpanded: expanded,
                                   onToggle: {
                                       withAnimation(.easeInOut(duration: 0.26)) {
                                           if expanded { collapsed.insert(section.id) } else { collapsed.remove(section.id) }
                                       }
                                   },
                                   onPlay: { playSection(section) })
                if expanded {
                    theme.surfaceContainerLow.opacity(0.5).frame(height: 10)
                    ForEach(Array(section.songs.enumerated()), id: \.element.id) { songIndex, song in
                        groupedRow(song, index: songIndex, count: section.songs.count, context: section.songs)
                    }
                }
            }
            .padding(.horizontal, Tokens.PageHero.sidePadding)
            .padding(.bottom, index == sections.count - 1 ? 0 : 16)
        }
    }

    private func openAlbum(_ section: ArtistAlbumSection) {
        if library.album(id: section.albumId) != nil {
            router.push(.albumDetail(albumId: section.albumId))
        } else {
            playSection(section)
        }
    }

    private func playSection(_ section: ArtistAlbumSection) {
        if let first = section.songs.first { playback.play(first, in: section.songs) }
    }

    /// Android `ArtistAlbumSectionSongItem`: a row in the 50 % `surfaceContainerLow` group (8 pt inset, 2 pt between
    /// rows, the last one closing the group with 24 pt corners).
    private func groupedRow(_ song: Song, index: Int, count: Int, context: [Song]) -> some View {
        let isLast = index == count - 1
        return VStack(spacing: 0) {
            if index > 0 { Spacer().frame(height: 2) }
            PlaybackRowState(songId: song.id) { isCurrent, isPlaying in
                SongCard(song: song, isCurrent: isCurrent, isPlaying: isPlaying,
                         onTap: { blocked.playTapped(song, in: context, using: playback) },
                         onMore: { router.present(AppSheet.songInfo(songId: song.id)) },
                         showsArtwork: false, corners: .grouped(index: index, count: count))
                    .swipeToQueue(song: song)
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
    let allSongs: [Song]
    let topSongs: [Song]
    /// "12 plays" per top song id.
    let plays: [String: String]
    /// The first song's cover: the hero when the artist has no image.
    let fallbackArt: String?
}

/// An album of the artist on the shelf: a 132 pt cover (18 pt corners), the title and the year (or song count).
private struct ArtistAlbumTile: View {
    let section: ArtistAlbumSection
    let onOpen: () -> Void
    let onPlay: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let size = Tokens.PageHero.albumTile
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 7) {
                ArtworkView(source: ArtworkSource(uriString: section.albumArtUriString), size: size,
                            cornerRadius: Tokens.PageHero.albumCorner)
                VStack(alignment: .leading, spacing: 0) {
                    Text(section.title)
                        .pixlFont(.custom(size: 15, weight: .regular))
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(subtitle)
                        .pixlFont(.custom(size: 13, weight: .light))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            .frame(width: size, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
        .contextMenu {
            Button("Play", systemImage: "play.fill", action: onPlay)
            Button("Go to album", systemImage: "square.stack", action: onOpen)
        }
        .accessibilityIdentifier("artist.album.\(section.albumId)")
    }

    private var subtitle: String {
        if let year = section.year, year > 0 { return "\(year)" }
        return LibraryFormat.songCount(section.songs.count)
    }
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
