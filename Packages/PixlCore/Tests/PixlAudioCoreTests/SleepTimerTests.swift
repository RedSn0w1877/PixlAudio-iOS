import Testing
@testable import PixlAudioCore

/// Swift tests for the SleepTimerStateHolder / counted-play / end-of-track port (no Android unit test exists).
@Suite("SleepTimer")
struct SleepTimerTests {
    @Test func durationTimerSchedulesAndFires() {
        var t = SleepTimer()
        #expect(t.display == nil)
        let effects = t.setDuration(minutes: 15, nowMs: 1_000)
        #expect(effects == [.scheduleWakeUp(atMs: 901_000), .toast(.setForMinutes(15))])
        #expect(t.display == .minutes(15) && t.activeDurationMinutes == 15)
        #expect(t.remainingMs(nowMs: 301_000) == 600_000)
        let v14 = t.tick(nowMs: 900_999)
        #expect(v14 == [])
        let v15 = t.tick(nowMs: 901_000)
        #expect(v15 == [.cancelWakeUp, .pause])
        #expect(t.mode == .off && t.display == nil)
        let v17 = t.tick(nowMs: 999_999)
        #expect(v17 == [])
    }

    @Test func zeroMinutesCancels() {
        var t = SleepTimer()
        _ = t.setDuration(minutes: 5, nowMs: 0)
        let v23 = t.setDuration(minutes: 0, nowMs: 0)
        #expect(v23 == [.cancelWakeUp, .toast(.cancelled)])
        #expect(t.mode == .off)
        let v25 = t.setDuration(minutes: -3, nowMs: 0)
        #expect(v25 == [.cancelWakeUp])
    }

    @Test func cancelToasts() {
        var t = SleepTimer()
        let v30 = t.cancel()
        #expect(v30 == [.cancelWakeUp])
        _ = t.setDuration(minutes: 5, nowMs: 0)
        let v32 = t.cancel(suppressDefaultToast: true)
        #expect(v32 == [.cancelWakeUp])
        _ = t.setDuration(minutes: 5, nowMs: 0)
        let v34 = t.cancel(overrideToast: "Bye")
        #expect(v34 == [.cancelWakeUp, .toast(.custom("Bye"))])
        #expect(SleepTimer.predefinedMinutes == [0, 5, 10, 15, 20, 30, 45, 60])
        #expect(SleepTimer.countedPlayRange == 1...10)
    }

    @Test func endOfTrackNeedsASong() {
        var t = SleepTimer()
        let v41 = t.setEndOfTrack(true, currentSongId: nil)
        #expect(v41 == [.toast(.endOfTrackNoSong)])
        #expect(!t.isEndOfTrackActive)
        _ = t.setDuration(minutes: 10, nowMs: 0)
        let v44 = t.setEndOfTrack(true, currentSongId: "a")
        #expect(v44 == [.cancelWakeUp, .toast(.endOfTrackSet)])
        #expect(t.display == .endOfTrack && t.endOfTrackSongId == "a" && t.activeDurationMinutes == nil)
        let v46 = t.setEndOfTrack(false, currentSongId: "a")
        #expect(v46 == [.cancelWakeUp, .toast(.cancelled)])
        let v47 = t.setEndOfTrack(false, currentSongId: "a")
        #expect(v47 == [])
    }

    @Test func durationReplacesEndOfTrackSilently() {
        var t = SleepTimer()
        _ = t.setEndOfTrack(true, currentSongId: "a")
        let v53 = t.setDuration(minutes: 20, nowMs: 0)
        #expect(v53 == [.cancelWakeUp, .scheduleWakeUp(atMs: 1_200_000), .toast(.setForMinutes(20))])
        #expect(!t.isEndOfTrackActive)
    }

    @Test func endOfTrackPausesWhenTheSongEndsOnItsOwn() {
        var t = SleepTimer()
        _ = t.setEndOfTrack(true, currentSongId: "a")
        let effects = t.onMediaItemTransition(newSongId: "b", previousSongId: "a", isAutomatic: true)
        #expect(effects == [.seekToStart, .pause, .toast(.stoppedAtEndOfTrack(songId: "a")), .cancelWakeUp])
        #expect(t.mode == .off)
    }

