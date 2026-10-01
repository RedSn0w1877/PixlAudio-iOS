// The sleep timer, ported from presentation/viewmodel/SleepTimerStateHolder.kt (duration timer, end of track,
// counted plays) together with the service halves it relies on: MusicService.startCountedPlay/stopCountedPlay and
// the end-of-track pause in MediaControllerSyncStateHolder. A value type; the app feeds it player events and
// carries out the returned effects (pause, seek, repeat mode, scheduling a wake-up, toasts).

import Foundation

/// Sleep timer and counted-play state.
public struct SleepTimer: Sendable, Hashable {
    /// Slider stops of the timer sheet in minutes (`predefinedTimes`; 0 means off).
    public static let predefinedMinutes = [0, 5, 10, 15, 20, 30, 45, 60]
    /// Counted-play slider range (`valueRange = 1f..10f`).
    public static let countedPlayRange = 1...10

    /// The active timer.
    public enum Mode: Sendable, Hashable {
        case off
        /// Pause at `endTimeMs` (epoch ms); `minutes` is the chosen duration (shown in the UI).
        case duration(minutes: Int, endTimeMs: Int64)
        /// Pause when the song with this id finishes.
        case endOfTrack(songId: String)
    }

    /// "Play this song N more times": repeat-one is forced and playback pauses after `target` plays.
    public struct CountedPlay: Sendable, Hashable {
        public var target: Int
        /// Plays started so far (1 = the current one).
        public var count: Int
        public var songId: String
    }

    /// Messages Android shows as toasts (the app localises them).
    public enum Toast: Sendable, Hashable {
        case setForMinutes(Int)
        case cancelled
        case endOfTrackSet
        case endOfTrackNoSong
        /// The user changed song while an end-of-track timer waited for `fromSongId`.
        case endOfTrackSongChanged(fromSongId: String, toSongId: String)
        /// Playback stopped because `songId` ended.
        case stoppedAtEndOfTrack(songId: String)
        case custom(String)
    }

    /// Side effects for the app to carry out, in order.
    public enum Effect: Sendable, Hashable {
        case pause
        case seekToStart
        /// Counted play forces repeat-one and restores off when it stops.
        case setRepeatMode(TransitionRepeatMode)
        /// Wake up / pause at this epoch time (Android's exact alarm).
        case scheduleWakeUp(atMs: Int64)
        case cancelWakeUp
        case toast(Toast)
    }

    /// What the timer row shows (`activeTimerValueDisplay`).
    public enum Display: Sendable, Hashable {
        case minutes(Int)
        case endOfTrack
    }

    public private(set) var mode: Mode = .off
    public private(set) var countedPlay: CountedPlay?
    /// The counted-play slider value (`playCount`; 1 when none).
    public private(set) var playCount: Float = 1

    public init() {}

    /// `activeTimerValueDisplay`.
    public var display: Display? {
        switch mode {
        case .off: return nil
        case .duration(let minutes, _): return .minutes(minutes)
        case .endOfTrack: return .endOfTrack
        }
    }

    /// `activeTimerDurationMinutes`.
    public var activeDurationMinutes: Int? {
        if case .duration(let minutes, _) = mode { return minutes }
        return nil
    }

    /// `isEndOfTrackTimerActive`.
    public var isEndOfTrackActive: Bool {
        if case .endOfTrack = mode { return true }
        return false
    }

    /// The end-of-track target (`EotStateHolder.eotTargetSongId`).
    public var endOfTrackSongId: String? {
        if case .endOfTrack(let id) = mode { return id }
        return nil
    }

    /// Milliseconds until a duration timer fires (nil without one).
    public func remainingMs(nowMs: Int64) -> Int64? {
        if case .duration(_, let end) = mode { return max(end - nowMs, 0) }
        return nil
    }

    // MARK: - Duration timer

    /// `setSleepTimer(durationMinutes)`. A non-positive duration cancels (the sheet's "Off" stop and the service's
    /// `minutes <= 0` rule).
    public mutating func setDuration(minutes: Int, nowMs: Int64) -> [Effect] {
        guard minutes > 0 else { return cancel() }
        var effects: [Effect] = []
        if isEndOfTrackActive { effects += cancel(suppressDefaultToast: true) }
        let end = nowMs + Int64(minutes) * 60_000
        mode = .duration(minutes: minutes, endTimeMs: end)
        effects.append(.scheduleWakeUp(atMs: end))
        effects.append(.toast(.setForMinutes(minutes)))
        return effects
    }

    /// The wake-up fired or a clock check ran: pause once the end time is reached (`ACTION_SLEEP_TIMER_EXPIRED`).
    /// Deviation: Android leaves the timer row showing after it fires (its UI-clearing job was removed); here the
    /// timer is cleared once it has paused playback.
    public mutating func tick(nowMs: Int64) -> [Effect] {
        guard case .duration(_, let end) = mode, nowMs >= end else { return [] }
        mode = .off
        return [.cancelWakeUp, .pause]
    }

