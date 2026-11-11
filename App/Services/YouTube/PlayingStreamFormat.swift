import Foundation
import PixlAudioCore
import PixlModel
import PixlNet

/// What the player is actually playing for a streamed song: SpotiFLAC's FLAC (with its sample rate) or a YouTube
/// stream (with its bitrate). The player's quality label reads this, not the library's `Song`, whose `mimeType` and
/// `sampleRate` describe nothing for a Spotify song: the label used to fall back to the setting's YouTube tier ("High")
/// even while FLAC played (Hoa, 2026-11-11). Android reads the same from ExoPlayer's format.
nonisolated struct PlayingStreamFormat: Sendable, Equatable {
    var mimeType: String
    var sampleRate: Int?
    var bitrateKbps: Int?

    /// The video the engine's current item plays (its own audio, or the render made from it), on the main actor.
    @MainActor
    static func currentVideoId(engine: DualDeckEngine?) -> String? {
        switch engine?.activeItem?.audio {
        case .own(let videoId?)?: videoId
        case .render(let key)?: key.videoId
        default: nil
        }
    }

    /// The format of `videoId`'s audio as this phone has it: a downloaded file, a prepared Opus file, or what the
    /// streaming cache recorded from the first bytes (SpotiFLAC's files are tagged `flac`, YouTube's by itag). Nil
    /// until something is known (the first bytes haven't arrived).
    static func of(videoId: String, cache: StreamCache?, opus: OpusStreamStore?) async -> PlayingStreamFormat? {
        let facts = SpotiFLACTrackRegistry.shared.facts(forVideoId: videoId)
        if let downloaded = DownloadFiles.existingFile(videoId: videoId) {
            if downloaded.pathExtension.lowercased() == "flac" {
                return PlayingStreamFormat(mimeType: "audio/flac", sampleRate: facts?.flacSampleRate)
            }
            return PlayingStreamFormat(mimeType: "audio/mp4", bitrateKbps: 256)
        }
        if opus?.readyFile(videoId: videoId) != nil, !StreamingPlayableURLResolver.flacPlaysInstead(videoId: videoId) {
            return PlayingStreamFormat(mimeType: "audio/opus", sampleRate: 48_000, bitrateKbps: 160)
        }
        guard let meta = await cache?.meta(videoId) else { return nil }
        if meta.itag == "flac" || meta.contentType.lowercased().contains("flac") {
            return PlayingStreamFormat(mimeType: "audio/flac", sampleRate: facts?.flacSampleRate)
        }
        let itag = meta.itag.flatMap(Int.init)
        return PlayingStreamFormat(mimeType: meta.contentType, sampleRate: itag.flatMap(sampleRate(itag:)),
                                   bitrateKbps: itag.flatMap(bitrateKbps(itag:)))
    }

    /// YouTube's audio itags: the nominal bitrate (what the tiers go by).
    static func bitrateKbps(itag: Int) -> Int? {
        switch itag {
        case 139: 48
        case 140: 128
        case 141: 256
        case 249: 50
        case 250: 70
        case 251: 160
        case 774: 256
        case 18: 96
        default: nil
        }
    }

    static func sampleRate(itag: Int) -> Int? {
        switch itag {
        case 249, 250, 251, 774: 48_000
        case 139: 22_050
        case 18: 44_100
        case 140, 141: 44_100
        default: nil
        }
    }
}
