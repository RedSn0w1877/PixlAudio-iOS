import AVFoundation
import Foundation
import PixlModel

/// The sync editor's view of the player (Android: `PlaybackStateHolder` + `DualPlayerEngine` +
/// `TransitionController` as used by `LyricsSyncEditorStateHolder`). Explicit play / pause (never a toggle), exact
/// positions read on demand, pitch-preserving rate, and — on the real engine — the exact-timing session (no hand-over,
/// pause at the end of the song) with crossfades suspended. UI tests drive `DemoPlaybackEngine` through the store and
/// skip the engine-only parts.
@MainActor
final class LyricsSyncPlayer {
    static let owner = "lyrics_sync"

    let playback: PlaybackStore
    private let engine: DualDeckEngine?
    /// Stage 14's instrumental switch: suspended for the session so the person hears the vocals they are timing.
    private let instrumental: InstrumentalController?
    /// What we asked for last (the store only learns the engine's state through its event stream).
    private(set) var playWhenReady: Bool
    /// The song reached its end during the session (the engine paused on it).
    var onSongEnded: (() -> Void)?
    private var sessionOpen = false

    init(playback: PlaybackStore, engine: DualDeckEngine?, instrumental: InstrumentalController? = nil) {
        self.playback = playback
        self.engine = engine
        self.instrumental = instrumental
        playWhenReady = playback.isPlaying
    }

    var currentSong: Song? { playback.current }

    /// The engine's rate now (restored when the session ends).
    var currentRate: Float { engine?.rate ?? 1 }

    func positionMs() -> Int64 { playback.positionMs() }
    func durationMs() -> Int64 { playback.durationMs() }

    func play() {
        playWhenReady = true
        playback.resume()
    }

    func pause() {
        playWhenReady = false
        playback.pause()
    }

    /// The store reported a play-state change (the engine's own pauses: interruptions, the end of the song).
    func storeReported(playing: Bool) { playWhenReady = playing }

    func seek(toMs ms: Int64) { playback.seek(toMs: max(0, ms)) }

    func setRate(_ rate: Float) { playback.setPlaybackRate(rate) }

    /// Android `beginExactTimingSession` + `TransitionController.suspend` + `InstrumentalCrossfadeController.suspend`.
    func beginSession() {
        guard !sessionOpen else { return }
        sessionOpen = true
        instrumental?.suspend(owner: Self.owner)
        guard let engine else { return }
        engine.beginExactTimingSession()
        engine.suspendTransitions(owner: Self.owner)
        engine.onExactTimingItemEnded = { [weak self] in
            self?.playWhenReady = false
            self?.onSongEnded?()
        }
    }

    /// Puts everything back. Idempotent.
    func endSession(restoreRate: Float) {
        guard sessionOpen else { return }
        sessionOpen = false
        // Always, not only when it differs (Android: a speed change may still be in flight).
        playback.setPlaybackRate(restoreRate)
        instrumental?.resume(owner: Self.owner)
        guard let engine else { return }
        engine.onExactTimingItemEnded = nil
        engine.endExactTimingSession()
        engine.resumeTransitions(owner: Self.owner)
    }

    /// Bluetooth output (A2DP / LE / HFP) gets the longer default reaction offset (Android `isBluetoothRoute`).
    static func isBluetoothRoute() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.portType) }
    }
}
