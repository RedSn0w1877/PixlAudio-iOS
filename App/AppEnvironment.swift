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
    /// Spotify account, library sync, YouTube matching and catalogue (stage 12).
    let spotify: SpotifyService

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
        let spotify = SpotifyService(launch: launch, accounts: accounts, persistence: persistence)
        self.spotify = spotify
        lyrics = LyricsStore()
        artwork = .shared
        let extractor = ColorExtractor(pipeline: .shared, persistence: persistence)
        colorExtractor = extractor
        theme = ThemeStore(extractor: extractor, appearance: settings.appearance)
        let home = HomeStore.make(launch: launch)
        self.home = home

        // Stage 5: the dual-deck AVPlayer engine for real launches; UI tests keep the demo engine.
        if isUITest {
            playbackServices = nil
            playback = PlaybackStore(engine: DemoPlaybackEngine())
        } else {
            let services = PlaybackServices(settings: settings, persistence: persistence)
            // Listening sessions feed Home's history (Recently Played, Stats, mixes) — one owner of the file.
            let history = home.history
            services.recordHistory = { songId, durationMs, timestamp in
                history.record(songId: songId, durationMs: durationMs, endTimestampMs: timestamp)
            }
            // Stage 12: Spotify songs (`spotify://<id>`) play through their YouTube match; keep this the outermost
            // resolver (after any other stage's) so other songs reach the inner ones unchanged.
            services.engine.factory.resolver = spotify.playableURLResolver(base: services.engine.factory.resolver)
            playbackServices = services
            playback = PlaybackStore(engine: services.engine)
        }

        if isUITest {
            library = LibraryStore(snapshot: DemoLibrary.snapshot)
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
        } else {
            let loader = persistence.map { SnapshotLoader(persistence: $0, cacheURL: SnapshotLoader.defaultCacheURL()) }
            let importer = persistence.map { LocalLibraryImporter(persistence: $0) }
            LocalLibraryImporter.installArtworkLoader()
            let library = LibraryStore(loader: loader, importer: importer)
            self.library = library
            libraryImporter = importer
            libraryAutoRefresh = importer == nil ? nil : LibraryAutoRefresh(library: library)
            searchProviders = [.library: LibrarySearchProvider(),
                               .spotify: SpotifyCatalogSearchProvider(service: spotify),
                               .youtubeMusic: UnavailableSearchProvider(source: .youtubeMusic)]
        }
    }

    /// Launch work, off the first frame: load the library snapshot (cache first, then the store), then start the
    /// automatic incremental rescans (launch, foreground, music-library changes).
    func start() async {
        guard !launch.isUITest else { return }
        playbackServices?.start()
        let library = self.library, playback = self.playback
        spotify.attach(reloadLibrary: { await library.reloadFromStore() }, isPlaybackActive: { playback.isPlaying })
        spotify.songLookup = { library.song(id: $0) }
        await library.load()
        playbackServices?.restoreQueue(lookup: library.song(id:))
        libraryAutoRefresh?.start()
        await spotify.start()
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
