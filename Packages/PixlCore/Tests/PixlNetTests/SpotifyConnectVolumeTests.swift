import Foundation
import Testing
@testable import PixlNet

/// The volume buttons driving a Spotify Connect device (owner request 2026-10-07; Swift-only — Android gets volume
/// keys natively from Media3's remote `DeviceInfo`, so it has no such logic to port).
@Suite("Spotify Connect: volume buttons")
struct SpotifyConnectVolumeKeysTests {
    typealias Keys = SpotifyConnectVolumeKeys

    @Test func oneStepChangesAreOnePress() {
        let centre: Float = 0.5
        // The exact 1/16 step and its rounded reports (0.05, 0.10), up and down.
        #expect(Keys.classify(old: 0.5, new: 0.5625, centre: centre, awaitingEcho: false) == .press(1))
        #expect(Keys.classify(old: 0.5, new: 0.4375, centre: centre, awaitingEcho: false) == .press(-1))
        #expect(Keys.classify(old: 0.5, new: 0.55, centre: centre, awaitingEcho: false) == .press(1))
        #expect(Keys.classify(old: 0.5, new: 0.45, centre: centre, awaitingEcho: false) == .press(-1))
        #expect(Keys.classify(old: 0.5, new: 0.6, centre: centre, awaitingEcho: false) == .press(1))
        #expect(Keys.classify(old: 0.5, new: 0.4, centre: centre, awaitingEcho: false) == .press(-1))
    }

    @Test func twoStepJumpIsTwoPresses() {
        #expect(Keys.classify(old: 0.5, new: 0.625, centre: 0.5, awaitingEcho: false) == .press(2))
        #expect(Keys.classify(old: 0.5, new: 0.375, centre: 0.5, awaitingEcho: false) == .press(-2))
    }

    @Test func theResetsEchoIsIgnored() {
        // The phone went up a step, PixlAudio set it back: the change back to the centre is not a press.
        #expect(Keys.classify(old: 0.5625, new: 0.5, centre: 0.5, awaitingEcho: true) == .echo(settled: true))
        // Reported rounded: within the tolerance of the centre.
        #expect(Keys.classify(old: 0.6, new: 0.53, centre: 0.5, awaitingEcho: true) == .echo(settled: true))
        #expect(Keys.classify(old: 0.4, new: 0.47, centre: 0.5, awaitingEcho: true) == .echo(settled: true))
        // A reset landing in two changes: the first moves towards the centre and is not a press either.
        #expect(Keys.classify(old: 0.625, new: 0.5625, centre: 0.5, awaitingEcho: true) == .echo(settled: false))
        // Without a reset pending the same change is a press.
        #expect(Keys.classify(old: 0.5625, new: 0.5, centre: 0.5, awaitingEcho: false) == .press(-1))
    }

    @Test func aPressBeforeTheEchoStillCounts() {
        // Up, reset pending, up again before it lands: a press (it moves away from the centre).
        #expect(Keys.classify(old: 0.5625, new: 0.625, centre: 0.5, awaitingEcho: true) == .press(1))
        // Then the reset lands: the echo.
        #expect(Keys.classify(old: 0.625, new: 0.5, centre: 0.5, awaitingEcho: true) == .echo(settled: true))
    }

    @Test func otherChangesReanchor() {
        // A route change (headphones) or a big drag.
        #expect(Keys.classify(old: 0.5, new: 0.8, centre: 0.5, awaitingEcho: false) == .reanchor(0.8))
        #expect(Keys.classify(old: 0.5, new: 0.1, centre: 0.5, awaitingEcho: false) == .reanchor(0.1))
        // Small drag steps (a slider moved by hand).
        #expect(Keys.classify(old: 0.5, new: 0.51, centre: 0.5, awaitingEcho: false) == .reanchor(0.51))
        #expect(Keys.classify(old: 0.5, new: 0.48, centre: 0.5, awaitingEcho: false) == .reanchor(0.48))
        #expect(Keys.classify(old: 0.5, new: 0.5, centre: 0.5, awaitingEcho: false) == .reanchor(0.5))
    }

