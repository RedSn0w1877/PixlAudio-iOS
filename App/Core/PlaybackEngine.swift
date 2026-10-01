import Foundation
import PixlModel

/// What an engine reports back to `PlaybackStore`. Never position: that is read on demand (`currentPositionMs()`).
nonisolated enum PlaybackEngineEvent: Sendable, Equatable {
    /// The item at `index` of the queue became current (nil = nothing loaded).
    case currentIndexChanged(Int?)
    case playingChanged(Bool)
    /// The engine is loading / buffering the current item (mini player "Preparing playback…").
    case preparingChanged(Bool)
    /// The queue reached its end with repeat off.
    case queueEnded
    case failed(message: String)
    /// The play order changed (shuffle, queue edits, a restored queue). `currentIndex` indexes `songs`.
    case queueChanged([Song], currentIndex: Int?)
    /// Repeat mode changed outside `setRepeatMode` (lock screen, sleep timer's counted play, restore).
    case repeatModeChanged(RepeatMode)
    /// Shuffle changed outside `setShuffleEnabled` (lock screen, restore).
    case shuffleChanged(Bool)
}

/// Android `Player.REPEAT_MODE_*` values (stored under `repeat_mode`).
nonisolated enum RepeatMode: Int, Sendable, CaseIterable {
    case off = 0
    case one = 1
    case all = 2
}

/// The seam between the UI and audio. Stage 5 implements it with the dual-deck AVPlayer engine
/// (`App/Playback/DualDeckEngine.swift`); `DemoPlaybackEngine` (no audio) backs UI tests and previews.
///
/// Rules: commands return immediately (work happens on the engine's own queues); events are delivered on the
/// main actor through `events`; position is never pushed — call `currentPositionMs()` when you need it.
@MainActor
protocol PlaybackEngine: AnyObject {
    /// Events, in order. One consumer (`PlaybackStore`).
    var events: AsyncStream<PlaybackEngineEvent> { get }

    /// Replaces the queue and loads `songs[startIndex]`.
    func setQueue(_ songs: [Song], startIndex: Int, startPositionMs: Int64, playWhenReady: Bool)
    func play()
    func pause()
    func skipToNext()
    /// Android semantics: restarts the current song when more than 3 s in, else goes to the previous one.
    func skipToPrevious()
    func seek(toMs positionMs: Int64)
    func setRepeatMode(_ mode: RepeatMode)
    func setShuffleEnabled(_ enabled: Bool)

    /// The current position, read from the player timebase (cheap; call at most a few times a second).
    func currentPositionMs() -> Int64
    /// The current item's duration (0 while unknown).
    func currentDurationMs() -> Int64

    // Queue editing and rate (stage 5). Defaults below make them optional for engines without a queue model.
    /// Inserts songs right after the current one ("Play next").
    func playNext(_ songs: [Song])
    /// Appends songs to the queue ("Add to queue").
    func addToQueue(_ songs: [Song])
    /// Moves the queue entry at `from` to `to` (indices into the current play order).
    func moveQueueItem(from: Int, to: Int)
    func removeQueueItem(at index: Int)
    /// Plays the queue entry at `index` from its start.
    func skipToQueueItem(at index: Int)
    /// Pitch-preserving playback rate (1 = normal).
    func setPlaybackRate(_ rate: Float)
}

extension PlaybackEngine {
    func playNext(_ songs: [Song]) {}
    func addToQueue(_ songs: [Song]) {}
    func moveQueueItem(from: Int, to: Int) {}
    func removeQueueItem(at index: Int) {}
    func skipToQueueItem(at index: Int) {}
    func setPlaybackRate(_ rate: Float) {}
}