    // MARK: - End of track

    /// `setEndOfTrackTimer(enable, currentSongId)`.
    public mutating func setEndOfTrack(_ enable: Bool, currentSongId: String?) -> [Effect] {
        if enable {
            guard let currentSongId else { return [.toast(.endOfTrackNoSong)] }
            // Android cancels a duration job/end time without touching its alarm here; the app cancels the wake-up.
            var effects: [Effect] = []
            if case .duration = mode { effects.append(.cancelWakeUp) }
            mode = .endOfTrack(songId: currentSongId)
            effects.append(.toast(.endOfTrackSet))
            return effects
        }
        if isEndOfTrackActive { return cancel() }
        return []
    }

    // MARK: - Cancel

    /// `cancelSleepTimer(overrideToastMessage, suppressDefaultToast)`: clears both timers (not counted play).
    public mutating func cancel(overrideToast: String? = nil, suppressDefaultToast: Bool = false) -> [Effect] {
        let wasActive = mode != .off
        mode = .off
        var effects: [Effect] = [.cancelWakeUp]
        if let overrideToast {
            effects.append(.toast(.custom(overrideToast)))
        } else if !suppressDefaultToast && wasActive {
            effects.append(.toast(.cancelled))
        }
        return effects
    }

    // MARK: - Counted play

    /// `playCounted(count)` + `MusicService.startCountedPlay`: play the current song `count` times in total
    /// (repeat-one), then pause. Without a current song only the slider value changes, as on Android.
    public mutating func startCountedPlay(_ count: Int, currentSongId: String?) -> [Effect] {
        playCount = Float(count)
        guard let currentSongId else { return [] }
        var effects = stopCountedPlayInternal(restoreRepeatMode: true)
        countedPlay = CountedPlay(target: count, count: 1, songId: currentSongId)
        effects.append(.setRepeatMode(.one))
        return effects
    }

    /// `cancelCountedPlay`.
    public mutating func cancelCountedPlay() -> [Effect] {
        playCount = 1
        return stopCountedPlayInternal(restoreRepeatMode: true)
    }

    private mutating func stopCountedPlayInternal(restoreRepeatMode: Bool) -> [Effect] {
        guard countedPlay != nil else { return [] }
        countedPlay = nil
        return restoreRepeatMode ? [.setRepeatMode(.off)] : []
    }

    // MARK: - Player events

    /// The player looped or advanced on its own (`DISCONTINUITY_REASON_AUTO_TRANSITION`). Under counted play each
    /// loop is one more play; past the target playback pauses and counted play ends.
    public mutating func onAutoTransitionDiscontinuity() -> [Effect] {
        guard var counted = countedPlay else { return [] }
        counted.count += 1
        if counted.count > counted.target {
            countedPlay = counted
            return [.pause] + stopCountedPlayInternal(restoreRepeatMode: true)
        }
        countedPlay = counted
        return []
    }

    /// The current item changed. `isAutomatic` is `MEDIA_ITEM_TRANSITION_REASON_AUTO`; `previousSongId` is the item
    /// before it in the queue.
    /// - End of track: an automatic move away from the target song seeks back to its start, pauses and ends the
    ///   timer; any other change of song cancels the timer with a "song changed" toast.
    /// - Counted play: any other song cancels it (repeat mode back to off).
    public mutating func onMediaItemTransition(newSongId: String?, previousSongId: String?, isAutomatic: Bool) -> [Effect] {
        var effects: [Effect] = []
        if let target = endOfTrackSongId {
            if isAutomatic, let previousSongId, previousSongId == target {
                effects += [.seekToStart, .pause, .toast(.stoppedAtEndOfTrack(songId: previousSongId))]
                effects += cancel(suppressDefaultToast: true)
            } else if let newSongId, newSongId != target {
                effects.append(.toast(.endOfTrackSongChanged(fromSongId: target, toSongId: newSongId)))
                effects += cancel(suppressDefaultToast: true)
            }
        }
        if let counted = countedPlay, newSongId != counted.songId {
            effects += stopCountedPlayInternal(restoreRepeatMode: true)
        }
        return effects
    }

    /// The user changed the repeat mode: anything but repeat-one ends counted play and keeps the user's choice.
    public mutating func onRepeatModeChanged(_ mode: TransitionRepeatMode) -> [Effect] {
        guard countedPlay != nil, mode != .one else { return [] }
        return stopCountedPlayInternal(restoreRepeatMode: false)
    }

    /// Playback reached the end of the queue (`STATE_ENDED`): an end-of-track timer has nothing left to wait for
    /// (the service clears its target here).
    public mutating func onPlaybackEnded() -> [Effect] {
        guard isEndOfTrackActive else { return [] }
        return cancel(suppressDefaultToast: true)
    }
}
