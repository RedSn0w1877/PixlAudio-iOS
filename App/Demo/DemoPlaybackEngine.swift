import Foundation
import PixlModel

/// A `PlaybackEngine` without audio for UI tests and previews: keeps a queue and an index, and derives the
/// position from a start timestamp (nothing ticks).
@MainActor
final class DemoPlaybackEngine: PlaybackEngine {
    let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation

    private var queue: [Song] = []
    private var index: Int?
    private var isPlaying = false
    private var repeatMode: RepeatMode = .off
    private var accumulatedMs: Int64 = 0
    private var startedAt: Date?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: PlaybackEngineEvent.self)
    }

    func setQueue(_ songs: [Song], startIndex: Int, startPositionMs: Int64, playWhenReady: Bool) {
        queue = songs
        index = songs.indices.contains(startIndex) ? startIndex : (songs.isEmpty ? nil : 0)
        accumulatedMs = startPositionMs
        startedAt = playWhenReady ? Date() : nil
        isPlaying = playWhenReady && index != nil
        continuation.yield(.currentIndexChanged(index))
        continuation.yield(.playingChanged(isPlaying))
    }

    func play() {
        guard index != nil, !isPlaying else { return }
        isPlaying = true
        startedAt = Date()
        continuation.yield(.playingChanged(true))
    }

    func pause() {
        guard isPlaying else { return }
        accumulatedMs = currentPositionMs()
        startedAt = nil
        isPlaying = false
        continuation.yield(.playingChanged(false))
    }

    func skipToNext() {
        guard let index, !queue.isEmpty else { return }
        if index + 1 < queue.count {
            move(to: index + 1)
        } else if repeatMode == .all {
            move(to: 0)
        } else {
            continuation.yield(.queueEnded)
        }
    }

    func skipToPrevious() {
        guard let index else { return }
        if currentPositionMs() > 3000 || index == 0 {
            seek(toMs: 0)
        } else {
            move(to: index - 1)
        }
    }

    func seek(toMs positionMs: Int64) {
        accumulatedMs = max(0, positionMs)
        startedAt = isPlaying ? Date() : nil
    }

    func setRepeatMode(_ mode: RepeatMode) { repeatMode = mode }
    func setShuffleEnabled(_ enabled: Bool) {}

    func playNext(_ songs: [Song]) {
        guard let index else { return }
        queue.insert(contentsOf: songs, at: min(index + 1, queue.count))
        continuation.yield(.queueChanged(queue, currentIndex: index))
    }

    func addToQueue(_ songs: [Song]) {
        guard index != nil else { return }
        queue.append(contentsOf: songs)
        continuation.yield(.queueChanged(queue, currentIndex: index))
    }

    // Stage 8: queue edits from the queue sheet and the album carousel.
    func moveQueueItem(from: Int, to: Int) {
        guard queue.indices.contains(from), queue.indices.contains(to), from != to else { return }
        let song = queue.remove(at: from)
        queue.insert(song, at: to)
        if let index {
            if index == from { self.index = to } else if from < index, to >= index { self.index = index - 1 }
            else if from > index, to <= index { self.index = index + 1 }
        }
        continuation.yield(.queueChanged(queue, currentIndex: self.index))
    }

    func removeQueueItem(at removed: Int) {
        guard queue.indices.contains(removed), removed != index else { return }
        queue.remove(at: removed)
        if let index, removed < index { self.index = index - 1 }
        continuation.yield(.queueChanged(queue, currentIndex: index))
    }

    func skipToQueueItem(at target: Int) {
        guard queue.indices.contains(target) else { return }
        move(to: target)
    }

    func currentPositionMs() -> Int64 {
        let running = startedAt.map { Int64(Date().timeIntervalSince($0) * 1000) } ?? 0
        return min(accumulatedMs + running, currentDurationMs())
    }

    func currentDurationMs() -> Int64 {
        guard let index, queue.indices.contains(index) else { return 0 }
        return queue[index].duration
    }

    private func move(to newIndex: Int) {
        index = newIndex
        accumulatedMs = 0
        startedAt = isPlaying ? Date() : nil
        continuation.yield(.currentIndexChanged(newIndex))
    }
}
