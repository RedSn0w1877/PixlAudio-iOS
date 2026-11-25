import Foundation
import PixlLibrary

/// The words under Ask Taizo's answers (docs/brain-spec.md, 9.3 "What the listener gets", stage 4 milestone 2; Android `strings_brain.xml`): the
/// mix card, the one-tap "Less X", the factors of a pick, the weekly note and the switch for the optional jobs. The same sentences as Android.
/// `BrainCopyTests` reads this file as text: no string here may use a word the app never says, and none says "learn".
nonisolated extension BrainStrings {
    // MARK: The mix card

    static func taizoMixSongs(_ count: Int) -> String { count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs") }
    static var taizoMixPlay: String { String(localized: "Play") }
    /// The mix card's eyebrow (redesign 2, Android `brain_taizo_mix_new_label`).
    static var taizoMixNewLabel: String { String(localized: "New playlist") }
    static var taizoMixSave: String { String(localized: "Save") }
    static var taizoMixSaved: String { String(localized: "Saved") }
    static var taizoMixUpdating: String { String(localized: "Updating") }
    static var taizoMixFailed: String { String(localized: "That did not work. Try again.") }
    static var taizoMixSeedNotUsed: String {
        String(localized: "I could not load songs like what you started from just now, so this mix may not follow it.")
    }
    static var taizoMixNotApplied: String {
        String(localized: "Some of what you asked for could not be applied, because PixlAudio has no data on it yet.")
    }

    // MARK: "Less X"

    static func taizoLessDone(_ name: String) -> String { String(localized: "Done. You will get less \(name).") }
    static var taizoLessUndo: String { String(localized: "Undo") }
    static var taizoLessFailed: String { String(localized: "Could not change that.") }

    // MARK: Why this song: what moved the pick

    static func whyFactorsUp(_ names: String) -> String { String(localized: "What helped: \(names)") }
    static func whyFactorsDown(_ names: String) -> String { String(localized: "What held it back: \(names)") }

    // MARK: The weekly note and the optional jobs

    static var weeklyNoteTitle: String { String(localized: "This week") }
    static var assistTitle: String { String(localized: "Let Taizo help the engine") }
    static var assistBody: String {
        String(localized: "Taizo can name your taste islands, suggest artists you may not know once a week, and add genres to songs that no source knows, a batch at a time. It sends genre names, artist names and song titles to the cloud assistant, never play counts or dates, and it counts against your monthly allowance. Off unless you turn it on.")
    }

    // MARK: A station from a sentence

    static func taizoStationStarted(_ name: String) -> String { String(localized: "Started a station from \(name).") }
    static func taizoStationNotFound(_ name: String) -> String {
        String(localized: "I could not find \(name) in your library, your genres or your playlists, so I did not start a station.")
    }
}
