import PixlNet
import SwiftUI

/// Spotify catalogue browse (Android `presentation/spotify/browse/SpotifyBrowseScreen`): the search field, then by
/// level — home (your top artists as bubbles, your top songs with "Add all"), search results (artists, albums, songs),
/// an artist (header, popular songs, albums) or an album (header, "Add whole album", its tracks). Drill-down is state
/// (`SpotifyBrowseModel`); the back button steps out of it first. Rows are glass cards in Android's 16 pt shape, the
/// field a glass capsule; the row's add button is a plain icon on the glass (no glass on glass).
///
/// Difference from Android: the system edge-swipe pops the whole screen (iOS has no BackHandler to intercept it);
/// the back button steps out of the drill-down first, as Android's does.
struct SpotifyBrowseView: View {
    let query: String

    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @State private var model = SpotifyBrowseModel()
    @State private var toast: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SpotifyScaffold(title: model.title, screenID: "spotifyBrowse", verticalPadding: 8, spacing: 10,
                        onBack: { if !model.goBack() { dismiss() } },
                        header: AnyView(header)) {
            if env.spotify.isLoggedIn {
                levelContent
            }
        }
        .settingsToast($toast)
        .onChange(of: model.message) { _, message in
            guard let message else { return }
            toast = message
            model.message = nil
        }
        .task {
            model.attach(env.spotify)
            await model.start(initialQuery: query, demoScreen: env.launch.isUITest ? env.launch.screen : nil)
        }
    }

    // MARK: Header: loading line, sign-in notice or the search field

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                SpotifyIndeterminateProgress()
            }
            if !env.spotify.isLoggedIn {
                SpotifyBrowseEmptyMessage(text: "Connect Spotify first to browse the catalog.")
            } else {
                SpotifyBrowseSearchField(text: Binding(get: { model.query }, set: { model.onQueryChange($0) }))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: Levels

    @ViewBuilder
    private var levelContent: some View {
        switch model.level {
        case .home: homeContent
        case .results: resultsContent
        case .artist(let artist): artistContent(artist)
        case .album(let album): albumContent(album)
        }
    }

    @ViewBuilder
    private var homeContent: some View {
        if model.topReadDenied {
            SpotifyBrowseInfoCard(text: "Your most-played data isn't available yet. Disconnect and reconnect Spotify once — the permission for it was added after you signed in.")
        }
        if !model.topArtists.isEmpty {
            SpotifyBrowseSectionHeader(title: "Your top artists")
            artistBubbles(model.topArtists)
        }
        if !model.tracks.isEmpty {
            SpotifyBrowseSectionHeader(title: "Your top songs", action: "Add all") {
                model.addToLibrary(model.tracks, label: "your top songs")
            }
            ForEach(model.tracks, id: \.self) { track in
                trackRow(track)
            }
        }
        if model.topArtists.isEmpty && model.tracks.isEmpty && !model.isLoading {
            SpotifyBrowseEmptyMessage(text: "Search above to find artists, albums and songs.")
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        if !model.artists.isEmpty {
            SpotifyBrowseSectionHeader(title: "Artists")
            artistBubbles(model.artists)
        }
        if !model.albums.isEmpty {
            SpotifyBrowseSectionHeader(title: "Albums")
            ForEach(model.albums, id: \.self) { album in
                SpotifyAlbumRow(album: album) { model.openAlbum(album) }
            }
        }
        if !model.tracks.isEmpty {
            SpotifyBrowseSectionHeader(title: "Songs")
            ForEach(model.tracks, id: \.self) { track in
                trackRow(track)
            }
        }
    }

    @ViewBuilder
    private func artistContent(_ artist: SpotifyArtistFull) -> some View {
        SpotifyArtistHeader(artist: artist)
        if !model.tracks.isEmpty {
            SpotifyBrowseSectionHeader(title: "Popular", action: "Add all") {
                model.addToLibrary(model.tracks, label: "\(artist.name ?? "")'s top songs")
            }
            ForEach(model.tracks, id: \.self) { track in
                trackRow(track)
            }
        }
        if !model.artistAlbums.isEmpty {
            SpotifyBrowseSectionHeader(title: "Albums")
            ForEach(model.artistAlbums, id: \.self) { album in
                SpotifyAlbumRow(album: album) { model.openAlbum(album) }
            }
        }
    }

    @ViewBuilder
    private func albumContent(_ album: SpotifyAlbumFull) -> some View {
        SpotifyAlbumHeader(album: album)
        Button {
            model.addToLibrary(model.tracks, label: album.name ?? "")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "text.badge.plus").font(.system(size: 16, weight: .semibold))
                Text("Add whole album to library").pixlFont(.labelLarge)
            }
            .foregroundStyle(model.tracks.isEmpty ? theme.onSurface.opacity(0.38) : .black)
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(model.tracks.isEmpty)
        .pixlGlass(in: Capsule(), tint: model.tracks.isEmpty ? nil : SpotifyBrand.green.opacity(GlassTint.prominent),
                   interactive: !model.tracks.isEmpty)
        .accessibilityIdentifier("spotifyBrowse.addAlbum")
        ForEach(model.tracks, id: \.self) { track in
            trackRow(track)
        }
    }

    // MARK: Pieces

    private func trackRow(_ track: SpotifyTrack) -> some View {
        SpotifyTrackRow(track: track) { model.addToLibrary([track], label: track.name ?? "") }
    }

    private func artistBubbles(_ artists: [SpotifyArtistFull]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(artists, id: \.self) { artist in
                    SpotifyArtistBubble(artist: artist) { model.openArtist(artist) }
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

// MARK: - Pieces (Android `SpotifyBrowseScreen` private composables)

/// Android `OutlinedTextField` with a search icon, as a glass capsule.
struct SpotifyBrowseSearchField: View {
    @Binding var text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant)
                .accessibilityHidden(true)
            TextField("", text: $text, prompt: Text("Search songs, artists, albums").foregroundStyle(theme.onSurfaceVariant))
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurface)
                .tint(theme.primary)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("spotifyBrowse.field")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
    }
}

