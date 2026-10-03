import PixlBackup
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// First-run setup (Android `SetupScreen`): a pager with PixlAudio's bottom bar ("Let's Go!" / "Step n of m" and the
/// shape-changing next button). Android's steps mapped to iOS:
///
/// | Android | iOS |
/// |---|---|
/// | Welcome | Welcome (same) |
/// | Media permission (`READ_MEDIA_AUDIO`) | Music library access (`MPMediaLibrary`); not a gate — folders work without it |
/// | Notifications, Alarms, Battery optimisation | dropped (iOS needs none of them for playback or the sleep timer) |
/// | Backup restore | Backup restore — after the folders, because the backup's songs are matched against the library |
/// | Excluded folders | Music folders: add folders with the system picker (`LibraryImporting` bookmarks) |
/// | Theme, Library layout | same (`app_theme_mode`, `library_navigation_mode`) |
/// | Nav bar layout | dropped (the iOS shell has one bar style; nav-bar radius is Material-only) |
/// | Spotify link, Finish | same |
///
/// After a successful restore the pager jumps to Finish, as Android does. Finishing writes `initial_setup_done`.
struct SetupView: View {
    nonisolated enum Page: Int, CaseIterable, Sendable {
        case welcome, mediaPermission, musicFolders, backupRestore, theme, libraryLayout, spotify, finish
    }

    nonisolated enum MediaStatus: Sendable { case unknown, granted, denied }

    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(SettingsStore.self) private var settings
    @Environment(AccountsStore.self) private var accounts
    @Environment(LibraryStore.self) private var library
    @Environment(\.appTheme) private var theme
    @Environment(\.openURL) private var openURL

