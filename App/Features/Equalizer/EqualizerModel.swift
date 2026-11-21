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

    var customPresets: [EqualizerPreset] { prefs.savedPresets }

    @ObservationIgnored private var decodedPinsJSON: String?
    @ObservationIgnored private var decodedPins: [String] = []

    var pinnedNames: [String] {
        guard let json = prefs.pinnedPresetsJSON else { return EqualizerPreset.allPresets.map(\.name) }
        if json != decodedPinsJSON {
            let names = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? EqualizerPreset.allPresets.map(\.name)
            var seen: Set<String> = []
            decodedPins = names.filter { $0 != "custom" && seen.insert($0).inserted }
            decodedPinsJSON = json
        }
        return decodedPins
    }

    var currentPreset: EqualizerPreset { prefs.selectedPreset }

    var bandLevels: [Int] {
        currentPreset.bandLevels
    }

    /// Pinned presets resolved to presets (custom first, then built-in) — Android `accessiblePresets`.
    var accessiblePresets: [EqualizerPreset] {
        let custom = customPresets
        return pinnedNames.compactMap { name in
            custom.first { $0.name == name } ?? EqualizerPreset.allPresets.first { $0.name == name }
        }
    }

    /// Pinned presets in the order chosen in Manage presets, followed by the editable custom curve.
    var tabPresets: [EqualizerPreset] {
        accessiblePresets + [.custom(bandLevels: Array(repeating: 0, count: 10))]
    }

    var allAvailablePresets: [EqualizerPreset] { EqualizerPreset.allPresets + customPresets }

    var viewMode: EqualizerViewMode { EqualizerViewMode(rawValue: prefs.viewMode) ?? .sliders }

    // MARK: Actions

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

    func canNamePreset(_ draft: String) -> Bool {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != "custom" && !allAvailablePresets.contains { $0.name == name }
    }

    func saveCurrentAsCustomPreset(_ draft: String) {
        guard canNamePreset(draft) else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = EqualizerPreset(name: name, displayName: name, bandLevels: prefs.customBands, isCustom: true)
        var presets = customPresets
        presets.append(preset)
        writePresets(presets)
        if !pinnedNames.contains(name) { togglePin(name) }
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
        if editingPresetName == preset.name { editingPresetName = nil }
    }

    func renameCustomPreset(_ oldName: String, to newName: String) {
        guard canNamePreset(newName) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if editingPresetName == oldName { editingPresetName = trimmed }
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

    var title: String {
        switch self {
        case .sliders: String(localized: "Sliders")
        case .graph: String(localized: "Graph")
        case .hybrid: String(localized: "Hybrid")
        }
    }
}

extension EqualizerPreferences {
    fileprivate var selectedPreset: EqualizerPreset {
        if presetName == "custom" { return .custom(bandLevels: customBands) }
        return savedPresets.first { $0.name == presetName } ?? .fromName(presetName)
    }

    /// The settings the audio engine applies (PixlAudioCore `EqualizerSettings`), from the stored preferences.
    var engineSettings: EqualizerSettings {
        var settings = EqualizerSettings()
        // Built-in presets restore by name; "custom" and saved custom presets apply their band levels.
        let preset = selectedPreset
        settings.restore(enabled: isEnabled, presetName: preset.isCustom ? "custom" : preset.name, customBands: preset.bandLevels,
                         bassBoostEnabled: bassBoostEnabled, bassBoostStrength: bassBoostStrength,
                         virtualizerEnabled: virtualizerEnabled, virtualizerStrength: virtualizerStrength,
                         loudnessEnabled: loudnessEnhancerEnabled, loudnessStrength: loudnessEnhancerStrength)
        return settings
    }
}
