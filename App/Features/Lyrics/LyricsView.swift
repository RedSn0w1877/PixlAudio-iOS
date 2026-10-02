import PixlLyrics
import PixlModel
import SwiftUI
import Translation
import UIKit
import UniformTypeIdentifiers

/// The karaoke lyrics screen (Android `LyricsSheet` with `KaraokeLyricsView`): the animated artwork background, the
/// karaoke lines (or plain lyrics, or the loading / no-lyrics state), the track pill on top, and the control cluster
/// at the bottom (play/pause, seek bar, back · Synced · Static · more) that hides in immersive mode. Swipe sideways
/// for the previous / next song. Always dark.
struct LyricsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(PlaybackStore.self) private var playback
    @Environment(LyricsStore.self) private var lyricsStore
    @Environment(SettingsStore.self) private var settings
    @Environment(\.playerTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var driver = LyricsDriver()
    @State private var seekPreview = LyricsSeekPreview()
    @State private var swipe = LyricsSwipeState()
    @State private var interaction = LyricsInteractionClock()
    @State private var brightArt = false
    @State private var syncedOverride: Bool?
    @State private var overrideSongId: String?
    @State private var immersive = LyricsLaunchOptions.current.immersive && LaunchConfiguration.current.isUITest
    @State private var immersiveTemporarilyDisabled = false
    @State private var controlsHeight: CGFloat = 0
    @State private var showSyncControls = false
    @State private var showMoreSheet = false
    @State private var showFetchDialog = false
    @State private var showSaveDialog = false
    @State private var showImporter = false
    @State private var exportDocument: LyricsTextDocument?
    @State private var syncChipDismissedFor: String?
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationLines: [String] = []
    @State private var translationSongId: String?
    @State private var shownPrepared: PreparedLyrics?
    @State private var shownPreparedSong: String?

    private var launch: LyricsLaunchOptions { LyricsLaunchOptions.current }
    private var isUITest: Bool { LaunchConfiguration.current.isUITest }
    private var controller: LyricsController { env.lyricsController }
    private var song: Song? { playback.current }
    private var lyrics: Lyrics? {
        guard let song, case .loaded(let id, let lyrics, _) = lyricsStore.state, id == song.id else { return nil }
        return lyrics
    }

    private var highContrast: Bool { contrast == .increased || (isUITest && launch.highContrast) }

    /// true = karaoke, false = plain, nil = nothing to show (loading / none). Android `showSyncedLyrics`.
    private var showSyncedLyrics: Bool? {
        let hasSynced = !(lyrics?.synced ?? []).isEmpty
        let hasPlain = !(lyrics?.plain ?? []).isEmpty
        if let syncedOverride, overrideSongId == song?.id {
            if syncedOverride && hasSynced { return true }
            if !syncedOverride && (hasPlain || hasSynced) { return false }
        }
        if hasSynced { return true }
        if hasPlain { return false }
        return nil
    }

    private var lacksWordTiming: Bool {
        guard let lyrics else { return false }
        return lyrics.document?.metadata.source != LyricsRepositoryLogic.userSource
            && !(lyrics.synced ?? []).contains { !($0.words ?? []).isEmpty }
            && !(lyrics.document?.lines ?? []).contains { !$0.syllables.isEmpty }
            && (!(lyrics.synced ?? []).isEmpty || !(lyrics.plain ?? []).isEmpty)
    }

    private var showSyncChip: Bool {
        guard let song else { return false }
        return syncChipDismissedFor != song.id && lacksWordTiming
    }

    private var immersiveActive: Bool {
        settings.lyrics.immersiveLyricsEnabled && showSyncedLyrics == true && !immersiveTemporarilyDisabled
    }

    private var appearance: KaraokeLyricsAppearance {
        let prefs = LyricsAppearancePrefs(
            alignment: controller.preferences.alignment,
            showTranslation: controller.preferences.showTranslation,
            showRomanization: controller.preferences.showRomanization,
            animatedBlurEnabled: settings.lyrics.animatedBlurEnabled,
            disableBlurAllOver: controller.preferences.disableBlurAllOver,
            blurStrength: Float(settings.lyrics.animatedBlurStrength),
            highContrast: highContrast)
        return prefs.toAppearance(textSize: nil, brightArt: brightArt)
    }

    var body: some View {
        let chrome = LyricsChromeColors(theme: theme, highContrast: highContrast)
        GeometryReader { geometry in
            let safeTop = geometry.safeAreaInsets.top
            let safeBottom = geometry.safeAreaInsets.bottom
            let topChrome = safeTop + LyricsChromeMetrics.headerInset + (showSyncChip ? LyricsChromeMetrics.syncChipInset : 0)
            let controlsVisible = !immersive
            let showButtonArea = safeBottom + LyricsChromeMetrics.showControlsBottomGap + LyricsChromeMetrics.showControlsSize
            let bottomChrome = controlsVisible ? controlsHeight : showButtonArea

            ZStack {
                LyricsArtworkBackground(
                    artSource: song.flatMap(ArtworkSource.init(song:)),
                    overrideImage: isUITest && launch.brightArt ? LyricsDemoArt.bright : nil,
                    fallbackTheme: theme,
                    paused: scenePhase != .active || ProcessInfo.processInfo.isLowPowerModeEnabled
                        || (isUITest && launch.freezeMs != nil),
                    deterministic: isUITest,
                    onBrightArtChange: { brightArt = $0 })

                // A soft scrim grounds the control cluster over bright or busy art.
                LinearGradient(colors: [.clear, .black.opacity(LyricsChromeMetrics.scrimAlpha)], startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: max(controlsHeight + LyricsChromeMetrics.scrimExtra, 1))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(false)

                lyricsContent(topChrome: topChrome, bottomChrome: bottomChrome)

                header(chrome: chrome, safeTop: safeTop)

                controls(chrome: chrome, safeBottom: safeBottom, visible: controlsVisible)

                if immersive {
                    LyricsShowControlsButton(chrome: chrome) { resetImmersive() }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, safeBottom + LyricsChromeMetrics.showControlsBottomGap)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }

                LyricsSwipeOverlay(swipe: swipe, chrome: chrome)

                if showFetchDialog {
                    FetchLyricsDialog(
                        state: controller.searchState, song: song,
                        onSearch: { force in if let song { controller.searchOnline(song: song, forcePick: force) } },
                        onPick: { result in if let song { controller.pick(result, song: song) } },
                        onManualSearch: { title, artist in controller.manualSearch(title: title, artist: artist) },
                        onImport: { showImporter = true },
                        onDismiss: closeFetchDialog)
                        .transition(.opacity)
                }

                if let message = controller.message {
                    LyricsToast(text: message)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, safeTop + 90)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(2.5))
                            withAnimation { controller.message = nil }
                        }
                }
            }
            .ignoresSafeArea()
            .simultaneousGesture(swipeGesture)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("screen.lyrics")
        .onAppear(perform: startDriver)
        .onDisappear(perform: stopDriver)
        .task(id: song?.id) {
            controller.ensureLoaded(for: song)
            if overrideSongId != song?.id { syncedOverride = nil }
        }
        .onChange(of: controller.prepared, initial: true) { _, _ in updateShownPrepared() }
        .onChange(of: controller.preparedSongId) { _, _ in updateShownPrepared() }
        .onChange(of: playback.isPlaying, initial: true) { _, playing in driver.setPlaying(playing) }
        .onChange(of: lyricsStore.offsetMs, initial: true) { _, ms in driver.offsetMs = Int64(ms) }
        .onChange(of: controller.searchState) { _, state in
            if state == .success { closeFetchDialog() }
        }
        .onChange(of: controller.preferences.keepScreenOn) { _, on in
            UIApplication.shared.isIdleTimerDisabled = on
        }
        .onChange(of: scenePhase) { _, phase in
            // Android turns keep-screen-on off when the screen goes off or the app stops.
            if phase == .background && controller.preferences.keepScreenOn { controller.preferences.keepScreenOn = false }
        }
        .task(id: ImmersiveKey(active: immersiveActive, immersive: immersive)) { await runImmersiveTimer() }
        .animation(.spring(response: 0.31, dampingFraction: 1), value: immersive)
        .animation(.easeInOut(duration: 0.25), value: showFetchDialog)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: controller.message)
        .sheet(isPresented: $showMoreSheet) { moreSheet }
        .alert("Save Lyrics", isPresented: $showSaveDialog) {
            if !(lyrics?.synced ?? []).isEmpty {
                Button("Synced (with timestamps)") { export(synced: true) }
            }
            if !(lyrics?.plain ?? []).isEmpty {
                Button("Plain (text only)") { export(synced: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose which version to save:")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: LyricsTextDocument.importTypes) { result in
            if case .success(let url) = result, let song { controller.importFile(url, song: song) }
        }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .plainText,
                      defaultFilename: song.map { "\($0.displayArtist) - \($0.title).lrc" } ?? "lyrics.lrc") { result in
            if case .success = result { controller.message = "Lyrics file saved" }
        }
        .translationTask(translationConfig) { session in
            // The session is not Sendable: it is only ever used inside LyricsTranslator (one @concurrent
            // call, awaited here, never shared), so it is handed over unchecked; plain values come back.
            nonisolated(unsafe) let session = session
            let songId = translationSongId
            let map = await LyricsTranslator.translate(lines: translationLines, session: session)
            finishTranslation(map, songId: songId)
        }
    }

    // MARK: Lyrics content

    @ViewBuilder
    private func lyricsContent(topChrome: CGFloat, bottomChrome: CGFloat) -> some View {
        switch showSyncedLyrics {
        case .some(true):
            if let prepared = shownPrepared {
                KaraokeLyricsView(
                    prepared: prepared, songKey: shownPreparedSong, driver: driver, appearance: appearance,
                    reducedMotion: reduceMotion, topInset: topChrome, topFadeLength: LyricsChromeMetrics.topFade,
                    bottomInset: bottomChrome, bottomFadeLength: LyricsChromeMetrics.bottomFade,
                    footer: footerText,
                    onSeekLine: { line in
                        playback.seek(toMs: LyricsSheetLogic.resolveSeekPositionMs(lineTimeMs: line.startMs,
                                                                                    lyricsSyncOffsetMs: lyricsStore.offsetMs))
                        resetImmersive()
                    },
                    onInteraction: { resetImmersive() })
                    .transition(.opacity)
            }
        case .some(false):
            PlainLyricsList(
                lines: plainLines, alignment: controller.preferences.alignment,
                showTranslation: controller.hasTranslatedLyrics ? controller.preferences.showTranslation : true,
                showRomanization: controller.hasRomanizedLyrics ? controller.preferences.showRomanization : true,
                topInset: topChrome, bottomInset: bottomChrome, textScale: 1)
                .id(song?.id)
        case .none:
            LyricsStatusContent(
                isLoading: lyricsStore.isLoading, song: song, topInset: topChrome, bottomInset: bottomChrome,
                onFindLyrics: openFetchDialog,
                onSyncYourself: syncYourselfAction)
        }
    }

    private var plainLines: [String] {
        if let plain = lyrics?.plain, !plain.isEmpty { return plain }
        return (lyrics?.synced ?? []).map(\.line)
    }

    private var footerText: String? {
        guard lyrics?.areFromRemote == true else { return nil }
        if let source = lyrics?.document?.metadata.source ?? lyricsStore.currentSource { return "Lyrics: \(source)" }
        return "Online lyrics"
    }

    private func updateShownPrepared() {
        guard let song else {
            withAnimation(.easeIn(duration: 0.18)) { shownPrepared = nil }
            return
        }
        if controller.preparedSongId == song.id, let prepared = controller.prepared {
            shownPreparedSong = song.id
            shownPrepared = prepared
        } else {
            // The outgoing lines fade out instead of being cut.
            withAnimation(.easeIn(duration: 0.18)) { shownPrepared = nil }
        }
    }

    // MARK: Header

    private func header(chrome: LyricsChromeColors, safeTop: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let song {
                LyricsHeader(song: song, isPlaying: playback.isPlaying, chrome: chrome, brightArt: brightArt)
                    .animation(.easeOut(duration: 0.3), value: song.id)
            }
            if showSyncChip && !immersive, let sync = syncYourselfAction {
                LyricsSyncChip(onTap: sync, onDismiss: { syncChipDismissedFor = song?.id })
                    .transition(.opacity)
            }
        }
        .padding(.top, safeTop + 4)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Controls

    private func controls(chrome: LyricsChromeColors, safeBottom: CGFloat, visible: Bool) -> some View {
        VStack(spacing: 0) {
        // Stage 14: Android's floating instrumental toggle sits above the cluster when the song has a render.
        InstrumentalLyricsToggle(chrome: chrome, brightArt: brightArt)
        LyricsControlCluster(
            chrome: chrome, brightArt: brightArt, isPlaying: playback.isPlaying,
            showSyncControls: showSyncedLyrics == true && lyrics?.synced != nil && showSyncControls,
            offsetMs: lyricsStore.offsetMs, showSyncedLyrics: showSyncedLyrics,
            hasSyncedLyrics: !(lyrics?.synced ?? []).isEmpty, clock: playback.clock,
            onOffsetChange: { ms in
                if let song { controller.setOffset(ms, songId: song.id) }
                resetImmersive()
            },
            onPlayPause: {
                playback.togglePlayPause()
                resetImmersive()
            },
            onSeek: { ms in
                playback.seek(toMs: ms)
                resetImmersive()
            },
            onSeekPreview: { ms in
                seekPreview.positionMs = ms
                driver.wake()
            },
            onShowSyncedChange: { synced in
                syncedOverride = synced
                overrideSongId = song?.id
                resetImmersive()
            },
            onBack: { router.dismissCover() },
            onMore: { showMoreSheet = true })
        }
            .padding(.horizontal, 16)
            .padding(.bottom, safeBottom + 10)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : LyricsChromeMetrics.controlsSlide)
            .allowsHitTesting(visible)
    }

    private var syncYourselfAction: (() -> Void)? {
        guard let song else { return nil }
        let router = self.router
        return { router.present(.lyricsSync(songId: song.id)) }
    }

    // MARK: More sheet

    private var moreSheet: some View {
        LyricsMoreSheet(
            song: song, lyrics: lyrics, source: lyricsStore.currentSource,
            showSyncedLyrics: showSyncedLyrics == true, isSyncControlsVisible: showSyncControls,
            hasTranslatedLyrics: controller.hasTranslatedLyrics, hasRomanizedLyrics: controller.hasRomanizedLyrics,
            immersiveEnabled: settings.lyrics.immersiveLyricsEnabled,
            immersiveTemporarilyDisabled: $immersiveTemporarilyDisabled,
            preferences: controller.preferences,
            isShuffleEnabled: playback.isShuffleEnabled, repeatMode: playback.repeatMode,
            isFavorite: song.map { env.libraryEditor.isFavorite($0.id) } ?? false,
            actions: LyricsMoreActions(
                onSyncYourself: syncYourselfAction,
                onSave: { showSaveDialog = true },
                onTranslate: { startTranslation() },
                onTranslateViaAI: {
                    if let song { controller.translateViaAI(song: song, translator: env.ai.lyricsTranslator) }
                },
                onReset: { if let song { controller.reset(song: song) } },
                onToggleSyncControls: {
                    resetImmersive()
                    showSyncControls.toggle()
                },
                onShuffle: { playback.setShuffleEnabled(!playback.isShuffleEnabled) },
                onRepeat: { playback.setRepeatMode(LyricsView.nextRepeatMode(playback.repeatMode)) },
                onFavorite: { if let song { env.libraryEditor.toggleFavorite(song.id) } }))
            .environment(\.appTheme, theme)
            .pixlSheet(detents: [.large])
    }

    /// Android's repeat cycle: off → all → one → off.
    static func nextRepeatMode(_ mode: RepeatMode) -> RepeatMode {
        switch mode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    // MARK: Fetch dialog, save, translate

    private func openFetchDialog() {
        controller.dismissSearch()
        showFetchDialog = true
    }

    private func closeFetchDialog() {
        showFetchDialog = false
        controller.dismissSearch()
    }

    private func export(synced: Bool) {
        guard let lyrics else { return }
        let text = synced ? LyricsUtils.syncedToLrcString(lyrics.synced ?? [])
                          : LyricsUtils.plainToString(lyrics.plain ?? [])
        exportDocument = LyricsTextDocument(text: text)
    }

    private func startTranslation() {
        if controller.hasTranslatedLyrics {
            controller.message = "These lyrics already have a translation"
            return
        }
        guard let synced = lyrics?.synced, !synced.isEmpty else { return }
        translationLines = synced.map(\.line)
        translationSongId = song?.id
        controller.message = "Translating lyrics..."
        if translationConfig == nil {
            translationConfig = TranslationSession.Configuration(source: nil, target: Locale.current.language)
        } else {
            translationConfig?.invalidate()
        }
    }

    private func finishTranslation(_ map: [Int: String]?, songId: String?) {
        guard let song = playback.current, song.id == songId else { return }
        guard let map else {
            controller.message = "Translation isn't available for these lyrics"
            return
        }
        if map.isEmpty {
            controller.message = "These lyrics are already in this language"
        } else {
            controller.applyTranslations(map, song: song)
        }
    }

    // MARK: Driver

    private func startDriver() {
        let playback = self.playback
        let preview = seekPreview
        driver.positionProvider = { preview.positionMs ?? playback.positionMs() }
        if isUITest, let frozen = launch.freezeMs { driver.frozenPositionMs = frozen }
        driver.setPlaying(playback.isPlaying)
        driver.offsetMs = Int64(lyricsStore.offsetMs)
        driver.start()
        interaction.touch()
        UIApplication.shared.isIdleTimerDisabled = controller.preferences.keepScreenOn
    }

    private func stopDriver() {
        driver.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Immersive mode and swipes

    private func resetImmersive() {
        interaction.touch()
        if immersive { immersive = false }
    }

    private func runImmersiveTimer() async {
        guard immersiveActive else {
            if immersive && !(isUITest && launch.immersive) { immersive = false }
            return
        }
        guard !immersive else { return }
        let timeout = Double(settings.lyrics.immersiveLyricsTimeoutMs) / 1000
        while !Task.isCancelled {
            let remaining = timeout - Date().timeIntervalSince(interaction.lastTouch)
            if remaining <= 0 {
                immersive = true
                return
            }
            try? await Task.sleep(for: .seconds(remaining))
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) || swipe.active else { return }
                swipe.active = true
                swipe.dx = dx
                interaction.touch()
            }
            .onEnded { value in
                guard swipe.active else { return }
                let dx = value.translation.width
                if abs(dx) > LyricsSwipeState.threshold {
                    if dx > 0 { playback.skipToPrevious() } else { playback.skipToNext() }
                    swipe.commits += 1
                }
                withAnimation(.easeOut(duration: 0.2)) { swipe.dx = 0 }
                swipe.active = false
            }
    }
}

