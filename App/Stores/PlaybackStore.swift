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
    /// The device a remote output plays on ("Playing on <device>"), nil while this phone plays.
    private(set) var remoteOutputName: String?

    private let engine: any PlaybackEngine
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    /// Spotify Connect while it drives playback: the transport goes there and the engine stays paused, its queue
    /// model still the one shown (`RemotePlaybackOutput`).
    @ObservationIgnored private weak var remote: (any RemotePlaybackOutput)?
    /// The engine's own play state (what `isPlaying` returns to when the remote output detaches).
    @ObservationIgnored private var engineIsPlaying = false

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

    /// Whether a remote output drives playback.
    var isRemoteActive: Bool { remote != nil }

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
        if let remote {
            // The new queue plays on the remote device; the engine only holds it.
            engine.setQueue(songs, startIndex: currentIndex ?? 0, startPositionMs: startPositionMs, playWhenReady: false)
            remote.remoteQueueChanged()
            return
        }
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
        if let remote {
            isPlaying ? remote.remotePause() : remote.remotePlay()
            return
        }
        isPlaying ? engine.pause() : engine.play()
    }

    /// Explicit play / pause (stage 10's sync editor: two quick calls never cancel out the way two toggles could).
    func resume() {
        guard hasItem else { return }
        if let remote { remote.remotePlay(); return }
        engine.play()
    }

    func pause() {
        if let remote { remote.remotePause(); return }
        engine.pause()
    }

    func skipToNext() {
        if let remote { remote.remoteSkipToNext(); return }
        engine.skipToNext()
    }

    func skipToPrevious() {
        if let remote { remote.remoteSkipToPrevious(); return }
        engine.skipToPrevious()
    }

    func seek(toMs positionMs: Int64) {
        if let remote { remote.remoteSeek(toMs: positionMs); return }
        engine.seek(toMs: positionMs)
    }

    func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        engine.setRepeatMode(mode)
        remote?.remoteRepeatModeChanged(mode)
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
    func skipToQueueItem(at index: Int) {
        if let remote { remote.remoteSkip(toQueueIndex: index); return }
        engine.skipToQueueItem(at: index)
    }
    func setPlaybackRate(_ rate: Float) { engine.setPlaybackRate(rate) }

    // MARK: Position (read on demand, never observed)

    /// A non-observable clock over the engine's timebase, for the scrubber and the lyrics display link.
    var clock: PlaybackClock { PlaybackClock(engine: engine, remote: { [weak self] in self?.remote }) }

    func positionMs() -> Int64 { remote?.remotePositionMs() ?? engine.currentPositionMs() }

    func durationMs() -> Int64 {
        guard let remote else { return engine.currentDurationMs() }
        let duration = remote.remoteDurationMs()
        return duration > 0 ? duration : (current?.duration ?? 0)
    }

    // MARK: Remote output (Spotify Connect)

    /// Hands the transport to `output` (playing on `name`) and pauses the engine; nothing else is torn down.
    func attachRemote(_ output: any RemotePlaybackOutput, name: String, isPlaying playing: Bool) {
        remote = output
        if remoteOutputName != name { remoteOutputName = name }
        engine.pause()
        if isPlaying != playing { isPlaying = playing }
    }

    /// Gives the transport back to the engine (which stays paused until told otherwise).
    func detachRemote() {
        guard remote != nil else { return }
        remote = nil
        remoteOutputName = nil
        if isPlaying != engineIsPlaying { isPlaying = engineIsPlaying }
    }

    /// The remote device's play state.
    func remotePlayingChanged(_ playing: Bool) {
        guard remote != nil, isPlaying != playing else { return }
        isPlaying = playing
    }

    /// The remote device moved to another queue entry: the local model follows (loaded paused, never played).
    func remoteMoved(toQueueIndex index: Int) {
        guard remote != nil, index != currentIndex, queue.indices.contains(index) else { return }
        engine.skipToQueueItem(at: index)
    }

    /// Back on this phone: the remote's song and position, playing (or paused) here.
    func resumeLocally(atQueueIndex index: Int?, positionMs: Int64, play: Bool) {
        detachRemote()
        if let index, index != currentIndex, queue.indices.contains(index) { engine.skipToQueueItem(at: index) }
        engine.seek(toMs: positionMs)
        if play { engine.play() }
    }

    // MARK: Events

    private func handle(_ event: PlaybackEngineEvent) {
        switch event {
        case .currentIndexChanged(let index):
            if currentIndex != index { currentIndex = index }
            syncCurrent()
        case .playingChanged(let playing):
            engineIsPlaying = playing
            if remote != nil {
                // A remote device plays: anything that started the engine (a headset reconnect) is undone.
                if playing { engine.pause() }
                return
            }
            if isPlaying != playing { isPlaying = playing }
        case .preparingChanged(let preparing):
            if isPreparing != preparing { isPreparing = preparing }
        case .queueEnded:
            if remote == nil, isPlaying { isPlaying = false }
        case .failed(let message):
            lastError = message
        case .queueChanged(let songs, let index):
            // The engine's queue holds the songs it was given (it never edits metadata), so the order of ids says
            // whether anything changed. Equal Strings compare by storage: the usual case (the engine echoing the
            // queue `play` just set) is a cheap pass, not a field-by-field compare of thousands of songs.
            let orderChanged = queue.count != songs.count || !queue.elementsEqual(songs, by: { $0.id == $1.id })
            if orderChanged {
                queue = songs
                queueRevision &+= 1
            }
            if currentIndex != index { currentIndex = index }
            syncCurrent()
            if orderChanged { remote?.remoteQueueChanged() }
        case .repeatModeChanged(let mode):
            if repeatMode != mode { repeatMode = mode }
            remote?.remoteRepeatModeChanged(mode)
        case .shuffleChanged(let enabled):
            if isShuffleEnabled != enabled { isShuffleEnabled = enabled }
        }
    }
}
