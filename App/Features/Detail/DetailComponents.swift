import Observation
import PixlModel
import SwiftUI

// Shared pieces of the detail screens: the collapsing artwork header of Album / Artist (Android
// `SharedAlbumTopBarProbe` / `SharedArtistTopBarProbe` + `CollapsibleCommonTopBar` + `ExpressiveTopBarContent`),
// Genre's gradient header (`GenreCollapsibleTopBar`) and the plain top bar of Playlist / folders.

/// How far a detail list has scrolled. Only the header reads it, so scrolling never re-renders the list.
@Observable
final class HeaderScrollState {
    var offset: CGFloat = 0
}

extension View {
    /// Feeds a `HeaderScrollState` from this scroll view (distance scrolled from the top, 0...`maxOffset`). The headers
    /// are fully collapsed by their `maxHeight` (300 pt at most), so a larger offset changes nothing they draw: the
    /// value stops changing there and the header stops re-rendering every frame of the rest of the scroll.
    func trackingHeaderScroll(_ state: HeaderScrollState, maxOffset: CGFloat = 300) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            min(maxOffset, max(0, (geometry.contentOffset.y + geometry.contentInsets.top).rounded()))
        } action: { _, newValue in
            state.offset = newValue
        }
    }
}

/// Collapse metrics shared by the headers (Android `CollapsingHeaderHeight` + `rememberCollapseFraction`).
nonisolated struct CollapseMetrics: Sendable {
    let maxHeight: CGFloat
    let minHeight: CGFloat

    func height(offset: CGFloat) -> CGFloat { min(maxHeight, max(minHeight, maxHeight - offset)) }

    func fraction(offset: CGFloat) -> CGFloat {
        guard maxHeight > minHeight else { return 1 }
        return (maxHeight - height(offset: offset)) / (maxHeight - minHeight)
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}

/// The Album / Artist header: the artwork filling 300 pt and fading out (by twice the collapse), the gradient into
/// `surface`, the status-bar scrim, the back circle, the title (30 → 18 pt semibold, 2 lines while mostly open,
/// sliding from the bottom-left to the top bar), the subtitle (`labelLarge`), trailing actions, and the shuffle
/// button (Android's large FAB → a 96 pt prominent glass circle) that rides from bottom to top while it fades out.
struct CollapsingArtworkHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let artwork: ArtworkSource?
    let scroll: HeaderScrollState
    let metrics: CollapseMetrics
    let safeTop: CGFloat
    var collapsedTitleEnd: CGFloat = 24
    var placeholderSymbol = "music.note"
    let onBack: () -> Void
    let onShuffle: () -> Void
    @ViewBuilder var actions: Actions

    @Environment(\.appTheme) private var theme

    var body: some View {
        let height = metrics.height(offset: scroll.offset)
        let fraction = metrics.fraction(offset: scroll.offset)
        let solid = min(1, fraction * 2)
        let expanded = 1 - solid
        ZStack(alignment: .topLeading) {
            if expanded > 0.01 {
                GeometryReader { proxy in
                    Group {
                        if let artwork {
                            ArtworkView(source: artwork, size: max(proxy.size.width, metrics.maxHeight), cornerRadius: 0)
                        } else {
                            Image(systemName: placeholderSymbol)
                                .font(.system(size: 96, weight: .semibold))
                                .foregroundStyle(theme.onSurfaceVariant.opacity(0.2))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(theme.surfaceVariant)
                        }
                    }
                    .frame(width: proxy.size.width, height: metrics.maxHeight)
                    .clipped()
                }
                .opacity(expanded)
                LinearGradient(colors: [.clear, theme.surface.opacity(0.22 * expanded), theme.surface.opacity(0.82 * expanded),
                                        theme.surface],
                               startPoint: .top, endPoint: .bottom)
            }
            theme.surface.opacity(solid)
            LinearGradient(colors: [theme.isDark ? Color.black.opacity(0.6) : Color.white.opacity(0.4), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 80)
            titleBlock(fraction: fraction, height: height)
            // The back and action circles render together (spacing below their 6 pt gap); the shuffle circle stays
            // apart, it rides up next to them.
            GlassEffectContainer(spacing: 3) {
                HStack(spacing: Tokens.TopBar.actionSpacing) {
                    GlassCircleButton(systemImage: "arrow.left", accessibilityLabel: "Back",
                                      tint: theme.surfaceContainerLow.opacity(GlassTint.container),
                                      foreground: theme.onSurface, action: onBack)
                        .accessibilityIdentifier("detail.back")
                    Spacer()
                    actions
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.top, safeTop + 4)
            shuffleButton(fraction: fraction, expanded: expanded, height: height)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    /// Android `ExpressiveTopBarContent`: a box 112 → 56 pt high, aligned bottom → top of the area under the status
    /// bar, padded 24 → 68 pt at the start and 136 → `collapsedTitleEnd` at the end.
    private func titleBlock(fraction: CGFloat, height: CGFloat) -> some View {
        let lerp = CollapseMetrics.lerp
        let boxHeight = lerp(112, 56, fraction)
        let area = height - safeTop
        let y = safeTop + lerp(area - boxHeight, 0, fraction)
        let size = lerp(30, 18, fraction)
        return VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: size, weight: .bold))
                .lineLimit(fraction < 0.5 ? 2 : 1)
                .foregroundStyle(theme.onSurface)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .pixlFont(.labelLarge)
                .foregroundStyle(theme.onSurfaceVariant)
                .lineLimit(fraction < 0.5 ? 2 : 1)
        }
        .frame(height: boxHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, lerp(24, 68, fraction))
        .padding(.trailing, lerp(136, collapsedTitleEnd, fraction))
        .offset(y: y)
    }

    private func shuffleButton(fraction: CGFloat, expanded: CGFloat, height: CGFloat) -> some View {
        let size: CGFloat = 96
        let area = height - safeTop
        let y = safeTop + CollapseMetrics.lerp(area - size, 0, fraction)
        return HStack {
            Spacer()
            Button(action: onShuffle) {
                Image(systemName: "shuffle")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .frame(width: size, height: size)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .pixlGlass(in: Circle(), tint: theme.primaryContainer.opacity(GlassTint.prominent), interactive: true)
            .accessibilityLabel("Shuffle play")
            .accessibilityIdentifier("detail.shuffle")
        }
        .padding(.trailing, 16)
        .offset(y: y)
        .scaleEffect(max(expanded, 0.001), anchor: .trailing)
        .opacity(expanded)
        .allowsHitTesting(expanded > 0.5)
    }
}

/// A plain detail top bar (Android `LargeFlexibleTopAppBar` of the playlist screen): back circle
/// (`surfaceContainerHigh`) at 10 pt, trailing actions, then the title (`headlineMedium`) and subtitle
/// (`labelMedium`, `onSurfaceVariant`) 24 pt in.
struct DetailTopBar<Actions: View>: View {
    let title: String
    var subtitle: String?
    let onBack: () -> Void
    @ViewBuilder var actions: Actions

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Not in a GlassEffectContainer: the playlist's actions are system menus on the glass button style,
            // whose morph out of the button Hoa approved as it is (2026-10-02); leave their glass ungrouped.
            HStack(spacing: Tokens.TopBar.actionSpacing) {
                GlassCircleButton(systemImage: "arrow.left", accessibilityLabel: "Back",
                                  tint: theme.surfaceContainerHigh.opacity(GlassTint.container),
                                  foreground: theme.onSurface, action: onBack)
                    .accessibilityIdentifier("detail.back")
                Spacer()
                actions
            }
            .padding(.horizontal, 10)
            .frame(height: Tokens.TopBar.height)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .pixlFont(.headlineMedium, weight: .regular)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .pixlFont(.labelMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }
}

extension DetailTopBar where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, onBack: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, onBack: onBack) { EmptyView() }
    }
}

/// Applies an artwork's colour scheme to a whole screen (Android `GlassAwareMaterialTheme(albumColorScheme)`).
struct ArtworkThemed<Content: View>: View {
    let artUri: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        AlbumSchemeReader(artUri: artUri) { scheme in
            content().environment(\.appTheme, scheme)
        }
    }
}
