import Observation

/// What is playing — never *where* in the song (position is read on demand from the player timebase).
///
/// Stage 0: demo only (no audio). Stage 5 puts the real `PlaybackEngine` behind this store.
@Observable
final class PlaybackStore {
    private(set) var current: DemoSong?
    private(set) var isPlaying = false
    private var queue: [DemoSong]

    var hasItem: Bool { current != nil }

    init(demoQueue: [DemoSong]) {
        queue = demoQueue
        current = demoQueue.first
    }

    func play(_ song: DemoSong) {
        current = song
        isPlaying = true
    }

    func togglePlayPause() {
        guard current != nil else { return }
        isPlaying.toggle()
    }

    func skipToNext() {
        guard let current, let index = queue.firstIndex(of: current), !queue.isEmpty else { return }
        self.current = queue[(index + 1) % queue.count]
    }
}
