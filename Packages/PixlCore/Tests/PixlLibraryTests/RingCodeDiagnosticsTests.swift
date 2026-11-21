import Foundation
import Testing
@testable import PixlLibrary

/// Developer mode > Ring code diagnostics: what is copied from a scan, only while the screen is open, and the text it makes.
@Suite("Ring code diagnostics")
struct RingCodeDiagnosticsTests {
    private let video = "dQw4w9WgXcQ"

    private func scanned() throws -> (RingFrame, RingScanResult, RingScanDiagnostics) {
        let bits = try #require(RingCodePayloads.encodeSlots(videoId: video, minuteBucket: 12, random: 77))
        let rendered = RingCodeRenderer.render(bits, RenderParams())
        let frame = RingFrame(width: rendered.image.width, height: rendered.image.height, luma: rendered.image.luma, hue: rendered.image.orange)
        let scanner = RingScanner()
        let result = scanner.scan(frame)
        return (frame, result, scanner.diagnostics)
    }

    @Test func closedItRecordsNothingAndAnOpenOneCopiesTheScan() throws {
        let (frame, result, d) = try scanned()
        let hub = RingCodeDiagnostics()
        hub.onFrame(nowMs: 100)
        hub.record(frame: frame, result: result, diagnostics: d, rotationDegrees: 0, nowMs: 1_000)
        #expect(hub.snapshot == .empty)
        #expect(hub.log.isEmpty)

        hub.setEnabled(true)
        hub.record(frame: frame, result: result, diagnostics: d, rotationDegrees: 0, nowMs: 2_000)
        let s = hub.snapshot
        #expect(s.serial == 1)
        #expect(s.found)
        #expect(s.markerFound)
        #expect(s.outcome.hasPrefix("decoded dQw4w9WgXcQ"))
        #expect(s.frameWidth == frame.width && s.frameHeight == frame.height)
        #expect(s.previewWidth > 0 && s.previewHeight > 0)
        #expect(s.preview.count == s.previewWidth * s.previewHeight)
        #expect(s.confidence.count == RingCodeLayout.slots)
        // The plate sits in the middle of the rendered picture.
        #expect(abs(s.centreX - 0.5) < 0.05 && abs(s.centreY - 0.5) < 0.05)
        #expect(s.radius > 0.1 && s.radius < 0.5)
        #expect(hub.log.count == 1)

        hub.setEnabled(false)
        #expect(hub.snapshot == .empty)
        #expect(hub.log.isEmpty)
    }

    @Test func aSnapshotIsPublishedAtMostFiveTimesASecond() throws {
        let (frame, result, d) = try scanned()
        let hub = RingCodeDiagnostics()
        hub.setEnabled(true)
        hub.record(frame: frame, result: result, diagnostics: d, rotationDegrees: 0, nowMs: 1_000)
        hub.record(frame: frame, result: result, diagnostics: d, rotationDegrees: 0, nowMs: 1_100)
        #expect(hub.snapshot.serial == 1)
        hub.record(frame: frame, result: result, diagnostics: d, rotationDegrees: 0, nowMs: 1_250)
        #expect(hub.snapshot.serial == 2)
        // Every decode is logged even when its snapshot was not published.
        #expect(hub.log.count == 3)
    }

    @Test func aPortraitFrameIsTurnedUprightAndThePlateFollows() throws {
        let (_, result, d) = try scanned()
        // A landscape frame made by hand: the plate (a known place) lands where the rotation says.
        let wide = RingFrame(width: 400, height: 200, luma: [UInt8](repeating: 100, count: 400 * 200))
        var diag = d
        diag.found = true
        diag.centreX = 300
        diag.centreY = 50
        diag.bezelRadiusPx = 40
        for (rotation, expected) in [(0, (0.75, 0.25)), (90, (0.75, 0.75)), (180, (0.25, 0.75)), (270, (0.25, 0.25))] {
            let hub = RingCodeDiagnostics()
            hub.setEnabled(true)
            hub.record(frame: wide, result: result, diagnostics: diag, rotationDegrees: rotation, nowMs: 1_000)
            let s = hub.snapshot
            #expect(abs(s.centreX - expected.0) < 0.001 && abs(s.centreY - expected.1) < 0.001, "rotation \(rotation): \(s.centreX), \(s.centreY)")
            #expect((rotation == 90 || rotation == 270) == (s.previewHeight > s.previewWidth), "rotation \(rotation) turns a landscape frame upright")
        }
    }

    @Test func theLogKeepsTwentyLinesAndRepeatedFailuresAreNotRepeated() throws {
        let (frame, _, d) = try scanned()
        let hub = RingCodeDiagnostics()
        hub.setEnabled(true)
        let miss = RingScanResult.failed(.noPlate)
        for i in 0..<50 { hub.record(frame: frame, result: miss, diagnostics: d, rotationDegrees: 0, nowMs: 10_000 + Int64(i) * 40) }
        // 2 seconds of misses: one line now and one more a second later, never one per frame.
        #expect(hub.log.count <= 3)
        let ok = RingScanResult.decoded(payload: RingCodePayload(videoId: video, minuteBucket: 1, random: 2), corrected: 3, erasures: 0)
        for i in 0..<30 { hub.record(frame: frame, result: ok, diagnostics: d, rotationDegrees: 0, nowMs: 20_000 + Int64(i) * 40) }
        #expect(hub.log.count == RingCodeDiagnostics.logSize)
        #expect(hub.log.last?.hasPrefix("00:21.160") == true)
    }

    @Test func theFrameRateIsCountedPerSecond() throws {
        let (frame, result, d) = try scanned()
        let hub = RingCodeDiagnostics()
        hub.setEnabled(true)
        for i in 0..<30 { hub.onFrame(nowMs: 5_000 + Int64(i) * 33) }
        hub.onFrame(nowMs: 6_100)
        hub.record(frame: frame, result: result, diagnostics: d, rotationDegrees: 0, nowMs: 6_200)
        #expect(hub.snapshot.framesPerSecond >= 28)
    }

    @Test func theCopyTextHasTheNumbersTheThresholdsAndTheLastResults() throws {
        let (frame, result, d) = try scanned()
        let hub = RingCodeDiagnostics()
        hub.setEnabled(true)
        hub.onSlow()
        hub.record(frame: frame, result: result, diagnostics: d, rotationDegrees: 0, nowMs: 3_000)
        let text = hub.copyText(device: "iPhone, iOS 26")
        #expect(text.hasPrefix("Ring code diagnostics\ndevice: iPhone, iOS 26\n"))
        #expect(text.contains("plate found: true, start dot found: true"))
        #expect(text.contains("scanner too slow for this phone: true"))
        #expect(text.contains("last outcome: decoded dQw4w9WgXcQ"))
        #expect(text.contains("slot confidence:"))
        #expect(text.contains("last results:\n"))
    }

    @Test func theNumbersAreTypedWithoutAFormattingApi() {
        #expect(RingText.fixed(12.5, decimals: 1) == "12.5")
        #expect(RingText.fixed(0.07, decimals: 2) == "0.07")
        #expect(RingText.fixed(3.0, decimals: 1) == "3.0")
        #expect(RingText.fixed(-1.25, decimals: 1) == "-1.3")
        #expect(RingText.fixed(7, decimals: 0) == "7")
        #expect(RingText.millis(7_400) == "7.4")
        #expect(RingText.stamp(61_005) == "01:01.005")
    }
}
