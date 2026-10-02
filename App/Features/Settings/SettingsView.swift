import SwiftUI

/// Settings (Android `SettingsScreen`, Material 3 mode): the collapsing "Settings" header and one group of category
/// rows — the everyday categories, Accounts, then Developer Options and Device Capabilities, About last. Each row is
/// 88 pt: a 56 pt coloured circle with the category icon, the title (`titleMedium` semibold) and a two-line subtitle
/// (`bodyMedium`, 65 %). Rows are glass shapes 2 pt apart; the group's first row has 24 pt top corners, the last
/// 24 pt bottom corners, the rest 4 pt.
///
/// Dropped from Android: the "PixelPlayer Plus" card at the top (everything is unlocked on iOS).
struct SettingsView: View {
    @Environment(Router.self) private var router

    var body: some View {
        SettingsScaffold(title: L10n.commonSettings, screenID: "settings", spacing: 0) {
            SettingsGroup(outer: 24, inner: 4) {
                ForEach(SettingsMainEntry.ordered) { entry in
                    SettingsCategoryRow(entry: entry) { open(entry) }
                }
            }
            Spacer().frame(height: 32)
        }
    }

    private func open(_ entry: SettingsMainEntry) {
        switch entry {
        case .category(.equalizer): router.push(.equalizer)
        case .category(.deviceCapabilities): router.push(.deviceCapabilities)
        case .category(.about): router.push(.about)
        case .category(let category): router.push(.settingsCategory(category))
        case .accounts: router.push(.accounts)
        }
    }
}

/// One row of the main list: a category, or Accounts (not a category on Android either).
nonisolated enum SettingsMainEntry: Hashable, Identifiable, Sendable {
    case category(SettingsCategory)
    case accounts

    var id: String {
        switch self {
        case .category(let category): category.rawValue
        case .accounts: "accounts"
        }
    }

    /// Android order: everyday categories, Accounts, Developer Options, Device Capabilities, About.
    static let ordered: [SettingsMainEntry] = {
        let advanced: [SettingsCategory] = [.developer, .deviceCapabilities]
        let main = SettingsCategory.allCases.filter { $0 != .about && !advanced.contains($0) }
        return main.map(SettingsMainEntry.category) + [.accounts] + advanced.map(SettingsMainEntry.category)
            + [.category(.about)]
    }()

    /// SF Symbols for Android's category icons.
    var systemImage: String {
        switch self {
        case .accounts: "person.crop.circle.fill"
        case .category(let c):
            switch c {
            case .library: "music.note.square.stack.fill"
            case .appearance: "paintpalette.fill"
            case .playback: "music.note"
            case .equalizer: "waveform"
            case .behavior: "hand.tap"
            case .ai: "sparkles"
            case .backupRestore: "doc.badge.arrow.up"
            case .developer: "chevron.left.forwardslash.chevron.right"
            case .deviceCapabilities: "cpu"
            case .about: "info.circle.fill"
            }
        }
    }

    /// Android `getCategoryColors` / `getAccountsColors`: (circle, icon) ARGB for light and dark.
    func colors(dark: Bool) -> (UInt32, UInt32) {
        switch self {
        case .accounts: return dark ? (0xFF37474F, 0xFFBBD9E8) : (0xFFD6EAF5, 0xFF103548)
        case .category(let category):
            switch category {
            case .library: return dark ? (0xFF004A77, 0xFFC2E7FF) : (0xFFD7E3FF, 0xFF005AC1)
            case .appearance: return dark ? (0xFF7D5260, 0xFFFFD8E4) : (0xFFFFD8E4, 0xFF631835)
            case .playback: return dark ? (0xFF633B48, 0xFFFFD8EC) : (0xFFFFD8EC, 0xFF631B4B)
            case .behavior: return dark ? (0xFF3E4C63, 0xFFD7E3FF) : (0xFFD7E3FF, 0xFF253347)
            case .ai: return dark ? (0xFF004F58, 0xFF88FAFF) : (0xFFCCE8EA, 0xFF004F58)
            case .backupRestore: return dark ? (0xFF3B4869, 0xFFD9E2FF) : (0xFFD9E2FF, 0xFF27304E)
            case .developer: return dark ? (0xFF324F34, 0xFFCBEFD0) : (0xFFCBEFD0, 0xFF042106)
            case .equalizer: return dark ? (0xFF6E4E13, 0xFFFFDEAC) : (0xFFFFDEAC, 0xFF281900)
            case .deviceCapabilities: return dark ? (0xFF004D61, 0xFFACEFEE) : (0xFFACEFEE, 0xFF002022)
            case .about: return dark ? (0xFF3F474D, 0xFFDEE3EB) : (0xFFEFF1F7, 0xFF44474F)
            }
        }
    }
}

extension SettingsMainEntry {
    var title: String {
        switch self {
        case .accounts: L10n.settingsCategoryAccountsTitle
        case .category(let c): c.localizedTitle
        }
    }

