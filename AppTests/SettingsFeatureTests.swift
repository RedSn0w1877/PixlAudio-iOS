import PixlAudioCore
import PixlModel
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

    func testMainListOrderMatchesAndroid() {
        XCTAssertEqual(SettingsMainEntry.ordered.map(\.id), [
            "library", "appearance", "playback", "equalizer", "behavior", "ai", "backup_restore",
            "accounts", "developer", "device_capabilities", "about",
        ])
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

    func testEngineSettingsFollowThePreferences() {
        let prefs = EqualizerPreferences(defaults: freshDefaults())
        let model = EqualizerModel(prefs: prefs)
        model.toggleEnabled()
        model.select(.bassBoost)
        prefs.virtualizerEnabled = true
        prefs.virtualizerStrength = 500
        let engine = prefs.engineSettings
        XCTAssertTrue(engine.isEnabled)
        XCTAssertEqual(engine.bandLevels, EqualizerPreset.bassBoost.bandLevels)
        XCTAssertTrue(engine.virtualizerEnabled)
        XCTAssertEqual(engine.virtualizerStrength, 500)
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
    }

    // MARK: Delimiters (Android ArtistSettingsViewModel)

    func testDefaultsAreAndroids() {
        let library = LibrarySettings(defaults: freshDefaults())
        XCTAssertEqual(library.artistDelimiters, [";"])
        XCTAssertEqual(library.artistWordDelimiters.first, "featuring")
    }
}
