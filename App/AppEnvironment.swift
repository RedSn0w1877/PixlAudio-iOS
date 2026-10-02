import Observation
import PixlModel
import SwiftData
import SwiftUI

/// The app's dependency container, built once in `PixlAudioApp` (architecture §2): small `@Observable` stores for
/// the UI, actors for the work. UI tests (`-uiTest`) get an in-memory store, the demo library, the demo engine and
/// ephemeral settings, so screenshots are deterministic and nothing touches the user's data.
@Observable
final class AppEnvironment {
    let launch: LaunchConfiguration
    let router: Router
    let library: LibraryStore
    let playback: PlaybackStore
    let settings: SettingsStore
    let accounts: AccountsStore
    let lyrics: LyricsStore
    /// Stage 9: loads lyrics into `lyrics` (`LyricsService`: providers, cache, embedded tags) and runs the search.
    let lyricsController: LyricsController
    let theme: ThemeStore
    let artwork: ArtworkPipeline
    let colorExtractor: ColorExtractor
    let persistence: PersistenceActor?
    /// The real playback stack (stage 5); nil for UI tests, which use `DemoPlaybackEngine`.
    let playbackServices: PlaybackServices?
    /// Stage 6: builds the library from folders, Documents and the music library (nil in UI tests).
    let libraryImporter: LocalLibraryImporter?
    private let libraryAutoRefresh: LibraryAutoRefresh?
    /// Home's state holder: playback history, mixes, recommendations, stats overview (stage 7b).
    let home: HomeStore
    /// Search providers by source: the library on `SearchIndex` (stage 7c); stages 11/12 replace the YouTube Music
    /// and Spotify ones (UI tests get demo providers so Search's remote sections render).
    let searchProviders: [SearchSource: any SearchProviding]
    /// Stage 8: the player sheet (mini player ↔ full player) state.
    let playerSheet = PlayerSheetController()
    /// Play counts for "Most played" on artist pages, warmed after launch (see `PlayCountStore`).
    let playCounts = PlayCountStore()
    /// Stage 8: the sleep timer the queue's timer sheet drives — the engine's (`PlaybackServices`), or an engine-less
    /// one for UI tests.
    let sleepTimer: SleepTimerController
    /// Stage 11: YouTube session, streaming loader, downloads, YouTube Music search (demo variant in UI tests).
    let youtube: YouTubeServices
    /// Spotify account, library sync, YouTube matching and catalogue (stage 12).
    let spotify: SpotifyService

    @ObservationIgnored private var aiStorage: AIService?

    /// Stage 13: AI providers (cloud, local and on-device), the AI playlist and TAIS DJ state, lyric translation.
    /// Built on first use, so nothing AI-related runs at launch.
    var ai: AIService {
        if let aiStorage { return aiStorage }
        let library = self.library, persistence = self.persistence, writesCache = !launch.isUITest
        let service = AIService(launch: launch, settings: settings, persistence: persistence, library: library, home: home,
                                playback: playback, router: router, searchProviders: searchProviders,
                                libraryEditor: { LibraryEditor(store: library, persistence: persistence, writesCache: writesCache) })
        aiStorage = service
        return service
    }

    /// Stage 15: `.pxpl` export, inspection and restore (PixlBackup) and the pending playlist restore.
    let backup: BackupService
    /// Stage 15: the notify-only GitHub release check.
    let updates: UpdateNotifier

