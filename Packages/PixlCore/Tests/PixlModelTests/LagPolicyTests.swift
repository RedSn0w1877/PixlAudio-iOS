import Foundation
import Testing
@testable import PixlModel

@Suite struct LagPolicyTests {
    @Test func aHangStartsAtTwoHundredFiftyMilliseconds() {
        #expect(!LagPolicy.isHang(latencyMs: 249))
        #expect(LagPolicy.isHang(latencyMs: 250))
        #expect(LagPolicy.isHang(latencyMs: 2_700))
    }

    @Test func aHitchIsOverOneAndAHalfFramesButNotAPause() {
        // 60 Hz: 16.7 ms due, 25 ms is the limit.
        #expect(!LagPolicy.isHitch(deltaMs: 16.7, expectedMs: 16.7))
        #expect(!LagPolicy.isHitch(deltaMs: 25.0, expectedMs: 16.7))
        #expect(LagPolicy.isHitch(deltaMs: 33.4, expectedMs: 16.7))
        // 120 Hz: 8.3 ms due, a 16.7 ms gap is a dropped frame.
        #expect(LagPolicy.isHitch(deltaMs: 16.7, expectedMs: 8.3))
        // A gap of seconds is the app having been paused or suspended.
        #expect(!LagPolicy.isHitch(deltaMs: 5_000, expectedMs: 16.7))
        #expect(!LagPolicy.isHitch(deltaMs: 40, expectedMs: 0))
    }

    @Test func aSmoothMinuteWritesNothingAndAHitchyOneSumsUp() {
        var window = HitchWindow(startedAt: 10)
        for _ in 0..<3_600 { window.record(deltaMs: 16.7, expectedMs: 16.7) }
        #expect(window.summary == nil)
        #expect(window.frames == 3_600)
        window.record(deltaMs: 83, expectedMs: 16.7)
        window.record(deltaMs: 41, expectedMs: 16.7)
        #expect(window.hitches == 2)
        #expect(window.worstMs == 83)
        #expect(window.summary == "2 of 3602 frames over 1.5x, worst 83 ms")
        #expect(!window.isDue(nowSeconds: 69.9))
        #expect(window.isDue(nowSeconds: 70))
        window.reset(startedAt: 70)
        #expect(window == HitchWindow(startedAt: 70))
    }

    @Test func onlyTheFiveNewestHangsAreKept() {
        var kept: [Int] = []
        for n in 1...8 { kept = LagPolicy.keepingRecent(kept, adding: n) }
        #expect(kept == [8, 7, 6, 5, 4])
    }
}
