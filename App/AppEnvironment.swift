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
    /// Artist pictures from Deezer after each load / rescan (nil in UI tests).
    let artistImages: ArtistImageService?
    /// Home's state holder: playback history, mixes, recommendations, stats overview (stage 7b).
    let home: HomeStore
    /// Settings › AI › Music intelligence: what listening teaches the recommendations.
    let musicTaste: MusicTasteStore
    /// Listening history imported from Spotify / YouTube Music (automatic and from data downloads), fed to the
    /// recommendations; its read API (`topArtists`, `topTracks`, `recentPlays`, `listeningSummary`) serves the assistant.
    let importedHistory: ImportedHistoryStore
    /// Ask Taizo's taste changes (Settings › Library & storage): explicit boosts, reductions, mutes and blocks above the
    /// learned signals. Taizo's tools change them; Settings lists and undoes them.
    let tasteAdjustments: TasteAdjustmentStore
    /// The automatic Spotify / YouTube Music history sync (app start, after connecting, background refresh).
    let historySync: ListeningHistorySync
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
    /// The music brain (docs/brain-spec.md): the tracks Autoplay played from outside the library, and the state of
    /// the queue's Autoplay line. Its files are read on first use, never at launch.
    let brain: BrainService
    /// Autoplay (docs/brain-spec.md, 7.1): keeps the queue going with related music. Nil in UI tests.
    let autoplayController: AutoplayController?
    /// What the listener does to the music brain by hand (docs/brain-spec.md, 8.3, 8.5): "Start station", "Not for
    /// me" and its bar, the Familiar / Blend / Discover switch, a Home row's card.
    let brainActions: BrainActions

    @ObservationIgnored private var aiStorage: AIService?

    /// Stage 13: AI providers (cloud, local and on-device), the AI playlist and Ask Taizo state, lyric translation;
    /// Claude first for all of them (2026-10-23). Built on first use, so nothing AI-related runs at launch.
    var ai: AIService {
        if let aiStorage { return aiStorage }
        let library = self.library, persistence = self.persistence, writesCache = !launch.isUITest
        let service = AIService(launch: launch, settings: settings, persistence: persistence, library: library, home: home,
                                playback: playback, router: router, searchProviders: searchProviders,
                                libraryEditor: { LibraryEditor(store: library, persistence: persistence, writesCache: writesCache) },
                                environment: { [weak self] in self })
        aiStorage = service
        return service
    }

    /// Stage 14: on-device models, the TAIS Studio jobs (lyric sync, instrumentals) and the instrumental switch.
    let tais: TaisServices
    /// Stage 15: `.pxpl` export, inspection and restore (PixlBackup) and the pending playlist restore.
    let backup: BackupService
    /// Stage 15: the notify-only GitHub release check.
    let updates: UpdateNotifier
    /// Cloud Studio (iOS-first): instrumentals on the owner's RunPod GPUs, results through R2.
    /// Built here because a background relaunch (BGAppRefresh, the transfer session) never runs `start()`.
    let cloud: CloudStudio
    /// Home's "Active jobs" button and sheet: what is running across the services above (`ActiveJobs`).
    let activeJobs: ActiveJobs
    /// Crash protection and diagnostics: how the last run ended, safe mode, memory / thermal conditions, the event log.
    let health: AppHealth
    /// Music Haptics (iOS-first, 2026-10-18): the Taptic Engine plays along with the music while the switch is on.
    let musicHaptics: MusicHapticsController
    /// Spatial audio (cloud audio spec of 2026-11-10): the settings, what plays, and the cloud
    /// render's status, for the player sheet and Settings. Its two halves come from `SpatialPlaybackFactory` (the
    /// engine side) and `SpatialLibraryFactory` (the cloud side), which is where that work plugs in: not here.
    let spatial: SpatialAudioModel

    init(launch: LaunchConfiguration) {
        self.launch = launch
        let isUITest = launch.isUITest
        let router = Router(launch: launch)
        self.router = router
        // Before anything else starts: how did the last run end? Safe mode (no heavy work by itself) follows from it.
        let health: AppHealth
        // A unit-test host is killed between runs: that is not a crash of the app, so it gets the demo variant too.
        let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if isUITest || isUnitTestHost {
            let crashed = launch.screen == .homeSafeMode || launch.screen == .jobsInterrupted
            health = AppHealth(defaults: UserDefaults(suiteName: "pixlaudio.uitest") ?? .standard,
                               markerURL: nil,
                               demo: crashed ? SafeModeState(consecutiveAbnormal: 1, isActive: true, bannerPending: true) : SafeModeState())
        } else {
            health = AppHealth()
            health.launch()
        }
        self.health = health
        let container = try? PersistenceActor.makeContainer(inMemory: isUITest)
        let persistence = container.map { PersistenceActor(modelContainer: $0) }
        self.persistence = persistence
        let settings = isUITest ? SettingsStore.ephemeral() : SettingsStore()
        self.settings = settings
        // Blocked-artist demo states (UI tests): the artists the screenshots show as blocked.
        if isUITest { Self.seedBlockedDemo(settings.blocked, screen: launch.screen) }
        // The previous run died with the downloaded AI model loaded or writing: it stays off until the person turns it on
        // again, so a crash loop cannot repeat.
        if health.localModelBlamed, settings.ai.useDownloadedModel {
            settings.ai.useDownloadedModel = false
            DiagnosticsLog.shared.log("safemode", "downloaded AI model turned off after it was in flight at a crash")
        }
        // The optional cloud rows of Settings › AI features, for their screenshot.
        if launch.screen == .settingsAICloud { settings.ai.setUsesCloudAssistant(true) }
        // The downloaded AI model's rows (its demo states are set in `TaisDemo`).
        if launch.screen == .settingsAILocalModel || launch.screen == .settingsAILocalModelReady
            || launch.screen == .settingsAILocalModelFailed {
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
        let importedHistory = ImportedHistoryStore.make(launch: launch)
        self.importedHistory = importedHistory
        home.imported = importedHistory
        let tasteAdjustments = TasteAdjustmentStore.make(launch: launch)
        self.tasteAdjustments = tasteAdjustments
        home.adjustments = tasteAdjustments

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
            // Spotify-only: nothing scans the phone's own audio files, so the store has no importer.
            let library = LibraryStore(loader: loader, importer: nil)
            self.library = library
            let artistImages = ArtistImageService(library: library, persistence: persistence)
            self.artistImages = artistImages
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
                // A seek or restart made on the lock screen must move a paused progress bar here too.
                let playbackStore = playback
                spotifyConnect.onRemoteStateChanged = {
                    nowPlaying.update()
                    playbackStore.notePositionJumped()
                }
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
        // The music brain: Autoplay continues the queue; Recently Played, Like and "Add to playlist" know the tracks
        // it played from outside the library. Nothing is read or fetched here.
        let brainLibrary = library, brainHistory = home.history, brainImports = importedHistory
        let brainTaste = tasteAdjustments
        let brain = BrainService(radioSource: youtube.radioSource, isEnabled: !isUITest, sources: BrainEngine.Sources(
            library: { @MainActor in brainLibrary.songs },
            history: { @MainActor in
                await brainHistory.ensureLoaded()
                return brainHistory.events
            },
            importSignature: { @MainActor in
                await brainImports.ensureLoaded()
                let aggregate = brainImports.aggregate
                return "\(aggregate.totalPlays)|\(aggregate.lastPlayMs)"
            },
            imported: { @MainActor in await brainImports.importedContents() },
            adjustments: { @MainActor in
                await brainTaste.ensureLoaded()
                return brainTaste.activeAdjustments(nowMs: currentTimeMillis())
            }))
        self.brain = brain
        BrainService.shared = brain
        home.engineSongs = { await brain.engineSongsForHome() }
        // The stored tracks are read a moment after launch; Home then resolves the rest of its history.
        let brainHome = home
        brain.onStoredTracksLoaded = {
            brainHome.engineTracksChanged()
            Task { await brainHome.refresh(snapshot: brainLibrary.snapshot, libraryRevision: brainLibrary.songsRevision) }
        }
        // "Go to artist" on a track from outside the library opens the library's own artist of that name.
        brain.libraryLinks = (hasArtist: { brainLibrary.artist(id: $0) != nil }, hasAlbum: { brainLibrary.album(id: $0) != nil })
        if let realPlayback {
            // Every play that ends reaches the event log, with no five-second floor (docs/brain-spec.md, 4.2).
            let stats = realPlayback.stats
            stats.onBrainPlay = { [weak brain] play in brain?.playFinished(play) }
            stats.onBrainOpen = { [weak brain] play in brain?.playOpen(play) }
            brain.markPlaying = { [weak stats] songId, flag in stats?.markFlag(songId: songId, flag: flag) }
            realPlayback.isInLibrary = { brainLibrary.song(id: $0) != nil }
            realPlayback.isEngineTrack = { [weak brain] songId in brain?.track(songId: songId) != nil }
            // After a restart the restored queue knows its picks before the brain's files are read.
            let pickEngine = realPlayback.engine
            brain.queuedPick = { [weak pickEngine] songId in
                pickEngine?.queue.entries.first { $0.song.id == songId && $0.brain?.arm != nil }?.song
            }
        }
        if let realPlayback {
            let libraryStore = library, playbackStore = playback, blockedStore = settings.blocked, connectOutput = spotifyConnect
            let aiSettings = settings.ai
            let streamCache = youtube.cache
            let autoplay = AutoplayController(engine: realPlayback.engine, brain: brain, sources: AutoplayController.Sources(
                isEnabled: { aiSettings.musicDiscoveryEnabled },
                youTubeSourceEnabled: { aiSettings.brainYouTubeSourceEnabled },
                remoteOutput: { playbackStore.isRemoteActive ? .connect : .none },
                playableOnRemote: { songs in await connectOutput.canPlay(songs) },
                library: { libraryStore.songs },
                librarySong: { libraryStore.song(id: $0) },
                events: { home.history.events },
                blocked: { blockedStore.matcher },
                adjustments: { tasteAdjustments.activeSet(nowMs: currentTimeMillis()) },
                signals: { musicTaste.learnedSignals },
                imported: { importedHistory.aggregate },
                exploration: { Float(aiSettings.musicExploration) },
                matchedVideoId: { spotifyId in try? await persistence?.matchedVideoId(spotifyId: spotifyId) },
                offlinePlayable: { songs in
                    await AutoplayOffline.playable(songs, persistence: persistence, cache: streamCache)
                }))
            realPlayback.autoplay = autoplay
            brain.onReaction = { [weak autoplay] reaction in autoplay?.reaction(reaction) }
            // "Not for me", "Less from ...", a mute or an undo from anywhere: what it excludes leaves the engine's
            // picks at once (docs/brain-spec.md, 8.5). Nothing runs until a change is made.
            autoplay.observeTasteChanges { tasteAdjustments.revision }
            autoplayController = autoplay
        } else {
            autoplayController = nil
        }
        brainActions = BrainActions(brain: brain, playback: playback, library: library, taste: tasteAdjustments,
                                    playCounts: playCounts, engine: realPlayback?.engine, autoplay: autoplayController)
        // Daily Mix and Your Mix with new music (docs/brain-spec.md, 8.2, stage 2a) and the once-a-day background search
        // for new music (3.7). Nothing here reads a file or asks the network: the sources are closures, and a mix is
        // built after the app has settled, never at launch.
        if !isUITest {
            let mixLibrary = library, mixHistory = home.history, mixTaste = musicTaste, mixImported = importedHistory
            let mixAdjustments = tasteAdjustments, mixBlocked = settings.blocked, mixSettings = settings.ai
            let mixPersistence = persistence, mixPlayback = playback
            brain.configureMixes(sources: MixSources(
                library: { @MainActor in mixLibrary.songs },
                librarySongs: { @MainActor ids in
                    var found: [String: Song] = [:]
                    for id in ids { if let song = mixLibrary.song(id: id) { found[id] = song } }
                    return found
                },
                legacyPicks: { @MainActor library, limit, nowMs, epochDay in
                    // The existing ranking's best songs, the way Autoplay's library pool asks for them.
                    await mixHistory.ensureLoaded()
                    await mixTaste.ensureLoaded()
                    await mixImported.ensureLoaded()
                    await mixAdjustments.ensureLoaded()
                    let events = mixHistory.events, signals = mixTaste.learnedSignals, imported = mixImported.aggregate
                    let exploration = Float(mixSettings.musicExploration)
                    let adjustments = mixAdjustments.activeSet(nowMs: nowMs)
                    return await Task.detached(priority: .utility) {
                        let inputs = HomeStore.recommendationInputs(songs: library, events: events, signals: signals, imported: imported)
                        return DailyMix.personalizedPicks(
                            allSongs: library, favoriteSongIds: Set(library.filter(\.isFavorite).map(\.id)),
                            engagements: inputs.engagements, storedSignals: inputs.signals, exploration: exploration,
                            nowMs: nowMs, limit: limit, seed: DailyMix.dailySeed(epochDay: epochDay),
                            artistAffinity: inputs.artistAffinity, adjustments: adjustments).map(\.song)
                    }.value
                },
                constraints: { @MainActor in
                    await mixAdjustments.ensureLoaded()
                    let signature = mixAdjustments.items.map(\.id).joined(separator: ",") + "|\(mixBlocked.count)"
                    return MixConstraints(blocked: mixBlocked.matcher,
                                          adjustments: mixAdjustments.activeSet(nowMs: currentTimeMillis()),
                                          favoriteIds: [], signature: signature)
                },
                engine: { @MainActor in mixSettings.brainEngine },
                noveltyLevel: { @MainActor in brain.stations.novelty },
                tzOffsetMin: { nowMs in
                    Int32(clamping: TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000)) / 60)
                },
                song: { BrainService.queueSong(for: $0) },
                matchedVideoId: { spotifyId in try? await mixPersistence?.matchedVideoId(spotifyId: spotifyId) },
                mixBuilt: { Task { @MainActor in brain.mixWasBuilt() } },
                timing: { name, ms in DiagnosticsLog.shared.log("brain", "\(name) \(ms) ms") }),
                budget: youtube.radioBudget)
            brain.refreshIsAllowed = { mixSettings.brainRefreshEnabled && BrainRemoteFlags.refreshAllowed() }
            brain.isMusicPlaying = { mixPlayback.isPlaying }
            // Home and the two mix screens read the mixes through the brain once the app has settled.
            home.brainMixes = brain.mixes
            home.brainQuiet = { [weak brain] in await brain?.waitForStartup() }
            home.brainEngineIsOn = { mixSettings.brainEngine == BrainEngineChoice.brain }
            home.onBrainMixTracks = { [weak brain] tracks in brain?.register(tracks) }
            home.linkBrainSong = { [weak brain] song in brain?.linked(song) ?? song }
            // The handler is only registered here; no brain code runs until iOS grants a task.
            BrainBackground.register(for: brain)
        }
        if let homeRows = brain.homeRows {
            // Home's "Because you listened to" rows (docs/brain-spec.md, 8.1): the saved rows at once; a rebuild only
            // once music has played in this run, off the main actor, with what it reads captured when it is due.
            let rowsLibrary = library, rowsBlocked = settings.blocked, rowsSettings = settings.ai
            let rowsTaste = tasteAdjustments, rowsAutoplay = autoplayController, rowsPersistence = persistence
            home.brainRows = HomeBrainRowsSource(
                isEnabled: { rowsSettings.musicDiscoveryEnabled },
                cached: { await homeRows.cached() },
                refreshIfDue: {
                    await rowsTaste.ensureLoaded()
                    // What the rows depend on besides their anchors: the taste changes in force and the blocked artists.
                    let tasteSignature = Int(truncatingIfNeeded: BrainHash.fnv1a64(rowsTaste.items.map(\.id).joined(separator: ",")))
                    return await homeRows.refreshIfDue(tasteRevision: tasteSignature, blockedCount: rowsBlocked.count) { @MainActor in
                        let now = currentTimeMillis()
                        return HomeRowInputs(
                            library: rowsLibrary.songs, blocked: rowsBlocked.matcher,
                            adjustments: rowsTaste.activeSet(nowMs: now),
                            allowNetwork: rowsAutoplay?.mayUseNetwork() ?? false,
                            tzOffsetMin: Int32(clamping: TimeZone.current.secondsFromGMT() / 60),
                            matchedVideoId: { spotifyId in try? await rowsPersistence?.matchedVideoId(spotifyId: spotifyId) })
                    }
                })
        }
        historySync = ListeningHistorySync(store: importedHistory, spotify: spotify, youtube: youtube)
        let historyLibrary = library
        importedHistory.localSource = { (home.history.events, historyLibrary.songs) }
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
        // Sing starts its cloud job through Cloud Studio, which is created after the instrumental controller.
        tais.instrumental.cloud = cloud
        // The automatic studio leaves songs alone while the cloud is working on them (design §7.1).
        automaticStudio.skipsSong = { [weak cloud] songId in cloud?.hasPendingJob(songId: songId) ?? false }
        activeJobs = isUITest
            ? ActiveJobsDemo.make(launch: launch)
            : ActiveJobs(sources: ActiveJobs.Sources(library: library, spotify: spotify, downloads: youtube.downloads,
                                                     models: tais.models, studio: tais.studio, cloud: cloud, health: health))
        musicHaptics = MusicHapticsController(behavior: settings.behavior, playback: playback, health: health,
                                              bus: playbackServices?.engine.effects.haptics, isDemo: isUITest)
        // Spatial audio: both halves are built from this one context by their own factories.
        spatial = SpatialAudioModel.make(SpatialAudioContext(
            launch: launch, defaults: settingsDefaults, settings: settings, library: library, playback: playback,
            playbackServices: playbackServices, youtube: youtube, spotify: spotify, tais: tais,
            lyricsController: lyricsController, cloud: cloud, persistence: persistence, home: home,
            musicTaste: musicTaste, importedHistory: importedHistory, tasteAdjustments: tasteAdjustments,
            health: health))
        wireHealth(health)
        wireBlockedArtists(settings.blocked)
        // A tap on "Your instrumentals are ready" opens the Cloud queue (the notification centre's delegate is set
        // here, early: a launch from the notification reaches it before `start()`).
        if !isUITest {
            cloud.installNotificationRouting(router: router)
            wireAutoPrepare()
        }
    }

    /// Settings › Sing › "Prepare songs ahead in the cloud": the runner that picks songs from the listening and the library
    /// and has Cloud Studio send them (never in UI tests). It follows its settings by itself; `start()` turns it on.
    private func wireAutoPrepare() {
        let library = self.library, home = self.home, taste = self.musicTaste, blocked = settings.blocked
        let imported = self.importedHistory, adjustments = self.tasteAdjustments
        let runner = SingPrepareRunner(cloud: cloud, sources: SingPrepareRunner.Sources(
            songs: { library.songs },
            playlists: { library.playlists },
            events: { home.history.events },
            signals: { taste.learnedSignals },
            blocked: { blocked.matcher },
            isAppActive: { UIApplication.shared.applicationState == .active },
            imported: { imported.aggregate },
            adjustments: { adjustments.activeSet(nowMs: currentTimeMillis()) }))
        cloud.autoPrepare = runner
        // The phone's own automatic studio leaves an instrumental the cloud is getting ready to the cloud.
        automaticStudio.cloudPreparesInstrumental = { [weak runner] songId in runner?.owns(songId: songId) ?? false }
    }

    /// `-screen playlistBlocked` blocks Pixel Parade (two songs of "Late Night Drive"); `blockedArtists` lists three.
    private static func seedBlockedDemo(_ blocked: BlockedArtistsStore, screen: DemoScreen?) {
        let names: [String]
        switch screen {
        case .playlistBlocked?: names = ["Pixel Parade"]
        case .blockedArtists?: names = ["Pixel Parade", "The Quiet Arcade", "Hollow Pines"]
        default: return
        }
        for artist in DemoLibrary.snapshot.artists where names.contains(artist.name) {
            blocked.block(artistId: artist.id, name: artist.name)
        }
    }

    /// Blocked artists: the engine skips their songs when it moves on, Home leaves them out of its mixes and lists.
    private func wireBlockedArtists(_ blocked: BlockedArtistsStore) {
        let playback = self.playback, home = self.home, library = self.library
        playback.setBlocklist(blocked.matcher)
        home.setBlocked(blocked.matcher)
        blocked.onChange = { matcher in
            playback.setBlocklist(matcher)
            home.setBlocked(matcher)
            Task { await home.refresh(snapshot: library.snapshot, libraryRevision: library.songsRevision) }
        }
    }

    /// How many heavy jobs run and how many wait (lyric sync, separation, a model install), for Diagnostics.
    func heavyJobCounts() -> (running: Int, waiting: Int) {
        var running = 0, waiting = 0
        for job in tais.studio.jobs.values where job.isActive {
            if job.phase == .running && !job.waiting { running += 1 } else { waiting += 1 }
        }
        for model in ModelCatalog.all {
            guard case .installing = tais.models.state(model.id) else { continue }
            if tais.models.isWaitingToInstall(model.id) || tais.models.isWaitingForForeground(model.id) {
                waiting += 1
            } else {
                running += 1
            }
        }
        return (running, waiting)
    }

    /// What the health monitor needs from the services: when nothing heavy is in flight (the clean-exit marker may be
    /// written) and what to do on a memory warning (release what is idle, stop what nobody asked for) or a critical one.
    private func wireHealth(_ health: AppHealth) {
        let studio = tais.studio
        health.isHeavyWorkIdle = { JobTelemetry.shared.entries().isEmpty }
        health.onMemoryWarning = {
            studio.handleMemoryWarning()
            LocalModelRuntime.shared.unload()
        }
        health.onMemoryCritical = { studio.stopForMemory() }
    }

    /// Launch work, off the first frame: load the library snapshot (cache first, then the store), then start the
    /// Spotify services.
    func start() async {
        guard !launch.isUITest else { return }
        MetricKitCollector.shared.onDiagnostics = { [weak health] crashLike in
            Task { @MainActor in health?.metricKitReported(crashLike: crashLike) }
        }
        MetricKitCollector.shared.start()
        LagMonitor.start()
        library.beginCachedLoad() // decode the snapshot cache and the saved queue alongside the service starts below
        playbackServices?.prepareQueueRestore()
        // Every stored album theme into the synchronous mirror, so cards and pills start with their colours.
        let extractor = colorExtractor, appearance = settings.appearance
        Task(priority: .userInitiated) {
            await extractor.warm(style: appearance.paletteStyle, accuracyLevel: appearance.colorAccuracy)
        }
        // First run: PixlAudio's setup (Android shows `SetupScreen` until `initial_setup_done`).
        if !settings.behavior.initialSetupDone, router.cover == nil { router.present(AppCover.setup) }
        playbackServices?.start()
        youtube.start()
        activeJobs.start()
        musicHaptics.start()
        tais.start()
        automaticStudio.start()
        spatial.start()
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
        let theme = self.theme
        await playbackServices?.restoreQueue(lookup: library.song(id:), beforeRestore: { await theme.seed(for: $0) })
        if hasCache { await library.reconcileWithStore() }
        artistImages?.prefetchMissing()
        let home = self.home, playCounts = self.playCounts, editor = libraryEditor
        Task {
            await home.history.ensureLoaded()
            await playCounts.refresh(editor: editor, revision: home.history.revision)
        }
        // "Most played" follows the engagement table when it changes after the history revision did.
        let reloadPlayCounts: () -> Void = {
            Task { await playCounts.reload(editor: editor, revision: home.history.revision) }
        }
        // A finished listening session also tells "Prepare songs ahead" that its picks may have changed.
        let autoPrepare = cloud.autoPrepare
        playbackServices?.onEngagementRecorded = {
            reloadPlayCounts()
            autoPrepare?.engagementRecorded()
        }
        autoPrepare?.start()
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
        historySync.attach()
        await spotify.start()
        // Listening history: a little after launch, quietly (at most every 6 hours per source).
        let historySync = self.historySync
        if HeavyWorkGate.shared.allowsLaunchWork {
            Task(priority: .utility) {
                try? await Task.sleep(for: .seconds(12))
                historySync.syncIfDue()
            }
        }
        await updates.checkIfDue()
    }

    /// A file opened in PixlAudio from Files or the share sheet (the declared document types; Android's external
    /// intents): a `.pxpl` backup, or the Android app's legacy `.json.gz`, opens the restore flow on it; an M3U
    /// library and plays.
    func open(_ url: URL) {
        guard !launch.isUITest, url.isFileURL else { return }
        if case .setup? = router.cover { return } // the setup comes first (it has its own restore page)
        switch ExternalFiles.kind(of: url) {
        case .backup: openBackup(url)
        case .playlist: openPlaylist(url)
        case .lyrics: openLyrics(url)
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

    /// Library at its root, where the toast of an opened file shows.
    private func showLibraryRoot() {
        router.libraryPath.removeAll()
        router.selection = .library
    }


    /// The colour scheme forced by UI tests, else the user's `app_theme_mode`.
    var preferredColorScheme: ColorScheme? {
        launch.colorScheme ?? theme.preferredColorScheme
    }
}
