import Foundation

/// What the spoken host (Endless Listening, `HostVoiceController`) reads from the decks. Read-only, main actor, nothing stored: the rules
/// that decide with these numbers are `HostVoice` in PixlLibrary.
extension DualDeckEngine {
    /// The music is really playing (not asked to, not loading, not paused by a call or an unplugged route).
    var hostIsPlaying: Bool { playWhenReady && active.player.timeControlStatus == .playing }

    /// The id of the song the active deck plays now; nil while one loads.
    var hostPlayingSongId: String? { activeItem?.song.id }

    /// The song the queue is on, which is the one a note is about (a crossfade shows the next one while the old one still sounds).
    var hostQueueSongId: String? { queue.current?.song.id }

    /// A line may bring the music down only at a calm moment: playing, the audio session live, no transition or hand-over running or
    /// planned to start within the line, and no duck already held.
    var hostCanDuck: Bool {
        hostIsPlaying && session.isActive && fade == nil && scheduledHandOver == nil && !hostDuck.isActive
    }

    /// The playhead and what is left of the song, in milliseconds; `remainingMs` is -1 when the length is unknown.
    func hostTiming() -> (positionMs: Int64, remainingMs: Int64) {
        let position = max(currentPositionMs(), 0)
        let duration = currentDurationMs()
        return (position, duration > 0 ? max(duration - position, 0) : -1)
    }
}