private struct ImmersiveKey: Hashable {
    let active: Bool
    let immersive: Bool
}

/// The seek bar's preview position while it is dragged (the lyrics follow the finger). Never observed.
final class LyricsSeekPreview {
    var positionMs: Int64?
}

/// The last touch on the lyrics screen (immersive timer), kept out of observation.
final class LyricsInteractionClock {
    private(set) var lastTouch = Date()
    func touch() { lastTouch = Date() }
}

/// The horizontal swipe in progress; only the overlay observes it.
@Observable
final class LyricsSwipeState {
    static let threshold: CGFloat = 100
    var dx: CGFloat = 0
    var commits = 0
    @ObservationIgnored var active = false
}

private struct LyricsSwipeOverlay: View {
    let swipe: LyricsSwipeState
    let chrome: LyricsChromeColors

    var body: some View {
        let progress = min(abs(swipe.dx) / LyricsSwipeState.threshold, 1)
        let towardsNext = swipe.dx < 0
        ZStack {
            if progress > 0 {
                LyricsSwipeIndicator(towardsNext: towardsNext, progress: progress, chrome: chrome)
                    .padding(towardsNext ? .trailing : .leading, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: towardsNext ? .trailing : .leading)
            }
        }
        .allowsHitTesting(false)
        .sensoryFeedback(.impact(weight: .heavy), trigger: swipe.commits)
    }
}

