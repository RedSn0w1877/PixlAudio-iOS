import PixlBackup
import PixlModel
import XCTest
@testable import PixlAudio

/// Stage 15: the settings ↔ `UserDefaults` mapping, and an Android v3 backup (PixlBackup's fixture, generated from the
/// Android app's classes) restored end to end into SwiftData, `UserDefaults` and the listening history, plus an
/// export that inspects back.
@MainActor
final class BackupServiceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var library: LibraryStore!
    private var history: ListeningHistoryStore!

    override func setUp() async throws {
        suiteName = "pixlaudio.backuptests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Settings mapping

    func testExportTypesValuesAsAndroidDeclaresThem() {
        defaults.set("dark", forKey: "app_theme_mode")
        defaults.set(6000, forKey: "crossfade_duration")
        defaults.set(true, forKey: "is_crossfade_enabled")
        defaults.set(2.5, forKey: "animated_lyrics_blur_strength")
        defaults.set(4000, forKey: "immersive_lyrics_timeout")
        defaults.set(["Shoegaze"], forKey: "custom_genres")
        defaults.set("/x/y", forKey: "allowed_directories_not_a_key")
        defaults.set(["a"], forKey: "allowed_directories") // Android-only: never exported
        let values = SettingsBackup.exportValues(defaults: defaults, keychain: { _ in nil })
        let byKey = Dictionary(values.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byKey["app_theme_mode"], .string("dark"))
        XCTAssertEqual(byKey["crossfade_duration"], .int(6000))
        XCTAssertEqual(byKey["is_crossfade_enabled"], .bool(true))
        XCTAssertEqual(byKey["animated_lyrics_blur_strength"], .float(2.5))
        XCTAssertEqual(byKey["immersive_lyrics_timeout"], .long(4000))
        XCTAssertEqual(byKey["custom_genres"], .stringSet(["Shoegaze"]))
        XCTAssertNil(byKey["allowed_directories"])
        XCTAssertNil(byKey["allowed_directories_not_a_key"])
    }

    func testApplyClearsOwnedKeysWritesPortableOnesAndRoutesApiKeys() throws {
        defaults.set("light", forKey: "app_theme_mode")
        defaults.set(true, forKey: "show_scrollbar") // portable, absent from the backup → cleared (Android default)
        defaults.set(Data([1]), forKey: "ios_only_state")
        let payload = PreferencesModule.export(.globalSettings, values: [
            ("app_theme_mode", .string("dark")), ("ai_temperature", .float(0.7)), ("gemini_api_key", .string("secret")),
        ])
        let restore = try PreferencesModule.restore(.globalSettings, payload: payload)
        var keychain: [String: String] = [:]
        let result = SettingsBackup.apply(restore, defaults: defaults) { account, value in
            keychain[account] = value
            return true
        }
        XCTAssertEqual(result.applied, 2)
        XCTAssertEqual(result.keychain, 1)
        XCTAssertEqual(defaults.string(forKey: "app_theme_mode"), "dark")
        XCTAssertEqual(defaults.double(forKey: "ai_temperature"), 0.7)
        XCTAssertNil(defaults.object(forKey: "show_scrollbar"))
        XCTAssertNotNil(defaults.object(forKey: "ios_only_state"))
        XCTAssertNil(defaults.object(forKey: "gemini_api_key"))
        XCTAssertEqual(keychain["gemini_api_key"], "secret")
    }

    func testSettingsStoreReloadFollowsRestoredDefaults() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.appearance.appThemeMode, .followSystem)
        defaults.set("dark", forKey: PreferenceKeys.appThemeMode)
        defaults.set(6000, forKey: PreferenceKeys.crossfadeDuration)
        store.reload(from: defaults)
        XCTAssertEqual(store.appearance.appThemeMode, .dark)
        XCTAssertEqual(store.playback.crossfadeDurationMs, 6000)
    }

    /// Settings › Appearance › Accent Color (iOS-only) travels in the global-settings module as a string and comes
    /// back on restore; the running app follows (`reload`).
    func testAccentColorIsExportedAndRestored() throws {
        let source = SettingsStore(defaults: defaults)
        source.appearance.accentColor = "#FF453A"
        let values = SettingsBackup.exportValues(defaults: defaults, keychain: { _ in nil })
        let byKey = Dictionary(values.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byKey[PreferenceKeys.accentColor], .string("#FF453A"))

        let payload = PreferencesModule.export(.globalSettings, values: values)
        let restore = try PreferencesModule.restore(.globalSettings, payload: payload)
        XCTAssertFalse(restore.skippedKeys.contains(PreferenceKeys.accentColor))
        let targetSuite = suiteName + ".target"
        let target = try XCTUnwrap(UserDefaults(suiteName: targetSuite))
        defer { target.removePersistentDomain(forName: targetSuite) }
        let running = SettingsStore(defaults: target)
        XCTAssertEqual(running.appearance.accentColor, "")
        SettingsBackup.apply(restore, defaults: target)
        running.reload(from: target)
        XCTAssertEqual(running.appearance.accentColor, "#FF453A")
    }

    /// A backup made before the accent existed (or on Android) restores cleanly: nothing is skipped, and the accent
    /// returns to PixlAudio's violet like every setting the backup doesn't carry.
    func testOldBackupWithoutTheAccentRestoresTheDefault() throws {
        let store = SettingsStore(defaults: defaults)
        store.appearance.accentColor = "#34C759"
        let old = PreferencesModule.export(.globalSettings, values: [("app_theme_mode", .string("dark"))])
        let restore = try PreferencesModule.restore(.globalSettings, payload: old)
        XCTAssertTrue(restore.skippedKeys.isEmpty)
        SettingsBackup.apply(restore, defaults: defaults)
        store.reload(from: defaults)
        XCTAssertEqual(store.appearance.appThemeMode, .dark)
        XCTAssertEqual(store.appearance.accentColor, "")
        // The reload writes the default back through didSet, like every other setting; what matters is that no
        // colour from before the restore survives.
        XCTAssertEqual(defaults.string(forKey: PreferenceKeys.accentColor) ?? "", "")
    }

    /// "Keep screen on" left the lyrics More sheet (owner, 2026-10-07: the lyrics screen always keeps the screen on).
    /// An old backup that still carries the key (Android, or iOS from before) restores cleanly: the key is listed under
    /// skipped settings and never written. A value stored before the switch went is dropped and never exported.
    func testOldBackupWithKeepScreenOnRestoresAndListsItSkipped() throws {
        let old = PreferencesModule.export(.globalSettings, values: [
            ("keep_screen_on_lyrics", .bool(true)), ("app_theme_mode", .string("dark")),
        ])
        let restore = try PreferencesModule.restore(.globalSettings, payload: old)
        XCTAssertEqual(restore.skippedKeys, ["keep_screen_on_lyrics"])
        let result = SettingsBackup.apply(restore, defaults: defaults)
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(defaults.string(forKey: "app_theme_mode"), "dark")
        XCTAssertNil(defaults.object(forKey: "keep_screen_on_lyrics"))

        defaults.set(true, forKey: "keep_screen_on_lyrics")
        XCTAssertFalse(SettingsBackup.exportValues(defaults: defaults, keychain: { _ in nil })
            .contains { $0.key == "keep_screen_on_lyrics" })
        _ = LyricsViewPreferences(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "keep_screen_on_lyrics"))
    }

    // MARK: Restore

    func testRestoresTheAndroidFixtureAndReportsUnmatchedSongs() async throws {
        let service = try makeService()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android-v3", withExtension: "pxpl"),
                                "android-v3.pxpl is not bundled with the tests")
        let backup = try await service.inspect(url: url)
        XCTAssertTrue(backup.isFromAndroid)
        XCTAssertEqual(backup.plan.availableModules.count, 12)

        let report = await service.restore(backup, sections: Set(backup.plan.availableModules))
        XCTAssertEqual(report.outcome, .success, "\(report.failures)")
        XCTAssertTrue(report.fromAndroid)
        XCTAssertEqual(report.entries.first { $0.section == .playlists }?.restored, 2)
        XCTAssertEqual(report.entries.first { $0.section == .favorites }?.unmatched, 1)
        XCTAssertTrue(report.hasUnmatchedSongData)
        XCTAssertTrue(report.restoredSettings)
        XCTAssertTrue(report.skippedSettings.contains("nav_bar_corner_radius"))

        XCTAssertEqual(library!.playlists.map(\.name).sorted(), ["Gym • AI", "Late Night"])
        XCTAssertEqual(library!.song(id: "f:music/M83/Midnight City.flac")?.isFavorite, true)
        XCTAssertEqual(defaults.string(forKey: "app_theme_mode"), "dark")
        XCTAssertEqual(defaults.integer(forKey: "crossfade_duration"), 6000)
        XCTAssertEqual(history!.events.count, 2)
    }

    func testExportInspectsBackAsAPixlAudioBackup() async throws {
        let service = try makeService()
        defaults.set("dark", forKey: "app_theme_mode")
        let document = try await service.export(sections: [.playlists, .globalSettings, .favorites])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pxpl")
        try document.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let backup = try await service.inspect(url: url)
        XCTAssertFalse(backup.isFromAndroid)
        XCTAssertEqual(Set(backup.plan.availableModules), [.playlists, .globalSettings, .favorites])
    }

    func testSetupOpensTheRequestedPage() {
        XCTAssertEqual(SetupView.initialPage(for: nil), .welcome)
        XCTAssertEqual(SetupView.initialPage(for: .setupBackup), .backupRestore)
        XCTAssertEqual(SetupView.initialPage(for: .setupFinish), .finish)
        XCTAssertEqual(SetupView.Page.allCases.count, 8)
    }

    // MARK: -

    private func makeService() throws -> BackupService {
        let persistence = PersistenceActor(modelContainer: try PersistenceActor.makeContainer(inMemory: true))
        let songs = [
            song("f:music/M83/Midnight City.flac", "Midnight City", "M83", "Hurry Up, We're Dreaming", 243_500),
            song("f:music/The xx/Intro.m4a", "Intro", "The xx", "xx", 127_000),
            song("mp:9001", "Teardrop", "Massive Attack", "Mezzanine", 330_200),
        ]
        let library = LibraryStore(snapshot: LibrarySnapshot(songs: songs, albums: [], artists: [], playlists: []))
        let home = HomeStore.make(launch: LaunchConfiguration(arguments: ["-uiTest"]))
        self.library = library
        history = home.history
        return BackupService(persistence: persistence, library: library, settings: SettingsStore(defaults: defaults),
                             defaults: defaults, history: home.history, playbackServices: nil, isUITest: true)
    }

    private func song(_ id: String, _ title: String, _ artist: String, _ album: String, _ duration: Int64) -> Song {
        Song(id: id, title: title, artist: artist, artistId: 1, album: album, albumId: 1, path: "/\(id)",
             contentUriString: "file:///\(id)", albumArtUriString: nil, duration: duration, mimeType: nil, bitrate: nil,
             sampleRate: nil)
    }
}
