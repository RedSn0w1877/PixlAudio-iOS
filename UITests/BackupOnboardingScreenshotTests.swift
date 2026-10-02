import XCTest

/// Stage 15 screenshots: every setup page (Android `SetupScreen`) and the backup restore steps — the module dialog
/// for an Android backup and the restore report. Setup pages open the `setup` cover on a page
/// (`-screen setupTheme` …); the backup steps open the `backupImport` cover on a step.
@MainActor
final class BackupOnboardingScreenshotTests: XCTestCase {
    // MARK: Setup

    func testSetupWelcomeLight() throws { try capture("setup", "light", ready: "screen.setup") }
    func testSetupWelcomeDark() throws { try capture("setup", "dark", ready: "screen.setup") }
    func testSetupPermissionLight() throws { try capture("setupPermission", "light", ready: "screen.setup") }
    func testSetupFoldersDark() throws { try capture("setupFolders", "dark", ready: "screen.setup") }
    func testSetupBackupLight() throws { try capture("setupBackup", "light", ready: "screen.setup") }
    func testSetupThemeLight() throws { try capture("setupTheme", "light", ready: "screen.setup") }
    func testSetupThemeDark() throws { try capture("setupTheme", "dark", ready: "screen.setup") }
    func testSetupLibraryLayoutLight() throws { try capture("setupLibraryLayout", "light", ready: "screen.setup") }
    func testSetupSpotifyDark() throws { try capture("setupSpotify", "dark", ready: "screen.setup") }
    func testSetupFinishLight() throws { try capture("setupFinish", "light", ready: "screen.setup") }

    /// Next moves to the following page (the step counter and the button's shape change).
    func testSetupNextLight() throws {
        try capture("setup", "light", ready: "screen.setup") { app in
            let next = app.descendants(matching: .any)["setup.next"].firstMatch
            if next.waitForExistence(timeout: 5) { next.tap() }
        }
    }

    // MARK: Backup

    func testBackupRestorePlanLight() throws { try capture("backupRestorePlan", "light", ready: "screen.backupRestorePlan") }
    func testBackupRestorePlanDark() throws { try capture("backupRestorePlan", "dark", ready: "screen.backupRestorePlan") }
    func testBackupImportReportLight() throws { try capture("backupImportReport", "light", ready: "screen.backupReport") }
    func testBackupImportReportDark() throws { try capture("backupImportReport", "dark", ready: "screen.backupReport") }

    /// Tapping "Select & Export" opens the export cover from the root (the real tap path, not the demo launch).
    func testBackupExportPickerLight() throws {
        try capture("settingsCategory.backup_restore", "light", ready: "screen.settingsCategory.backup_restore") { app in
            let button = app.buttons["Select & Export"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Select & Export missing")
            button.tap()
            XCTAssertTrue(app.descendants(matching: .any)["screen.backupExport"].firstMatch.waitForExistence(timeout: 10),
                          "screen.backupExport did not appear")
        }
    }

    /// Diagnostic for a cover attached inside Settings' lazy list (Library › Music folders, stage 7d's code): does a
    /// tap present it? Recorded as a screenshot, never fails the run.
    func testLibraryFoldersCoverProbeLight() throws {
        try capture("settingsCategory.library", "light", ready: "screen.settingsCategory.library") { app in
            // By identifier or label: settings rows share a glass container, whose children keep only their labels.
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH[c] %@", "settings.library.folders",
                                      "Excluded Directories"))
                .firstMatch
            guard row.waitForExistence(timeout: 5) else { return }
            row.tap()
            let shown = app.descendants(matching: .any)["screen.musicFolders"].firstMatch.waitForExistence(timeout: 8)
            let note = XCTAttachment(string: "musicFolders cover presented: \(shown)")
            note.lifetime = .keepAlways
            self.add(note)
        }
    }

    // MARK: - Helper

    private func capture(_ screen: String, _ appearance: String, ready: String,
                         interact: ((XCUIApplication) -> Void)? = nil) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance, "-noSong"]
        app.launch()

        let element = app.descendants(matching: .any)[ready].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 25), "\(ready) did not appear")
        interact?(app)

        // Let glass, the page transition and the cover presentation settle.
        Thread.sleep(forTimeInterval: 2.0)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(screen)-\(appearance)" + (interact == nil ? "" : "-interacted")
        attachment.lifetime = .keepAlways
        add(attachment)

        app.terminate()
    }
}
