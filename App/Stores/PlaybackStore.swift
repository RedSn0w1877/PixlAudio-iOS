import Foundation
import Observation
import PixlModel

/// What is playing — never *where* in the song. Position is read on demand (`positionMs()`) from the engine's
/// timebase; the scrubber samples it ≤ 4 Hz with `TimelineView`, lyrics per display-link tick (stage 9).
@Observable
final class PlaybackStore {
    private(set) var queue: [Song] = []
    private(set) var currentIndex: Int?
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var isShuffleEnabled = false
    private(set) var lastError: String?

    private let engine: any PlaybackEngine
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    init(engine: any PlaybackEngine) {
        self.engine = engine
        let events = engine.events
        eventsTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    var current: Song? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var hasItem: Bool { current != nil }

    // MARK: Commands

    /// Plays `songs` from `startIndex` (Android `showAndPlaySong` / `playSongs`).
    func play(_ songs: [Song], startIndex: Int = 0, startPositionMs: Int64 = 0, playWhenReady: Bool = true) {
        guard !songs.isEmpty else { return }
        queue = songs
        currentIndex = min(max(startIndex, 0), songs.count - 1)
        engine.setQueue(songs, startIndex: currentIndex ?? 0, startPositionMs: startPositionMs,
                        playWhenReady: playWhenReady)
    }

    /// Plays one song within `context` (defaults to just that song).
    func play(_ song: Song, in context: [Song]? = nil) {
        let list = context ?? [song]
        play(list, startIndex: list.firstIndex(where: { $0.id == song.id }) ?? 0)
    }

    func togglePlayPause() {
        guard hasItem else { return }
        isPlaying ? engine.pause() : engine.play()
    }

    func skipToNext() { engine.skipToNext() }
    func skipToPrevious() { engine.skipToPrevious() }
    func seek(toMs positionMs: Int64) { engine.seek(toMs: positionMs) }

    func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        engine.setRepeatMode(mode)
    }

    func setShuffleEnabled(_ enabled: Bool) {
        isShuffleEnabled = enabled
        engine.setShuffleEnabled(enabled)
    }

    // MARK: Position (read on demand, never observed)

    func positionMs() -> Int64 { engine.currentPositionMs() }
    func durationMs() -> Int64 { engine.currentDurationMs() }

    // MARK: Events

    private func handle(_ event: PlaybackEngineEvent) {
        switch event {
        case .currentIndexChanged(let index):
            if currentIndex != index { currentIndex = index }
        case .playingChanged(let playing):
            if isPlaying != playing { isPlaying = playing }
        case .preparingChanged(let preparing):
            if isPreparing != preparing { isPreparing = preparing }
        case .queueEnded:
            if isPlaying { isPlaying = false }
        case .failed(let message):
            lastError = message
        }
    }
}