    init(launch: LaunchConfiguration) {
        self.launch = launch
        let isUITest = launch.isUITest
        router = Router(launch: launch)
        let container = try? PersistenceActor.makeContainer(inMemory: isUITest)
        let persistence = container.map { PersistenceActor(modelContainer: $0) }
        self.persistence = persistence
        let settings = isUITest ? SettingsStore.ephemeral() : SettingsStore()
        self.settings = settings
        let accounts = AccountsStore()
        self.accounts = accounts
        let lyrics = LyricsStore()
        self.lyrics = lyrics
        lyricsController = LyricsController(store: lyrics, settings: settings, persistence: persistence, isUITest: isUITest)
        artwork = .shared
        let extractor = ColorExtractor(pipeline: .shared, persistence: persistence)
        colorExtractor = extractor
        theme = ThemeStore(extractor: extractor, appearance: settings.appearance)
        let home = HomeStore.make(launch: launch)
        self.home = home

        // Stage 5: the dual-deck AVPlayer engine for real launches; UI tests keep the demo engine.
        var realPlayback: PlaybackServices?
        if isUITest {
            playbackServices = nil
            playback = PlaybackStore(engine: DemoPlaybackEngine())
            sleepTimer = SleepTimerController(engine: nil)
        } else {
            let services = PlaybackServices(settings: settings, persistence: persistence)
            // Listening sessions feed Home's history (Recently Played, Stats, mixes) — one owner of the file.
            let history = home.history
            services.recordHistory = { songId, durationMs, timestamp in
                history.record(songId: songId, durationMs: durationMs, endTimestampMs: timestamp)
            }
            playbackServices = services
            realPlayback = services
            playback = PlaybackStore(engine: services.engine)
            sleepTimer = services.sleepTimer
        }

        if isUITest {
            let library = LibraryStore(snapshot: DemoLibrary.snapshot)
            self.library = library
            youtube = YouTubeServices(launch: launch, library: library, persistence: persistence, accounts: accounts)
            let spotify = SpotifyService(launch: launch, accounts: accounts, persistence: persistence)
            self.spotify = spotify
            libraryImporter = nil
            libraryAutoRefresh = nil
            searchProviders = [.library: LibrarySearchProvider(),
                               .spotify: DemoCatalogSearchProvider(),
                               .youtubeMusic: DemoYouTubeMusicSearchProvider()]
            if launch.hasSong {
                let songs = DemoLibrary.songs
                playback.play(songs, startIndex: min(launch.songIndex, songs.count - 1),
                              playWhenReady: launch.startsPlaying)
            }
            if launch.hasSong, launch.screen?.opensOverPlayer == true { playerSheet.expand(animated: false) }
        } else {
            let loader = persistence.map { SnapshotLoader(persistence: $0, cacheURL: SnapshotLoader.defaultCacheURL()) }
            let importer = persistence.map { LocalLibraryImporter(persistence: $0) }
            LocalLibraryImporter.installArtworkLoader()
            let library = LibraryStore(loader: loader, importer: importer)
            self.library = library
            libraryImporter = importer
            libraryAutoRefresh = importer == nil ? nil : LibraryAutoRefresh(library: library)
            let youtube = YouTubeServices(launch: launch, library: library, persistence: persistence, accounts: accounts)
            self.youtube = youtube
            youtube.install(on: realPlayback)
            // Stage 12 on stage 11: Spotify matches and plays through the YouTube session (signed-in search, the
            // JavaScriptCore cipher + Piped chain, the `pixlstream://` loader and downloads).
            let spotify = SpotifyService(launch: launch, accounts: accounts, persistence: persistence,
                                         bridge: youtube.service.map { InnerTubeSpotifyBridge(service: $0) })
            self.spotify = spotify
            // Spotify songs (`spotify://<id>`) play their YouTube match; this stays the outermost resolver (after
            // stage 11's streaming resolver) so other songs reach the inner ones unchanged.
            if let realPlayback {
                realPlayback.engine.factory.resolver = spotify.playableURLResolver(base: realPlayback.engine.factory.resolver)
            }
            searchProviders = [.library: LibrarySearchProvider(),
                               .spotify: SpotifyCatalogSearchProvider(service: spotify),
                               .youtubeMusic: youtube.searchProvider ?? (UnavailableSearchProvider(source: .youtubeMusic) as any SearchProviding)]
        }

        let settingsDefaults = isUITest ? (UserDefaults(suiteName: "pixlaudio.uitest") ?? .standard) : .standard
        backup = BackupService(persistence: persistence, library: library, settings: settings, defaults: settingsDefaults,
                               history: home.history, playbackServices: playbackServices, isUITest: isUITest)
        updates = UpdateNotifier(isEnabled: !isUITest)
    }

    /// Launch work, off the first frame: load the library snapshot (cache first, then the store), then start the
    /// automatic incremental rescans (launch, foreground, music-library changes).
    func start() async {
        guard !launch.isUITest else { return }
        // First run: PixlAudio's setup (Android shows `SetupScreen` until `initial_setup_done`).
        if !settings.behavior.initialSetupDone, router.cover == nil { router.present(AppCover.setup) }
        playbackServices?.start()
        youtube.start()
        let library = self.library, playback = self.playback
        spotify.attach(reloadLibrary: { await library.reloadFromStore() }, isPlaybackActive: { playback.isPlaying })
        spotify.songLookup = { library.song(id: $0) }
        await library.load()
        await playbackServices?.restoreQueue(lookup: library.song(id:))
        libraryAutoRefresh?.start()
        let home = self.home, playCounts = self.playCounts, editor = libraryEditor
        Task {
            await home.history.ensureLoaded()
            await playCounts.refresh(editor: editor, revision: home.history.revision)
        }
        backup.start()
        await spotify.start()
        await updates.checkIfDue()
    }

    /// A file opened in PixlAudio from Files or the share sheet (the declared document types; Android's external
    /// intents): a `.pxpl` backup, or the Android app's legacy `.json.gz`, opens the restore flow on it.
    func open(_ url: URL) {
        guard !launch.isUITest, url.isFileURL else { return }
        let name = url.lastPathComponent.lowercased()
        guard name.hasSuffix(".pxpl") || name.hasSuffix(".gz") else { return }
        if case .setup? = router.cover { return } // the setup has its own restore page
        let backup = self.backup, router = self.router
        Task {
            guard let inspected = try? await backup.inspect(url: url) else { return }
            backup.importStart = .inspected(inspected)
            router.present(AppCover.backupImport)
        }
    }

    /// Call after music-library access was granted so its change notifications start.
    func libraryAccessChanged() {
        libraryAutoRefresh?.observeMediaLibraryIfAuthorized()
    }

    /// The colour scheme forced by UI tests, else the user's `app_theme_mode`.
    var preferredColorScheme: ColorScheme? {
        launch.colorScheme ?? theme.preferredColorScheme
    }
}
