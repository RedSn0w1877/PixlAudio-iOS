import Foundation
import Testing
@testable import PixlLibrary

/// Endless Listening, milestone E2: the spoken host's rules (`HostVoice`) against Android's golden file `hostvoice.jsonl`, and the same unit
/// cases as Android's `HostVoiceTest`.
@Suite("Endless Listening spoken host (brainMatchesAndroid)")
struct BrainHostVoiceTests {
    typealias G = BrainGoldenTests

    // MARK: hostvoice.jsonl

    @Test func goldenMatchesAndroid() throws {
        var report = G.Report(file: "hostvoice.jsonl")
        var counts: [String: Int] = [:]
        for c in try G.cases("hostvoice.jsonl") {
            counts[c.fn, default: 0] += 1
            let i = c.input
            switch c.fn {
            case "decide":
                let inputs = HostVoice.Inputs(
                    enabled: G.int(i, "enabled") == 1, endless: G.int(i, "endless") == 1, notesOn: G.int(i, "notesOn") == 1,
                    line: G.string(i, "line"), sameAsLast: G.int(i, "sameAsLast") == 1, tracksSinceLast: Int(G.int(i, "tracksSinceLast")),
                    sinceStartMs: G.long(i, "sinceStartMs"), currentIsTarget: G.int(i, "currentIsTarget") == 1,
                    transitionRunning: G.int(i, "transitionRunning") == 1, playing: G.int(i, "playing") == 1, inCall: G.int(i, "inCall") == 1,
                    msSinceRoute: G.long(i, "msSinceRoute"), positionMs: G.long(i, "positionMs"), remainingMs: G.long(i, "remainingMs"),
                    voice: Int(G.int(i, "voice")), canDuck: G.int(i, "canDuck") == 1)
                let d = HostVoice.decide(inputs)
                report.record(c, c.matches {
                    $0.int("action", d.action); $0.string("reason", d.reason); $0.long("waitMs", d.waitMs)
                })
            case "cancel":
                let r = HostVoice.Running(
                    enabled: G.int(i, "enabled") == 1, endless: G.int(i, "endless") == 1, notesOn: G.int(i, "notesOn") == 1,
                    songChanged: G.int(i, "songChanged") == 1, playing: G.int(i, "playing") == 1,
                    transitionRunning: G.int(i, "transitionRunning") == 1, focusLost: G.int(i, "focusLost") == 1,
                    inCall: G.int(i, "inCall") == 1, routeChanged: G.int(i, "routeChanged") == 1,
                    volumeTaken: G.int(i, "volumeTaken") == 1, sinceSpeechStartMs: G.long(i, "sinceSpeechStartMs"))
                let reason = HostVoice.cancelReason(r)
                report.record(c, c.matches { $0.string("reason", reason) })
            case "ramp":
                let v = HostVoice.ramp(Int(G.int(i, "from")), Int(G.int(i, "to")), elapsedMs: G.long(i, "elapsedMs"), rampMs: G.long(i, "rampMs"))
                report.record(c, c.matches { $0.int("permille", v) })
            case "line":
                let l = HostVoice.line(G.string(i, "text"))
                report.record(c, c.matches { $0.string("line", l) })
            case "estimate":
                let ms = HostVoice.estimateMs(G.string(i, "line"))
                report.record(c, c.matches { $0.long("ms", ms) })
            default: report.record(c, false)
            }
        }
        report.verify(atLeast: 630)
        #expect(counts["decide"] == 430)
        #expect(counts["cancel"] == 120)
        #expect(counts["ramp"] == 70)
        #expect(counts["line"] == 17)
        #expect(counts["estimate"] == 1)
    }

    @Test func theHostVoiceFileIsInTheManifest() throws {
        let manifest = String(decoding: try G.fixtureData("MANIFEST.sha256"), as: UTF8.self)
        #expect(manifest.contains("  hostvoice.jsonl"), "hostvoice.jsonl is not in MANIFEST.sha256")
    }

    // MARK: decide

    private let note = "From your Bedroom pop side."

