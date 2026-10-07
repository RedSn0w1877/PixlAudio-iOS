import XCTest

/// Spotify Connect output: the devices sheet's "Spotify Connect" section on its DEVICES page (demo devices: an Echo
/// Show, a TV, the active desktop, a receiver without volume control, a restricted car), the playing state with the
/// stop row and the device volume in the hero, the reconnect row of a pre-Connect login, the empty hint, and the
/// "Playing on <device>" chip in the full and the mini player, and the volume pop-up the volume buttons show. Demo data
/// only (`-uiTest`): no network.
@MainActor
final class SpotifyConnectScreenshotTests: XCTestCase {
    func testDevicesLight() throws {
        let app = launch("devices.spotifyConnect", "light")
        try waitFor(app, "devices.spotifyConnect")
        XCTAssertTrue(element(app, "Kitchen Echo Show").exists, "the demo devices are missing")
        snapshot(app, "spotifyConnectDevices-light")
    }

    func testDevicesDark() throws {
        let app = launch("devices.spotifyConnect", "dark")
        try waitFor(app, "devices.spotifyConnect")
        snapshot(app, "spotifyConnectDevices-dark")
    }

    /// Tapping a device starts a (demo) session: the stop row appears; stopping brings the queue back.
    func testConnectAndStopLight() throws {
        let app = launch("devices.spotifyConnect", "light")
        try waitFor(app, "devices.spotifyConnect")
        let echo = app.buttons.matching(identifier: "spotifyConnect.device.demo-echo").firstMatch
        XCTAssertTrue(echo.waitForExistence(timeout: 10), "the Echo row is missing")
        echo.tap()
        let stop = app.buttons.matching(identifier: "spotifyConnect.stop").firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "no stop row after connecting")
        snapshot(app, "spotifyConnectConnected-light", terminate: false)
        stop.tap()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 10), "the stop row stayed after stopping")
        app.terminate()
    }

    func testPlayingLight() throws {
        let app = launch("devices.spotifyPlaying", "light")
        try waitFor(app, "spotifyConnect.stop")
        snapshot(app, "spotifyConnectPlaying-light")
    }

    func testPlayingDark() throws {
        let app = launch("devices.spotifyPlaying", "dark")
        try waitFor(app, "spotifyConnect.stop")
        snapshot(app, "spotifyConnectPlaying-dark")
    }

    /// The hero on CONTROLS shows the Echo and its volume while it plays.
    func testPlayingHeroLight() throws {
        let app = launch("devices.spotifyPlaying", "light")
        try waitFor(app, "spotifyConnect.stop")
        let controls = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "devices.tab.0", "CONTROLS")).firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        controls.tap()
        XCTAssertTrue(app.descendants(matching: .any)["spotifyConnect.volume"].firstMatch.waitForExistence(timeout: 10),
                      "the device volume slider is missing")
        snapshot(app, "spotifyConnectHero-light")
    }

    func testReconnectLight() throws {
        let app = launch("devices.spotifyReconnect", "light")
        try waitFor(app, "spotifyConnect.reconnect")
        snapshot(app, "spotifyConnectReconnect-light")
    }

    func testEmptyLight() throws {
        let app = launch("devices.spotifyEmpty", "light")
        try waitFor(app, "spotifyConnect.empty")
        snapshot(app, "spotifyConnectEmpty-light")
    }

    func testNowPlayingChipLight() throws {
        let app = launch("nowPlaying.spotifyConnect", "light")
        try waitFor(app, "screen.nowPlaying")
        let chip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Playing on Kitchen Echo Show")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the Playing on chip is missing")
        snapshot(app, "spotifyConnectPlayer-light")
    }

    func testNowPlayingChipDark() throws {
        let app = launch("nowPlaying.spotifyConnect", "dark")
        try waitFor(app, "screen.nowPlaying")
        snapshot(app, "spotifyConnectPlayer-dark")
    }

    func testMiniPlayerChipLight() throws {
        let app = launch("miniPlayer.spotifyConnect", "light")
        try waitFor(app, "miniPlayer.remoteDevice")
        snapshot(app, "spotifyConnectMiniPlayer-light")
    }

    // MARK: - Volume buttons (2026-10-07)

    /// PixlAudio's volume pop-up after one press up on the Echo (45 % → 50 %), at the top of the full player. The real
    /// button handling can't run here (the simulator can't change the volume); the demo shows the pop-up pinned.
    func testVolumeHUDLight() throws {
        let app = launch("nowPlaying.spotifyVolumeHUD", "light")
        try waitFor(app, "screen.nowPlaying")
        let hud = app.descendants(matching: .any)["spotifyConnect.volumeHUD"].firstMatch
        XCTAssertTrue(hud.waitForExistence(timeout: 10), "the volume pop-up is missing")
        XCTAssertEqual(hud.label, "Volume for Kitchen Echo Show, 50%")
        snapshot(app, "spotifyConnectVolumeHUD-light")
    }

    func testVolumeHUDDark() throws {
        let app = launch("nowPlaying.spotifyVolumeHUD", "dark")
        try waitFor(app, "spotifyConnect.volumeHUD")
        snapshot(app, "spotifyConnectVolumeHUD-dark")
    }

    /// Over the lyrics screen (a full-screen cover, which shows its own copy of the pop-up).
    func testVolumeHUDOverLyricsLight() throws {
        let app = launch("lyrics.spotifyVolumeHUD", "light")
        try waitFor(app, "screen.lyrics")
        try waitFor(app, "spotifyConnect.volumeHUD")
        snapshot(app, "spotifyConnectVolumeHUDLyrics-light")
    }

    /// The hero's slider follows the volume the buttons set (50 % after the demo press).
    func testVolumeHUDHeroFollowsLight() throws {
        let app = launch("nowPlaying.spotifyVolumeHUD", "light")
        try waitFor(app, "spotifyConnect.volumeHUD")
        let pill = app.buttons.matching(identifier: "player.devices").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.tap()
        let slider = app.sliders.matching(identifier: "spotifyConnect.volume").firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10), "the device volume slider is missing")
        XCTAssertTrue((slider.value as? String)?.contains("50") == true,
                      "the hero's slider reads \(String(describing: slider.value)), not the 50 % the press set")
        // The devices sheet hides the pop-up (its slider already moves).
        XCTAssertTrue(app.descendants(matching: .any)["spotifyConnect.volumeHUD"].firstMatch.waitForNonExistence(timeout: 5),
                      "the pop-up stays over the devices sheet")
        snapshot(app, "spotifyConnectVolumeHUDHero-light")
    }

    // MARK: - Helpers

    private func launch(_ screen: String, _ appearance: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func waitFor(_ app: XCUIApplication, _ identifier: String) throws {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(identifier) did not appear")
    }

    private func snapshot(_ app: XCUIApplication, _ name: String, terminate: Bool = true) {
        // Let glass, the sheet presentation and album colours settle.
        Thread.sleep(forTimeInterval: 2.0)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if terminate { app.terminate() }
    }
}
