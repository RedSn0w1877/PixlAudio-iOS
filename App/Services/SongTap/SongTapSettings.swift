import Foundation
import Observation
import PixlLibrary
import UIKit

/// Song Tap's switches, in a small store of their own (nothing is read at app start; the first read is when Song Tap
/// opens). Android keeps the same two in a DataStore called `song_tap`.
///
/// - `allowed`: "Allow Song Tap", off by default. Turned on from the Song Tap row in the player's menu (that is also when
///   the permissions are asked), or in Settings.
/// - `firstBeamAsks`: the first beam a receiver ever gets shows an explicit Add / Not now card; once the listener has
///   said yes, later beams save by themselves with a 6 second Undo.
/// - `name`: "Your name", the name other phones show ("Song drop to X?", "From X"). 1 to 20 characters, cleaned like Android's.
/// - `sensitivity`: Normal or High (the default), applied live to the tap.
@Observable
final class SongTapSettings {
    nonisolated enum Keys {
        static let allow = "allow_song_tap"
        static let firstBeamAccepted = "song_tap_first_beam_accepted"
        static let name = "song_tap_your_name"
        static let sensitivity = "song_tap_sensitivity"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var allowed: Bool { didSet { defaults.set(allowed, forKey: Keys.allow) } }
    private(set) var firstBeamAsks: Bool
    /// The name other phones see; never empty. Empty after cleaning puts the device's name back.
    private(set) var name: String
    private(set) var sensitivity: SongTapSensitivity

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        allowed = defaults.bool(forKey: Keys.allow)
        firstBeamAsks = !defaults.bool(forKey: Keys.firstBeamAccepted)
        name = Self.stored(defaults.string(forKey: Keys.name))
        sensitivity = SongTapSensitivity.fromCode(defaults.string(forKey: Keys.sensitivity))
    }

    /// The device's name as iOS gives it (a generic "iPhone" unless the system shares the owner's), cleaned; "iPhone" when nothing is left.
    static var deviceName: String {
        let cleaned = SongTapNames.clean(UIDevice.current.name)
        return cleaned.isEmpty ? "iPhone" : cleaned
    }

    private static func stored(_ raw: String?) -> String {
        guard let raw else { return deviceName }
        let cleaned = SongTapNames.clean(raw)
        return cleaned.isEmpty ? deviceName : cleaned
    }

    /// Saves `raw` as the name (cleaned: 1 to 20 characters); an empty one puts the device's name back.
    func setName(_ raw: String) {
        let cleaned = SongTapNames.clean(raw)
        if cleaned.isEmpty {
            defaults.removeObject(forKey: Keys.name)
            name = Self.deviceName
        } else {
            defaults.set(cleaned, forKey: Keys.name)
            name = cleaned
        }
    }

    func setSensitivity(_ value: SongTapSensitivity) {
        sensitivity = value
        defaults.set(value.code, forKey: Keys.sensitivity)
    }

    /// The listener said yes to a first beam: from now on beams save at once.
    func markFirstBeamAccepted() {
        firstBeamAsks = false
        defaults.set(true, forKey: Keys.firstBeamAccepted)
    }
}
