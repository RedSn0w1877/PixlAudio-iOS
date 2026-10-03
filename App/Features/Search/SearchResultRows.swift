import PixlFoundation
import PixlModel
import SwiftUI

// Result rows of Search (Android `SearchScreen.kt`: `SearchResultAlbumItem`, `SearchResultArtistItem`,
// `SearchResultPlaylistItem`, `SearchResultCatalogItem`, `SearchResultYouTubeMusicItem`, the section header and
// `EmptySearchResults`). Material cards become one glass layer each, same geometry; the round play / like buttons
// sit on that glass, so they are plain fills with press feedback rather than a second glass layer.

/// Android `SearchResultSectionHeader`: `titleMedium` bold, 8 × 4 pt padding.
struct SearchResultSectionHeader: View {
    let title: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        Text(title)
            .pixlFont(.titleMedium, weight: .bold)
            .foregroundStyle(theme.onSurface)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The round play button on album / artist / playlist rows (Android 40 dp `FilledIconButton`, role at 80 %).
private struct RowPlayButton: View {
    let fill: Color
    let foreground: Color
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 40, height: 40)
                .background(Circle().fill(fill))
                .contentShape(.circle)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(label)
    }
}

/// Shared shell of the album / artist / playlist rows: 12 pt padding, 26 pt continuous corners, glass tinted with
/// `surfaceContainerLow` (Android's card colour).
private struct ResultCard<Leading: View>: View {
    let title: String
    let subtitle: String
    let playFill: Color
    let playForeground: Color
    let playLabel: String
    let identifier: String
    let onOpen: () -> Void
    let onPlay: () -> Void
    @ViewBuilder var leading: Leading

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SearchMetrics.resultCardRadius, style: .continuous)
        HStack(spacing: 0) {
            // The artwork and the two lines read as one button that opens the result; Play stays its own button.
            HStack(spacing: 0) {
                leading
                Spacer().frame(width: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .pixlFont(.titleMedium, weight: .bold)
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
            .accessibilityAction(.default, onOpen)
            RowPlayButton(fill: playFill, foreground: playForeground, label: playLabel, action: onPlay)
        }
        .padding(12)
        .contentShape(shape)
        .onTapGesture(perform: onOpen)
        .pixlGlass(in: shape, tint: theme.surfaceContainerLow.opacity(GlassTint.surface), interactive: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

struct SearchResultAlbumRow: View {
    let album: Album
    let onOpen: () -> Void
    let onPlay: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        ResultCard(title: album.title, subtitle: album.artist,
                   playFill: theme.secondary.opacity(0.8), playForeground: theme.onSecondary, playLabel: "Play album",
                   identifier: "searchAlbum.\(album.id)", onOpen: onOpen, onPlay: onPlay) {
            // Android clips the art with the card's own 26 dp shape.
            ArtworkView(source: ArtworkSource(uriString: album.albumArtUriString), size: 56,
                        cornerRadius: SearchMetrics.resultCardRadius)
        }
    }
}

struct SearchResultArtistRow: View {
    let artist: Artist
    let onOpen: () -> Void
    let onPlay: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        ResultCard(title: artist.name, subtitle: SearchFormat.songCount(artist.songCount),
                   playFill: theme.tertiary.opacity(0.8), playForeground: theme.onTertiary, playLabel: "Play Artist",
                   identifier: "searchArtist.\(artist.id)", onOpen: onOpen, onPlay: onPlay) {
            if let url = artist.effectiveImageUrl, let source = ArtworkSource(uriString: url) {
                ArtworkView(source: source, size: 56, cornerRadius: 28)
            } else {
                // Android `rounded_artist_24` on `tertiaryContainer`, 12 dp padding.
                Image(systemName: "person.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(theme.onTertiaryContainer)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(theme.tertiaryContainer))
                    .accessibilityHidden(true)
            }
        }
    }
}

struct SearchResultPlaylistRow: View {
    let playlist: Playlist
    let songs: [Song]
    let onOpen: () -> Void
    let onPlay: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        ResultCard(title: playlist.name, subtitle: SearchFormat.songCount(playlist.songIds.count),
                   playFill: theme.primary.opacity(0.8), playForeground: theme.onPrimary, playLabel: "Play Playlist",
                   identifier: "searchPlaylist.\(playlist.id)", onOpen: onOpen, onPlay: onPlay) {
            SearchPlaylistCover(playlist: playlist, songs: songs, size: 56)
        }
    }
}

/// Catalogue / YouTube Music rows: 10 pt padding, 22 pt corners, 50 pt art with 10 pt corners, the title
/// (`bodyLarge` medium) over the artist (`bodyMedium`, `onSurfaceVariant`).
private struct RemoteResultCard<Trailing: View>: View {
    let title: String
    let artist: String
    let artURL: String?
    let identifier: String
    let onTap: () -> Void
    @ViewBuilder var trailing: Trailing

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        HStack(spacing: 0) {
            // The artwork and the two lines read as one button; the trailing control stays its own element.
            HStack(spacing: 0) {
                ArtworkView(source: ArtworkSource(uriString: artURL), size: 50, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .pixlFont(.bodyLarge, weight: .medium)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(artist)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onTap)
            trailing
        }
        .padding(10)
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .pixlGlass(in: shape, tint: theme.surfaceContainerLow.opacity(GlassTint.surface), interactive: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// Android `SearchResultCatalogItem`: tap imports and plays; the heart only saves it (spinner while busy).
struct SearchResultCatalogRow: View {
    let track: CatalogTrack
    let isBusy: Bool
    let onPlay: () -> Void
    let onLike: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        RemoteResultCard(title: track.title, artist: track.artist, artURL: track.albumArtUrl,
                         identifier: "searchCatalog.\(track.spotifyId)", onTap: { if !isBusy { onPlay() } }) {
            // FilledTonalIconButton: 40 dp `secondaryContainer` circle.
            Button { if !isBusy { onLike() } } label: {
                ZStack {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(theme.onSecondaryContainer)
                    } else {
                        Image(systemName: "heart")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.onSecondaryContainer)
                    }
                }
                .frame(width: 40, height: 40)
                .background(Circle().fill(theme.secondaryContainer))
                .contentShape(.circle)
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(isBusy)
            .accessibilityLabel("Like — adds to your library without playing")
        }
    }
}

/// Android `SearchResultYouTubeMusicItem`: tap imports and plays; a play glyph (spinner while busy).
struct SearchResultYouTubeMusicRow: View {
    let track: YouTubeMusicTrack
    let isBusy: Bool
    let onPlay: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        RemoteResultCard(title: track.title, artist: track.artist, artURL: track.thumbnailUrl,
                         identifier: "searchYouTubeMusic.\(track.videoId)", onTap: { if !isBusy { onPlay() } }) {
            ZStack {
                if isBusy {
                    ProgressView().tint(theme.primary)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.primary)
                        .accessibilityLabel("Play")
                }
            }
            .frame(width: 24, height: 24)
        }
    }
}

