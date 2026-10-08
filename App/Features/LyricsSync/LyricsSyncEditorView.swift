import PixlLyrics
import PixlModel
import SwiftUI

/// A request to open the sync editor. The screen that opens it presents it from inside its own presentation (the
/// lyrics screen's cover, Edit song's cover) with `fullScreenCover(item:)`, so closing the editor returns to that
/// screen instead of swapping the app's one root cover (which tore the lyrics screen down, and with it the editor).
/// The id is the song: a second request for the same song while the editor shows changes nothing.
nonisolated struct LyricsSyncRequest: Identifiable, Hashable, Sendable {
    let songId: String
    var entry: SyncEntry = .auto

    var id: String { songId }
}

/// The "sync it yourself" editor (Android `LyricsSyncEditorOverlay` + the sync screens): a full-screen cover with the
/// lyrics screen's animated artwork behind it and a light scrim, switching between Intro → Words → Tap → Preview (plus
/// the resume, manage, loading and error screens). It keeps the screen on, pauses when the app leaves the foreground,
/// and hands the player back as it was on close (`LyricsSyncSession.close`).
///
/// Whoever presents it owns the presentation: `onClose` dismisses it (the lyrics screen and Edit song clear their
/// `LyricsSyncRequest`; the `AppCover.lyricsSync` route, kept for `-screen lyricsSync` UI tests, dismisses the root
/// cover). The view only calls `onClose` when the session ends while it is on screen; its own disappearance closes
/// the session with `.viewGone`, which never navigates.
struct LyricsSyncEditorView: View {
    let songId: String
    var entry: SyncEntry = .auto
    let onClose: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var session: LyricsSyncSession?
    @State private var brightArt = false
    /// The last screen shown, kept while the cover animates away after the session closed.
    @State private var shownPhase: SyncPhase = .loading

    /// Always dark, like the lyrics screen: the album scheme's dark roles whatever the system appearance.
    private var theme: ThemeColors { themeStore.colors(for: .dark).player }

    private var isUITest: Bool { LaunchConfiguration.current.isUITest }

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
                    // Over the bottom of the tap pad: only Undo takes touches, everything else lets taps through to
                    // the pad (Android: only the Undo box is clickable; owner decision 2026-10-07).
                    SyncNoticePill(notice: notice, palette: palette, onUndo: session.undoRemoval,
                                   onTimeout: { session.dismissNotice(id: $0) })
                        .padding(.horizontal, 24)
                        .padding(.bottom, 92)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(notice.canUndo)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: session?.notice)
        .background(Color.black.ignoresSafeArea())
        .alwaysDarkTheme(themeStore)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.lyricsSync")
        .onAppear(perform: start)
        .onDisappear {
            // Teardown only: restore the player, keep the taps. Never navigate from here (`.viewGone`); a later
            // appearance starts a fresh session.
            session?.close(.viewGone)
            session = nil
            ScreenAwake.set(false, for: .lyricsSync)
        }
        .onChange(of: session?.phase) { _, phase in
            // Keep drawing the last screen while the cover leaves.
            if let phase, phase != .closed { shownPhase = phase }
        }
        .onChange(of: playback.isPlaying) { _, playing in session?.playingChanged(playing) }
        .onChange(of: playback.current?.id) { _, id in session?.currentSongChanged(to: id) }
        // `remoteOutputName`, not `isRemoteActive`: the latter reads an unobserved weak reference.
        .onChange(of: playback.remoteOutputName) { _, name in
            if name != nil { session?.remoteOutputAttached() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session?.onHostStopped() }
            // Claimed again on coming back, as the lyrics screen does (the docs don't say the flag survives the
            // background); opened from Edit song there is no lyrics screen underneath to do it.
            if phase == .active { ScreenAwake.set(true, for: .lyricsSync) }
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

    /// UI tests keep drafts in the temporary directory, which outlives the app from one test to the next: a test that
    /// leaves taps behind ("Leave without saving?") turned the next test's intro into "You synced 3 of 128 words last
    /// time" (CI, 2026-10-07). Each launch starts without them; within a launch they stay (leave, reopen, resume).
    private static var uiTestDraftsCleared = false

    private static func clearUITestDraftsOnce(_ directory: URL) {
        guard !uiTestDraftsCleared else { return }
        uiTestDraftsCleared = true
        try? FileManager.default.removeItem(at: directory)
    }

    private func start() {
        guard session == nil else { return }
        ScreenAwake.set(true, for: .lyricsSync)

        let fileManager = FileManager.default
        let draftsDirectory: URL
        if isUITest {
            draftsDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("uitest-" + LyricsSyncDraftStore.directoryName, isDirectory: true)
            Self.clearUITestDraftsOnce(draftsDirectory)
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
        // Runs once, and only for a close while the editor is on screen (never for `.viewGone`).
        created.onClosed = onClose
        session = created
        if isUITest, let step = LyricsSyncLaunchOptions.current.step, let song = playback.current {
            created.applyDemo(LyricsSyncDemoState.make(step, song: song))
        } else {
            created.open(songId: songId, entry: entry)
        }
        shownPhase = created.phase == .closed ? .loading : created.phase
    }
}