    private func inputs(
        enabled: Bool = true, endless: Bool = true, notesOn: Bool = true, line: String? = nil, sameAsLast: Bool = false,
        tracksSinceLast: Int = HostVoice.never, sinceStartMs: Int64 = 2_000, currentIsTarget: Bool = true, transitionRunning: Bool = false,
        playing: Bool = true, inCall: Bool = false, msSinceRoute: Int64 = 60_000, positionMs: Int64 = 2_000, remainingMs: Int64 = 120_000,
        voice: Int = HostVoice.voiceReady, canDuck: Bool = true
    ) -> HostVoice.Inputs {
        HostVoice.Inputs(enabled: enabled, endless: endless, notesOn: notesOn, line: line ?? note, sameAsLast: sameAsLast,
                         tracksSinceLast: tracksSinceLast, sinceStartMs: sinceStartMs, currentIsTarget: currentIsTarget,
                         transitionRunning: transitionRunning, playing: playing, inCall: inCall, msSinceRoute: msSinceRoute,
                         positionMs: positionMs, remainingMs: remainingMs, voice: voice, canDuck: canDuck)
    }

    private func reason(_ i: HostVoice.Inputs) -> String { HostVoice.decide(i).reason }

    @Test func aCalmMomentSpeaks() {
        let d = HostVoice.decide(inputs())
        #expect(d.action == HostVoice.actSpeak)
        #expect(d.reason == "speak")
    }

    @Test func nothingIsSaidWithTheSwitchOffOrOffEndlessListening() {
        #expect(reason(inputs(enabled: false)) == "off")
        #expect(reason(inputs(endless: false)) == "not_endless")
        #expect(reason(inputs(notesOn: false)) == "notes_off")
        #expect(reason(inputs(line: "")) == "no_line")
        #expect(HostVoice.decide(inputs(enabled: false)).action == HostVoice.actSkip)
    }

    @Test func neverOverATransitionAndATransitionIsWaitedFor() {
        let d = HostVoice.decide(inputs(transitionRunning: true))
        #expect(d.action == HostVoice.actWait)
        #expect(d.reason == "transition")
        // The deck still plays the previous song while the new one is already shown: wait, do not speak.
        #expect(reason(inputs(currentIsTarget: false)) == "not_current")
        #expect(HostVoice.decide(inputs(currentIsTarget: false)).action == HostVoice.actWait)
    }

    @Test func aLineStartsAtLeastOneAndAHalfSecondsIntoTheTrack() {
        let early = HostVoice.decide(inputs(positionMs: 400))
        #expect(early.action == HostVoice.actWait)
        #expect(early.reason == "too_early")
        #expect(early.waitMs == 1_100)
        #expect(HostVoice.decide(inputs(positionMs: 1_500)).action == HostVoice.actSpeak)
        #expect(reason(inputs(positionMs: 1_499)) == "too_early")
    }

    @Test func notInACallNotPausedNotJustAfterARouteChange() {
        #expect(reason(inputs(inCall: true)) == "call")
        #expect(reason(inputs(playing: false)) == "paused")
        #expect(reason(inputs(msSinceRoute: 3_999)) == "route_changed")
        #expect(reason(inputs(msSinceRoute: 4_000)) == "speak")
        // A call beats everything that could be waited for.
        #expect(reason(inputs(transitionRunning: true, inCall: true, positionMs: 0)) == "call")
    }

    @Test func aRepeatALineTooSoonAfterTheLastOneAndALateLineAreDropped() {
        #expect(reason(inputs(sameAsLast: true)) == "repeat")
        #expect(reason(inputs(tracksSinceLast: 3)) == "too_soon")
        #expect(reason(inputs(tracksSinceLast: 4)) == "speak")
        #expect(reason(inputs(sinceStartMs: 15_001)) == "window_over")
        #expect(reason(inputs(sinceStartMs: 15_000)) == "speak")
    }

    @Test func theSongMustHaveTimeLeftForTheLineAndTheNextTransition() {
        let need = HostVoice.estimateMs(note) + HostVoice.transitionMarginMs
        #expect(reason(inputs(remainingMs: need - 1)) == "short_left")
        #expect(reason(inputs(remainingMs: need)) == "speak")
        #expect(reason(inputs(remainingMs: -1)) == "unknown_length")
    }