    @Test func endOfTrackIsCancelledWhenTheUserChangesSong() {
        var t = SleepTimer()
        _ = t.setEndOfTrack(true, currentSongId: "a")
        let v68 = t.onMediaItemTransition(newSongId: "a", previousSongId: nil, isAutomatic: false)
        #expect(v68 == [])
        let effects = t.onMediaItemTransition(newSongId: "c", previousSongId: "b", isAutomatic: false)
        #expect(effects == [.toast(.endOfTrackSongChanged(fromSongId: "a", toSongId: "c")), .cancelWakeUp])
        #expect(!t.isEndOfTrackActive)
    }

    @Test func endOfTrackClearsWhenPlaybackEnds() {
        var t = SleepTimer()
        let v76 = t.onPlaybackEnded()
        #expect(v76 == [])
        _ = t.setEndOfTrack(true, currentSongId: "a")
        let v78 = t.onPlaybackEnded()
        #expect(v78 == [.cancelWakeUp])
        #expect(t.mode == .off)
    }

    @Test func countedPlayLoopsThenPauses() {
        var t = SleepTimer()
        let v84 = t.startCountedPlay(3, currentSongId: "a")
        #expect(v84 == [.setRepeatMode(.one)])
        #expect(t.playCount == 3 && t.countedPlay == SleepTimer.CountedPlay(target: 3, count: 1, songId: "a"))
        let v86 = t.onAutoTransitionDiscontinuity()
        #expect(v86 == [])
        let v87 = t.onAutoTransitionDiscontinuity()
        #expect(v87 == [])
        #expect(t.countedPlay?.count == 3)
        let v89 = t.onAutoTransitionDiscontinuity()
        #expect(v89 == [.pause, .setRepeatMode(.off)])
        #expect(t.countedPlay == nil)
        let v91 = t.onAutoTransitionDiscontinuity()
        #expect(v91 == [])
    }

    @Test func countedPlayStopsOnSongChangeOrRepeatChange() {
        var t = SleepTimer()
        _ = t.startCountedPlay(5, currentSongId: "a")
        let v97 = t.onMediaItemTransition(newSongId: "a", previousSongId: "a", isAutomatic: true)
        #expect(v97 == [])
        let v98 = t.onMediaItemTransition(newSongId: "b", previousSongId: "a", isAutomatic: false)
        #expect(v98 == [.setRepeatMode(.off)])
        _ = t.startCountedPlay(5, currentSongId: "a")
        let v100 = t.onRepeatModeChanged(.one)
        #expect(v100 == [])
        let v101 = t.onRepeatModeChanged(.all)
        #expect(v101 == []) // the user's choice is kept: no repeat-mode effect
        #expect(t.countedPlay == nil)
    }

    @Test func countedPlayRestartAndCancel() {
        var t = SleepTimer()
        let v107 = t.startCountedPlay(4, currentSongId: nil)
        #expect(v107 == [])
        #expect(t.playCount == 4 && t.countedPlay == nil)
        _ = t.startCountedPlay(2, currentSongId: "a")
        let v110 = t.startCountedPlay(6, currentSongId: "b")
        #expect(v110 == [.setRepeatMode(.off), .setRepeatMode(.one)])
        #expect(t.countedPlay?.songId == "b")
        let v112 = t.cancelCountedPlay()
        #expect(v112 == [.setRepeatMode(.off)])
        #expect(t.playCount == 1)
        let v114 = t.cancelCountedPlay()
        #expect(v114 == [])
    }

    @Test func countedPlayAndTimersAreIndependent() {
        var t = SleepTimer()
        _ = t.startCountedPlay(2, currentSongId: "a")
        _ = t.setDuration(minutes: 5, nowMs: 0)
        #expect(t.countedPlay != nil)
        _ = t.cancel()
        #expect(t.countedPlay != nil)
    }
}
