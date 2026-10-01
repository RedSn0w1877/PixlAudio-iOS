// Port of `presentation/lyrics/LyricsClock.kt`: the lyrics time base (spec §3.4).
//
// Android reads the player through provider lambdas; on iOS the display-link driver reads the player timebase itself
// and passes the value in (`tick(frameNanos:positionMs:offsetMs:)`), so the clock stays a plain value type.

import Foundation
import PixlFoundation

/// The lyrics time base. Once per frame, `tick` takes the player position (frame-accurate and speed-aware, read on
/// the main thread), adds the lyric sync offset and publishes the result as `currentMs`.
///
/// - **Monotonic guard:** while playing, backward steps smaller than `backwardJitterMs` are rejected; a position
///   extrapolation can jitter backward when the player updates its state.
/// - **Seek detection:** a jump of more than `seekThresholdMs` away from the prediction (last time + elapsed frame
///   time × speed while playing) counts as a seek; the engine picks it up once through `consumeSeek()`.
public struct LyricsClock: Sendable, Equatable {
    public static let backwardJitterMs: Int64 = 80
    public static let seekThresholdMs: Int64 = 1_000

    /// Lyrics time in ms: `playerPosition + lyricsSyncOffset`, guarded. (Android `currentMs` / `nowMs`.)
    public private(set) var currentMs: Int64 = 0

    /// Set by the owner from the player state; the guard and the prediction only apply while playing.
    public var isPlaying = false

    /// Playback speed used to predict the next position (seek detection only).
    public var playbackSpeed: Float = 1

    /// Number of seeks detected since construction or `reset()`.
    public private(set) var seekCount = 0

    private var initialized = false
    private var lastFrameNanos: Int64 = 0
    private var seekPending = false
    private var rebasePending = false

    public init() {}

    /// The frame loop went idle: the next `tick` must not predict across the idle gap (that gap is wall-clock time
    /// with no frames, and would read as a seek on resume).
    public mutating func rebase() {
        rebasePending = true
    }

    /// Samples the player once. Call exactly once per frame, before `LyricsEngine.step`.
    /// - Returns: true if this sample was a seek.
    @discardableResult
    public mutating func tick(frameNanos: Int64, positionMs: Int64, offsetMs: Int64 = 0) -> Bool {
        tick(frameNanos: frameNanos, rawMs: positionMs &+ offsetMs)
    }

    /// Samples an already offset-adjusted lyrics time (`position + offset`).
    @discardableResult
    public mutating func tick(frameNanos: Int64, rawMs raw: Int64) -> Bool {
        if !initialized {
            initialized = true
            lastFrameNanos = frameNanos
            currentMs = raw
            return false
        }
        let elapsedMs: Int64 = rebasePending ? 0 : Swift.max((frameNanos &- lastFrameNanos) / 1_000_000, 0)
        rebasePending = false
        lastFrameNanos = frameNanos

        // `(elapsedMs * playbackSpeed).toLong()`: Long × Float is Float in Kotlin.
        let predicted = isPlaying ? currentMs &+ KotlinMath.toLong(Float(elapsedMs) * playbackSpeed) : currentMs
        let distance = raw &- predicted
        // Kotlin `abs(Long.MIN_VALUE)` stays negative (no seek); Swift `abs` would trap.
        let isSeek = distance != Int64.min && abs(distance) > Self.seekThresholdMs
        if isSeek {
            seekPending = true
            seekCount += 1
            currentMs = raw
            return true
        }
        let backward = currentMs &- raw
        if isPlaying && backward >= 1 && backward < Self.backwardJitterMs {
            // Jitter: hold the current time rather than stepping back.
            return false
        }
        currentMs = raw
        return false
    }

    /// Returns whether a seek happened since the last call, and clears the flag.
    public mutating func consumeSeek() -> Bool {
        let s = seekPending
        seekPending = false
        return s
    }

    /// Flags a seek the owner knows about (e.g. tap-to-seek) without waiting for detection.
    public mutating func markSeek() {
        seekPending = true
        seekCount += 1
    }

    /// Forget the history (song change): the next `tick` adopts the position as-is.
    public mutating func reset() {
        initialized = false
        seekPending = false
    }
}
