import SwiftUI

/// Open source licences (Android `OpenSourceLicensesScreen`): a top bar with back and the "MIT-era notice" action,
/// then the licence list (Android `LibrariesContainer`: name and version, author, licence chips). The iOS app links
/// no third-party libraries, so the list names the open-source code ported into it; the notice opens the full
/// third-party notices (Apache-2.0 text and the preserved MIT notice) in a sheet.
struct OpenSourceLicensesView: View {
    @State private var showsNotices = false
    @Environment(\.appTheme) private var theme

    private struct Entry: Identifiable {
        let name: String
        let version: String
        let author: String
        let summary: String
        let licenses: [String]
        let url: String
        var id: String { name }
    }

    private let entries: [Entry] = [
        Entry(name: "material-color-utilities", version: "03336bf6de", author: "Google LLC",
              summary: String(localized: "licenses_entry_color_summary",
                              defaultValue: "Colour science behind album-art themes (HCT, quantizers, dynamic schemes), ported to Swift."),
              licenses: ["Apache-2.0"], url: "https://github.com/material-foundation/material-color-utilities"),
        Entry(name: "PixlAudio for Android", version: "Beta 2", author: "RedSn0w Studios by Hoa Vo and contributors",
              summary: String(localized: "licenses_entry_android_summary",
                              defaultValue: "Logic, layouts and constants ported from the Android app; contributions before 2026-05-12 are MIT-licensed."),
              licenses: ["MIT"], url: "https://github.com/RedSn0w1877/PixlAudio-iOS"),
    ]

    var body: some View {
        SettingsScaffold(title: L10n.openSourceLicensesScreenTitle, screenID: "openSourceLicenses",
                         expandedHeight: SettingsMetrics.headerExpandedLong, titleMaxLines: 2,
                         spacing: SettingsMetrics.rowSpacing) {
            Button { showsNotices = true } label: {
                Text(L10n.thirdPartyNoticesAction)
                    .pixlFont(.labelLarge)
                    .foregroundStyle(theme.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pixlGlass(in: Capsule(), tint: theme.surfaceContainerLow.opacity(GlassTint.surface), interactive: true)
            .padding(.trailing, 12)
            .accessibilityIdentifier("licenses.notices")
        } content: {
            SettingsGroup {
                ForEach(entries) { entry in
                    LicenseRow(name: entry.name, version: entry.version, author: entry.author, summary: entry.summary,
                               licenses: entry.licenses, url: entry.url)
                }
            }
        }
        .sheet(isPresented: $showsNotices) {
            ThirdPartyNoticesSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// One library row (Android `LibrariesContainer` item).
private struct LicenseRow: View {
    let name: String
    let version: String
    let author: String
    let summary: String
    let licenses: [String]
    let url: String

    @Environment(\.appTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { if let link = URL(string: url) { openURL(link) } } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: name)
                        .pixlFont(.titleMedium, weight: .semibold)
                        .foregroundStyle(theme.onSurface)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: version)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                Text(verbatim: author)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                Text(summary)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                HStack(spacing: 6) {
                    ForEach(licenses, id: \.self) { license in
                        Text(verbatim: license)
                            .pixlFont(.labelMedium)
                            .foregroundStyle(theme.onSecondaryContainer)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(theme.secondaryContainer, in: Capsule())
                    }
                }
                .padding(.top, 2)
            }
            .multilineTextAlignment(.leading)
            .padding(16)
        }
        .buttonStyle(.plain)
        .settingsRowGlass(interactive: true)
        .accessibilityIdentifier("licenses.\(name)")
    }
}

/// Android `ThirdPartyNoticesDialog`: the title with Close, a divider, the selectable notice text.
private struct ThirdPartyNoticesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.thirdPartyNoticesTitle)
                    .pixlFont(.titleLarge)
                    .foregroundStyle(theme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GlassPillButton(title: LocalizedStringKey(L10n.thirdPartyNoticesClose)) { dismiss() }
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
            Rectangle().fill(theme.outlineVariant).frame(height: 0.5)
            ScrollView {
                Text(ThirdPartyNotices.text)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .accessibilityIdentifier("licenses.noticesSheet")
    }
}
