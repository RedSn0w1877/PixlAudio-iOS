// Interruption resume rules, ported from DualPlayerEngine.kt (`shouldResumeAfterTransientAudioFocusLoss` and the
// `focusChangeListener` that uses it). On iOS an `AVAudioSession` interruption plays the part of Android's transient
// audio-focus loss; see `AudioFocusResumeState` for the mapping.

import Foundation

/// The pure resume rule (`shouldResumeAfterTransientAudioFocusLoss`).
public enum AudioFocusResumePolicy {
    /// Whether playback should resume once a transient interruption ends: the active (master) deck was playing or
    /// about to play, or a crossfade was running and the incoming (auxiliary) deck was playing. A paused auxiliary
    /// deck outside a transition is ignored.
    @inlinable
    public static func shouldResumeAfterTransientLoss(
        masterPlayWhenReady: Bool,
        masterIsPlaying: Bool,
        transitionRunning: Bool,
        auxiliaryPlayWhenReady: Bool,
        auxiliaryIsPlaying: Bool
    ) -> Bool {
        masterPlayWhenReady || masterIsPlaying || (transitionRunning && (auxiliaryPlayWhenReady || auxiliaryIsPlaying))
    }
}

/// What the player should do in response to an interruption event.
public struct AudioFocusActions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Stop the active deck (`playWhenReady = false`).
    public static let pauseMaster = AudioFocusActions(rawValue: 1 << 0)
    /// Stop the auxiliary (crossfade) deck.
    public static let pauseAuxiliary = AudioFocusActions(rawValue: 1 << 1)
    /// Give up the audio session (Android `abandonAudioFocus`; iOS: deactivate if appropriate).
    public static let abandonFocus = AudioFocusActions(rawValue: 1 << 2)
    /// Resume the active deck.
    public static let resumeMaster = AudioFocusActions(rawValue: 1 << 3)
    /// Resume the auxiliary deck (only while a transition is running).
    public static let resumeAuxiliary = AudioFocusActions(rawValue: 1 << 4)
}

/// Snapshot of both decks when an interruption begins.
public struct DeckPlaybackSnapshot: Sendable, Hashable {
    public var masterPlayWhenReady: Bool
    public var masterIsPlaying: Bool
    public var transitionRunning: Bool
    public var auxiliaryPlayWhenReady: Bool
    public var auxiliaryIsPlaying: Bool

    public init(masterPlayWhenReady: Bool, masterIsPlaying: Bool, transitionRunning: Bool,
                auxiliaryPlayWhenReady: Bool = false, auxiliaryIsPlaying: Bool = false) {
        self.masterPlayWhenReady = masterPlayWhenReady
        self.masterIsPlaying = masterIsPlaying
        self.transitionRunning = transitionRunning
        self.auxiliaryPlayWhenReady = auxiliaryPlayWhenReady
        self.auxiliaryIsPlaying = auxiliaryIsPlaying
    }
}

/// The `isFocusLossPause` bookkeeping of DualPlayerEngine's focus listener as a value type.
///
/// Android → iOS mapping: `AUDIOFOCUS_LOSS_TRANSIENT` → `AVAudioSession.interruptionNotification` with type
/// `.began`; `AUDIOFOCUS_GAIN` → `.ended` with the `.shouldResume` option; `AUDIOFOCUS_LOSS` → a permanent loss
/// (e.g. another app taking over for good). An `.ended` without `.shouldResume` keeps playback paused
/// (`interruptionEnded(shouldResume: false, …)`), which iOS asks of apps.
public struct AudioFocusResumeState: Sendable, Hashable {
    /// True when playback was paused by a transient loss and should come back on gain.
    public private(set) var isFocusLossPause: Bool

    public init(isFocusLossPause: Bool = false) { self.isFocusLossPause = isFocusLossPause }

    /// `AUDIOFOCUS_LOSS`: pause both decks, forget any pending resume and give up focus.
    public mutating func permanentLoss() -> AudioFocusActions {
        isFocusLossPause = false
        return [.pauseMaster, .pauseAuxiliary, .abandonFocus]
    }

    /// `AUDIOFOCUS_LOSS_TRANSIENT`: remember whether to resume, then pause both decks.
    public mutating func transientLoss(_ decks: DeckPlaybackSnapshot) -> AudioFocusActions {
        isFocusLossPause = AudioFocusResumePolicy.shouldResumeAfterTransientLoss(
            masterPlayWhenReady: decks.masterPlayWhenReady,
            masterIsPlaying: decks.masterIsPlaying,
            transitionRunning: decks.transitionRunning,
            auxiliaryPlayWhenReady: decks.auxiliaryPlayWhenReady,
            auxiliaryIsPlaying: decks.auxiliaryIsPlaying
        )
        return [.pauseMaster, .pauseAuxiliary]
    }

    /// `AUDIOFOCUS_GAIN`: resume if the pause came from a transient loss (the auxiliary deck only while a transition
    /// is still running).
    public mutating func gain(transitionRunning: Bool) -> AudioFocusActions {
        guard isFocusLossPause else { return [] }
        isFocusLossPause = false
        return transitionRunning ? [.resumeMaster, .resumeAuxiliary] : [.resumeMaster]
    }

    /// iOS: an interruption ended. With `.shouldResume` this is `gain`; without it the system asks the app to stay
    /// paused, so the pending resume is dropped.
    public mutating func interruptionEnded(shouldResume: Bool, transitionRunning: Bool) -> AudioFocusActions {
        if shouldResume { return gain(transitionRunning: transitionRunning) }
        isFocusLossPause = false
        return []
    }

    /// `AUDIOFOCUS_REQUEST_DELAYED` (Android `requestAudioFocus`): the system queued the request behind a transient
    /// holder, so pause now and resume on the eventual gain. iOS has no delayed grant; kept for parity.
    public mutating func delayedGrant(transitionRunning: Bool) -> AudioFocusActions {
        isFocusLossPause = true
        return transitionRunning ? [.pauseMaster, .pauseAuxiliary] : [.pauseMaster]
    }
}
