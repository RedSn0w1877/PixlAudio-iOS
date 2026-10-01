import Testing
@testable import PixlAudioCore

/// Port of `data/service/player/AudioFocusResumePolicyTest` (4 cases) plus the focus-listener state machine.
@Suite("AudioFocusResumePolicy")
struct AudioFocusResumePolicyTests {
    @Test func transientFocusLossDoesNotResumeWhenPlaybackWasAlreadyPaused() {
        #expect(!AudioFocusResumePolicy.shouldResumeAfterTransientLoss(
            masterPlayWhenReady: false, masterIsPlaying: false, transitionRunning: false,
            auxiliaryPlayWhenReady: false, auxiliaryIsPlaying: false))
    }

    @Test func transientFocusLossResumesWhenMasterWasPlaying() {
        #expect(AudioFocusResumePolicy.shouldResumeAfterTransientLoss(
            masterPlayWhenReady: true, masterIsPlaying: false, transitionRunning: false,
            auxiliaryPlayWhenReady: false, auxiliaryIsPlaying: false))
    }

    @Test func transientFocusLossResumesWhenAuxiliaryTransitionWasPlaying() {
        #expect(AudioFocusResumePolicy.shouldResumeAfterTransientLoss(
            masterPlayWhenReady: false, masterIsPlaying: false, transitionRunning: true,
            auxiliaryPlayWhenReady: false, auxiliaryIsPlaying: true))
    }

    @Test func transientFocusLossIgnoresPausedAuxiliaryOutsideTransition() {
        #expect(!AudioFocusResumePolicy.shouldResumeAfterTransientLoss(
            masterPlayWhenReady: false, masterIsPlaying: false, transitionRunning: false,
            auxiliaryPlayWhenReady: true, auxiliaryIsPlaying: true))
    }

    // Swift-only: the `focusChangeListener` bookkeeping.

    @Test func transientLossThenGainResumesWhatWasPlaying() {
        var state = AudioFocusResumeState()
        let playing = DeckPlaybackSnapshot(masterPlayWhenReady: true, masterIsPlaying: true, transitionRunning: false)
        let r36 = state.transientLoss(playing)
        #expect(r36 == [.pauseMaster, .pauseAuxiliary])
        #expect(state.isFocusLossPause)
        let r38 = state.gain(transitionRunning: false)
        #expect(r38 == [.resumeMaster])
        #expect(!state.isFocusLossPause)
        let r40 = state.gain(transitionRunning: false)
        #expect(r40 == [])
    }

    @Test func gainDuringATransitionAlsoResumesTheAuxiliaryDeck() {
        var state = AudioFocusResumeState()
        _ = state.transientLoss(DeckPlaybackSnapshot(masterPlayWhenReady: false, masterIsPlaying: false,
                                                     transitionRunning: true, auxiliaryPlayWhenReady: true))
        let r47 = state.gain(transitionRunning: true)
        #expect(r47 == [.resumeMaster, .resumeAuxiliary])
    }

    @Test func pausedPlaybackStaysPausedAfterGain() {
        var state = AudioFocusResumeState()
        _ = state.transientLoss(DeckPlaybackSnapshot(masterPlayWhenReady: false, masterIsPlaying: false, transitionRunning: false))
        let r53 = state.gain(transitionRunning: false)
        #expect(r53 == [])
    }

    @Test func permanentLossForgetsThePendingResume() {
        var state = AudioFocusResumeState()
        _ = state.transientLoss(DeckPlaybackSnapshot(masterPlayWhenReady: true, masterIsPlaying: true, transitionRunning: false))
        let r59 = state.permanentLoss()
        #expect(r59 == [.pauseMaster, .pauseAuxiliary, .abandonFocus])
        let r60 = state.gain(transitionRunning: false)
        #expect(r60 == [])
    }

    @Test func iosInterruptionEndedWithoutShouldResumeStaysPaused() {
        var state = AudioFocusResumeState()
        _ = state.transientLoss(DeckPlaybackSnapshot(masterPlayWhenReady: true, masterIsPlaying: true, transitionRunning: false))
        let r66 = state.interruptionEnded(shouldResume: false, transitionRunning: false)
        #expect(r66 == [])
        #expect(!state.isFocusLossPause)
        _ = state.transientLoss(DeckPlaybackSnapshot(masterPlayWhenReady: true, masterIsPlaying: true, transitionRunning: false))
        let r69 = state.interruptionEnded(shouldResume: true, transitionRunning: false)
        #expect(r69 == [.resumeMaster])
    }

    @Test func delayedGrantPausesAndResumesOnGain() {
        var state = AudioFocusResumeState()
        let r74 = state.delayedGrant(transitionRunning: true)
        #expect(r74 == [.pauseMaster, .pauseAuxiliary])
        let r75 = state.gain(transitionRunning: false)
        #expect(r75 == [.resumeMaster])
        let r76 = state.delayedGrant(transitionRunning: false)
        #expect(r76 == [.pauseMaster])
    }
}
