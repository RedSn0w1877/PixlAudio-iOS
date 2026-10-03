import Foundation

/// The playback position, read on demand from the engine's player timebase (architecture §2). It holds no state and
/// is never observable: the scrubber samples it at most 4 times a second from a `TimelineView`, the lyrics view once
/// per display-link tick (stage 9). Nothing pushes position into SwiftUI.
@MainActor
struct PlaybackClock {
    private let engine: any PlaybackEngine
    /// The remote output driving playback right now (Spotify Connect), looked up on each read.
    private let remote: @MainActor () -> (any RemotePlaybackOutput)?

    init(engine: any PlaybackEngine, remote: @escaping @MainActor () -> (any RemotePlaybackOutput)? = { nil }) {
        self.engine = engine
        self.remote = remote
    }

    /// Current position in milliseconds (`CMTimebaseGetTime` on the active item, or the pending seek target; the
    /// remote's interpolated position while Spotify Connect plays).
    var positionMs: Int64 { remote()?.remotePositionMs() ?? engine.currentPositionMs() }

    /// The current item's duration in milliseconds (0 while unknown).
    var durationMs: Int64 {
        if let remote = remote() {
            let duration = remote.remoteDurationMs()
            if duration > 0 { return duration }
        }
        return engine.currentDurationMs()
    }

    /// Position as a 0…1 fraction of the duration (0 while the duration is unknown).
    var fraction: Double {
        let duration = durationMs
        guard duration > 0 else { return 0 }
        return min(max(Double(positionMs) / Double(duration), 0), 1)
    }
}
