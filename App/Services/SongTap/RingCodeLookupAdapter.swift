import Foundation
import PixlLibrary
import PixlModel

/// What a ring code's receiver looks a song up with (Android `InnerTubeRingCodeResolver`): YouTube Music's `get_queue` for the one
/// video id the code carries (the anonymous radio source the music brain uses, under the same request budget), turned into the card's
/// payload by PixlCore's `RingCodeSongs`. A failure, no internet or no source (UI tests) is nil and the screen offers the QR code.
nonisolated struct AppRingCodeLookup: RingCodeLookup {
    let source: (any RadioSource)?

    func resolve(videoId: String, nowMs: Int64) async -> SongTapPayload? {
        guard let source, let rows = await source.hydrate(videoIds: [videoId]),
              let row = rows.first(where: { $0.videoId == videoId }) else { return nil }
        return RingCodeSongs.payload(from: row, nowMs: nowMs)
    }
}