    @Test func centreSnapsToTheGridAndStaysAwayFromTheEnds() {
        #expect(Keys.centre(for: 0.5) == 0.5)
        #expect(Keys.centre(for: 0.52) == 0.5)
        #expect(Keys.centre(for: 0.55) == 0.5625)
        #expect(Keys.centre(for: 0.3) == 0.3125)
        #expect(Keys.centre(for: 0) == 0.125)
        #expect(Keys.centre(for: 0.05) == 0.125)
        #expect(Keys.centre(for: 1) == 0.875)
        #expect(Keys.centre(for: 0.95) == 0.875)
        // On the grid, so the 1/16 hardware steps from it are exact.
        for original in stride(from: Float(0), through: 1, by: 0.01) {
            let centre = Keys.centre(for: original)
            #expect(Keys.centreRange.contains(centre))
            #expect((centre * 16).rounded() == centre * 16)
        }
    }

    @Test func devicesAndPercentages() {
        #expect(Keys.controls(type: "Speaker", supportsVolume: true))
        #expect(Keys.controls(type: "TV", supportsVolume: true))
        #expect(!Keys.controls(type: "Speaker", supportsVolume: false))
        #expect(!Keys.controls(type: "Smartphone", supportsVolume: true))
        #expect(!Keys.controls(type: "smartphone", supportsVolume: true))
        #expect(!Keys.controls(type: "Tablet", supportsVolume: true))
        #expect(Keys.step == 5)
        #expect(Keys.percent(after: 1, from: 45) == 50)
        #expect(Keys.percent(after: -2, from: 45) == 35)
        #expect(Keys.percent(after: 1, from: nil) == 55)
        #expect(Keys.percent(after: 3, from: 98) == 100)
        #expect(Keys.percent(after: -1, from: 2) == 0)
        #expect(Keys.reachedEnd(phoneVolume: 1, presses: 1))
        #expect(!Keys.reachedEnd(phoneVolume: 1, presses: -1))
        #expect(Keys.reachedEnd(phoneVolume: 0, presses: -1))
        #expect(!Keys.reachedEnd(phoneVolume: 0.5, presses: 1))
    }
}

@Suite("Spotify Connect: volume request lane")
struct SpotifyConnectVolumeLaneTests {
    @Test func firstChangeGoesAtOnce() {
        var lane = SpotifyConnectVolumeLane()
        #expect(lane.next(nowMs: 0) == .idle)
        lane.enqueue(50)
        #expect(lane.next(nowMs: 1_000) == .send(50))
        #expect(!lane.isIdle)
        // One request at a time.
        lane.enqueue(55)
        #expect(lane.next(nowMs: 1_010) == .idle)
        lane.completed()
        // Then no sooner than the interval after the last send.
        #expect(lane.next(nowMs: 1_100) == .wait(200))
        #expect(lane.next(nowMs: 1_300) == .send(55))
        lane.completed()
        #expect(lane.isIdle)
        #expect(lane.next(nowMs: 5_000) == .idle)
    }

    @Test func burstsCoalesceToTheLatestValue() {
        var lane = SpotifyConnectVolumeLane()
        lane.enqueue(50)
        #expect(lane.next(nowMs: 0) == .send(50))
        lane.completed()
        for value in [55, 60, 65, 70] { lane.enqueue(value) }
        #expect(lane.next(nowMs: 100) == .wait(200))
        #expect(lane.next(nowMs: 300) == .send(70))
        lane.completed()
        #expect(lane.next(nowMs: 400) == .idle)
        // Clamped.
        lane.enqueue(140)
        #expect(lane.next(nowMs: 1_000) == .send(100))
    }

    @Test func rateLimitWaitsThenSendsOnlyTheLatest() {
        var lane = SpotifyConnectVolumeLane()
        lane.enqueue(50)
        #expect(lane.next(nowMs: 0) == .send(50))
        lane.rateLimited(retryAfterMs: 5_000, nowMs: 100)
        // The value is kept and goes once the gate opens.
        #expect(lane.next(nowMs: 200) == .wait(4_900))
        #expect(lane.next(nowMs: 5_100) == .send(50))
        lane.rateLimited(retryAfterMs: 2_000, nowMs: 5_200)
        // A newer value replaces it.
        lane.enqueue(65)
        #expect(lane.next(nowMs: 7_200) == .send(65))
        lane.completed()
        #expect(lane.isIdle)
    }

    @Test func anotherCallersGateHoldsSends() {
        var lane = SpotifyConnectVolumeLane()
        lane.gate(untilMs: 3_000)
        lane.enqueue(40)
        #expect(lane.next(nowMs: 1_000) == .wait(2_000))
        #expect(lane.next(nowMs: 3_000) == .send(40))
        // A failure drops that value only.
        lane.failed()
        #expect(lane.isIdle)
        lane.enqueue(45)
        #expect(lane.next(nowMs: 3_500) == .send(45))
    }
}
