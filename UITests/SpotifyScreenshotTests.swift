import XCTest

/// Stage 12 screenshots: Accounts (signed out / signed in), the Spotify dashboard (signed out, signed in, with a
/// playback test report) and Browse Spotify (home with top artists and songs, search results, an artist, an album),
/// with demo data (`SpotifyDemo`, no network). Compare with Android's `AccountsScreen`, `SpotifyDashboardScreen` and
/// `SpotifyBrowseScreen` (Compose code; there are no design-ref PNGs for these screens).
@MainActor
final class SpotifyScreenshotTests: XCTestCase {
    // MARK: Accounts

    func testAccountsSignedOutLight() throws { try capture("accounts", "light", ready: "accounts.connectSpotify") }
    func testAccountsSignedOutDark() throws { try capture("accounts", "dark", ready: "accounts.connectSpotify") }
    func testAccountsSignedInLight() throws { try capture("accounts.signedIn", "light", ready: "accounts.openSpotify") }
    func testAccountsSignedInDark() throws { try capture("accounts.signedIn", "dark", ready: "accounts.openSpotify") }

    // MARK: Dashboard

    func testDashboardSignedOutLight() throws { try capture("spotifyDashboard", "light", ready: "spotify.signIn") }
    func testDashboardSignedInLight() throws { try capture("spotifyDashboard.signedIn", "light", ready: "spotify.sync") }
    func testDashboardSignedInDark() throws { try capture("spotifyDashboard.signedIn", "dark", ready: "spotify.sync") }
    func testDashboardPlaylistsLight() throws {
        try capture("spotifyDashboard.signedIn", "light", ready: "spotify.sync", name: "spotifyDashboard.playlists", swipes: 1)
    }
    func testDashboardTestReportDark() throws {
        try capture("spotifyDashboard.tested", "dark", ready: "spotify.testClose", name: "spotifyDashboard.tested", swipes: 1)
    }

    // MARK: Browse

    func testBrowseHomeLight() throws { try capture("spotifyBrowse", "light", ready: "spotifyBrowse.artist.demo-ar-1") }
    func testBrowseHomeDark() throws { try capture("spotifyBrowse", "dark", ready: "spotifyBrowse.artist.demo-ar-1") }
    func testBrowseResultsLight() throws { try capture("spotifyBrowse.results", "light", ready: "spotifyBrowse.album.demo-al-44") }
    func testBrowseArtistLight() throws { try capture("spotifyBrowse.artist", "light", ready: "spotifyBrowse.album.demo-al-44") }
    func testBrowseArtistDark() throws { try capture("spotifyBrowse.artist", "dark", ready: "spotifyBrowse.album.demo-al-44") }
    func testBrowseAlbumLight() throws { try capture("spotifyBrowse.album", "light", ready: "spotifyBrowse.addAlbum") }

    // MARK: - Helper

    private func capture(_ screen: String, _ appearance: String, ready: String, name: String? = nil, swipes: Int = 0) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance, "-noSong"]
        app.launch()

        let route = String(screen.split(separator: ".").first ?? "")
        let identifier = "screen.\(route)"
        XCTAssertTrue(app.descendants(matching: .any)[identifier].firstMatch.waitForExistence(timeout: 20),
                      "\(identifier) did not appear")
        XCTAssertTrue(app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 10),
                      "\(ready) did not appear")

        // Artwork, glass and the debounced demo search settle.
        Thread.sleep(forTimeInterval: 1.5)
        for _ in 0..<swipes {
            app.swipeUp(velocity: .slow)
        }
        Thread.sleep(forTimeInterval: swipes > 0 ? 1.5 : 0.5)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(name ?? screen)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
