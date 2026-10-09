import Observation
import PixlLibrary
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
    /// Artist pictures from Deezer after each load / rescan (nil in UI tests).
    let artistImages: ArtistImageService?
    /// Home's state holder: playback history, mixes, recommendations, stats overview (stage 7b).
    let home: HomeStore
    /// Settings › AI › Music intelligence: what listening teaches the recommendations.
    let musicTaste: MusicTasteStore
    /// Settings › AI › "Ready when you play": automatic lyric sync and instrumentals while the app is open.
    let automaticStudio: AutomaticStudioRunner
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
    /// Spotify Connect output: plays the queue on a Connect device and drives it (the devices sheet's section).
    let spotifyConnect: SpotifyConnectController

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

    /// Stage 14: on-device models, the TAIS Studio jobs (lyric sync, instrumentals) and the instrumental switch.
    let tais: TaisServices
    /// Stage 15: `.pxpl` export, inspection and restore (PixlBackup) and the pending playlist restore.
    let backup: BackupService
    /// Stage 15: the notify-only GitHub release check.
    let updates: UpdateNotifier
    /// Cloud Studio (iOS-first): instrumentals and word-timed lyrics on the owner's RunPod GPU, results through R2.
    /// Built here because a background relaunch (BGAppRefresh, the transfer session) never runs `start()`.
    let cloud: CloudStudio

    init(launch: LaunchConfiguration) {
        self.launch = launch
        let isUITest = launch.isUITest
        let router = Router(launch: launch)
        self.router = router
        let container = try? PersistenceActor.makeContainer(inMemory: isUITest)
        let persistence = container.map { PersistenceActor(modelContainer: $0) }
        self.persistence = persistence
        let settings = isUITest ? SettingsStore.ephemeral() : SettingsStore()
        self.settings = settings
        // The optional cloud rows of Settings › AI features, for their screenshot.
        if launch.screen == .settingsAICloud { settings.ai.setUsesCloudAssistant(true) }
        // The downloaded AI model's rows (its demo states are set in `TaisDemo`).
        if launch.screen == .settingsAILocalModel || launch.screen == .settingsAILocalModelReady {
            settings.ai.useDownloadedModel = true
        }
        // `-accent RRGGBB` (UI tests): the accent screenshots start with a picked colour, stored normalised.
        if isUITest, let seed = launch.accentHex.flatMap(AccentPalette.seed(hex:)) {
            settings.appearance.accentColor = AccentPalette.hex(argb: seed)
        }
        // Settings › Default tab (Android `launchTabFlow`): set before the first frame so Home never flashes first.
        // UI tests open the tab their screen asks for.
        if !isUITest, launch.screen == nil { router.selection = settings.behavior.launchTab }
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
        let musicTaste = MusicTasteStore(settings: settings.ai, file: isUITest ? nil : MusicTasteStore.defaultURL())
        self.musicTaste = musicTaste
        home.taste = musicTaste
        home.explorationFraction = { Float(settings.ai.musicExploration) }

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
            services.recordTaste = { record in
                musicTaste.record(songId: record.songId, listenedMs: record.listenedMs,
                                  durationMs: record.totalDurationMs, voluntary: record.isVoluntary,
                                  changedTrack: record.changedTrack, timestamp: record.timestamp)
            }
            playbackServices = services
            realPlayback = services
            playback = PlaybackStore(engine: services.engine)
            sleepTimer = services.sleepTimer
        }

        let spotifyConnect: SpotifyConnectController
        if isUITest {
            let library = LibraryStore(snapshot: DemoLibrary.snapshot)
            self.library = library
            youtube = YouTubeServices(launch: launch, library: library, persistence: persistence, accounts: accounts)
            let spotify = SpotifyService(launch: launch, accounts: accounts, persistence: persistence)
            self.spotify = spotify
            spotifyConnect = SpotifyConnectController(launch: launch, spotify: spotify, playback: playback)
            libraryImporter = nil
            libraryAutoRefresh = nil
            artistImages = nil
            searchProviders = [.library: LibrarySearchProvider(),
                               .spotify: DemoCatalogSearchProvider(),
                               .youtubeMusic: DemoYouTubeMusicSearchProvider()]
            if launch.hasSong {
                let songs = DemoLibrary.songs
                playback.play(songs, startIndex: min(launch.songIndex, songs.count - 1),
                              playWhenReady: launch.startsPlaying)
            }
            if launch.hasSong, launch.screen?.opensOverPlayer == true { playerSheet.expand(animated: false) }
            if launch.hasSong { spotifyConnect.startDemoSessionIfNeeded(launch.screen) }
        } else {
            let loader = persistence.map { SnapshotLoader(persistence: $0, cacheURL: SnapshotLoader.defaultCacheURL()) }
            let importer = persistence.map { LocalLibraryImporter(persistence: $0) }
            LocalLibraryImporter.installArtworkLoader()
            let library = LibraryStore(loader: loader, importer: importer)
            self.library = library
            libraryImporter = importer
            let artistImages = ArtistImageService(library: library, persistence: persistence)
            self.artistImages = artistImages
            let autoRefresh = importer == nil ? nil : LibraryAutoRefresh(library: library)
            autoRefresh?.onRefreshed = { artistImages.prefetchMissing() }
            libraryAutoRefresh = autoRefresh
            let youtube = YouTubeServices(launch: launch, library: library, persistence: persistence, accounts: accounts)
            self.youtube = youtube
            youtube.install(on: realPlayback)
            // Stage 12 on stage 11: Spotify matches and plays through the YouTube session (signed-in search, the
            // JavaScriptCore cipher + Piped chain, the `pixlstream://` loader and downloads).
            let spotify = SpotifyService(launch: launch, accounts: accounts, persistence: persistence,
                                         bridge: youtube.service.map { InnerTubeSpotifyBridge(service: $0) })
            self.spotify = spotify
            spotifyConnect = SpotifyConnectController(launch: launch, spotify: spotify, playback: playback)
            if let realPlayback {
                // Lock screen and remote commands follow the Connect device while a session runs.
                let nowPlaying = realPlayback.nowPlaying
                spotifyConnect.onSessionChanged = { [weak spotifyConnect] active in
                    nowPlaying.remote = active ? spotifyConnect : nil
                    nowPlaying.update()
                }
                spotifyConnect.onRemoteStateChanged = { nowPlaying.update() }
                // The phone's volume buttons drive the Connect device while the app is open (not in UI tests: the
                // simulator can't change the volume).
                let volumeButtons = SpotifyConnectVolumeButtons(session: realPlayback.session)
                volumeButtons.onPress = { [weak spotifyConnect] presses in spotifyConnect?.adjustVolume(byPresses: presses) }
                volumeButtons.onEndReached = { [weak spotifyConnect] in spotifyConnect?.volumeButtonsReachedEnd() }
                spotifyConnect.volumeButtons = volumeButtons
                // Lock screen / Control Center "Like" toggles the playing song's favourite (the library owns
                // favourites); its state follows favourite edits made anywhere in the app.
                let favorites = LibraryEditor(store: library, persistence: persistence, writesCache: true)
                nowPlaying.onLike = { song in favorites.toggleFavorite(song.id) }
                nowPlaying.isFavorite = { song in library.song(id: song.id)?.isFavorite ?? song.isFavorite }
                nowPlaying.followFavorites(revision: { library.revision })
            }
            // Spotify songs (`spotify://<id>`) play their YouTube match; this stays the outermost resolver (after
            // stage 11's streaming resolver) so other songs reach the inner ones unchanged.
            if let realPlayback {
                realPlayback.engine.factory.resolver = spotify.playableURLResolver(base: realPlayback.engine.factory.resolver)
            }
            searchProviders = [.library: LibrarySearchProvider(),
                               .spotify: SpotifyCatalogSearchProvider(service: spotify),
                               .youtubeMusic: youtube.searchProvider ?? (UnavailableSearchProvider(source: .youtubeMusic) as any SearchProviding)]
        }

        self.spotifyConnect = spotifyConnect
        tais = TaisServices(launch: launch, settings: settings, lyricsController: lyricsController, playback: playback,
                            playbackServices: playbackServices, youtube: youtube)
        automaticStudio = AutomaticStudioRunner(studio: tais.studio, models: tais.models, settings: settings,
                                                library: library, playback: playback, history: home.history,
                                                lyricsService: lyricsController.lyricsService,
                                                isEnabled: !isUITest)

        let settingsDefaults = isUITest ? (UserDefaults(suiteName: "pixlaudio.uitest") ?? .standard) : .standard
        backup = BackupService(persistence: persistence, library: library, settings: settings, defaults: settingsDefaults,
                               history: home.history, playbackServices: playbackServices, isUITest: isUITest)
        updates = UpdateNotifier(isEnabled: !isUITest)
        let cloud = CloudStudio.make(launch: launch, defaults: settingsDefaults, library: library, playback: playback,
                                     tais: tais, lyricsService: lyricsController.lyricsService,
                                     persistence: persistence, playbackServices: playbackServices, youtube: youtube)
        self.cloud = cloud
        // The automatic studio leaves songs alone while the cloud is working on them (design §7.1).
        automaticStudio.skipsSong = { [weak cloud] songId in cloud?.hasPendingJob(songId: songId) ?? false }
    }

    /// Launch work, off the first frame: load the library snapshot (cache first, then the store), then start the
    /// automatic incremental rescans (launch, foreground, music-library changes).
    func start() async {
        guard !launch.isUITest else { return }
        library.beginCachedLoad() // decode the snapshot cache and the saved queue alongside the service starts below
        playbackServices?.prepareQueueRestore()
        // First run: PixlAudio's setup (Android shows `SetupScreen` until `initial_setup_done`).
        if !settings.behavior.initialSetupDone, router.cover == nil { router.present(AppCover.setup) }
        playbackServices?.start()
        youtube.start()
        tais.start()
        automaticStudio.start()
        let library = self.library, playback = self.playback
        let artistImages = self.artistImages
        spotify.attach(reloadLibrary: {
            await library.reloadFromStore()
            artistImages?.prefetchMissing()
        }, isPlaybackActive: { playback.isPlaying })
        spotify.songLookup = { library.song(id: $0) }
        // Before Home's first refresh, which may ask the selected assistant for today's greeting.
        await AIProviderStatus.migrateDefaultProviderIfNeeded(self)
        home.greeter = HomeAIGreeter.make(self)
        // The cached snapshot has everything the queue restore needs, so the mini player no longer waits for the
        // store's full read, which only reconciles. Without a cache (first launch) the order stays as it was.
        let hasCache = await library.installCached()
        if !hasCache { await library.reconcileWithStore() }
        await playbackServices?.restoreQueue(lookup: library.song(id:))
        if hasCache { await library.reconcileWithStore() }
        artistImages?.prefetchMissing()
        libraryAutoRefresh?.start()
        let home = self.home, playCounts = self.playCounts, editor = libraryEditor
        Task {
            await home.history.ensureLoaded()
            await playCounts.refresh(editor: editor, revision: home.history.revision)
        }
        // "Most played" follows the engagement table when it changes after the history revision did.
        let reloadPlayCounts: () -> Void = {
            Task { await playCounts.reload(editor: editor, revision: home.history.revision) }
        }
        playbackServices?.onEngagementRecorded = reloadPlayCounts
        backup.onRestored = { [weak self] in
            reloadPlayCounts()
            // A restore may write AI keys and base URLs (it dropped the cached answer): re-check off the main actor.
            // It may also bring back GEMINI without a key (an Android backup): move that to the on-device model again.
            guard let self else { return }
            Task {
                await AIProviderStatus.migrateDefaultProviderIfNeeded(self, ignoringFlag: true)
                await AIProviderStatus.refresh(self)
            }
        }
        backup.start()
        // Settings › Library › Album Art Cache Limit: the thumbnail disk cache is kept under it.
        let artCacheLimit = Int64(settings.library.albumArtCacheLimitMb) * 1_048_576
        Task.detached(priority: .background) { ArtworkPipeline.trimDiskCache(limitBytes: artCacheLimit) }
        // The output-route monitor queries the audio session when first touched: do it now, while nothing animates,
        // not in the full player's first frame.
        _ = AudioRouteMonitor.shared
        await AIProviderStatus.refresh(self)
        await spotify.start()
        await updates.checkIfDue()
    }

    /// A file opened in PixlAudio from Files or the share sheet (the declared document types; Android's external
    /// intents): a `.pxpl` backup, or the Android app's legacy `.json.gz`, opens the restore flow on it; an M3U
    /// playlist becomes a playlist; LRC / TTML lyrics are imported for the playing song; an audio file joins the
    /// library and plays.
    func open(_ url: URL) {
        guard !launch.isUITest, url.isFileURL else { return }
        if case .setup? = router.cover { return } // the setup comes first (it has its own restore page)
        switch ExternalFiles.kind(of: url) {
        case .backup: openBackup(url)
        case .playlist: openPlaylist(url)
        case .lyrics: openLyrics(url)
        case .audio: openAudio(url)
        case .unsupported: return
        }
    }

    private func openBackup(_ url: URL) {
        let backup = self.backup, router = self.router
        Task {
            guard let inspected = try? await backup.inspect(url: url) else { return }
            backup.importStart = .inspected(inspected)
            router.present(AppCover.backupImport)
        }
    }

    /// Android's M3U import (Library › Import), from a file handed to the app: the playlist is created and Library
    /// opens, where it shows up and the toast confirms it.
    private func openPlaylist(_ url: URL) {
        showLibraryRoot()
        guard let data = ExternalFiles.read(url) else {
            LibraryToast.shared.show("Couldn't read this playlist")
            return
        }
        let parsed = M3U.parse(utf8: Array(data), fileName: url.lastPathComponent, library: library.songs)
        libraryEditor.createPlaylist(name: parsed.name, songIds: parsed.songIds)
        LibraryToast.shared.show("Playlist created")
    }

    /// Lyrics for the song that is playing (the lyrics screen's Import, `LyricsImportSecurity`), shown on the lyrics
    /// screen; with nothing playing there is no song to attach them to.
    private func openLyrics(_ url: URL) {
        guard let song = playback.current else {
            showLibraryRoot()
            LibraryToast.shared.show("Play a song first, then open the lyrics file again")
            return
        }
        lyricsController.importFile(url, song: song)
        if router.cover == nil { router.present(AppCover.lyrics) }
    }

    /// An audio file: copied into Documents (unless it is already there), scanned into the library and played.
    private func openAudio(_ url: URL) {
        let library = self.library, playback = self.playback
        Task {
            guard let relativePath = await ExternalFiles.importAudio(url) else {
                self.showLibraryRoot()
                LibraryToast.shared.show("Couldn't open this file")
                return
            }
            let id = LibraryIdentity.fileSongID(rootID: FolderRoot.documentsID, relativePath: relativePath)
            // Opening a file the user once deleted (whose file couldn't be removed) asks for it back.
            HiddenSongs.unhide([id])
            // An incremental refresh joins a scan that is already running (the foreground rescan), which may have
            // listed the folder before the copy: scan once more if the song isn't there yet.
            for _ in 0..<2 where library.song(id: id) == nil {
                try? await library.refresh(mode: .incremental)
            }
            if let song = library.song(id: id) {
                playback.play([song], startIndex: 0)
            } else {
                self.showLibraryRoot()
                LibraryToast.shared.show("This file couldn't be added to the library")
            }
        }
    }

    /// Library at its root, where the toast of an opened file shows.
    private func showLibraryRoot() {
        router.libraryPath.removeAll()
        router.selection = .library
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