/// Android `PlaylistCover` (56 pt here): the custom cover image, else the colour + icon cover, else
/// `PlaylistArtCollage` — round song arts (1 full, 2 stacked, 3 in a triangle, 4 in a grid), or the queue icon on
/// `secondaryContainer` when the playlist is empty.
struct SearchPlaylistCover: View {
    let playlist: Playlist
    let songs: [Song]
    let size: CGFloat
    @Environment(\.appTheme) private var theme

    var body: some View {
        Group {
            if let uri = playlist.coverImageUri, let source = ArtworkSource(uriString: uri) {
                ArtworkView(source: source, size: size, cornerRadius: 8)
            } else if let argb = playlist.coverColorArgb {
                let color = UInt32(bitPattern: argb)
                Image(systemName: Self.symbol(playlist.coverIconName))
                    .font(.system(size: size / 2 * 0.8, weight: .medium))
                    .foregroundStyle(Color(argb: relativeLuminance(argb: color) > 0.5 ? 0xFF1B1B1F : 0xFFFFFFFF))
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(argb: color)))
            } else {
                collage
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Android `getIconByName`.
    static func symbol(_ name: String?) -> String {
        switch name {
        case "Headphones": "headphones"
        case "Album": "opticaldisc"
        case "Mic": "music.mic"
        case "Speaker": "hifispeaker"
        case "Favorite": "heart.fill"
        case "Piano": "pianokeys"
        case "Queue": "music.note.list"
        default: "music.note"
        }
    }

    @ViewBuilder
    private var collage: some View {
        let arts = Array(songs.prefix(4))
        let gap: CGFloat = 2
        switch arts.count {
        case 0:
            Image(systemName: "music.note.list")
                .resizable()
                .scaledToFit()
                .padding(12)
                .foregroundStyle(theme.onSecondaryContainer)
                .frame(width: size, height: size)
                .background(Circle().fill(theme.secondaryContainer))
        case 1:
            ArtworkView(song: arts[0], size: size, cornerRadius: size / 2)
        case 2:
            let item = (size - gap) / 2
            VStack(spacing: gap) {
                ArtworkView(song: arts[0], size: item, cornerRadius: item / 2)
                ArtworkView(song: arts[1], size: item, cornerRadius: item / 2)
            }
        case 3:
            // Three circles whose centres form an equilateral triangle, centred in the square.
            let item = (size * 2 / (2 + CGFloat(3).squareRoot()) - gap).rounded(.down)
            let side = item + gap
            let height = side * CGFloat(3).squareRoot() / 2
            let offsetX = (size - (side + item)) / 2
            let offsetY = (size - (height + item)) / 2
            ZStack(alignment: .topLeading) {
                ArtworkView(song: arts[0], size: item, cornerRadius: item / 2)
                    .offset(x: offsetX + side / 2, y: offsetY)
                ArtworkView(song: arts[1], size: item, cornerRadius: item / 2)
                    .offset(x: offsetX, y: offsetY + height)
                ArtworkView(song: arts[2], size: item, cornerRadius: item / 2)
                    .offset(x: offsetX + side, y: offsetY + height)
            }
            .frame(width: size, height: size, alignment: .topLeading)
        default:
            let item = (size - gap) / 2
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    ArtworkView(song: arts[0], size: item, cornerRadius: item / 2)
                    ArtworkView(song: arts[1], size: item, cornerRadius: item / 2)
                }
                HStack(spacing: gap) {
                    ArtworkView(song: arts[2], size: item, cornerRadius: item / 2)
                    ArtworkView(song: arts[3], size: item, cornerRadius: item / 2)
                }
            }
        }
    }
}

/// Android `EmptySearchResults`: an 80 pt search glyph (`primary` 60 %), the title and the hint, centred.
struct EmptySearchResultsView: View {
    let query: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(theme.primary.opacity(0.6))
                .frame(width: 64, height: 64)
                .padding(.bottom, 16)
                .accessibilityLabel("No results")
            Text(query.isKotlinBlank ? "Nothing found" : "No results for \"\(query)\"")
                .pixlFont(.titleLarge, weight: .bold)
                .foregroundStyle(theme.onSurface)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 8)
            Text("Try a different search term or check your filters.")
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onBackground.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityIdentifier("search.empty")
    }
}

nonisolated enum SearchMetrics {
    /// `AbsoluteSmoothCornerShape(26 dp, 60 %)` of the album / artist / playlist rows.
    static let resultCardRadius: CGFloat = 26
    /// The 12 pt gap under every result row.
    static let rowSpacing: CGFloat = 12
}

nonisolated enum SearchFormat {
    /// Android `formatSongCount`: "1 Song" for 0 or 1, else "N Songs".
    static func songCount(_ count: Int) -> String {
        count <= 1 ? "\(count) Song" : "\(count) Songs"
    }
}
