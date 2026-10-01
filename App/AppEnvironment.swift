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
    /// Stage 6: builds the library from folders, Documents and the music library (nil in UI tests).
    let libraryImporter: LocalLibraryImporter?
    private let libraryAutoRefresh: LibraryAutoRefresh?
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

        // Stage 5 replaces the demo engine with the dual-deck AVPlayer engine for real launches.
        playback = PlaybackStore(engine: DemoPlaybackEngine())

        if isUITest {
            library = LibraryStore(snapshot: DemoLibrary.snapshot)
            libraryImporter = nil
            libraryAutoRefresh = nil
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
            let importer = persistence.map { LocalLibraryImporter(persistence: $0) }
            LocalLibraryImporter.installArtworkLoader()
            let library = LibraryStore(loader: loader, importer: importer)
            self.library = library
            libraryImporter = importer
            libraryAutoRefresh = importer == nil ? nil : LibraryAutoRefresh(library: library)
            searchProviders = [.library: LocalSearchProvider(snapshot: .empty),
                               .spotify: UnavailableSearchProvider(source: .spotify),
                               .youtubeMusic: UnavailableSearchProvider(source: .youtubeMusic)]
        }
    }

    /// Launch work, off the first frame: load the library snapshot (cache first, then the store), then start the
    /// automatic incremental rescans (launch, foreground, music-library changes).
    func start() async {
        guard !launch.isUITest else { return }
        await library.load()
        libraryAutoRefresh?.start()
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
