import PixlBackup
import SwiftUI
import UniformTypeIdentifiers

/// First-run setup: a living glass backdrop, a segmented progress with a back button on top, one page at a time in
/// the middle, and one big glass button at the bottom. The steps:
///
/// | # | Page | What it does |
/// |---|---|---|
/// | 0 | Welcome | Logo, name, intro |
/// | 1 | Spotify | Sign in (the app's whole library comes from Spotify); skippable |
/// | 2 | Backup | Restore a PixlAudio backup; skippable, and a restore jumps straight to Finish |
/// | 3 | Theme | Dark, light or match the phone (`app_theme_mode`) |
/// | 4 | Library layout | Tab row or compact pill (`library_navigation_mode`) |
/// | 5 | Finish | Recap; the button writes `initial_setup_done` |
///
/// The app is Spotify-only, so there is no media-permission or music-folder page, and iOS needs none of Android's
/// notification, alarm or battery pages. Setup is resumable: the page is remembered, so killing the app mid-way
/// reopens it where it was (the theme and layout are saved the moment they are picked, and Spotify keeps its own
/// session). Finishing forgets the page and never shows setup again.
struct SetupView: View {
    nonisolated enum Page: Int, CaseIterable, Sendable {
        case welcome, spotify, backupRestore, theme, libraryLayout, finish
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(SettingsStore.self) private var settings
    @Environment(AccountsStore.self) private var accounts
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var page: Page = .welcome
    @State private var isForward = true
    @State private var showsBackupPicker = false
    @State private var isInspecting = false
    @State private var restoreBackup: InspectedBackup?
    @State private var showsSpotify = false
    @State private var toast: String?
    @State private var started = false

    /// UserDefaults key for the page to resume at.
    static let resumeKey = "setup_resume_page"

    var body: some View {
        ZStack {
            SetupBackdrop(page: page.rawValue)
            VStack(spacing: 0) {
                topBar
                pageArea
                bottomBar
            }
        }
        .accessibilityIdentifier("screen.setup")
        .pixlHaptic(stepFeedback, trigger: page)
        .pixlHaptic(.success, trigger: isSpotifyLinked)
        .fileImporter(isPresented: $showsBackupPicker, allowedContentTypes: UTType.backupImportTypes) { result in
            if case .success(let url) = result { inspect(url) }
        }
        .fullScreenCover(item: $restoreBackup) { backup in
            BackupImportFlowView(start: .inspected(backup)) { report in
                restoreBackup = nil
                if let report, Self.restoredSomething(report) { go(to: Page.finish.rawValue) }
            }
            .environment(\.appTheme, theme)
        }
        .sheet(isPresented: $showsSpotify) {
            NavigationStack { SpotifyDashboardView() }
                .environment(\.appTheme, theme)
        }
        .settingsToast($toast)
        .onAppear(perform: begin)
    }

    /// A tick on every step, a success buzz when the last page arrives.
    private var stepFeedback: SensoryFeedback {
        if page == .finish { return .success }
        return .selection
    }

    // MARK: Chrome

    /// Back on the left, the segmented progress in the middle (not on the welcome page), room to balance on the right.
    private var topBar: some View {
        ZStack {
            HStack {
                SetupBackButton { go(to: page.rawValue - 1) }
                    .opacity(page == .welcome ? 0 : 1)
                    .allowsHitTesting(page != .welcome)
                    .accessibilityHidden(page == .welcome)
                Spacer(minLength: 0)
            }
            SetupProgress(current: max(page.rawValue - 1, 0), count: Page.allCases.count - 1)
                .opacity(page == .welcome ? 0 : 1)
                .accessibilityHidden(page == .welcome)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .animation(reduceMotion ? nil : PixlMotion.state, value: page)
    }

    private var pageArea: some View {
        ZStack {
            pageView(page)
                .id(page)
                .transition(pageTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
            // Swiping right steps back a page.
            if value.translation.width > 80, abs(value.translation.height) < 60, page.rawValue > 0 {
                go(to: page.rawValue - 1)
            }
        })
        // VoiceOver can't drive the swipe: its escape gesture (two-finger Z) steps back a page.
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) {
            if page.rawValue > 0 { go(to: page.rawValue - 1) }
        }
    }

    /// The one big button. Where a page has its own action (sign in, import) this one is the plain "Skip for now".
    private var bottomBar: some View {
        let action = bottomAction
        return SetupFilledButton(title: action.title, systemImage: action.symbol, kind: action.kind,
                                 isEnabled: action.isEnabled, action: advance)
            .accessibilityIdentifier("setup.next")
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : PixlMotion.state, value: page)
    }

    private struct BottomAction {
        let title: String
        let symbol: String?
        let kind: SetupFilledButton.Kind
        var isEnabled = true
    }

