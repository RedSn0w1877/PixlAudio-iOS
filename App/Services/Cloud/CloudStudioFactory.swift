import Foundation
import PixlModel
import PixlNet

extension CloudStudio {
    /// The app's Cloud Studio (`AppEnvironment.init`, so a background relaunch has it before `start()`): live
    /// dependencies for real launches, the demo for UI tests. Nothing runs here — the job list is read on the first
    /// pass, and the transfer session is created when first needed.
    static func make(launch: LaunchConfiguration, defaults: UserDefaults, library: LibraryStore, playback: PlaybackStore,
                     tais: TaisServices, lyricsService: LyricsService?, persistence: PersistenceActor?,
                     playbackServices: PlaybackServices?, youtube: YouTubeServices) -> CloudStudio {
        if launch.isUITest { return CloudDemo.make(launch: launch, defaults: defaults) }
        // PixlAudio's built-in keys when this build carries them (CI, from the CLOUD_DEFAULTS_KEY secret); decrypted on
        // first use, off the main actor.
        let settings = CloudSettings(defaults: defaults, secrets: CloudKeychain(), builtIn: CloudBuiltInKeys())
        let host = LiveCloudStudioHost(
            library: library, playback: playback, lyricsService: lyricsService, studio: tais.studio,
            audioSource: { [weak playbackServices, weak youtube] song in
                // Streamed songs are downloaded permanently first (owner decision), like Android.
                try await TaisServices.audioSource(for: song, resolver: playbackServices?.engine.factory.resolver,
                                                   downloads: youtube?.downloads)
            },
            videoIdForSpotify: { spotifyId in
                (try? await persistence?.matchedVideoId(spotifyId: spotifyId)) ?? nil
            })
        let dependencies = Dependencies(
            store: CloudJobStore(file: CloudJobStore.defaultFile()),
            host: host,
            makeTransfers: { CloudTransfers.shared },
            preparer: LiveCloudAudioPreparer(),
            inspector: LiveCloudFileInspector(),
            makeRunPod: { config in
                guard config.hasRunPod else { return nil }
                return RunPodJobsClient(http: URLSessionHTTPClient(session: CloudPlatform.apiSession),
                                        endpointId: config.trimmedEndpointId, apiKey: config.trimmedRunpodKey)
            },
            makeObjects: { config in
                CloudPlatform.signer(config).map {
                    CloudObjectClient(http: URLSessionHTTPClient(session: CloudPlatform.apiSession), signer: $0)
                }
            },
            nowMs: { currentTimeMillis() },
            monthStartMs: { CloudPlatform.localMonthStartMs($0) },
            newJobKey: { UUID().uuidString.lowercased() },
            build: CloudPlatform.build,
            removeStaged: { CloudTransfers.removeStaged(jobKey: $0) },
            background: CloudBackground())
        return CloudStudio(settings: settings, dependencies: dependencies)
    }
}
