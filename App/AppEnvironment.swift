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
    /// Search providers by source (stage 7c builds the library one on `SearchIndex`; 11/12 add the others).
    let searchProviders: [SearchSource: any SearchProviding]

    init(launch: LaunchConfiguration) {
        self.launch = launch
        let isUITest = launch.isUITest
        router = Router(launch: launch)
        let container = try? PersistenceActor.makeContainer(inMemory: isUITest)
        let persistence = container.map { PersistenceActor(modelContainer: $0) }
        self.persistence = persistence
        let settings = isUITest ? SettingsStore.ephemeral() : SettingsStore()
        self.settings = settings
        accounts = AccountsStore()
        lyrics = LyricsStore()
        artwork = .shared
        let extractor = ColorExtractor(pipeline: .shared, persistence: persistence)
        colorExtractor = extractor
        theme = ThemeStore(extractor: extractor, appearance: settings.appearance)

        // Stage 5: the dual-deck AVPlayer engine for real launches; UI tests keep the demo engine.
        if isUITest {
            playbackServices = nil
            playback = PlaybackStore(engine: DemoPlaybackEngine())
        } else {
            let services = PlaybackServices(settings: settings, persistence: persistence)
            playbackServices = services
            playback = PlaybackStore(engine: services.engine)
        }

        if isUITest {
            library = LibraryStore(snapshot: DemoLibrary.snapshot)
            searchProviders = [.library: LocalSearchProvider(snapshot: DemoLibrary.snapshot),
                               .spotify: UnavailableSearchProvider(source: .spotify),
                               .youtubeMusic: UnavailableSearchProvider(source: .youtubeMusic)]
            if launch.hasSong {
                let songs = DemoLibrary.songs
                playback.play(songs, startIndex: min(launch.songIndex, songs.count - 1),
                              playWhenReady: launch.startsPlaying)
            }
        } else {
            let loader = persistence.map { SnapshotLoader(persistence: $0, cacheURL: SnapshotLoader.defaultCacheURL()) }
            // Stage 6 provides the real importer (folders, Documents, the music library).
            library = LibraryStore(loader: loader, importer: nil)
            searchProviders = [.library: LocalSearchProvider(snapshot: .empty),
                               .spotify: UnavailableSearchProvider(source: .spotify),
                               .youtubeMusic: UnavailableSearchProvider(source: .youtubeMusic)]
        }
    }

    /// Launch work, off the first frame: load the library snapshot (cache first, then the store).
    func start() async {
        guard !launch.isUITest else { return }
        playbackServices?.start()
        await library.load()
        playbackServices?.restoreQueue(lookup: library.song(id:))
    }

    /// The colour scheme forced by UI tests, else the user's `app_theme_mode`.
    var preferredColorScheme: ColorScheme? {
        launch.colorScheme ?? theme.preferredColorScheme
    }
}
