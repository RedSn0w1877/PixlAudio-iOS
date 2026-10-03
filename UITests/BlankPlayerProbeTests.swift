import UIKit
import XCTest

/// EXPERIMENT (not for main): does the expanded full player ever stay invisible (its layer or a section fade stuck
/// below 1 while the sheet is expanded)? Three ways in: launching straight into it, a tap and a drag before the
/// full player was pre-built (`-probeNoPrewarm` turns the pre-warm off).
@MainActor
final class BlankPlayerProbeTests: XCTestCase {
    func testLaunchExpanded() {
        probe(runs: 50, name: "launch") { app in
            app.launchArguments = ["-uiTest", "-screen", "nowPlaying", "-appearance", "dark"]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["screen.nowPlaying"].firstMatch.waitForExistence(timeout: 20))
        }
    }

    func testTapBeforePrewarm() {
        probe(runs: 25, name: "tap") { app in
            app.launchArguments = ["-uiTest", "-screen", "miniPlayer", "-appearance", "dark", "-probeNoPrewarm"]
            app.launch()
            let mini = app.descendants(matching: .any)["miniPlayer"].firstMatch
            XCTAssertTrue(mini.waitForExistence(timeout: 20))
            mini.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        }
    }

    func testDragBeforePrewarm() {
        probe(runs: 25, name: "drag") { app in
            app.launchArguments = ["-uiTest", "-screen", "miniPlayer", "-appearance", "dark", "-probeNoPrewarm"]
            app.launch()
            let mini = app.descendants(matching: .any)["miniPlayer"].firstMatch
            XCTAssertTrue(mini.waitForExistence(timeout: 20))
            let start = mini.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -420)))
        }
    }

    private func probe(runs: Int, name: String, open: (XCUIApplication) -> Void) {
        continueAfterFailure = true
        var bad = 0, blank = 0, recovered = 0
        for index in 0..<runs {
            let app = XCUIApplication()
            open(app)
            Thread.sleep(forTimeInterval: 2.0)
            let shot = app.screenshot()
            let state = probeState(app)
            let isBlank = Self.isBlank(shot.image)
            if isBlank { blank += 1 }
            if isBlank || state.hasPrefix("BAD") {
                bad += 1
                attach(shot, "probe-\(name)-\(index)-bad")
                attachText(state, "probe-\(name)-\(index)-state.txt")
                Thread.sleep(forTimeInterval: 3.0)
                let laterState = probeState(app)
                if !laterState.hasPrefix("BAD"), !Self.isBlank(app.screenshot().image) { recovered += 1 }
                attachText(laterState, "probe-\(name)-\(index)-state-after3s.txt")
            }
            if index == 0 {
                attach(shot, "probe-\(name)-first")
                attachText(state, "probe-\(name)-first-state.txt")
            }
            app.terminate()
        }
        attachText("\(name): \(bad) bad (\(blank) blank screens) of \(runs), \(recovered) recovered after 3 s",
                   "probe-\(name)-summary-\(bad)-bad-\(blank)-blank-of-\(runs)-recovered-\(recovered).txt")
    }

    private func probeState(_ app: XCUIApplication) -> String {
        let label = app.descendants(matching: .any)["debug.sheet"].firstMatch
        return label.waitForExistence(timeout: 2) ? label.label : "debug.sheet missing"
    }

    private func attachText(_ text: String, _ name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The screen below the status bar is one colour (downsampled to 12×24, every channel within 10 levels).
    private static func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let crop = cg.cropping(to: CGRect(x: 0, y: cg.height / 10, width: cg.width, height: cg.height * 8 / 10)) ?? cg
        let width = 12, height = 24
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        var low = [255, 255, 255], high = [0, 0, 0]
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 {
                low[channel] = min(low[channel], Int(pixels[offset + channel]))
                high[channel] = max(high[channel], Int(pixels[offset + channel]))
            }
        }
        return (0..<3).allSatisfy { high[$0] - low[$0] < 10 }
    }
}
