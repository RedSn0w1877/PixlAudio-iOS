import SwiftUI

/// The inside of a PixlAudio bottom sheet (Android `ModalBottomSheet` content): an optional title row
/// (`titleLarge` bold, 24 pt sides) and the content. Present it with `.pixlSheet(detents:)` so the system sheet
/// supplies the glass and the drag handle — never override `presentationBackground`. A sheet that should stay
/// see-through at nearly full height uses `[.tallGlass]` (below).
struct SheetScaffold<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var content: Content

    @Environment(\.appTheme) private var theme

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .pixlFont(.titleLarge, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .padding(.horizontal, Tokens.Spacing.xxl)
                    .padding(.top, Tokens.Spacing.xxl)
                    .padding(.bottom, Tokens.Spacing.m)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension View {
    /// System sheet presentation for a `SheetScaffold`: detents and the visible drag handle (Android's handle).
    func pixlSheet(detents: Set<PresentationDetent> = [.medium, .large]) -> some View {
        presentationDetents(detents)
            .presentationDragIndicator(.visible)
    }
}

extension PresentationDetent {
    /// The see-through tall sheet (Hoa, 2026-10-07, "more Liquid Glass"): one partial detent at 92 % of the height.
    /// iOS 26 draws a sheet at a partial detent as inset Liquid Glass that lets the screen behind show through, and
    /// turns it opaque at `.large` ("When a half sheet expands to full height, it transitions to a more opaque
    /// appearance", Adopting Liquid Glass). The queue, the song sheet, the AI Daily Mix sheet and Taizo's chat use it
    /// instead of `[.large]`, so the player or the page stays visible around and through them. A single detent can't
    /// be dragged to full height; drag down still dismisses. Apple documents no threshold for the glass look, so the
    /// value is checked on CI shots (fall back to 0.85 if 0.92 renders opaque). Android's sheets are full height
    /// (owner-requested divergence, docs/parity.md).
    nonisolated static var tallGlass: PresentationDetent { .fraction(0.92) }
}

/// A trivially simple screen for routes whose stage hasn't landed: the title and which stage owns it.
/// Every placeholder is replaced by its owning stage (see docs/design.md › Seams).
struct PlaceholderScreen: View {
    let title: String
    let systemImage: String
    /// Which stage replaces this screen (shown on screen, so screenshots say who owns it).
    let owner: String
    /// UI-test identifier: the view gets `screen.<screenID>`.
    let screenID: String

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: Tokens.Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(theme.primary)
            Text(title)
                .pixlFont(.headlineSmall, weight: .bold)
                .foregroundStyle(theme.onSurface)
            Text(owner)
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
        }
        .padding(Tokens.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.\(screenID)")
    }
}
