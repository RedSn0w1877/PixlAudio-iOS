import Foundation
import PixlModel

/// Stage 14's services in one place (`AppEnvironment.tais`): the on-device models, the TAIS Studio job lane and the
/// current song's instrumental switch. UI tests get demo variants (no network, no Core ML) whose states the launch
/// router sets (`TaisDemo`).
@MainActor
final class TaisServices {
    let models: ModelManager
    let studio: TaisStudio
    let instrumental: InstrumentalController

    init(launch: LaunchConfiguration, settings: SettingsStore, lyricsController: LyricsController,
         playback: PlaybackStore, playbackServices: PlaybackServices?, youtube: YouTubeServices) {
        let isUITest = launch.isUITest
        models = ModelManager(isDemo: isUITest)
        let dependencies: TaisStudio.Dependencies? = isUITest ? nil : TaisStudio.Dependencies(
            settings: settings, lyricsService: lyricsController.lyricsService, lyricsController: lyricsController,
            audioSource: { [weak playbackServices, weak youtube] song in
                try await Self.audioSource(for: song, resolver: playbackServices?.engine.factory.resolver,
                                           downloads: youtube?.downloads)
            })
        studio = TaisStudio(models: models, dependencies: dependencies)
        instrumental = InstrumentalController(playback: playback, engine: playbackServices?.engine, studio: studio)
        if isUITest { TaisDemo.apply(launch: launch, to: self) }
    }

    /// Launch (cheap): installed models and downloads left running.
    func start() {
        models.start()
    }

    /// A decodable URL for `song`: what the player would open when that is a file or a library item; a streamed
    /// song is downloaded first (Android downloads it permanently through the same cache as "Download").
    static func audioSource(for song: Song, resolver: (any PlayableURLResolving)?,
                            downloads: DownloadManager?) async throws -> URL {
        let url = await (resolver ?? DefaultPlayableURLResolver()).playableURL(for: song)
        if let url, url.isFileURL || url.scheme == "ipod-library" { return url }
        // A Spotify song plays its YouTube match (`pixlstream://<videoId>`): download that video (design §7.1's
        // `sp:` fix). Results stay keyed by the Spotify song.
        let ownVideoId = YouTubeSongIdentity.videoId(for: song)
        guard let downloads, let videoId = ownVideoId ?? url.flatMap(YouTubeSongIdentity.videoId(from:)) else {
            throw TaisStudio.JobFailure(message: "This song has no available audio source")
        }
        var download = song
        if ownVideoId == nil, let stream = YouTubeSongIdentity.streamURL(videoId: videoId) {
            download.contentUriString = stream.absoluteString
        }
        if let file = DownloadFiles.existingFile(videoId: videoId) { return file }
        for attempt in 1...3 {
            downloads.download(download)
            let deadline = Date().addingTimeInterval(90)
            waiting: while Date() < deadline {
                try Task.checkCancellation()
                let state = downloads.state(for: download)
                if case .downloaded? = state, let file = DownloadFiles.existingFile(videoId: videoId) { return file }
                if case .failed? = state { break waiting }
                // The download was cancelled (its row in Active jobs, or Cancel all): the job ends rather than start it again.
                if state == nil { throw TaisStudio.JobFailure(message: "The download of \(song.title) was cancelled.") }
                try await Task.sleep(for: .milliseconds(500))
            }
            if attempt < 3 { try await Task.sleep(for: .seconds(Double(attempt * 2))) }
        }
        throw TaisStudio.JobFailure(message: "Couldn't download \(song.title). Check your connection and retry this song.")
    }
}
