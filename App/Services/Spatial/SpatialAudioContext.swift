import Foundation
import PixlModel

/// What `AppEnvironment` hands the two halves of Spatial audio when the app is put together:
/// every store and service either of them may need. `SpatialLibraryFactory` (the cloud side) and
/// `SpatialPlaybackFactory` (the engine side) each build their half from it, so neither edits `AppEnvironment`.
///
/// It is made in `AppEnvironment.init`, on real launches and in UI tests alike (`launch.isUITest`: no real playback
/// stack, the demo Cloud Studio), and before `start()`: nothing may run from here that needs the library loaded.
struct SpatialAudioContext {
    let launch: LaunchConfiguration
    /// Where settings live: `.standard`, or the UI tests' own suite.
    let defaults: UserDefaults
    let settings: SettingsStore
    let library: LibraryStore
    let playback: PlaybackStore
    /// The real playback stack (engine, decks, audio session); nil in UI tests.
    let playbackServices: PlaybackServices?
    let youtube: YouTubeServices
    let spotify: SpotifyService
    /// Sing: `tais.instrumental` says whether the instrumental plays.
    let tais: TaisServices
    /// The lyrics of the playing song (word timings place an in-song switch at a quiet moment, as Sing does).
    let lyricsController: LyricsController
    /// Cloud Studio: the keys, the queue, the transfers.
    let cloud: CloudStudio
    let persistence: PersistenceActor?
    /// The listening history, taste signals and adjustments behind the "prepare ahead" ranking.
    let home: HomeStore
    let musicTaste: MusicTasteStore
    let importedHistory: ImportedHistoryStore
    let tasteAdjustments: TasteAdjustmentStore
    let health: AppHealth

    /// The seven settings as they are stored now.
    var settingsStore: CloudAudioSettingsStore { CloudAudioSettingsStore(defaults: defaults) }

    /// The settings in force now (the model applies them again at `start()` and after every change).
    var settingsNow: CloudAudioSettings {
        settingsStore.load(builtInCloudKeys: cloud.settings.builtInAvailable)
    }
}
