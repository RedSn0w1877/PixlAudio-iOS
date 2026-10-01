import PixlLibrary
import PixlModel
import SwiftUI

// Small pieces shared by the Library, detail and playlist screens. Each names the Android composable it ports;
// Material fills become tinted Liquid Glass (docs/design.md › mapping).

/// A glass button in one segment of a connected button group (Android `FilledTonalButton` /
/// `FilledTonalIconButton` with `RoundedCornerShape(26.dp outer, 8.dp inner)` in `LibraryActionRow` and
/// `SelectionActionRow`). `leading`/`trailing` are the corner radii of each side.
struct SegmentedGlassButton: View {
    var title: String?
    let systemImage: String
    var accessibilityLabel: String
    var leading: CGFloat = 26
    var trailing: CGFloat = 26
    var height: CGFloat = 42
    /// Square icon button (Android `Modifier.size(genHeight)`) when there is no title.
    var minWidth: CGFloat?
    var horizontalPadding: CGFloat = 16
    var iconSize: CGFloat = 20
    var tint: Color?
    var foreground: Color
    var iconRotation: Double = 0
    var titleStyle: PixlTextStyle = .labelLarge
    /// Stretch to the offered width (Android `Modifier.weight(1f)` buttons); the glass follows the full width.
    var fillsWidth = false
    let action: () -> Void

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: leading, bottomLeadingRadius: leading,
                                           bottomTrailingRadius: trailing, topTrailingRadius: trailing,
                                           style: .continuous)
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.s) {
                if iconSize > 0 {
                    Image(systemName: systemImage)
                        .font(.system(size: iconSize * 0.85, weight: .semibold))
                        .frame(width: iconSize, height: iconSize)
                        .rotationEffect(.degrees(iconRotation))
                }
                if let title {
                    Text(title)
                        .pixlFont(titleStyle)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, title == nil ? 0 : horizontalPadding)
            .frame(minWidth: minWidth ?? (title == nil ? height : nil), maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: height)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: tint, interactive: true)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Android `SelectionCountPill`: the floating count while multi-selecting (check icon + number, 20 pt corners,
/// `primaryContainer`).
struct SelectionCountPill: View {
    let count: Int
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
            Text("\(count)")
                .pixlFont(.labelLarge, weight: .semibold)
                .contentTransition(.numericText())
        }
        .foregroundStyle(theme.onPrimaryContainer)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                   tint: theme.primaryContainer.opacity(GlassTint.prominent))
        .padding(8)
        .accessibilityLabel("\(count) selected")
        .accessibilityIdentifier("selectionCount")
    }
}

/// Android `LibraryExpressiveEmptyState`: a 56 pt circle with the tab icon, title (`titleLarge` semibold) and
/// subtitle (`bodyMedium`, `onSurfaceVariant`), centred with 28 pt sides.
struct LibraryEmptyState: View {
    let systemImage: String
    let title: String
    let subtitle: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.onSecondaryContainer)
                .frame(width: 56, height: 56)
                .pixlGlass(in: Circle(), tint: theme.secondaryContainer.opacity(0.55))
            VStack(spacing: 6) {
                Text(title)
                    .pixlFont(.titleLarge, weight: .semibold)
                    .foregroundStyle(theme.onSurface)
                Text(subtitle)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// One action of a PixlAudio options sheet (Android song-info / multi-selection buttons: `FilledTonalButton`
/// rows with an icon and `TightWrapText`), as a tinted glass tile. `cornerRadius` nil = capsule.
struct ActionTile: View {
    var title: String?
    let systemImage: String
    var accessibilityLabel: String?
    var tint: Color
    var foreground: Color
    var minHeight: CGFloat = 66
    var cornerRadius: CGFloat?
    var titleStyle: PixlTextStyle = .titleMedium
    var iconSize: CGFloat = 24
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? minHeight / 2, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize * 0.85, weight: .semibold))
                    .frame(width: iconSize, height: iconSize)
                if let title {
                    Text(title)
                        .pixlFont(titleStyle)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .padding(.trailing, 4)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: tint.opacity(GlassTint.prominent), interactive: true)
        .accessibilityLabel(accessibilityLabel ?? title ?? "")
    }
}

