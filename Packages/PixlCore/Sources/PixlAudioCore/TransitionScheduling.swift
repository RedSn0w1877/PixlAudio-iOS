// Transition rule resolution and crossfade scheduling, ported from TransitionRepositoryImpl.resolveTransitionSettings,
// TransitionController.scheduleTransitionFor and DualPlayerEngine.getNextTransitionTarget. The app's transition
// controller drives these pure decisions from its own timers; the constants are Android's.
//
// Note (Android behaviour, kept): every mode except NONE runs the same overlap crossfade — FADE_IN_OUT, OVERLAP and
// SMOOTH differ only through the curves stored with them.

import Foundation
import PixlFoundation
import PixlModel

/// Rule priority: track-pair rule → playlist default → global settings.
public enum TransitionRuleResolver {
    /// `resolveTransitionSettings(playlistId, fromTrackId, toTrackId)`; without a playlist id the global settings
    /// are used (`TransitionController`: "Missing playlistId. Using global settings.").
    /// - Parameter rules: the stored rules (any playlist); the first match wins, like the DAO's single-row query.
    public static func resolve(playlistId: String?, fromTrackId: String, toTrackId: String,
                               rules: [TransitionRule], global: TransitionSettings) -> TransitionResolution {
        guard let playlistId else { return TransitionResolution(settings: global, source: .globalDefault) }
        if let specific = rules.first(where: {
            $0.playlistId == playlistId && $0.fromTrackId == fromTrackId && $0.toTrackId == toTrackId
        }) {
            return TransitionResolution(settings: specific.settings, source: .playlistSpecific)
        }
        if let playlistDefault = rules.first(where: {
            $0.playlistId == playlistId && $0.fromTrackId == nil && $0.toTrackId == nil
        }) {
            return TransitionResolution(settings: playlistDefault.settings, source: .playlistDefault)
        }
        return TransitionResolution(settings: global, source: .globalDefault)
    }
}

/// Repeat mode as the transition logic sees it (Media3 `REPEAT_MODE_*`).
public enum TransitionRepeatMode: Int, Sendable, Hashable, CaseIterable {
    case off = 0
    case one = 1
    case all = 2
}

/// The pure decisions of `TransitionController.scheduleTransitionFor`.
public enum CrossfadeScheduler {
    /// Debounce before preparing the next track (rapid skips).
    public static let debounceMs: Int64 = 1500
    /// Delay after a deck swap before scheduling the new track (its duration has to resolve first).
    public static let swapRescheduleDelayMs: Int64 = 1000
    /// Poll period while the player has no duration yet.
    public static let durationPollMs: Int64 = 500
    /// Shortest fade.
    public static let minFadeMs: Int64 = 500
    /// Kept clear at the very end of a track.
    public static let guardWindowMs: Int64 = 150
    /// How long `performOverlapTransition` waits for a buffering incoming deck before giving up.
    public static let incomingReadyTimeoutMs: Int64 = 3000

    /// Why no crossfade will run for this track.
    public enum SkipReason: Sendable, Hashable {
        /// Crossfade is off in settings and the settings came from the global default.
        case globallyDisabled
        /// Mode NONE or a non-positive duration.
        case disabledOrZeroDuration
        /// The track is shorter than `minFadeMs + guardWindowMs`.
        case trackTooShort
    }

    /// The schedule for one track.
    public enum Plan: Sendable, Hashable {
        /// No crossfade: cancel the prepared deck and let playback continue gaplessly.
        case none(SkipReason)
        /// Prepare the next track; start the fade when the position reaches `transitionPointMs`.
        case crossfade(transitionPointMs: Int64, fadeDurationMs: Int64)
    }

    /// Whether the settings allow a crossfade at all (checked before the next track is prepared and before the
    /// track duration is known).
    public static func skipReason(resolution: TransitionResolution, crossfadeEnabled: Bool) -> SkipReason? {
        if resolution.source == .globalDefault && !crossfadeEnabled { return .globallyDisabled }
        if resolution.settings.mode == .none || resolution.settings.durationMs <= 0 { return .disabledOrZeroDuration }
        return nil
    }

