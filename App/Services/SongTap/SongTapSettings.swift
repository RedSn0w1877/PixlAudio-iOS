import Foundation
import Observation

/// Song Tap's two switches, in a small store of their own (nothing is read at app start; the first read is when Song Tap
/// opens). Android keeps the same two in a DataStore called `song_tap`.
///
/// - `allowed`: "Allow Song Tap", off by default. Turned on from the Song Tap row in the player's menu (that is also when
///   the permissions are asked), or in Settings.
/// - `firstBeamAsks`: the first beam a receiver ever gets shows an explicit Add / Not now card; once the listener has
///   said yes, later beams save by themselves with a 6 second Undo.
@Observable
final class SongTapSettings {
    nonisolated enum Keys {
        static let allow = "allow_song_tap"
        static let firstBeamAccepted = "song_tap_first_beam_accepted"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var allowed: Bool { didSet { defaults.set(allowed, forKey: Keys.allow) } }
    private(set) var firstBeamAsks: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        allowed = defaults.bool(forKey: Keys.allow)
        firstBeamAsks = !defaults.bool(forKey: Keys.firstBeamAccepted)
    }

    /// The listener said yes to a first beam: from now on beams save at once.
    func markFirstBeamAccepted() {
        firstBeamAsks = false
        defaults.set(true, forKey: Keys.firstBeamAccepted)
    }
}