    @State private var page: Page = .welcome
    @State private var isForward = true
    @State private var mediaStatus: MediaStatus = .unknown
    @State private var folders: [String] = []
    @State private var showsFolderPicker = false
    @State private var showsBackupPicker = false
    @State private var isInspecting = false
    @State private var isScanning = false
    @State private var didScan = false
    @State private var restoreBackup: InspectedBackup?
    @State private var showsSpotify = false
    @State private var toast: String?
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                pageView(page)
                    .id(page)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                // Android's back handler steps back a page; swiping right does it here.
                if value.translation.width > 80, abs(value.translation.height) < 60, page.rawValue > 0 {
                    go(to: page.rawValue - 1)
                }
            })
            // VoiceOver can't drive the swipe: its escape gesture (two-finger Z) steps back a page.
            .accessibilityElement(children: .contain)
            .accessibilityAction(.escape) {
                if page.rawValue > 0 { go(to: page.rawValue - 1) }
            }
            SetupBottomBar(page: page.rawValue, pageCount: Page.allCases.count, onNext: next, onFinish: finish)
        }
        .background(theme.background.ignoresSafeArea())
        .accessibilityIdentifier("screen.setup")
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

    @ViewBuilder
    private func pageView(_ page: Page) -> some View {
        switch page {
        case .welcome:
            SetupWelcomePage()
        case .mediaPermission:
            SetupMediaPermissionPage(status: mediaStatus, onGrant: requestMediaAccess)
        case .musicFolders:
            // Each picker sits on its own page: SwiftUI honours one `fileImporter` per view.
            SetupMusicFoldersPage(folders: folders, onChoose: { showsFolderPicker = true }, onSkip: next)
                .fileImporter(isPresented: $showsFolderPicker, allowedContentTypes: [.folder],
                              allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { addFolders(urls) }
                }
        case .backupRestore:
            SetupBackupPage(isInspecting: isInspecting, isRestoring: restoreBackup != nil && env.backup.isBusy,
                            isScanning: isScanning,
                            onImport: { showsBackupPicker = true }, onSkip: next)
                .task { await scanBeforeRestore() }
                .fileImporter(isPresented: $showsBackupPicker, allowedContentTypes: UTType.backupImportTypes) { result in
                    if case .success(let url) = result { inspect(url) }
                }
        case .theme:
            SetupThemePage(selected: settings.appearance.appThemeMode) { mode in
                withAnimation(PixlMotion.state) { settings.appearance.appThemeMode = mode }
            }
        case .libraryLayout:
            SetupLibraryLayoutPage(isCompact: settings.appearance.libraryNavigationMode == "compact_pill") { compact in
                settings.appearance.libraryNavigationMode = compact ? "compact_pill" : "tab_row"
            }
        case .spotify:
            SetupSpotifyPage(isLoggedIn: isSpotifyLinked, onSignIn: { showsSpotify = true }, onSkip: next)
        case .finish:
            SetupFinishPage()
        }
    }

    private var pageTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: isForward ? .leading : .trailing).combined(with: .opacity))
    }

    private var isSpotifyLinked: Bool {
        if case .signedIn = accounts.spotify { return true }
        return false
    }

    /// Android's `RestoreCompleted` moves on to Finish; a failed restore stays on the backup page.
    private static func restoredSomething(_ report: BackupRestoreReport) -> Bool {
        if case .failed = report.outcome { return false }
        return !report.entries.isEmpty
    }

    // MARK: Navigation

    private func begin() {
        guard !started else { return }
        started = true
        page = Self.initialPage(for: env.launch.screen)
        guard !env.launch.isUITest else { return }
        mediaStatus = MediaLibraryImporter.isAuthorized ? .granted
            : (MediaLibraryImporter.canRequestAccess ? .unknown : .denied)
        Task {
            if let sources = try? await env.libraryImporter?.folderSources() { folders = sources.map(\.displayName) }
        }
    }

    /// UI tests open a page directly (`-screen setupTheme` …).
    static func initialPage(for screen: DemoScreen?) -> Page {
        switch screen {
        case .setupPermission: .mediaPermission
        case .setupFolders: .musicFolders
        case .setupBackup: .backupRestore
        case .setupTheme: .theme
        case .setupLibraryLayout: .libraryLayout
        case .setupSpotify: .spotify
        case .setupFinish: .finish
        default: .welcome
        }
    }

    private func next() { go(to: page.rawValue + 1) }

    private func go(to index: Int) {
        guard let target = Page(rawValue: min(max(index, 0), Page.allCases.count - 1)), target != page else { return }
        isForward = target.rawValue > page.rawValue
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { page = target }
    }

    /// Android `setSetupComplete` + `onSetupComplete`: never shown again; the library scan picks up new folders.
    private func finish() {
        settings.behavior.initialSetupDone = true
        if !didScan, !env.launch.isUITest, !folders.isEmpty || mediaStatus == .granted {
            let library = self.library
            Task { try? await library.refresh() }
        }
        router.dismissCover()
    }

    // MARK: Steps

    private func requestMediaAccess() {
        guard !env.launch.isUITest else { return }
        if mediaStatus == .denied {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            return
        }
        Task {
            let granted = await MediaLibraryImporter.requestAccess()
            withAnimation(PixlMotion.state) { mediaStatus = granted ? .granted : .denied }
            if granted {
                env.libraryAccessChanged()
                didScan = false
            }
        }
    }

    private func addFolders(_ urls: [URL]) {
        guard let importer = env.libraryImporter else {
            folders.append(contentsOf: urls.map(\.lastPathComponent))
            return
        }
        Task {
            for url in urls {
                do {
                    let source = try await importer.addFolder(url)
                    withAnimation(PixlMotion.state) { folders.append(source.displayName) }
                    didScan = false
                } catch {
                    toast = error.localizedDescription
                }
            }
        }
    }

    /// The backup's songs are matched against the library, so read it once before restoring.
    private func scanBeforeRestore() async {
        guard !didScan, !isScanning, !env.launch.isUITest, !folders.isEmpty || mediaStatus == .granted else { return }
        isScanning = true
        try? await library.refresh()
        isScanning = false
        didScan = true
    }

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