    /// The plan once the track duration is known (`duration > 0`).
    public static func plan(resolution: TransitionResolution, crossfadeEnabled: Bool, trackDurationMs: Int64) -> Plan {
        if let reason = skipReason(resolution: resolution, crossfadeEnabled: crossfadeEnabled) { return .none(reason) }
        if trackDurationMs < minFadeMs + guardWindowMs { return .none(.trackTooShort) }
        let maxFade = max(trackDurationMs - guardWindowMs, minFadeMs)
        let effective = min(max(Int64(resolution.settings.durationMs), minFadeMs), maxFade)
        return .crossfade(transitionPointMs: trackDurationMs - effective, fadeDurationMs: effective)
    }

    /// What to do at the transition point (or immediately when scheduling found the position already past it).
    public enum FireDecision: Sendable, Hashable {
        /// Start the crossfade with this fade length (the remaining time, capped at the planned fade).
        case fire(durationMs: Int)
        /// Too close to the end (nothing left): cancel the prepared deck, no crossfade.
        case tooCloseToEnd
    }

    /// The final check of the countdown: fire with `min(remaining, fade)`, or skip when nothing remains.
    public static func fireDecision(trackDurationMs: Int64, positionMs: Int64, fadeDurationMs: Int64) -> FireDecision {
        let remaining = max(trackDurationMs - positionMs, 0)
        guard remaining > 0 else { return .tooCloseToEnd }
        return .fire(durationMs: Int(KotlinMath.toInt(min(remaining, fadeDurationMs))))
    }

    /// The settings to hand to the engine for a fire decision (`settings.copy(durationMs = adjusted)`).
    public static func firingSettings(_ settings: TransitionSettings, durationMs: Int) -> TransitionSettings {
        var copy = settings
        copy.durationMs = durationMs
        return copy
    }

    /// One countdown step: how long to sleep (ms) when `remainingMs` are left before the transition point at
    /// playback `speed`. Far away it sleeps until ~4 s before the target (speed-scaled); then 250 ms; under 1 s, 50 ms.
    /// A seek or a speed change should wake the countdown early.
    public static func countdownSleepMs(remainingMs: Int64, speed: Float) -> Int64 {
        let s = max(speed, 0.1)
        let sleep: Int64
        if remainingMs > 5000 {
            sleep = KotlinMath.toLong(Float(remainingMs - 4000) / s)
        } else if remainingMs > 1000 {
            sleep = 250
        } else {
            sleep = 50
        }
        return max(min(sleep, remainingMs), 1)
    }

    /// `getNextTransitionTarget`: the queue index the crossfade goes to — the same track under repeat-one, otherwise
    /// the next one; nil at the end of the queue (no wrap-around, even with repeat-all) or when the current track is
    /// not in the queue.
    public static func nextTargetIndex(currentIndex: Int?, queueCount: Int, repeatMode: TransitionRepeatMode) -> Int? {
        guard let currentIndex, queueCount > 0, currentIndex >= 0 else { return nil }
        let target = repeatMode == .one ? currentIndex : currentIndex + 1
        return target < queueCount ? target : nil
    }
}

/// Owners that currently forbid transitions (e.g. the lyrics tap-sync editor), from `TransitionController.suspend`
/// and `resume`.
public struct TransitionSuspensions: Sendable, Hashable {
    public private(set) var owners: Set<String> = []

    public init() {}

    public var isSuspended: Bool { !owners.isEmpty }

    /// Adds an owner. Returns true when this call suspended transitions (first owner): cancel the scheduled job and
    /// the prepared deck.
    @discardableResult
    public mutating func suspend(_ owner: String) -> Bool {
        let inserted = owners.insert(owner).inserted
        return inserted && owners.count == 1
    }

    /// Removes an owner. Returns true when this call lifted the last suspension: reschedule for the current track.
    @discardableResult
    public mutating func resume(_ owner: String) -> Bool {
        owners.remove(owner) != nil && owners.isEmpty
    }
}
