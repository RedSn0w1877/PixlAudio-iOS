import PixlModel
import SwiftUI

/// Settings (Android `SettingsScreen`, redesign 2 2026-11-25, mockup AndroidSettings). The header scrolls with the list
/// (no collapsing bar): 20 pt under the status bar a 48 pt row — Back as a 48 pt neutral glass circle, 12 pt,
/// "Settings" 36/44 bold — then blocks 14 pt apart in the 16 pt gutter: the Accounts card (72 pt, `primaryContainer`
/// glass, 28 pt corners, a 52 pt Cookie9 badge), "Listening" (Playback, Equalizer, Lyrics, Sing, Endless Listening,
/// Song Tap) and "App" (AI, Music management, Appearance, Behaviour, Backup, About, then the Developer mode switch and,
/// while it is on, Developer and Device capabilities). Rows are `RedesignGroupedRow`s (title only, 52 pt), badges in
/// each category's colour pair on shapes cycling Cookie9, Sunny, Flower, Clover4, SoftBurst, Cookie6.
///
/// Dropped from Android: the "PixelPlayer Plus" card at the top (everything is unlocked on iOS).
struct SettingsView: View {
    @Environment(Router.self) private var router
    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var experimental = settings.experimental
        let developerMode = experimental.developerMode
        let app = SettingsMainEntry.app
        let advanced = SettingsMainEntry.developerOnly
        let appTotal = app.count + 1 + (developerMode ? advanced.count : 0)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                header
                SettingsAccountsCard { router.push(.accounts) }
                VStack(spacing: 0) {
                    RedesignSectionLabel(LocalizedStringKey(L10n.settingsGroupListening))
                    GlassEffectContainer(spacing: 0) {
                        VStack(spacing: Redesign.rowGap) {
                            ForEach(Array(SettingsMainEntry.listening.enumerated()), id: \.element) { index, entry in
                                SettingsCategoryRow(entry: entry, badge: .cycled(index),
                                                    shape: groupedRowShape(index: index,
                                                                           count: SettingsMainEntry.listening.count)) {
                                    open(entry)
                                }
                            }
                        }
                    }
                }
                VStack(spacing: 0) {
                    RedesignSectionLabel(LocalizedStringKey(L10n.settingsGroupApp))
                    GlassEffectContainer(spacing: 0) {
                        VStack(spacing: Redesign.rowGap) {
                            ForEach(Array(app.enumerated()), id: \.element) { index, entry in
                                SettingsCategoryRow(entry: entry, badge: .cycled(index + 4),
                                                    shape: groupedRowShape(index: index, count: appTotal)) {
                                    open(entry)
                                }
                            }
                            developerModeRow(isOn: $experimental.developerMode,
                                             shape: groupedRowShape(index: app.count, count: appTotal))
                            if developerMode {
                                ForEach(Array(advanced.enumerated()), id: \.element) { index, entry in
                                    SettingsCategoryRow(entry: entry, badge: .cycled(index + 2),
                                                        shape: groupedRowShape(index: app.count + 1 + index,
                                                                               count: appTotal)) {
                                        open(entry)
                                    }
                                    .transition(.opacity)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Redesign.gutter)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .background(SettingsBackSwipeEnabler().frame(width: 0, height: 0))
        .animation(PixlMotion.state, value: developerMode)
        .accessibilityIdentifier("screen.settings")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(theme.onSurface)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pixlGlass(in: Circle(), tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), interactive: true)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("settings.back")
            RedesignScreenTitle(LocalizedStringKey(L10n.commonSettings))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 48)
    }

    /// The Developer mode switch closing the App group (Clover4 badge in Developer's colours). The switch is the system's.
    private func developerModeRow(isOn: Binding<Bool>, shape: UnevenRoundedRectangle) -> some View {
        let colors = SettingsMainEntry.category(.developer).colors(dark: theme.isDark)
        return RedesignGroupedRow(title: L10n.settingsMainDeveloperModeTitle, shape: shape,
                                  action: { withAnimation(PixlMotion.state) { isOn.wrappedValue.toggle() } }) {
            ShapeBadge(systemImage: "chevron.left.forwardslash.chevron.right", shape: .clover4,
                       container: Color(argb: colors.0), content: Color(argb: colors.1))
        } trailing: {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(theme.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityIdentifier("settings.switch.\(L10n.settingsMainDeveloperModeTitle)")
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

/// The Accounts card at the top of Settings (redesign 2, Android `SettingsAccountsCard`): 72 pt, `primaryContainer`
/// glass, 28 pt corners, 10 / 12 pt padding; a 52 pt Cookie9 badge (`onPrimaryContainer` fill, the 26 dp account icon
/// in `primaryContainer`), 14 pt, "Accounts" 18/24 medium over its line 13/18, a chevron.
struct SettingsAccountsCard: View {
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        Button(action: action) {
            HStack(spacing: 14) {
                ShapeBadge(systemImage: "person.crop.circle", shape: .cookie9, container: theme.onPrimaryContainer,
                           content: theme.primaryContainer, size: 52, iconSize: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.settingsCategoryAccountsTitle)
                        .pixlFont(.custom(size: 18, weight: .medium, lineHeight: 24))
                        .lineLimit(1)
                    Text(L10n.settingsMainAccountsSubtitle)
                        .pixlFont(.redesignRowSubtitle)
                        .lineLimit(1)
                }
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.onPrimaryContainer)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 72)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: theme.primaryContainer.opacity(GlassTint.prominent), interactive: true)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("settings.accounts")
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

    /// The everyday rows, top to bottom (redesign 2): Accounts (the card), the Listening group, then the App group.
    static var everyday: [SettingsMainEntry] { [.accounts] + listening + app }

    /// Redesign 2: the "Listening" group (Android `SettingsListeningCategories`).
    static let listening: [SettingsMainEntry] = [
        .category(.playback), .category(.equalizer), .category(.lyrics), .category(.sing), .category(.endless),
        .category(.songTap),
    ]

    /// Redesign 2: the "App" group, before the Developer mode switch.
    static let app: [SettingsMainEntry] = [
        .category(.ai), .category(.library), .category(.appearance), .category(.behavior), .category(.backupRestore),
        .category(.about),
    ]

    /// The rows only developer mode shows, under its switch.
    static let developerOnly: [SettingsMainEntry] = [.category(.developer), .category(.deviceCapabilities)]

    /// Every row the list shows, in order (the switch sits between the two blocks).
    static func ordered(developerMode: Bool) -> [SettingsMainEntry] {
        developerMode ? everyday + developerOnly : everyday
    }

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
            case .lyrics: "quote.bubble.fill"
            case .sing: "music.mic"
            case .songTap: "iphone.radiowaves.left.and.right"
            case .behavior: "hand.tap"
            case .ai: "sparkles"
            case .endless: "infinity"
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
            case .lyrics: return dark ? (0xFF4A4458, 0xFFE8DEF8) : (0xFFE8DEF8, 0xFF1D192B)
            case .sing: return dark ? (0xFF5E3A22, 0xFFFFDBC9) : (0xFFFFDBC9, 0xFF3A1900)
            case .songTap: return dark ? (0xFF3A4A5E, 0xFFD6E4FF) : (0xFFD6E4FF, 0xFF0F2B4A)
            case .behavior: return dark ? (0xFF3E4C63, 0xFFD7E3FF) : (0xFFD7E3FF, 0xFF253347)
            case .ai: return dark ? (0xFF004F58, 0xFF88FAFF) : (0xFFCCE8EA, 0xFF004F58)
            case .endless: return dark ? (0xFF1F4D45, 0xFFBFF2E6) : (0xFFBFF2E6, 0xFF00201B)
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
        case .accounts: L10n.settingsMainAccountsSubtitle
        case .category(let c): c.localizedSubtitle
        }
    }
}

extension SettingsCategory {
    /// Android `settings_category_*_title` (localised); the plain-English names of 2026-10-22.
    var localizedTitle: String {
        switch self {
        case .library: L10n.settingsMainLibraryTitle
        case .appearance: L10n.settingsCategoryAppearanceTitle
        case .playback: L10n.settingsCategoryPlaybackTitle
        case .equalizer: L10n.settingsCategoryEqualizerTitle
        case .lyrics: L10n.settingsMainLyricsTitle
        case .sing: L10n.settingsMainSingTitle
        case .songTap: SongTapStrings.settingsTitle
        case .behavior: L10n.settingsMainBehaviorTitle
        case .ai: L10n.settingsCategoryAiTitle
        case .endless: EndlessStrings.settingsTitle
        case .backupRestore: L10n.settingsCategoryBackupTitle
        case .developer: L10n.settingsMainDeveloperTitle
        case .deviceCapabilities: L10n.settingsMainDeviceCapabilitiesTitle
        case .about: L10n.settingsCategoryAboutTitle
        }
    }

