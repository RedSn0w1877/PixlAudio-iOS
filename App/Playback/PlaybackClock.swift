import Foundation

/// The playback position, read on demand from the engine's player timebase (architecture §2). It holds no state and
/// is never observable: the scrubber samples it at most 4 times a second from a `TimelineView`, the lyrics view once
/// per display-link tick (stage 9). Nothing pushes position into SwiftUI.
@MainActor
struct PlaybackClock {
    private let engine: any PlaybackEngine

    init(engine: any PlaybackEngine) {
        self.engine = engine
    }

    /// Current position in milliseconds (`CMTimebaseGetTime` on the active item, or the pending seek target).
    var positionMs: Int64 { engine.currentPositionMs() }

    /// The current item's duration in milliseconds (0 while unknown).
    var durationMs: Int64 { engine.currentDurationMs() }

    /// Position as a 0…1 fraction of the duration (0 while the duration is unknown).
    var fraction: Double {
        let duration = durationMs
        guard duration > 0 else { return 0 }
        return min(max(Double(positionMs) / Double(duration), 0), 1)
    }
}