/// On-device translation of lyric lines (the session is not Sendable, so this stays off the main actor).
nonisolated enum LyricsTranslator {
    /// index → translated text for the lines that changed; nil when the session failed.
    @concurrent
    static func translate(lines: [String], session: TranslationSession) async -> [Int: String]? {
        let requests = lines.enumerated().compactMap { index, line -> TranslationSession.Request? in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
        guard !requests.isEmpty else { return [:] }
        do {
            let responses = try await session.translations(from: requests)
            var map: [Int: String] = [:]
            for response in responses {
                guard let id = response.clientIdentifier, let index = Int(id), lines.indices.contains(index) else { continue }
                let original = lines[index].trimmingCharacters(in: .whitespaces)
                if response.targetText.trimmingCharacters(in: .whitespaces) != original { map[index] = response.targetText }
            }
            return map
        } catch {
            return nil
        }
    }
}

/// A short message under the header (Android toasts).
private struct LyricsToast: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .pixlFont(.labelLarge)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(Glass.clear.tint(.black.opacity(0.35)), in: Capsule())
            .padding(.horizontal, 24)
    }
}

/// A lyrics text file for the exporter (`.lrc` / plain text).
nonisolated struct LyricsTextDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    static var importTypes: [UTType] {
        LyricsImportSecurity.supportedFileExtensions().compactMap { UTType(filenameExtension: $0) } + [.plainText, .xml]
    }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Lyrics options (Android `LyricsMoreBottomSheet`) when opened as an app sheet (`AppSheet.lyricsOptions`): the same
