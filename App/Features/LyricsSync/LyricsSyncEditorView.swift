import PixlLyrics
import PixlModel
import SwiftUI
import UIKit

/// The "sync it yourself" editor (Android `LyricsSyncEditorOverlay` + the sync screens): a full-screen cover with the
/// lyrics screen's animated artwork behind it and a light scrim, switching between Intro → Words → Tap → Preview (plus
/// the resume, manage, loading and error screens). It keeps the screen on, pauses when the app leaves the foreground,
/// and hands the player back as it was on close (`LyricsSyncSession.close`).
struct LyricsSyncEditorView: View {
    let songId: String

    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(PlaybackStore.self) private var playback
    @Environment(\.playerTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    @State private var session: LyricsSyncSession?
    @State private var brightArt = false
    /// The last screen shown, kept while the cover animates away after the session closed.
    @State private var shownPhase: SyncPhase = .loading

    private var isUITest: Bool { LaunchConfiguration.current.isUITest }

    // MARK: Opening

    /// What the next presentation should do (set by `open`; the route carries only the song id).
    private static var pendingEntry: SyncEntry = .auto
    private static var pendingReturnToLyrics = false
    private static var returnToLyrics = false

    /// Opens the editor for a song: from the lyrics screen it returns there when it closes (Android: the editor is a
    /// layer over the lyrics sheet); "Change the words" / "Fix timing" pass their entry.
    static func open(songId: String, router: Router, entry: SyncEntry = .auto, fromLyrics: Bool = false) {
        pendingEntry = entry
        pendingReturnToLyrics = fromLyrics
        router.present(AppCover.lyricsSync(songId: songId))
    }

    // MARK: Body

    var body: some View {
        let palette = SyncEditorPalette(theme: theme, brightArt: brightArt)
        ZStack {
            LyricsArtworkBackground(
                artSource: (session?.song ?? playback.current).flatMap(ArtworkSource.init(song:)),
                fallbackTheme: theme,
                paused: scenePhase != .active || ProcessInfo.processInfo.isLowPowerModeEnabled
                    || (isUITest && session?.frozenPositionMs != nil),
                deterministic: isUITest,
                onBrightArtChange: { brightArt = $0 })
                .ignoresSafeArea()
            // A light scrim keeps white controls legible over any artwork.
            Color.black.opacity(shownPhase == .preview ? 0.08 : 0.24)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // The screens keep to the safe area (status bar, home indicator and the keyboard on the words screen).
            if let session {
                screen(for: shownPhase, session: session, palette: palette)
                    .id(Self.screenKey(shownPhase))
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.06)),
                                            removal: .opacity.animation(.easeIn(duration: 0.14))))

                if let notice = session.notice {
                    SyncNoticePill(notice: notice, palette: palette, onUndo: session.undoRemoval,
                                   onTimeout: { session.dismissNotice(id: $0) })
                        .padding(.horizontal, 24)
                        .padding(.bottom, 92)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: session?.notice)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.lyricsSync")
        .onAppear(perform: start)
        .onDisappear {
            session?.close()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: session?.phase) { _, phase in
            // Keep drawing the last screen while the cover leaves.
            if let phase, phase != .closed { shownPhase = phase }
        }
        .onChange(of: playback.isPlaying) { _, playing in session?.playingChanged(playing) }
        .onChange(of: playback.current?.id) { _, id in session?.currentSongChanged(to: id) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session?.onHostStopped() }
        }
        .alert(SyncStrings.leaveTitle, isPresented: dialogBinding(.leave)) {
            Button(SyncStrings.leave, role: .destructive) { session?.confirmLeave() }
            Button(SyncStrings.stay, role: .cancel) { session?.dismissDialog() }
        } message: {
            Text(SyncStrings.leaveBody)
        }
        .alert(SyncStrings.songChangedTitle, isPresented: dialogBinding(.songChanged)) {
            Button(SyncStrings.ok) { session?.dismissDialog() }
        } message: {
            Text(SyncStrings.songChangedBody)
        }
        .alert(SyncStrings.endedEarly(session?.endedEarlyWords ?? 0), isPresented: dialogBinding(.endedEarly)) {
            Button(SyncStrings.keepGoing) { session?.endedKeepGoing() }
            Button(SyncStrings.timeRest) { session?.endedTimeRest() }
        }
        .alert(SyncStrings.saveFailed, isPresented: dialogBinding(.saveFailed)) {
            Button(SyncStrings.tryAgain) {
                session?.dismissDialog()
                session?.save()
            }
            Button(SyncStrings.cancel, role: .cancel) { session?.dismissDialog() }
        }
    }

    @ViewBuilder
    private func screen(for phase: SyncPhase, session: LyricsSyncSession, palette: SyncEditorPalette) -> some View {
        switch phase {
        case .closed, .loading: SyncLoadingScreen()
        case .resumePrompt(let tapped, let total):
            SyncResumeScreen(tapped: tapped, total: total, session: session, palette: palette)
        case .needWords: SyncWordsEntryScreen(session: session, palette: palette)
        case .intro: SyncIntroScreen(session: session, palette: palette)
        case .tapping, .fixLine: SyncTapScreen(session: session, palette: palette)
        case .preview: SyncPreviewScreen(session: session, palette: palette, brightArt: brightArt)
        case .manage: SyncManageScreen(session: session, palette: palette)
        case .error(let message): SyncErrorScreen(message: message, session: session, palette: palette)
        }
    }

    private static func screenKey(_ phase: SyncPhase) -> String {
        switch phase {
        case .closed, .loading: "loading"
        case .resumePrompt: "resume"
        case .needWords: "words"
        case .intro: "intro"
        case .tapping, .fixLine: "tap"
        case .preview: "preview"
        case .manage: "manage"
        case .error: "error"
        }
    }

    private func dialogBinding(_ dialog: SyncDialog) -> Binding<Bool> {
        Binding(get: { session?.dialog == dialog },
                set: { shown in if !shown, session?.dialog == dialog { session?.dialog = .none } })
    }

    // MARK: Session

    private func start() {
        guard session == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        let entry = Self.pendingEntry
        Self.returnToLyrics = Self.pendingReturnToLyrics
        Self.pendingEntry = .auto
        Self.pendingReturnToLyrics = false

        let fileManager = FileManager.default
        let draftsDirectory: URL
        if isUITest {
            draftsDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("uitest-" + LyricsSyncDraftStore.directoryName, isDirectory: true)
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            draftsDirectory = support.appendingPathComponent(LyricsSyncDraftStore.directoryName, isDirectory: true)
        }
        let library = env.library
        let created = LyricsSyncSession(
            player: LyricsSyncPlayer(playback: playback, engine: env.playbackServices?.engine,
                                     instrumental: env.tais.instrumental),
            settings: env.settings, lyricsStore: env.lyrics, lyricsController: env.lyricsController,
            draftStore: LyricsSyncDraftStore(directory: draftsDirectory),
            preferences: LyricsSyncPreferences(isUITest: isUITest), isUITest: isUITest,
            songLookup: { library.song(id: $0) })
        let router = self.router
        created.onClosed = {
            if Self.returnToLyrics {
                Self.returnToLyrics = false
                router.present(AppCover.lyrics)
            } else {
                router.dismissCover()
            }
        }
        session = created
        if isUITest, let step = LyricsSyncLaunchOptions.current.step, let song = playback.current {
            created.applyDemo(LyricsSyncDemoState.make(step, song: song))
        } else {
            created.open(songId: songId, entry: entry)
        }
        shownPhase = created.phase == .closed ? .loading : created.phase
    }
}