    var subtitle: String {
        switch self {
        case .accounts: L10n.settingsCategoryAccountsSubtitle
        case .category(let c): c.localizedSubtitle
        }
    }
}

extension SettingsCategory {
    /// Android `settings_category_*_title` (localised).
    var localizedTitle: String {
        switch self {
        case .library: L10n.settingsCategoryMusicManagementTitle
        case .appearance: L10n.settingsCategoryAppearanceTitle
        case .playback: L10n.settingsCategoryPlaybackTitle
        case .equalizer: L10n.settingsCategoryEqualizerTitle
        case .behavior: L10n.settingsCategoryBehaviorTitle
        case .ai: L10n.settingsCategoryAiTitle
        case .backupRestore: L10n.settingsCategoryBackupTitle
        case .developer: L10n.settingsCategoryDeveloperTitle
        case .deviceCapabilities: L10n.settingsCategoryDeviceCapabilitiesTitle
        case .about: L10n.settingsCategoryAboutTitle
        }
    }

    var localizedSubtitle: String {
        switch self {
        case .library: L10n.settingsCategoryMusicManagementSubtitle
        case .appearance: L10n.settingsCategoryAppearanceSubtitle
        case .playback: L10n.settingsCategoryPlaybackSubtitle
        case .equalizer: L10n.settingsCategoryEqualizerSubtitle
        case .behavior: L10n.settingsCategoryBehaviorSubtitle
        case .ai: L10n.settingsCategoryAiSubtitle
        case .backupRestore: L10n.settingsCategoryBackupSubtitle
        case .developer: L10n.settingsCategoryDeveloperSubtitle
        case .deviceCapabilities: L10n.settingsCategoryDeviceCapabilitiesSubtitle
        case .about: L10n.settingsCategoryAboutSubtitle
        }
    }
}

/// Android `ExpressiveCategoryItem` / `ExpressiveNavigationItem`.
struct SettingsCategoryRow: View {
    let entry: SettingsMainEntry
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let colors = entry.colors(dark: theme.isDark)
        Button(action: action) {
            HStack(spacing: 0) {
                ZStack {
                    Circle().fill(Color(argb: colors.0))
                    Image(systemName: entry.systemImage)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color(argb: colors.1))
                }
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
                Spacer().frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.title)
                        .pixlFont(.titleMedium, weight: .semibold)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(entry.subtitle)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurface.opacity(0.65))
                        .lineLimit(2)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 8)
            }
            .padding(16)
            .frame(minHeight: 88)
        }
        .buttonStyle(.plain)
        .settingsRowGlass(interactive: true)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("settings.\(entry.id)")
    }
}

/// One settings category (Android `SettingsCategoryScreen`). Equalizer, Device Capabilities and About have their own
/// screens on Android too; their category routes show those screens.
struct SettingsCategoryView: View {
    let category: SettingsCategory

    var body: some View {
        switch category {
        case .equalizer: EqualizerView(screenID: "settingsCategory.equalizer")
        case .deviceCapabilities: DeviceCapabilitiesView(screenID: "settingsCategory.device_capabilities")
        case .about: AboutView(screenID: "settingsCategory.about")
        default:
            // Each category's section builds its own scaffold (`SettingsCategoryScaffold`), so its subsections are
            // the lazy stack's children rather than one VStack built whole in the push's first frame.
            SettingsCategoryContent(category: category)
        }
    }
}

/// A settings category's screen: the collapsing header and the category's subsections as direct children of the
/// scaffold's lazy stack, so only the visible ones are built when the screen is pushed. The section's toast overlays
/// the content as before (the same rect: the bottom of the content).
struct SettingsCategoryScaffold<Content: View>: View {
    let category: SettingsCategory
    var toast: Binding<String?>?
    @ViewBuilder let content: Content

    init(category: SettingsCategory, toast: Binding<String?>? = nil, @ViewBuilder content: () -> Content) {
        self.category = category
        self.toast = toast
        self.content = content()
    }

    var body: some View {
        let isLong = category.localizedTitle.count > 13
        SettingsScaffold(title: category.localizedTitle, screenID: "settingsCategory.\(category.rawValue)",
                         expandedHeight: isLong ? SettingsMetrics.headerExpandedLong : SettingsMetrics.headerExpanded,
                         titleMaxLines: isLong ? 2 : 1, contentToast: toast) {
            content
        }
    }
}

/// The body of a category, one view per category (each in its own file).
struct SettingsCategoryContent: View {
    let category: SettingsCategory

    var body: some View {
        switch category {
        case .library: LibrarySettingsSection()
        case .appearance: AppearanceSettingsSection()
        case .playback: PlaybackSettingsSection()
        case .behavior: BehaviorSettingsSection()
        case .ai: AISettingsSection()
        case .backupRestore: BackupSettingsSection()
        case .developer: DeveloperSettingsSection()
        case .equalizer, .deviceCapabilities, .about: EmptyView()
        }
    }
}
