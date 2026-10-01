import SwiftUI

/// Settings — placeholder until stage 7d ports PixlAudio's Settings (`SettingsScreen.kt`: the category list as
/// rounded groups). Every category and sub-screen is already routable so stages can link to them.
struct SettingsView: View {
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(spacing: Tokens.Spacing.s) {
                ForEach(SettingsCategory.allCases) { category in
                    row(category.title, systemImage: category.systemImage) {
                        router.push(.settingsCategory(category))
                    }
                    .accessibilityIdentifier("settings.\(category.rawValue)")
                }
                row("Accounts", systemImage: "person.crop.circle") { router.push(.accounts) }
                    .accessibilityIdentifier("settings.accounts")
                row("Diagnostics", systemImage: "stethoscope") { router.push(.diagnostics) }
                    .accessibilityIdentifier("settings.diagnostics")
                Text("Settings pages arrive in stage 7d · \(AppInfo.versionString)")
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.top, Tokens.Spacing.m)
            }
            .padding(.horizontal, Tokens.Spacing.l)
            .padding(.vertical, Tokens.Spacing.s)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .accessibilityIdentifier("screen.settings")
    }

    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.l) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(theme.primaryContainer))
                Text(title)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .padding(.horizontal, Tokens.Spacing.l)
            .padding(.vertical, Tokens.Spacing.m)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: RoundedRectangle(cornerRadius: Tokens.Radius.large, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(GlassTint.surface), interactive: true)
    }
}

/// One settings category (Android `SettingsCategoryScreen`) — stage 7d.
struct SettingsCategoryView: View {
    let category: SettingsCategory

    var body: some View {
        PlaceholderScreen(title: category.title, systemImage: category.systemImage,
                          owner: "Stage 7d — Settings, EQ, transitions, delimiters",
                          screenID: "settingsCategory.\(category.rawValue)")
    }
}