/// sheet for the current song, without the actions that need the lyrics screen.
struct LyricsOptionsSheet: View {
    let songId: String

    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @State private var immersiveOnce = false

    var body: some View {
        let controller = env.lyricsController
        let song = library.song(id: songId) ?? playback.current
        LyricsMoreSheet(
            song: song, lyrics: controller.store.currentLyrics, source: controller.store.currentSource,
            showSyncedLyrics: !(controller.store.currentLyrics?.synced ?? []).isEmpty, isSyncControlsVisible: false,
            hasTranslatedLyrics: controller.hasTranslatedLyrics, hasRomanizedLyrics: controller.hasRomanizedLyrics,
            immersiveEnabled: settings.lyrics.immersiveLyricsEnabled, immersiveTemporarilyDisabled: $immersiveOnce,
            preferences: controller.preferences, isShuffleEnabled: playback.isShuffleEnabled,
            repeatMode: playback.repeatMode, isFavorite: env.libraryEditor.isFavorite(songId),
            actions: LyricsMoreActions(
                onSyncYourself: nil, onSave: nil, onTranslate: nil,
                onReset: { if let song { controller.reset(song: song) } },
                onToggleSyncControls: nil,
                onShuffle: { playback.setShuffleEnabled(!playback.isShuffleEnabled) },
                onRepeat: { playback.setRepeatMode(LyricsView.nextRepeatMode(playback.repeatMode)) },
                onFavorite: { env.libraryEditor.toggleFavorite(songId) }))
            .task { controller.ensureLoaded(for: song) }
    }
}
