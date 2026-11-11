import PixlAudioCore
import PixlBackup
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// Stage 7d: the settings screens' logic (equalizer presets, transitions, update check, delimiters, entry order).
@MainActor
final class SettingsFeatureTests: XCTestCase {
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "pixlaudio.tests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: Main list

    /// The everyday rows, Accounts first and About last; Developer and Device capabilities come only with developer
    /// mode (under its switch, the list's last group).
    func testMainListOrderMatchesAndroid() {
        let everyday = [
            "accounts", "appearance", "playback", "equalizer", "lyrics", "sing", "behavior", "library", "ai",
            "backup_restore", "about",
        ]
        XCTAssertEqual(SettingsMainEntry.ordered(developerMode: false).map(\.id), everyday)
        XCTAssertEqual(SettingsMainEntry.ordered(developerMode: true).map(\.id),
                       everyday + ["developer", "device_capabilities"])
    }

    /// The plain-English names and subtitles of the rows whose text changed (or is new).
    func testMainListTitlesAndSubtitles() {
        let entries = SettingsMainEntry.ordered(developerMode: true)
        let titles = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.title) })
        let subtitles = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.subtitle) })
        XCTAssertEqual(titles["lyrics"], "Lyrics")
        XCTAssertEqual(titles["sing"], "Sing")
        XCTAssertEqual(titles["behavior"], "Gestures & haptics")
        XCTAssertEqual(titles["library"], "Library & storage")
        XCTAssertEqual(titles["developer"], "Developer")
        XCTAssertEqual(titles["device_capabilities"], "Device capabilities")
        XCTAssertEqual(subtitles["accounts"], "Connect Spotify and sync your playlists")
        XCTAssertEqual(subtitles["sing"], "Make instrumentals to sing along")
        XCTAssertEqual(subtitles["developer"], "Experiments and debugging tools")
    }

    // MARK: Developer mode

    /// Off by default, kept per device, and on in the UI tests' throwaway settings.
    func testDeveloperModeDefaultsOffAndPersists() {
        let defaults = freshDefaults()
        let experimental = ExperimentalSettings(defaults: defaults)
        XCTAssertFalse(experimental.developerMode)
        experimental.developerMode = true
        XCTAssertTrue(defaults.bool(forKey: PreferenceKeys.developerMode))
        XCTAssertTrue(ExperimentalSettings(defaults: defaults).developerMode)
        XCTAssertEqual(PreferenceKeys.developerMode, "developer_mode_enabled")
        XCTAssertTrue(SettingsStore.ephemeral().experimental.developerMode)
    }

    /// Turning developer mode off hides the advanced rows; what they set keeps applying.
    func testTurningDeveloperModeOffKeepsAdvancedValues() {
        let defaults = freshDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.experimental.developerMode = true
        settings.playback.replayGainEnabled = true
        settings.appearance.fullPlayerShowFileInfo = false
        settings.experimental.developerMode = false
        XCTAssertTrue(SettingsStore(defaults: defaults).playback.replayGainEnabled)
        XCTAssertFalse(SettingsStore(defaults: defaults).appearance.fullPlayerShowFileInfo)
    }

    /// A restore reloads the running store from the defaults, developer mode included.
    func testReloadFollowsDeveloperMode() {
        let defaults = freshDefaults()
        let running = SettingsStore(defaults: defaults)
        defaults.set(true, forKey: PreferenceKeys.developerMode)
        running.reload(from: defaults)
        XCTAssertTrue(running.experimental.developerMode)
    }

    /// The export picker and the restore list hide the technical sections outside developer mode.
    func testBackupListsHideTechnicalSectionsOutsideDeveloperMode() {
        let everyday = BackupSection.listed(developerMode: false)
        XCTAssertEqual(everyday.count, 7)
        XCTAssertFalse(everyday.contains(.transitions))
        XCTAssertFalse(everyday.contains(.engagementStats))
        XCTAssertFalse(everyday.contains(.quickFill))
        XCTAssertFalse(everyday.contains(.artistImages))
        XCTAssertFalse(everyday.contains(.aiUsageLogs))
        XCTAssertTrue(everyday.contains(.playlists) && everyday.contains(.globalSettings))
        XCTAssertEqual(BackupSection.listed(developerMode: true), BackupSection.allCases)
    }

    // MARK: Equalizer (Android EqualizerViewModel)

    func testMovingABandSwitchesToCustomAndKeepsTheOtherBands() {
        let model = EqualizerModel(prefs: EqualizerPreferences(defaults: freshDefaults()))
        model.select(.rock)
        model.setBandLevel(0, 2)
        XCTAssertEqual(model.prefs.presetName, "custom")
        XCTAssertEqual(model.bandLevels, [2] + Array(EqualizerPreset.rock.bandLevels.dropFirst()))
        model.setBandLevel(1, 99)
        XCTAssertEqual(model.bandLevels[1], EqualizerBands.maxLevel, "levels clamp to ±15")
    }

    func testSaveRenameDeleteCustomPreset() {
        let model = EqualizerModel(prefs: EqualizerPreferences(defaults: freshDefaults()))
        model.setBandLevel(3, 5)
        model.saveCurrentAsCustomPreset("Mine")
        XCTAssertEqual(model.customPresets.map(\.name), ["Mine"])
        XCTAssertTrue(model.pinnedNames.contains("Mine"))
        XCTAssertEqual(model.currentPreset.name, "Mine")
        XCTAssertEqual(model.bandLevels[3], 5)

        // Editing a saved preset remembers it for "Update".
        model.setBandLevel(4, -3)
        XCTAssertEqual(model.editingPresetName, "Mine")
        model.updateCustomPresetBands("Mine")
        XCTAssertEqual(model.customPresets.first?.bandLevels[4], -3)

        model.renameCustomPreset("Mine", to: "  Ours ")
        XCTAssertEqual(model.customPresets.map(\.name), ["Ours"])
        XCTAssertTrue(model.pinnedNames.contains("Ours"))
        XCTAssertEqual(model.prefs.presetName, "Ours")

        model.deleteCustomPreset(model.customPresets[0])
        XCTAssertTrue(model.customPresets.isEmpty)
        XCTAssertFalse(model.pinnedNames.contains("Ours"))
        XCTAssertEqual(model.prefs.presetName, "flat")
    }

    func testTabsArePinnedBuiltInsThenCustom() {
        let model = EqualizerModel(prefs: EqualizerPreferences(defaults: freshDefaults()))
        model.setPinnedOrder(["pop", "rock"])
        XCTAssertEqual(model.tabPresets.map(\.name), ["pop", "rock", "custom"])
        model.resetPinnedToDefault()
        XCTAssertEqual(model.tabPresets.count, EqualizerPreset.allPresets.count + 1)
    }

    /// The equalizer is marked broken (owner, 2026-10-26): the engine gets everything off whatever the preferences say,
    /// and a store that finds effects stored on switches them off.
    func testEqualizerIsLockedOffWhileItIsBroken() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: PreferenceKeys.equalizerEnabled)
        defaults.set(true, forKey: PreferenceKeys.bassBoostEnabled)
        defaults.set(true, forKey: PreferenceKeys.virtualizerEnabled)
        defaults.set(true, forKey: PreferenceKeys.loudnessEnhancerEnabled)
        let prefs = EqualizerPreferences(defaults: defaults)
        XCTAssertFalse(prefs.isEnabled || prefs.bassBoostEnabled || prefs.virtualizerEnabled || prefs.loudnessEnhancerEnabled)
        XCTAssertFalse(defaults.bool(forKey: PreferenceKeys.equalizerEnabled))
        XCTAssertFalse(defaults.bool(forKey: PreferenceKeys.virtualizerEnabled))
        // Even switched on afterwards (a restored backup), the engine stays flat.
        let model = EqualizerModel(prefs: prefs)
        model.toggleEnabled()
        model.select(.bassBoost)
        prefs.virtualizerEnabled = true
        prefs.virtualizerStrength = 500
        XCTAssertFalse(prefs.engineSettings.hasAnyEnabledEffects)
        XCTAssertEqual(prefs.engineSettings.bandLevels, EqualizerSettings().bandLevels)
        // The Settings list keeps the row, marked, and it does not open.
        let row = SettingsMainEntry.category(.equalizer)
        XCTAssertEqual(row.brokenFeature, .equalizer)
        XCTAssertNil(SettingsMainEntry.category(.lyrics).brokenFeature)
        XCTAssertNil(SettingsMainEntry.accounts.brokenFeature)
    }

    /// Smart features start on and nothing in a fresh store or in setup turns them off (owner, 2026-10-26).
    func testSmartFeaturesStartOn() {
        let settings = SettingsStore(defaults: freshDefaults())
        XCTAssertTrue(settings.ai.musicLearningEnabled)
        XCTAssertTrue(settings.ai.musicDiscoveryEnabled)
        XCTAssertTrue(settings.lyrics.automaticLyrics)
        XCTAssertTrue(settings.playback.automaticInstrumentals)
        XCTAssertGreaterThan(settings.ai.claudeMonthlyCap, 0, "cloud AI is on until the monthly limit is set to $0")
        XCTAssertEqual(settings.ai.provider, AiProvider.onDevice.rawValue, "the on-device model is always the fallback")
        // Finishing setup only records that setup ran.
        settings.behavior.initialSetupDone = true
        XCTAssertTrue(settings.ai.musicLearningEnabled)
        XCTAssertTrue(settings.ai.musicDiscoveryEnabled)
        XCTAssertTrue(settings.lyrics.automaticLyrics)
        XCTAssertGreaterThan(settings.ai.claudeMonthlyCap, 0)
    }

    // MARK: Transitions (Android TransitionViewModel / globalTransitionSettingsFlow)

    func testGlobalTransitionDurationComesFromCrossfadeDuration() {
        let playback = PlaybackSettings(defaults: freshDefaults())
        playback.crossfadeDurationMs = 30_000
        XCTAssertEqual(TransitionEditorModel.globalSettings(from: playback).durationMs, 12_000)
        playback.crossfadeDurationMs = 0
        XCTAssertEqual(TransitionEditorModel.globalSettings(from: playback).durationMs, 1_000)
    }

    func testGlobalSaveRoundTrips() async {
        let playback = PlaybackSettings(defaults: freshDefaults())
        let model = TransitionEditorModel()
        await model.load(playlistId: nil, playback: playback, persistence: nil)
        model.update(playlistId: nil) {
            $0.durationMs = 6000
            $0.curveIn = .linear
        }
        await model.save(playlistId: nil, playback: playback, persistence: nil)
        let reloaded = TransitionEditorModel.globalSettings(from: playback)
        XCTAssertEqual(reloaded.durationMs, 6000)
        XCTAssertEqual(reloaded.curveIn, .linear)
    }

    func testPlaylistFollowsGlobalUntilOverridden() async {
        let playback = PlaybackSettings(defaults: freshDefaults())
        let model = TransitionEditorModel()
        await model.load(playlistId: "p1", playback: playback, persistence: nil)
        XCTAssertTrue(model.useGlobalDefaults)
        model.enableOverride(isPlaylist: true)
        XCTAssertFalse(model.useGlobalDefaults)
        XCTAssertEqual(model.rule, model.globalSettings)
        model.useGlobal(isPlaylist: true)
        XCTAssertNil(model.rule)
    }

    func testCurveLabelsMatchAndroid() {
        XCTAssertEqual(TransitionCurve.allCases.map { TransitionCurvesLabel.label($0) },
                       ["Linear", "Exp", "Log", "S_curve"])
    }

    // MARK: About

    func testUpdateVersionComparison() {
        XCTAssertTrue(AppUpdateChecker.isNewer("1.10.0", than: "1.9.2"))
        XCTAssertTrue(AppUpdateChecker.isNewer("2", than: "1.99"))
        XCTAssertFalse(AppUpdateChecker.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(AppUpdateChecker.isNewer("0.9-beta", than: "1.0"))
        // Betas: the number first, then stable over beta, then the beta's number.
        XCTAssertTrue(AppUpdateChecker.isNewerRelease("1.1.0-beta1", than: "1.0.0"))
        XCTAssertTrue(AppUpdateChecker.isNewerRelease("1.1.0-beta2", than: "1.1.0-beta1"))
        XCTAssertTrue(AppUpdateChecker.isNewerRelease("1.1.0-beta10", than: "1.1.0-beta9"))
        XCTAssertTrue(AppUpdateChecker.isNewerRelease("1.1.0", than: "1.1.0-beta2"))
        XCTAssertFalse(AppUpdateChecker.isNewerRelease("1.1.0-beta1", than: "1.1.0"))
        XCTAssertFalse(AppUpdateChecker.isNewerRelease("1.1.0-beta1", than: "1.1.0-beta1"))
        XCTAssertFalse(AppUpdateChecker.isNewerRelease("1.0.0", than: "1.1.0-beta1"))
    }

    // MARK: Delimiters (Android ArtistSettingsViewModel)

    func testDefaultsAreAndroids() {
        let library = LibrarySettings(defaults: freshDefaults())
        XCTAssertEqual(library.artistDelimiters, [";"])
        XCTAssertEqual(library.artistWordDelimiters.first, "featuring")
    }
}
