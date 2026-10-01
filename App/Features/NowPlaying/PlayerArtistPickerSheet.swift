import PixlModel
import SwiftUI

/// "Pick an Artist" (Android `PlayerArtistPickerBottomSheet`), opened from the player's artist line when the song
/// credits several artists: the title (`headlineMedium` bold), then one card per artist — primary first — in a
/// group with 26 pt outer and 10 pt inner corners, 4 pt apart. A card: 52 pt avatar, name (`titleMedium` semibold),
/// a "Primary artist" / "Artist page" label capsule, and a 38 pt arrow circle. The primary card is
/// `secondaryContainer` with a `tertiary` label; the others `surfaceContainerLow`. Tapping collapses the player and
/// opens the artist.
struct PlayerArtistPickerSheet: View {
    let songId: String

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    private struct Item: Identifiable {
        let ref: ArtistRef
        let artist: Artist?
        let isPrimary: Bool
        var id: Int64 { ref.id }
    }

    var body: some View {
        let song = library.song(id: songId) ?? playback.queue.first { $0.id == songId }
        let items = song.map(Self.items(for:)) ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pick an Artist")
                    .pixlFont(.headlineMedium, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                VStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        card(item, shape: Self.shape(index: index, count: items.count))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                Spacer().frame(height: 12)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .padding(.top, 8)
        }
        .accessibilityIdentifier("screen.artistPicker")
    }

    /// Android `shortcutItems`: the primary artist (by id, else name, else the first) leads.
    private static func items(for song: Song) -> [Item] {
        let refs = song.artists.isEmpty ? [song.primaryArtist] : song.artists
        let primary = song.primaryArtist
        var items = refs.enumerated().map { index, ref -> Item in
            let isPrimary: Bool
            if primary.id != 0 && primary.id != -1 {
                isPrimary = ref.id == primary.id
            } else if !primary.name.isEmpty {
                isPrimary = ref.name.caseInsensitiveCompare(primary.name) == .orderedSame
            } else {
                isPrimary = index == 0
            }
            return Item(ref: ref, artist: nil, isPrimary: isPrimary)
        }
        if !items.contains(where: \.isPrimary), !items.isEmpty {
            items[0] = Item(ref: items[0].ref, artist: nil, isPrimary: true)
        }
        return items.filter(\.isPrimary) + items.filter { !$0.isPrimary }
    }

    private static func shape(index: Int, count: Int) -> UnevenRoundedRectangle {
        let outer: CGFloat = 26
        let inner: CGFloat = 10
        let top = count <= 1 || index == 0 ? outer : inner
        let bottom = count <= 1 || index == count - 1 ? outer : inner
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                                      topTrailingRadius: top, style: .continuous)
    }

    private func card(_ item: Item, shape: UnevenRoundedRectangle) -> some View {
        let content = item.isPrimary ? theme.onSecondaryContainer : theme.onSurface
        let container = item.isPrimary ? theme.secondaryContainer : theme.surfaceContainerLow
        let artist = library.artist(id: item.ref.id)
        return Button {
            router.dismissSheet()
            env.playerSheet.collapse()
            router.push(.artistDetail(artistId: item.ref.id))
        } label: {
            HStack(spacing: 14) {
                ArtistAvatar(imageURL: artist?.effectiveImageUrl, size: 52,
                             background: item.isPrimary ? theme.onSecondaryContainer.opacity(0.12)
                                 : theme.surfaceContainerHighest,
                             foreground: content)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.ref.name)
                        .pixlFont(.titleMedium, weight: .semibold)
                        .foregroundStyle(content)
                        .lineLimit(1)
                    Text(item.isPrimary ? "Primary artist" : "Artist page")
                        .pixlFont(.labelMedium)
                        .foregroundStyle(item.isPrimary ? theme.onTertiary : theme.onSurfaceVariant)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(item.isPrimary ? theme.tertiary : theme.surfaceContainerHighest))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(content)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(content.opacity(0.12)))
            }
            .padding(14)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: container.opacity(item.isPrimary ? GlassTint.prominent : GlassTint.container),
                   interactive: true)
        .accessibilityIdentifier("artistPicker.\(item.ref.id)")
    }
}

/// A round artist image (remote / file URL) with the person glyph as placeholder.
private struct ArtistAvatar: View {
    let imageURL: String?
    let size: CGFloat
    let background: Color
    let foreground: Color

    var body: some View {
        ZStack {
            Circle().fill(background)
            if let source = ArtworkSource(uriString: imageURL) {
                ArtworkView(source: source, size: size, cornerRadius: size / 2)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(foreground.opacity(0.8))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
