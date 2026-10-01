import SwiftUI

/// PixlAudio's large screen title (Library's `TopAppBar`: "Library" 40 sp ExtraBold, +1 sp tracking, `primary`)
/// with its action circles on the trailing side. 64 pt tall; title starts 24 pt in, actions end 18 pt in.
struct LargeHeader<Actions: View>: View {
    let title: LocalizedStringKey
    var titleColor: Color?
    @ViewBuilder var actions: Actions

    @Environment(\.appTheme) private var theme

    init(_ title: LocalizedStringKey, titleColor: Color? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.titleColor = titleColor
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .pixlFont(.custom(size: 40, weight: .heavy, tracking: 1))
                .foregroundStyle(titleColor ?? theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Tokens.Spacing.s)
            HStack(spacing: Tokens.TopBar.actionSpacing) { actions }
        }
        .padding(.leading, Tokens.TopBar.titleLeading)
        .padding(.trailing, Tokens.TopBar.actionTrailing)
        .frame(height: Tokens.TopBar.height)
    }
}

extension LargeHeader where Actions == EmptyView {
    init(_ title: LocalizedStringKey, titleColor: Color? = nil) {
        self.init(title, titleColor: titleColor) { EmptyView() }
    }
}

/// A section title with an optional subtitle and trailing control (Home's "Made for your listening":
/// `headlineSmall` bold + `bodyMedium` in `onSurfaceVariant`, 20 pt side padding).
struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var trailing: Trailing

    @Environment(\.appTheme) private var theme

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .pixlFont(.headlineSmall, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, Tokens.Spacing.xl)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}