    @Test func noVoiceMeansSilenceAStartingVoiceIsWaitedForAnEngineThatCannotDuckIsNotSpokenOver() {
        #expect(reason(inputs(voice: HostVoice.voiceNone)) == "no_voice")
        let pending = HostVoice.decide(inputs(voice: HostVoice.voicePending))
        #expect(pending.action == HostVoice.actWait)
        #expect(pending.reason == "voice_pending")
        #expect(reason(inputs(canDuck: false)) == "cant_duck")
    }

    @Test func aWaitIsNeverShorterThanAFewMilliseconds() {
        #expect(HostVoice.decide(inputs(positionMs: 1_499)).waitMs >= 50)
    }

    // MARK: cancelReason

    private func running(
        enabled: Bool = true, endless: Bool = true, notesOn: Bool = true, songChanged: Bool = false, playing: Bool = true,
        transitionRunning: Bool = false, focusLost: Bool = false, inCall: Bool = false, routeChanged: Bool = false,
        volumeTaken: Bool = false, sinceSpeechStartMs: Int64 = 1_000
    ) -> HostVoice.Running {
        HostVoice.Running(enabled: enabled, endless: endless, notesOn: notesOn, songChanged: songChanged, playing: playing,
                          transitionRunning: transitionRunning, focusLost: focusLost, inCall: inCall, routeChanged: routeChanged,
                          volumeTaken: volumeTaken, sinceSpeechStartMs: sinceSpeechStartMs)
    }

    @Test func aLineGoesOnWhileNothingChanges() {
        #expect(HostVoice.cancelReason(running()) == "")
        #expect(HostVoice.cancelReason(running(sinceSpeechStartMs: 8_000)) == "")
    }

    @Test func aSkipAPauseATransitionAFocusLossACallARouteChangeOrAForeignVolumeWriteStopItAtOnce() {
        #expect(HostVoice.cancelReason(running(songChanged: true)) == "skip")
        #expect(HostVoice.cancelReason(running(playing: false)) == "pause")
        #expect(HostVoice.cancelReason(running(transitionRunning: true)) == "transition")
        #expect(HostVoice.cancelReason(running(focusLost: true)) == "focus")
        #expect(HostVoice.cancelReason(running(inCall: true)) == "call")
        #expect(HostVoice.cancelReason(running(routeChanged: true)) == "route")
        #expect(HostVoice.cancelReason(running(volumeTaken: true)) == "volume_taken")
        #expect(HostVoice.cancelReason(running(sinceSpeechStartMs: 8_001)) == "too_long")
        #expect(HostVoice.cancelReason(running(enabled: false)) == "off")
        #expect(HostVoice.cancelReason(running(notesOn: false)) == "notes_off")
    }

    // MARK: ramp

    @Test func theDuckRampHasExactEndsAndMovesInAStraightLine() {
        let down = HostVoice.duckPermille
        #expect(HostVoice.ramp(1000, down, elapsedMs: 0, rampMs: HostVoice.rampDownMs) == 1000)
        #expect(HostVoice.ramp(1000, down, elapsedMs: HostVoice.rampDownMs, rampMs: HostVoice.rampDownMs) == down)
        #expect(HostVoice.ramp(1000, down, elapsedMs: 9_999, rampMs: HostVoice.rampDownMs) == down)
        #expect(HostVoice.ramp(1000, down, elapsedMs: 125, rampMs: HostVoice.rampDownMs) == 675)
        #expect(HostVoice.ramp(down, 1000, elapsedMs: HostVoice.rampUpMs, rampMs: HostVoice.rampUpMs) == 1000)
        #expect(HostVoice.ramp(down, 1000, elapsedMs: -5, rampMs: HostVoice.rampUpMs) == down)
        // No length: already there.
        #expect(HostVoice.ramp(down, 1000, elapsedMs: 0, rampMs: 0) == 1000)
        // Monotone downwards.
        var last = 1000
        var t: Int64 = 0
        while t <= 250 {
            let v = HostVoice.ramp(1000, down, elapsedMs: t, rampMs: 250)
            #expect(v <= last)
            last = v
            t += 10
        }
    }

