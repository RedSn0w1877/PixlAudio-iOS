import SwiftUI

/// Shared pieces of the Spotify screens (Android `presentation/spotify/**`): the brand colour, the plain
/// `TopAppBar` scaffold, card and button ports. Material elements become glass: cards and rows are glass panels in
/// Android's shapes tinted with the colour Android filled them with; buttons sitting on a card are fills (no glass on
/// glass), standalone buttons are glass.
nonisolated enum SpotifyBrand {
    /// `SpotifyBrandGreen` (0xFF1DB954).
    static let green = Color(argb: 0xFF1D_B954)
    /// The YouTube card's red (0xFFFF0000).
    static let youTubeRed = Color(argb: 0xFFFF_0000)
}

/// Scroll position of a `SpotifyScaffold`, read only by its bar (the list never re-evaluates while scrolling).
@Observable
final class SpotifyScrollState {
    var offset: CGFloat = 0
}

/// Android `Scaffold` + small `TopAppBar` (64 dp: back icon, `titleLarge` title) over a `LazyColumn`. The bar is
/// transparent at rest and fills with glass once content scrolls under it (Material's scrolled container colour).
/// The back circle sits 12 pt in like the app's other top bars, the title 68 pt in.
struct SpotifyScaffold<Content: View>: View {
    let title: String
    let screenID: String
    var horizontalPadding: CGFloat = 16
    var verticalPadding: CGFloat = 12
    var spacing: CGFloat = 12
    var onBack: (() -> Void)?
    var header: AnyView?
    @ViewBuilder var content: Content

    @State private var scroll = SpotifyScrollState()
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    init(title: String, screenID: String, horizontalPadding: CGFloat = 16, verticalPadding: CGFloat = 12, spacing: CGFloat = 12,
         onBack: (() -> Void)? = nil, header: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.screenID = screenID
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.spacing = spacing
        self.onBack = onBack
        self.header = header
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            SpotifyTopBar(title: title, scroll: scroll, onBack: { if let onBack { onBack() } else { dismiss() } })
            if let header { header }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: spacing) {
                    content
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .padding(.bottom, Tokens.Shell.miniPlayerHeight + 16)
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, value in
                scroll.offset = value
            }
            .accessibilityIdentifier("screen.\(screenID)")
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .background(SettingsBackSwipeEnabler().frame(width: 0, height: 0))
    }
}

/// Android `TopAppBar(title, navigationIcon = ArrowBack)`.
struct SpotifyTopBar: View {
    let title: String
    let scroll: SpotifyScrollState
    let onBack: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let scrolled = min(max(scroll.offset / 24, 0), 1)
        HStack(spacing: 16) {
            GlassCircleButton(systemImage: "arrow.left", accessibilityLabel: "Back",
                              tint: theme.surfaceContainerLow.opacity(GlassTint.surface), action: onBack)
                .accessibilityIdentifier("spotify.back")
            Text(title)
                .pixlFont(.titleLarge)
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(height: Tokens.TopBar.height)
        .background {
            Rectangle()
                .fill(.clear)
                .pixlGlass(in: Rectangle(), tint: theme.surfaceContainer.opacity(GlassTint.bar))
                .opacity(scrolled)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
        .zIndex(1)
    }
}

/// A Material `Card` as a glass panel: Android's container colour becomes the tint (`GlassTint.surface` for the
/// neutral `surfaceContainer*` roles, `container` for coloured ones such as `errorContainer`).
struct SpotifyCard<Content: View>: View {
    var cornerRadius: CGFloat
    var tint: Color?
    var strength: Double = GlassTint.surface
    var padding: CGFloat = 18
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    init(cornerRadius: CGFloat, tint: Color? = nil, strength: Double = GlassTint.surface, padding: CGFloat = 18,
         spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.strength = strength
        self.padding = padding
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint.map { $0.opacity(strength) })
    }
}

/// Material `Button` / `FilledTonalButton` sitting on a card: a filled capsule (or rounded rectangle) with immediate
/// press feedback — a second glass layer inside a glass card would be glass on glass.
struct SpotifyFilledButton: View {
    let title: String
    var systemImage: String?
    let fill: Color
    let foreground: Color
    var fullWidth = false
    var height: CGFloat = 40
    var cornerRadius: CGFloat?
    var iconSize: CGFloat = 18
    var iconSpacing: CGFloat = 8
    var isEnabled = true
    var identifier: String?
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? height / 2, style: .continuous)
        Button(action: action) {
            HStack(spacing: iconSpacing) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: iconSize - 2, weight: .semibold))
                }
                Text(title)
                    .pixlFont(.labelLarge)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(isEnabled ? foreground : theme.onSurface.opacity(0.38))
            .padding(.horizontal, 24)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(shape.fill(isEnabled ? fill : theme.onSurface.opacity(0.12)))
            .contentShape(shape)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
        .disabled(!isEnabled)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// Material `OutlinedButton` on a card: a 1 pt `outline` stroke (or the given colour), `primary` content.
struct SpotifyOutlinedButton: View {
    let title: String
    var systemImage: String?
    var fullWidth = false
    var height: CGFloat = 40
    var cornerRadius: CGFloat?
    var stroke: Color?
    var foreground: Color?
    var isEnabled = true
    var isBusy = false
    var identifier: String?
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? height / 2, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.small).tint(foreground ?? theme.primary)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .pixlFont(.labelLarge)
                    .lineLimit(1)
            }
            .foregroundStyle(isEnabled ? (foreground ?? theme.primary) : theme.onSurface.opacity(0.38))
            .padding(.horizontal, 24)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .overlay(shape.strokeBorder(isEnabled ? (stroke ?? theme.outline) : theme.onSurface.opacity(0.12), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
        .disabled(!isEnabled)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// A thin determinate progress bar (Material `LinearProgressIndicator`: 4 pt, `primary` on `secondaryContainer`).
struct SpotifyLinearProgress: View {
    let fraction: Double
    @Environment(\.appTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.secondaryContainer)
                Capsule().fill(theme.primary).frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// Material indeterminate `LinearProgressIndicator` (the browse screen's loading line): a `primary` segment sweeping
/// over the `secondaryContainer` track. The animation runs only while the bar is on screen.
struct SpotifyIndeterminateProgress: View {
    @State private var phase = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(theme.secondaryContainer)
                Capsule()
                    .fill(theme.primary)
                    .frame(width: width * 0.35)
                    .offset(x: phase ? width : -width * 0.35)
            }
            .clipped()
        }
        .frame(height: 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = true }
        }
        .accessibilityLabel("Loading")
    }
}
