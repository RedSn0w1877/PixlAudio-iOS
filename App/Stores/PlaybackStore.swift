import Foundation
import Observation
import PixlModel

/// What is playing — never *where* in the song. Position is read on demand (`positionMs()`) from the engine's
/// timebase; the scrubber samples it ≤ 4 Hz with `TimelineView`, lyrics per display-link tick (stage 9).
///
/// `current`, `currentSongId` and `hasItem` are stored (kept in step with `queue` and `currentIndex`), so views that
/// only need the current song — the shell, tab roots, every row's "is this the current song?" — don't observe the
/// whole queue: queue edits no longer re-render them, and a song change re-renders only what shows the current song.
@Observable
final class PlaybackStore {
    private(set) var queue: [Song] = []
    private(set) var currentIndex: Int?
    /// The current song (`queue[currentIndex]`), stored.
    private(set) var current: Song?
    /// `current?.id`, stored: what rows compare against.
    private(set) var currentSongId: String?
    /// Bumped whenever `queue` is replaced (the queue sheet reacts to it instead of comparing every id).
    private(set) var queueRevision = 0
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

    var hasItem: Bool { currentSongId != nil }

    /// Recomputes the stored current song from the queue and index; assigns only what changed.
    private func syncCurrent() {
        let song: Song? = currentIndex.flatMap { queue.indices.contains($0) ? queue[$0] : nil }
        if current != song { current = song }
        if currentSongId != song?.id { currentSongId = song?.id }
    }

    // MARK: Commands

    /// Plays `songs` from `startIndex` (Android `showAndPlaySong` / `playSongs`).
    func play(_ songs: [Song], startIndex: Int = 0, startPositionMs: Int64 = 0, playWhenReady: Bool = true) {
        guard !songs.isEmpty else { return }
        queue = songs
        queueRevision &+= 1
        currentIndex = min(max(startIndex, 0), songs.count - 1)
        syncCurrent()
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

    // Queue editing (stage 5): the engine answers with `queueChanged`.
    /// Inserts right after the current song (Android "Play next"); starts playback when nothing is loaded.
    func playNext(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        guard hasItem else { play(songs); return }
        engine.playNext(songs)
    }

    /// Appends to the queue (Android "Add to queue"); starts playback when nothing is loaded.
    func addToQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        guard hasItem else { play(songs); return }
        engine.addToQueue(songs)
    }
    func moveQueueItem(from: Int, to: Int) { engine.moveQueueItem(from: from, to: to) }
    func removeQueueItem(at index: Int) { engine.removeQueueItem(at: index) }
    func skipToQueueItem(at index: Int) { engine.skipToQueueItem(at: index) }
    func setPlaybackRate(_ rate: Float) { engine.setPlaybackRate(rate) }

    // MARK: Position (read on demand, never observed)

    /// A non-observable clock over the engine's timebase, for the scrubber and the lyrics display link.
    var clock: PlaybackClock { PlaybackClock(engine: engine) }

    func positionMs() -> Int64 { engine.currentPositionMs() }
    func durationMs() -> Int64 { engine.currentDurationMs() }

    // MARK: Events

    private func handle(_ event: PlaybackEngineEvent) {
        switch event {
        case .currentIndexChanged(let index):
            if currentIndex != index { currentIndex = index }
            syncCurrent()
        case .playingChanged(let playing):
            if isPlaying != playing { isPlaying = playing }
        case .preparingChanged(let preparing):
            if isPreparing != preparing { isPreparing = preparing }
        case .queueEnded:
            if isPlaying { isPlaying = false }
        case .failed(let message):
            lastError = message
        case .queueChanged(let songs, let index):
            // The engine's queue holds the songs it was given (it never edits metadata), so the order of ids says
            // whether anything changed. Equal Strings compare by storage: the usual case (the engine echoing the
            // queue `play` just set) is a cheap pass, not a field-by-field compare of thousands of songs.
            if queue.count != songs.count || !queue.elementsEqual(songs, by: { $0.id == $1.id }) {
                queue = songs
                queueRevision &+= 1
            }
            if currentIndex != index { currentIndex = index }
            syncCurrent()
        case .repeatModeChanged(let mode):
            if repeatMode != mode { repeatMode = mode }
        case .shuffleChanged(let enabled):
            if isShuffleEnabled != enabled { isShuffleEnabled = enabled }
        }
    }
}
