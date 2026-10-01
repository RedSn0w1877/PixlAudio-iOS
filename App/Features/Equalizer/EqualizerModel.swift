import Foundation
import Observation
import PixlAudioCore
import PixlModel

/// Android `EqualizerViewModel` + `EqualizerPreferencesRepository` presets logic, over `EqualizerPreferences` (the
/// Android keys). The playback engine (stage 5) reads the same preferences — `EqualizerPreferences.engineSettings`.
@Observable
final class EqualizerModel {
    let prefs: EqualizerPreferences
    /// The custom preset being edited after moving a band of a saved preset (Android `editingPresetName`).
    private(set) var editingPresetName: String?

    init(prefs: EqualizerPreferences) {
        self.prefs = prefs
    }

    // MARK: Derived state (Android `EqualizerUiState`)

    var customPresets: [EqualizerPreset] {
        guard let json = prefs.customPresetsJSON, let data = json.data(using: .utf8),
              let presets = try? JSONDecoder().decode([EqualizerPreset].self, from: data) else { return [] }
        return presets
    }

    var pinnedNames: [String] {
        guard let json = prefs.pinnedPresetsJSON, let data = json.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            return EqualizerPreset.allPresets.map(\.name)
        }
        return names
    }

    var currentPreset: EqualizerPreset {
        if prefs.presetName == "custom" { return .custom(bandLevels: prefs.customBands) }
        return customPresets.first { $0.name == prefs.presetName } ?? .fromName(prefs.presetName)
    }

    var bandLevels: [Int] {
        let preset = currentPreset
        return preset.name == "custom" ? prefs.customBands : preset.bandLevels
    }

    /// Pinned presets resolved to presets (custom first, then built-in) — Android `accessiblePresets`.
    var accessiblePresets: [EqualizerPreset] {
        let custom = customPresets
        return pinnedNames.compactMap { name in
            custom.first { $0.name == name } ?? EqualizerPreset.allPresets.first { $0.name == name }
        }
    }

    /// The tabs: pinned built-in presets, then the "Custom" tab (Android `visiblePresets`).
    var tabPresets: [EqualizerPreset] {
        accessiblePresets.filter { !$0.isCustom } + [.custom(bandLevels: Array(repeating: 0, count: 10))]
    }

    var allAvailablePresets: [EqualizerPreset] { EqualizerPreset.allPresets + customPresets }

    var viewMode: EqualizerViewMode { EqualizerViewMode(rawValue: prefs.viewMode) ?? .sliders }

    // MARK: Actions

    func cycleViewMode() {
        prefs.viewMode = viewMode.next.rawValue
    }

    func toggleEnabled() { prefs.isEnabled.toggle() }

    func select(_ preset: EqualizerPreset) {
        editingPresetName = nil
        prefs.presetName = preset.name
        if !preset.isCustom { prefs.customBands = preset.bandLevels }
    }

    /// Android `setBandLevel`: moving a band switches to "custom", remembering which saved preset was being edited.
    func setBandLevel(_ index: Int, _ level: Int) {
        var bands = bandLevels
        guard bands.indices.contains(index) else { return }
        let clamped = min(max(level, EqualizerBands.minLevel), EqualizerBands.maxLevel)
        guard bands[index] != clamped else { return }
        let current = currentPreset
        if editingPresetName == nil, current.isCustom, current.name != "custom" { editingPresetName = current.name }
        bands[index] = clamped
        prefs.customBands = bands
        if prefs.presetName != "custom" { prefs.presetName = "custom" }
    }

    func saveCurrentAsCustomPreset(_ name: String) {
        let preset = EqualizerPreset(name: name, displayName: name, bandLevels: prefs.customBands, isCustom: true)
        var presets = customPresets
        presets.removeAll { $0.name == name }
        presets.append(preset)
        writePresets(presets)
        togglePin(name)
        select(preset)
    }

    func deleteCustomPreset(_ preset: EqualizerPreset) {
        // Android checks the state from before the delete (its UI state still holds the deleted preset).
        let wasCurrent = currentPreset.name == preset.name
        writePresets(customPresets.filter { $0.name != preset.name })
        var pinned = pinnedNames
        if let index = pinned.firstIndex(of: preset.name) {
            pinned.remove(at: index)
            writePinned(pinned)
        }
        if wasCurrent { select(.flat) }
    }

    func renameCustomPreset(_ oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        var presets = customPresets
        guard let index = presets.firstIndex(where: { $0.name == oldName }) else { return }
        presets[index].name = trimmed
        presets[index].displayName = trimmed
        writePresets(presets)
        var pinned = pinnedNames
        if let i = pinned.firstIndex(of: oldName) {
            pinned[i] = trimmed
            writePinned(pinned)
        }
        if prefs.presetName == oldName { prefs.presetName = trimmed }
    }

    func updateCustomPresetBands(_ name: String) {
        var presets = customPresets
        guard let index = presets.firstIndex(where: { $0.name == name }) else { return }
        presets[index].bandLevels = prefs.customBands
        writePresets(presets)
        select(presets[index])
    }

    func togglePin(_ name: String) {
        var pinned = pinnedNames
        if let index = pinned.firstIndex(of: name) { pinned.remove(at: index) } else { pinned.append(name) }
        writePinned(pinned)
    }

    func setPinnedOrder(_ names: [String]) { writePinned(names) }

    func resetPinnedToDefault() { writePinned(EqualizerPreset.allPresets.map(\.name)) }

    private func writePresets(_ presets: [EqualizerPreset]) {
        prefs.customPresetsJSON = (try? JSONEncoder().encode(presets)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func writePinned(_ names: [String]) {
        prefs.pinnedPresetsJSON = (try? JSONEncoder().encode(names)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// Android `EqualizerViewMode`.
nonisolated enum EqualizerViewMode: String, Sendable, CaseIterable {
    case sliders = "SLIDERS"
    case graph = "GRAPH"
    case hybrid = "HYBRID"

    var next: EqualizerViewMode {
        switch self {
        case .sliders: .graph
        case .graph: .hybrid
        case .hybrid: .sliders
        }
    }

    /// SF Symbols for Android's GraphicEq / ShowChart / ViewQuilt.
    var systemImage: String {
        switch self {
        case .sliders: "slider.vertical.3"
        case .graph: "chart.xyaxis.line"
        case .hybrid: "rectangle.split.2x1"
        }
    }
}

extension EqualizerPreferences {
    /// The settings the audio engine applies (PixlAudioCore `EqualizerSettings`), from the stored preferences.
    var engineSettings: EqualizerSettings {
        var settings = EqualizerSettings()
        // Built-in presets restore by name; "custom" and saved custom presets apply their band levels.
        let isBuiltIn = EqualizerPreset.allPresets.contains { $0.name == presetName }
        var bands = customBands
        if !isBuiltIn, presetName != "custom", let json = customPresetsJSON, let data = json.data(using: .utf8),
           let saved = (try? JSONDecoder().decode([EqualizerPreset].self, from: data))?.first(where: { $0.name == presetName }) {
            bands = saved.bandLevels
        }
        settings.restore(enabled: isEnabled, presetName: isBuiltIn ? presetName : "custom", customBands: bands,
                         bassBoostEnabled: bassBoostEnabled, bassBoostStrength: bassBoostStrength,
                         virtualizerEnabled: virtualizerEnabled, virtualizerStrength: virtualizerStrength,
                         loudnessEnabled: loudnessEnhancerEnabled, loudnessStrength: loudnessEnhancerStrength)
        return settings
    }
}