/// Android `PlaylistArtCollage`: up to four circular album arts (one big, two stacked, three in a triangle, four in
/// a 2×2 grid, 2 pt apart); an empty playlist shows the queue icon on `secondaryContainer`.
struct ArtCollage: View {
    let songs: [Song]
    let size: CGFloat
    @Environment(\.appTheme) private var theme

    var body: some View {
        let preview = Array(songs.prefix(4))
        Group {
            switch preview.count {
            case 0:
                Image(systemName: "music.note.list")
                    .font(.system(size: max(size - 24, 8) * 0.7, weight: .semibold))
                    .foregroundStyle(theme.onSecondaryContainer)
                    .frame(width: size, height: size)
                    .background(Circle().fill(theme.secondaryContainer))
            case 1:
                art(preview[0], size)
            case 2:
                let item = (size - 2) / 2
                VStack(spacing: 2) {
                    art(preview[0], item)
                    art(preview[1], item)
                }
                .frame(width: size, height: size)
            case 3:
                // Three circles whose centres form an equilateral triangle (Android's custom Layout).
                let item = (size * 2 / (2 + 3.0.squareRoot())).rounded(.down) - 2
                let side = item + 2
                let h = side * 3.0.squareRoot() / 2
                let width = side + item, height = h + item
                ZStack(alignment: .topLeading) {
                    art(preview[0], item).offset(x: (width - item) / 2, y: 0)
                    art(preview[1], item).offset(x: 0, y: h)
                    art(preview[2], item).offset(x: side, y: h)
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .frame(width: size, height: size)
            default:
                let item = (size - 2) / 2
                VStack(spacing: 2) {
                    HStack(spacing: 2) { art(preview[0], item); art(preview[1], item) }
                    HStack(spacing: 2) { art(preview[2], item); art(preview[3], item) }
                }
                .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }

    private func art(_ song: Song, _ side: CGFloat) -> some View {
        ArtworkView(song: song, size: side, cornerRadius: side / 2)
    }
}

/// Android `PlaylistCover`: the playlist's own image, else its colour + icon in its shape, else the collage of its
/// first songs. Shapes: Circle, SmoothRect (corner from `coverShapeDetail1` scaled from a 200 pt reference),
/// RotatedPill (a pill rotated 45°), Star (sides `detail4`, curve `detail1`, rotation `detail2`, scale `detail3`).
struct PlaylistCoverView: View {
    let playlist: Playlist
    let songs: [Song]
    var size: CGFloat = 48
    @Environment(\.appTheme) private var theme

    var body: some View {
        PlaylistCoverArt(imageUri: playlist.coverImageUri, colorArgb: playlist.coverColorArgb,
                         iconName: playlist.coverIconName, shapeType: playlist.coverShapeType,
                         details: [playlist.coverShapeDetail1, playlist.coverShapeDetail2, playlist.coverShapeDetail3,
                                   playlist.coverShapeDetail4],
                         songs: songs, size: size)
    }
}

/// The drawing behind `PlaylistCoverView`, also used by the playlist editor's live preview.
struct PlaylistCoverArt: View {
    let imageUri: String?
    let colorArgb: Int32?
    let iconName: String?
    let shapeType: String?
    let details: [Float?]
    let songs: [Song]
    let size: CGFloat
    @Environment(\.appTheme) private var theme

    private func detail(_ index: Int) -> Float? { details.indices.contains(index) ? details[index] : nil }

    var body: some View {
        let isPill = shapeType == PlaylistShapeType.rotatedPill.rawValue
        let starScale = shapeType == PlaylistShapeType.star.rawValue ? CGFloat(detail(2) ?? 1) : 1
        content(isPill: isPill)
            .frame(width: size, height: size)
            .clipShape(PlaylistCoverShape(type: shapeType, size: size, details: details))
            .rotationEffect(.degrees(isPill ? 45 : 0))
            .scaleEffect(starScale)
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private func content(isPill: Bool) -> some View {
        if let imageUri, let source = ArtworkSource(uriString: imageUri) {
            ArtworkView(source: source, size: size, cornerRadius: 0)
                .rotationEffect(.degrees(isPill ? -45 : 0))
        } else if let colorArgb {
            let argb = UInt32(bitPattern: colorArgb)
            ZStack {
                Color(argb: argb)
                Image(systemName: PlaylistIcons.symbol(for: iconName))
                    .font(.system(size: size / 2 * 0.8, weight: .semibold))
                    .foregroundStyle(PlaylistIcons.contentColor(onArgb: argb, theme: theme))
                    .rotationEffect(.degrees(isPill ? -45 : 0))
            }
        } else {
            ArtCollage(songs: songs, size: size)
        }
    }
}

/// Clip shape of a playlist cover (Android `PlaylistCover` shapes); unknown / nil = 8 pt rounded square.
nonisolated struct PlaylistCoverShape: Shape {
    let type: String?
    let size: CGFloat
    let details: [Float?]

    private func detail(_ index: Int) -> Float? { details.indices.contains(index) ? details[index] : nil }

    func path(in rect: CGRect) -> Path {
        switch type {
        case PlaylistShapeType.circle.rawValue:
            return Circle().path(in: rect)
        case PlaylistShapeType.smoothRect.rawValue:
            let radius = CGFloat(detail(0) ?? 20) * size / 200
            return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
        case PlaylistShapeType.rotatedPill.rawValue:
            let pillWidth = rect.width * 0.75
            let pill = CGRect(x: rect.minX + (rect.width - pillWidth) / 2, y: rect.minY, width: pillWidth, height: rect.height)
            return RoundedRectangle(cornerRadius: pillWidth / 2, style: .continuous).path(in: pill)
        case PlaylistShapeType.star.rawValue:
            return RoundedStar(sides: Int(detail(3) ?? 5), curve: Double(detail(0) ?? 0.15),
                               rotation: Double(detail(1) ?? 0)).path(in: rect)
        default:
            return RoundedRectangle(cornerRadius: 8, style: .continuous).path(in: rect)
        }
    }
}

/// Android `RoundedStarShape(sides, curve, rotation)`: a star whose radius follows `1 + curve·cos(sides·θ)`,
/// sampled every degree.
nonisolated struct RoundedStar: Shape {
    var sides: Int
    var curve: Double
    var rotation: Double

    func path(in rect: CGRect) -> Path {
        let n = max(3, sides)
        let r = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rotationRad = rotation * .pi / 180
        var path = Path()
        for step in 0...360 {
            let theta = Double(step) * .pi / 180
            let radius = r * CGFloat((1 + curve * cos(Double(n) * theta)) / (1 + curve))
            let point = CGPoint(x: center.x + radius * CGFloat(cos(theta + rotationRad)),
                                y: center.y + radius * CGFloat(sin(theta + rotationRad)))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Playlist cover icons (Android `getIconByName`) as SF Symbols, and the icon colour on a cover colour
/// (`resolvePlaylistCoverContentColor`: the matching `on…` role when the colour is a scheme role, else black/white).
nonisolated enum PlaylistIcons {
    static let names = ["MusicNote", "Headphones", "Album", "Mic", "Speaker", "Favorite", "Piano", "Queue"]

    static func symbol(for name: String?) -> String {
        switch name {
        case "Headphones": "headphones"
        case "Album": "opticaldisc"
        case "Mic": "music.mic"
        case "Speaker": "hifispeaker.fill"
        case "Favorite": "heart.fill"
        case "Piano": "pianokeys"
        case "Queue": "music.note.list"
        default: "music.note"
        }
    }

    static func contentColor(onArgb argb: UInt32, theme: ThemeColors) -> Color {
        let pairs: [(KeyPath<ColorRoles, UInt32>, KeyPath<ColorRoles, UInt32>)] = [
            (\.primary, \.onPrimary), (\.primaryContainer, \.onPrimaryContainer), (\.secondary, \.onSecondary),
            (\.secondaryContainer, \.onSecondaryContainer), (\.tertiary, \.onTertiary),
            (\.tertiaryContainer, \.onTertiaryContainer), (\.error, \.onError), (\.errorContainer, \.onErrorContainer),
            (\.surfaceContainerHigh, \.onSurface), (\.inverseSurface, \.inverseOnSurface),
        ]
        for (fill, on) in pairs where theme.argb(fill) == argb { return Color(argb: theme.argb(on)) }
        return relativeLuminance(argb: argb) > 0.4 ? .black : .white
    }
}
