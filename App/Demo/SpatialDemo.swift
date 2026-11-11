import Foundation
import PixlModel

/// UI tests: the Spatial audio states the screenshots show. `SpatialAudioModel.make` calls `apply` on UI-test
/// launches only, right after the model is built (both of its halves are the no-ops there, and the settings start
/// from an emptied suite). Each Spatial `DemoScreen` picks a profile with `model.select(_:)`, sets "Cloud renders" with
/// `model.setCloud(_:)` and pins what plays with `model.setDemo(snapshot:libraryStatus:usage:)`.
///
/// Cloud renders need both switches (spec 6.1): `spatial.cloud`, set here, and Cloud Studio's own "Process songs in the
/// cloud", which the model reads from Cloud Studio's settings when it is built and which a UI test cannot reach from
/// here. `UITests/SpatialScreenshotTests.swift` turns that one on with the launch argument `-cloud_studio_enabled YES`
/// (the argument domain is shared by every `UserDefaults`, the UI-test suite included); without it the sheet shows
/// "On your phone only. Turn on cloud renders for the full version." and Settings the "Cloud processing is off" row.
enum SpatialDemo {
    /// The video the demo song "plays from" (any valid 11-character id).
    static let videoId = "pixlDemo0v1"

    static func apply(launch: LaunchConfiguration, to model: SpatialAudioModel) {
        guard let screen = launch.screen, let state = SpatialDemoState.of(screen) else { return }
        let songs = DemoLibrary.songs
        let songId = launch.hasSong && songs.indices.contains(launch.songIndex) ? songs[launch.songIndex].id : nil
        model.setCloud(state.cloud)
        model.select(state.selection)
        model.setDemo(snapshot: state.snapshot(songId: songId, videoId: videoId), libraryStatus: state.libraryStatus,
                      usage: state.usage)
    }
}

/// One demo state: what is selected, "Cloud renders", what the player does and where the cloud render stands.
nonisolated struct SpatialDemoState: Equatable, Sendable {
    var selection: SpatialSelection
    var cloud: Bool = true
    var output: SpatialOutputKind = .bluetooth
    var singInstrumentalOn = false
    var audible: SpatialAudible = .stereo
    var libraryStatus = RenditionStatus.none
    var usage: CloudAudioUsage = .empty

    /// What the Settings demo shows on the phone: 12 songs, 1.4 GB, $1.24 spent this month, 4 sent today.
    static let settingsUsage = CloudAudioUsage(songsReady: 12, bytes: 1_503_238_553, spentThisMonthMicroUSD: 1_240_000,
                                               sentToday: 4)

    /// The player's snapshot for this state (the route rule as the player would answer it, with the default mode).
    func snapshot(songId: String?, videoId: String?) -> SpatialPlaybackSnapshot {
        let route = SpatialRouteMode.headphones
        return SpatialPlaybackSnapshot(songId: songId, videoId: videoId, selection: selection, route: route,
                                       output: output,
                                       routePasses: SpatialActivation.routePasses(mode: route, output: output),
                                       singInstrumentalOn: singInstrumentalOn, audible: audible)
    }

    /// The state each Spatial demo screen shows; nil for every other screen (nothing is seeded there).
    static func of(_ screen: DemoScreen) -> SpatialDemoState? {
        switch screen {
        case .spatialAudio, .nowPlayingSpatial:
            SpatialDemoState(selection: .profile(.studio), audible: .onDevice(.studio), libraryStatus: .processing)
        case .settingsPlaybackSpatial:
            SpatialDemoState(selection: .profile(.studio), audible: .onDevice(.studio), libraryStatus: .processing,
                             usage: settingsUsage)
        case .spatialAudioOff:
            SpatialDemoState(selection: .off)
        case .spatialAudioWaitingForWifi:
            SpatialDemoState(selection: .profile(.hall), audible: .onDevice(.hall), libraryStatus: .waitingForNetwork)
        case .spatialAudioCloudLimit:
            SpatialDemoState(selection: .profile(.wide), audible: .onDevice(.wide), libraryStatus: .capReached)
        case .spatialAudioGettingCloudVersion:
            SpatialDemoState(selection: .profile(.intimate), audible: .onDevice(.intimate), libraryStatus: .downloading)
        case .spatialAudioCloudVersion:
            SpatialDemoState(selection: .profile(.night), audible: .render(.night), libraryStatus: .ready)
        case .spatialAudioOnPhoneOnly:
            SpatialDemoState(selection: .profile(.surround), cloud: false, audible: .onDevice(.surround))
        case .spatialAudioCloudFailed:
            SpatialDemoState(selection: .profile(.studio), audible: .onDevice(.studio), libraryStatus: .failed)
        case .spatialAudioHeadphonesOnly, .nowPlayingSpatialHeld:
            SpatialDemoState(selection: .profile(.hall), output: .phoneSpeaker)
        case .spatialAudioPausedForSing:
            SpatialDemoState(selection: .profile(.studio), singInstrumentalOn: true)
        default:
            nil
        }
    }
}