/// Android `SectionHeader` / `SectionHeaderWithAction`: `titleMedium` bold, 6 pt above; the action in brand green.
struct SpotifyBrowseSectionHeader: View {
    let title: String
    var action: String?
    var onAction: (() -> Void)?
    @Environment(\.appTheme) private var theme

    init(title: String, action: String? = nil, onAction: (() -> Void)? = nil) {
        self.title = title
        self.action = action
        self.onAction = onAction
    }

    var body: some View {
        HStack {
            Text(title)
                .pixlFont(.titleMedium, weight: .bold)
                .foregroundStyle(theme.onSurface)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let action, let onAction {
                Button(action: onAction) {
                    Text(action)
                        .pixlFont(.labelLarge)
                        .foregroundStyle(SpotifyBrand.green)
                        .padding(6)
                        .contentShape(.rect)
                }
                .buttonStyle(PressScaleButtonStyle())
            }
        }
        .padding(.top, 6)
        .padding(.bottom, action == nil ? 2 : 0)
    }
}

/// Android `InfoCard`: 16 pt `secondaryContainer` card.
struct SpotifyBrowseInfoCard: View {
    let text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        Text(text)
            .pixlFont(.bodyMedium)
            .foregroundStyle(theme.onSecondaryContainer)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                       tint: theme.secondaryContainer.opacity(GlassTint.container))
    }
}

/// Android `EmptyMessage`.
struct SpotifyBrowseEmptyMessage: View {
    let text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        Text(text)
            .pixlFont(.bodyMedium)
            .foregroundStyle(theme.onSurfaceVariant)
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity)
    }
}

/// A circular artist image with Android's person fallback.
struct SpotifyArtistImage: View {
    let url: String?
    let size: CGFloat
    @Environment(\.appTheme) private var theme

    var body: some View {
        if let source = ArtworkSource(uriString: url) {
            ArtworkView(source: source, size: size, cornerRadius: size / 2)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.3, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: size, height: size)
                .background(Circle().fill(theme.surfaceVariant))
                .accessibilityHidden(true)
        }
    }
}

/// Android `ArtistBubble`: 96 pt wide, 80 pt circle, `bodySmall` name (two lines).
struct SpotifyArtistBubble: View {
    let artist: SpotifyArtistFull
    let onTap: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                SpotifyArtistImage(url: artist.images?.first?.url, size: 80)
                Text(artist.name ?? "")
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 96)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
        .accessibilityIdentifier("spotifyBrowse.artist.\(artist.id ?? "")")
    }
}

/// Android `ArtistHeader`: 72 pt circle, name (`titleLarge` bold), up to two genres.
struct SpotifyArtistHeader: View {
    let artist: SpotifyArtistFull
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            SpotifyArtistImage(url: artist.images?.first?.url, size: 72)
            VStack(alignment: .leading, spacing: 0) {
                Text(artist.name ?? "")
                    .pixlFont(.titleLarge, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                if let genres = artist.genres, !genres.isEmpty {
                    Text(genres.prefix(2).joined(separator: " · "))
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Android `AlbumHeader`: 72 pt cover (12 pt corners), name, "year · N tracks".
struct SpotifyAlbumHeader: View {
    let album: SpotifyAlbumFull
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(source: ArtworkSource(uriString: album.images?.first?.url), size: 72, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(album.name ?? "")
                    .pixlFont(.titleLarge, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                Text([album.releaseDate.map { String($0.prefix(4)) }, album.totalTracks.map { "\($0) tracks" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Android `AlbumRow`: 16 pt `surfaceContainerLow` card, 10 pt padding, 48 pt cover, name, "year · Type".
struct SpotifyAlbumRow: View {
    let album: SpotifyAlbumFull
    let onTap: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ArtworkView(source: ArtworkSource(uriString: album.images?.first?.url), size: 48, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 0) {
                    Text(album.name ?? "")
                        .pixlFont(.bodyLarge)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text([album.releaseDate.map { String($0.prefix(4)) }, album.albumType.map(Self.capitalizedFirst)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(GlassTint.surface), interactive: true)
        .accessibilityIdentifier("spotifyBrowse.album.\(album.id ?? "")")
    }

    /// Kotlin `replaceFirstChar { it.uppercase() }`.
    static func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}

/// Android `TrackRow`: 16 pt card, 48 pt cover, name and artists, a green "add" icon button.
struct SpotifyTrackRow: View {
    let track: SpotifyTrack
    let onAdd: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(source: ArtworkSource(uriString: track.album?.images?.first?.url), size: 48, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 0) {
                Text(track.name ?? "")
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Text((track.artists ?? []).compactMap(\.name).joined(separator: ", "))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SpotifyBrand.green)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel("Add to library")
        }
        .padding(.leading, 10)
        .padding(.vertical, 2)
        .padding(.trailing, 4)
        .frame(minHeight: 68)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(GlassTint.surface))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spotifyBrowse.track.\(track.id ?? "")")
    }
}