    // MARK: line

    @Test func theLineIsTheNoteCleanedAndALongOrOddOneStaysOnTheScreenOnly() {
        #expect(HostVoice.line("From your Bedroom pop side.") == "From your Bedroom pop side.")
        #expect(HostVoice.line("From your V-pop & Hip hop side.") == "From your V-pop and Hip hop side.")
        #expect(HostVoice.line("  Spaced   out   words.  ") == "Spaced out words.")
        #expect(HostVoice.line("Say *this* and [that].") == "Say this and that.")
        #expect(HostVoice.line("") == "")
        #expect(HostVoice.line("   ") == "")
        #expect(HostVoice.line("One. Two. Three.") == "")
        #expect(HostVoice.line("A very very very very very very very very very very long sentence here.") == "")
        #expect(HostVoice.line("Learn the genre.") == "")
        #expect(HostVoice.line("Listen to the lossless sound.") == "")
    }

    @Test func noSpokenSentenceHasMoreThanTwelveWordsAndAtMostTwoSentencesAreSaid() {
        let twelve = "one two three four five six seven eight nine ten eleven twelve."
        #expect(HostVoice.line(twelve) == twelve)
        #expect(HostVoice.line("one two three four five six seven eight nine ten eleven twelve thirteen.") == "")
        #expect(HostVoice.line("Short one. Another short one.") == "Short one. Another short one.")
    }

    @Test func aSetNoteIsSaidWhenShortAndStaysOnTheScreenWhenItsNamesMakeItLong() {
        let short = SetNotes.text(SetNotes.Note(index: 0, kind: SetNotes.kindGenreThenNew, count: 3, genre: "V-pop", artist: "", newArtist: "HIEUTHUHAI"))
        #expect(HostVoice.line(short) == "Three from your V-pop side, then something new from HIEUTHUHAI.")
        let long = SetNotes.text(SetNotes.Note(index: 0, kind: SetNotes.kindGenreThenNew, count: 3, genre: "Alternative Dance Electronic Indie",
                                               artist: "", newArtist: "Florence Alexandra Margaret Of The Machine"))
        #expect(HostVoice.line(long) == "")
        // A line is the note, word for word, when nothing needs cleaning.
        #expect(HostVoice.line(short) == short)
    }

    @Test func everyHostNoteTheAppCanMakeIsALineOrStaysSilentNeverALongOne() {
        let kinds = [
            HostNotes.Note(index: 0, kind: HostNotes.kindNewFromArtist, a: "HIEUTHUHAI", b: ""),
            HostNotes.Note(index: 0, kind: HostNotes.kindSideways, a: "Shoegaze", b: "V-pop"),
            HostNotes.Note(index: 0, kind: HostNotes.kindIsland, a: "Soft pop & R&B", b: ""),
            HostNotes.Note(index: 0, kind: HostNotes.kindGenreFact, a: "Shoegaze", b: "A guitar wall of sound"),
            HostNotes.Note(index: 0, kind: HostNotes.kindYear, a: "2019", b: ""),
        ]
        for n in kinds {
            let line = HostVoice.line(HostNotes.text(n))
            #expect(!line.isEmpty, "\(HostNotes.text(n))")
            #expect(HostNotes.isSpeakable(line))
            #expect(!line.contains("&"))
        }
    }

    @Test func theNumbersAreTheOnesOnAndroid() {
        #expect(HostVoice.minIntoTrackMs == 1_500)
        #expect(HostVoice.routeQuietMs == 4_000)
        #expect(HostVoice.minTracksBetween == 4)
        #expect(HostVoice.windowMs == 15_000)
        #expect(HostVoice.rampDownMs == 250 && HostVoice.rampUpMs == 400 && HostVoice.rampUpQuickMs == 120)
        #expect(HostVoice.duckPermille == 350)
        #expect(HostVoice.maxSpeechMs == 8_000)
        #expect(HostVoice.transitionMarginMs == 15_000)
        #expect(HostVoice.logSize == 20)
    }
}