    private var bottomAction: BottomAction {
        switch page {
        case .welcome:
            return BottomAction(title: L10n.setupLetsGo, symbol: "arrow.right", kind: .primary)
        case .spotify:
            if isSpotifyLinked {
                return BottomAction(title: L10n.setupContinue, symbol: "arrow.right", kind: .primary)
            }
            return BottomAction(title: L10n.setupSkipForNow, symbol: nil, kind: .plain)
        case .backupRestore:
            return BottomAction(title: L10n.setupSkipForNow, symbol: nil, kind: .plain, isEnabled: !isBackupBusy)
        case .theme, .libraryLayout:
            return BottomAction(title: L10n.setupContinue, symbol: "arrow.right", kind: .primary)
        case .finish:
            return BottomAction(title: L10n.setupStartListening, symbol: "play.fill", kind: .primary)
        }
    }

    @ViewBuilder
    private func pageView(_ page: Page) -> some View {
        switch page {
        case .welcome:
            SetupWelcomePage()
        case .spotify:
            SetupSpotifyPage(isLoggedIn: isSpotifyLinked, onSignIn: { showsSpotify = true })
        case .backupRestore:
            SetupBackupPage(isInspecting: isInspecting, isRestoring: restoreBackup != nil && env.backup.isBusy,
                            onImport: { showsBackupPicker = true })
        case .theme:
            SetupThemePage(selected: settings.appearance.appThemeMode) { mode in
                withAnimation(PixlMotion.state) { settings.appearance.appThemeMode = mode }
            }
        case .libraryLayout:
            SetupLibraryLayoutPage(isCompact: isCompactLibrary) { compact in
                settings.appearance.libraryNavigationMode = compact ? "compact_pill" : "tab_row"
            }
        case .finish:
            SetupFinishPage(isSpotifyLinked: isSpotifyLinked, themeTitle: themeTitle, layoutTitle: layoutTitle)
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isForward ? .leading : .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.94)))
    }

    // MARK: State

    private var isSpotifyLinked: Bool {
        if case .signedIn = accounts.spotify { return true }
        return false
    }

    private var isBackupBusy: Bool {
        isInspecting || (restoreBackup != nil && env.backup.isBusy)
    }

    private var isCompactLibrary: Bool {
        settings.appearance.libraryNavigationMode == "compact_pill"
    }

    private var themeTitle: String {
        switch settings.appearance.appThemeMode {
        case .dark: return L10n.setupThemeDarkTitle
        case .light: return L10n.setupThemeLightTitle
        default: return L10n.setupThemeFollowTitle
        }
    }

    private var layoutTitle: String {
        isCompactLibrary ? L10n.setupLayoutPill : L10n.setupLayoutTabs
    }

    /// A restore that brought something back moves on to Finish; a failed one stays on the backup page.
    private static func restoredSomething(_ report: BackupRestoreReport) -> Bool {
        if case .failed = report.outcome { return false }
        return !report.entries.isEmpty
    }

    // MARK: Navigation

    private func begin() {
        guard !started else { return }
        started = true
        if let screen = env.launch.screen {
            page = Self.initialPage(for: screen)
        } else {
            page = Self.resumePage(storedIndex: UserDefaults.standard.integer(forKey: Self.resumeKey))
        }
    }

    /// UI tests open a page directly (`-screen setupTheme` …).
    static func initialPage(for screen: DemoScreen?) -> Page {
        switch screen {
        case .setupBackup: .backupRestore
        case .setupTheme: .theme
        case .setupLibraryLayout: .libraryLayout
        case .setupSpotify: .spotify
        case .setupFinish: .finish
        default: .welcome
        }
    }

    /// The page to reopen at after the app was closed mid-setup (anything out of range starts over).
    static func resumePage(storedIndex: Int) -> Page {
        Page(rawValue: storedIndex) ?? .welcome
    }

    private func advance() {
        if page == .finish {
            finish()
        } else {
            go(to: page.rawValue + 1)
        }
    }

    private func go(to index: Int) {
        guard let target = Page(rawValue: min(max(index, 0), Page.allCases.count - 1)), target != page else { return }
        isForward = target.rawValue > page.rawValue
        let animation: Animation = reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86)
        withAnimation(animation) { page = target }
        if env.launch.screen == nil { UserDefaults.standard.set(target.rawValue, forKey: Self.resumeKey) }
    }

    /// Never shown again.
    private func finish() {
        UserDefaults.standard.removeObject(forKey: Self.resumeKey)
        settings.behavior.initialSetupDone = true
        router.dismissCover()
    }

    // MARK: Steps

    private func inspect(_ url: URL) {
        guard !isInspecting else { return }
        isInspecting = true
        Task {
            defer { isInspecting = false }
            do {
                restoreBackup = try await env.backup.inspect(url: url)
            } catch {
                toast = L10n.settingsBackupInvalidFormat(BackupService.message(of: error))
            }
        }
    }
}
