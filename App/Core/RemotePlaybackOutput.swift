import Foundation

/// An output that plays PixlAudio's queue somewhere else and takes over the transport while it does (Spotify
/// Connect: `SpotifyConnectController`). `PlaybackStore` forwards play / pause / skip / seek / repeat / shuffle /
/// "play this entry" to it, keeps the local engine paused (its queue model stays the one shown), and tells it when the
/// queue changes. Position is read on demand, as with the engine: the remote interpolates between its polls.
@MainActor
protocol RemotePlaybackOutput: AnyObject {
    func remotePlay()
    func remotePause()
    func remoteSkipToNext()
    func remoteSkipToPrevious()
    func remoteSeek(toMs positionMs: Int64)
    /// The user picked another queue entry (the queue sheet, a row).
    func remoteSkip(toQueueIndex index: Int)
    /// The engine's repeat mode changed (already applied to the local queue model).
    func remoteRepeatModeChanged(_ mode: RepeatMode)
    /// The queue's entries or order changed (edits, shuffle, a new queue): re-send what plays.
    func remoteQueueChanged()
    /// The remote device's play state.
    var remoteIsPlaying: Bool { get }
    /// Interpolated position of the remote item.
    func remotePositionMs() -> Int64
    /// The remote item's duration (0 = unknown).
    func remoteDurationMs() -> Int64
}
