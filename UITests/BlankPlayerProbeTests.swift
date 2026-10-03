import UIKit
import XCTest

/// EXPERIMENT (not for main): how often does the expanded full player render blank (only the card's fill)?
/// One CI shot (run 37066421213, playerExpanded-dark) caught the full player invisible two seconds after launch.
/// Each probe launches many times and checks a downsampled screenshot for a uniform screen; a blank one is attached
/// with the accessibility tree and re-checked three seconds later (does it recover?).
@MainActor
final class BlankPlayerProbeTests: XCTestCase {
    /// `-screen nowPlaying`: the player is built at launch, already expanded (the shot's path).
    func testLaunchExpanded() {
        probe(runs: 70, name: "launch") { app in
            app.launchArguments = ["-uiTest", "-screen", "nowPlaying", "-appearance", "dark"]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["screen.nowPlaying"].firstMatch.waitForExistence(timeout: 20))
        }
    }

    private func probe(runs: Int, name: String, open: (XCUIApplication) -> Void) {
        continueAfterFailure = true
        var blanks = 0, recovered = 0
        for index in 0..<runs {
            let app = XCUIApplication()
            open(app)
            Thread.sleep(forTimeInterval: 2.0)
            let shot = app.screenshot()
            if Self.isBlank(shot.image) {
                blanks += 1
                attach(shot, "probe-\(name)-\(index)-blank")
                attachText(probeState(app), "probe-\(name)-\(index)-state.txt")
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "probe-\(name)-\(index)-tree.txt"
                tree.lifetime = .keepAlways
                add(tree)
                Thread.sleep(forTimeInterval: 3.0)
                let later = app.screenshot()
                if !Self.isBlank(later.image) { recovered += 1 }
                attach(later, "probe-\(name)-\(index)-after3s")
                attachText(probeState(app), "probe-\(name)-\(index)-state-after3s.txt")
            }
            if index == 0 {
                attach(shot, "probe-\(name)-first")
                attachText(probeState(app), "probe-\(name)-first-state.txt")
            }
            app.terminate()
        }
        let summary = XCTAttachment(string: "\(name): \(blanks) blank of \(runs), \(recovered) recovered after 3 s")
        summary.name = "probe-\(name)-summary-\(blanks)-of-\(runs)-recovered-\(recovered).txt"
        summary.lifetime = .keepAlways
        add(summary)
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