    var localizedSubtitle: String {
        switch self {
        case .library: L10n.settingsMainLibrarySubtitle
        case .appearance: L10n.settingsMainAppearanceSubtitle
        case .playback: L10n.settingsMainPlaybackSubtitle
        case .equalizer: L10n.settingsMainEqualizerSubtitle
        case .lyrics: L10n.settingsMainLyricsSubtitle
        case .sing: L10n.settingsMainSingSubtitle
        case .songTap: SongTapStrings.settingsSubtitle
        case .behavior: L10n.settingsMainBehaviorSubtitle
        case .ai: L10n.settingsMainAiSubtitle
        case .endless: EndlessStrings.settingsSubtitle
        case .backupRestore: L10n.settingsMainBackupSubtitle
        case .developer: L10n.settingsMainDeveloperSubtitle
        case .deviceCapabilities: L10n.settingsMainDeviceCapabilitiesSubtitle
        case .about: L10n.settingsMainAboutSubtitle
        }
    }
}

/// One category row of the main list (redesign 2, Android `SettingsCategoryRow`): a `RedesignGroupedRow` with the
/// category's 40 pt shape badge (its colour pair) and the title only.
struct SettingsCategoryRow: View {
    let entry: SettingsMainEntry
    let badge: BadgeShapeKind
    let shape: UnevenRoundedRectangle
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let colors = entry.colors(dark: theme.isDark)
        RedesignGroupedRow(title: entry.title, shape: shape, action: action) {
            ShapeBadge(systemImage: entry.systemImage, shape: badge, container: Color(argb: colors.0),
                       content: Color(argb: colors.1))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("settings.\(entry.id)")
    }
}

/// One settings category (Android `SettingsCategoryScreen`). Equalizer, Device capabilities and About have their own
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
        case .lyrics: LyricsSettingsSection()
        case .sing: SingSettingsSection()
        case .songTap: SongTapSettingsSection()
        case .behavior: BehaviorSettingsSection()
        case .ai: AISettingsSection()
        case .endless: EndlessSettingsSection()
        case .backupRestore: BackupSettingsSection()
        case .developer: DeveloperSettingsSection()
        case .equalizer, .deviceCapabilities, .about: EmptyView()
        }
    }
}
