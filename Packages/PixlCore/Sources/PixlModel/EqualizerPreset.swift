// Equalizer presets mirroring `data/equalizer/EqualizerPreset.kt`: 10 ISO bands (31 Hz…16 kHz), levels in dB
// steps from −15 to +15. kotlinx-serialized on Android (custom presets), so the Codable keys match.

import Foundation
import PixlFoundation

public struct EqualizerPreset: Sendable, Hashable, Codable, Identifiable {
    /// Stable identifier ("flat", "rock", …, "custom").
    public var name: String
    /// Android label (upper case).
    public var displayName: String
    /// One level per band in `bandFrequencies` order, −15…15.
    public var bandLevels: [Int]
    public var isCustom: Bool

    public var id: String { name }

    public init(name: String, displayName: String, bandLevels: [Int], isCustom: Bool = false) {
        self.name = name
        self.displayName = displayName
        self.bandLevels = bandLevels
        self.isCustom = isCustom
    }

    enum CodingKeys: String, CodingKey { case name, displayName, bandLevels, isCustom }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        displayName = try c.decode(String.self, forKey: .displayName)
        bandLevels = try c.decode([Int].self, forKey: .bandLevels)
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
    }

    /// Band labels (`BAND_FREQUENCIES`).
    public static let bandFrequencies = ["31Hz", "62Hz", "125Hz", "250Hz", "500Hz", "1kHz", "2kHz", "4kHz", "8kHz", "16kHz"]
    /// Band centre frequencies in Hz, same order.
    public static let bandFrequenciesHz: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let minLevel = -15
    public static let maxLevel = 15

    public static let flat = EqualizerPreset(name: "flat", displayName: "FLAT", bandLevels: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    public static let rock = EqualizerPreset(name: "rock", displayName: "ROCK", bandLevels: [5, 4, 3, 1, -1, -1, 1, 3, 4, 5])
    public static let pop = EqualizerPreset(name: "pop", displayName: "POP", bandLevels: [-1, 2, 4, 5, 5, 4, 2, 1, 2, 2])
    public static let hipHop = EqualizerPreset(name: "hip_hop", displayName: "HIP HOP", bandLevels: [6, 8, 4, 1, -1, -1, 1, 1, 3, 4])
    public static let jazz = EqualizerPreset(name: "jazz", displayName: "JAZZ", bandLevels: [3, 2, 1, 2, -1, -1, 0, 2, 3, 4])
    public static let classical = EqualizerPreset(name: "classical", displayName: "CLASSICAL", bandLevels: [4, 3, 2, 1, -1, -1, 0, 2, 4, 4])
    public static let electronic = EqualizerPreset(name: "electronic", displayName: "ELECTRONIC", bandLevels: [5, 6, 2, 0, -1, 1, 0, 2, 6, 7])
    public static let bassBoost = EqualizerPreset(name: "bass_boost", displayName: "BASS BOOST", bandLevels: [7, 9, 6, 3, 0, 0, 0, 0, 0, 0])
    public static let trebleBoost = EqualizerPreset(name: "treble_boost", displayName: "TREBLE BOOST", bandLevels: [0, 0, 0, 0, 0, 1, 3, 6, 8, 9])
    public static let vocal = EqualizerPreset(name: "vocal", displayName: "VOCAL", bandLevels: [-3, -2, -1, 2, 5, 6, 5, 3, 1, 0])

    /// Built-in presets in menu order (`ALL_PRESETS`).
    public static let allPresets: [EqualizerPreset] = [
        flat, rock, pop, hipHop, jazz, classical, electronic, bassBoost, trebleBoost, vocal,
    ]

    /// A user preset (`custom(bandLevels)`).
    public static func custom(bandLevels: [Int]) -> EqualizerPreset {
        EqualizerPreset(name: "custom", displayName: "CUSTOM", bandLevels: bandLevels, isCustom: true)
    }

    /// The built-in preset with this name, else `flat`.
    public static func fromName(_ name: String) -> EqualizerPreset {
        allPresets.first { $0.name.isIdentical(to: name) } ?? flat
    }
}
