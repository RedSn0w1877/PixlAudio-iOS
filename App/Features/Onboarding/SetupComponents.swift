import SwiftUI

// The setup's building blocks: the scrolling page frame, the staggered reveal, the glass hero tile, the title block,
// the glass card, the buttons and the segmented progress. Every page is built from these so they all move alike.

/// A page's frame: scrolls when the content is taller than the screen (small phones, big Dynamic Type), otherwise the
/// content is centred. `content` receives `true` on short screens so a page can shrink its artwork.
struct SetupPageScroll<Content: View>: View {
    @ViewBuilder var content: (_ isCompact: Bool) -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content(proxy.size.height < 560)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: Motion

private struct SetupReveal: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 18)
            .scaleEffect(shown || reduceMotion ? 1 : 0.97)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(0.08 + 0.07 * Double(index))) {
                        shown = true
                    }
                }
            }
    }
}

private struct SetupScrollFade: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollTransition(.animated(.snappy)) { view, phase in
            view
                .opacity(phase.isIdentity ? 1 : 0.35)
                .scaleEffect(phase.isIdentity ? 1 : 0.94)
        }
    }
}

extension View {
    /// Fades and lifts the view in when its page appears, `index` places in a row (each one a beat after the last).
    func setupReveal(_ index: Int) -> some View {
        modifier(SetupReveal(index: index))
    }

    /// Cards that scroll under the page's edges shrink and fade a little.
    func setupScrollFade() -> some View {
        modifier(SetupScrollFade())
    }

    /// A rounded glass card: the scheme's container colour as a light tint on real Liquid Glass.
    func setupGlassCard(cornerRadius: CGFloat = 24, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(SetupGlassCard(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }
}

private struct SetupGlassCard: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content.pixlGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                          tint: tint ?? theme.surfaceContainer.opacity(SettingsTint.row), interactive: interactive)
    }
}

// MARK: Header

/// The big glass tile at the top of a page with one symbol in it. The symbol hops once as the page arrives.
struct SetupHero: View {
    let symbol: String
    var size: CGFloat = 88
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hops = 0

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(theme.onPrimaryContainer)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, options: .nonRepeating, value: hops)
            .frame(width: size, height: size)
            .pixlGlass(in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous),
                       tint: theme.primaryContainer.opacity(GlassTint.container))
            .accessibilityHidden(true)
            .task {
                guard !SetupMotion.isStill(reduceMotion: reduceMotion) else { return }
                try? await Task.sleep(for: .milliseconds(380))
                hops += 1
            }
    }
}

/// The centred page title and subtitle every setup page starts with.
struct SetupPageHeader: View {
    let title: String
    let subtitle: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .pixlFont(.custom(size: 34, weight: .bold, lineHeight: 40))
                .foregroundStyle(theme.onSurface)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A small line under the content ("You can change this any time…").
struct SetupFootnote: View {
    let text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        Text(text)
            .pixlFont(.labelMedium)
            .foregroundStyle(theme.onSurfaceVariant.opacity(0.8))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
    }
}

// MARK: Buttons

/// The setup's wide capsule button, in glass. `primary` is the app's accent, `plain` is untinted glass (skips and
/// secondary choices), `spotify` is Spotify's green with black content.
struct SetupFilledButton: View {
    enum Kind: Equatable {
        case primary, plain, spotify
    }

    let title: String
    var systemImage: String?
    var kind: Kind = .primary
    var isEnabled = true
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    private var foreground: Color {
        if !isEnabled { return theme.onSurface.opacity(0.38) }
        switch kind {
        case .primary: return theme.onPrimary
        case .plain: return theme.onSurface
        case .spotify: return .black
        }
    }

    private var tint: Color? {
        if !isEnabled { return nil }
        switch kind {
        case .primary: return theme.primary.opacity(GlassTint.prominent)
        case .plain: return theme.surfaceContainerHigh.opacity(GlassTint.container)
        case .spotify: return SetupSpotifyPage.spotifyGreen.opacity(GlassTint.prominent)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(title)
                    .pixlFont(.titleMedium)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pixlGlass(in: Capsule(), tint: tint, interactive: isEnabled)
    }
}

/// The round glass back button at the top left.
struct SetupBackButton: View {
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.onSurface)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Circle(), tint: theme.surfaceContainer.opacity(GlassTint.surface), interactive: true)
        .accessibilityLabel(L10n.setupBack)
        .accessibilityIdentifier("setup.back")
    }
}

// MARK: Progress

/// The segmented progress at the top: one capsule per step. Done steps are filled, the current one is longer and
/// bright, the next ones are faint. It springs as the step changes.
struct SetupProgress: View {
    /// Zero-based index of the current step.
    let current: Int
    let count: Int
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(fill(for: index))
                    .frame(width: index == current ? 36 : 12, height: 6)
            }
        }
        .animation(reduceMotion ? nil : PixlMotion.selection, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.setupStepFormat(current + 1, count))
    }

    private func fill(for index: Int) -> Color {
        if index == current { return theme.primary }
        if index < current { return theme.primary.opacity(0.5) }
        return theme.onSurface.opacity(0.16)
    }
}
