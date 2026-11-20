import Foundation
import PixlLibrary

/// Every word of Your sound and the genre page (docs/brain-spec.md, 8.6, 8.7; Android `strings_brain.xml`, `brain_sound_*` and
/// `brain_genre_*`): the same sentences as Android. `BrainCopyTests` (PixlCore) reads this file as text. Stage 3 lets the word
/// "learn" appear in exactly four literals (`modelLearning` once for one play and once for the rest, `reset`, `resetTitle`), and the screen shows `modelLearning` only
/// while the learned weights are really in use (`ModelVoice.learning`); every other forbidden word still fails the test.
nonisolated enum YourSoundStrings {
    static var title: String { String(localized: "Your sound") }
    static var rowSubtitle: String { String(localized: "What you play, worked out on your phone") }
    static var empty: String { String(localized: "Play some music and this page fills in.") }

    static var now: String { String(localized: "Right now") }
    static var nowHint: String { String(localized: "The last 28 days") }
    static var islandUnnamed: String { String(localized: "Another side of your taste") }
    static func share(_ percent: Int) -> String { String(localized: "\(percent)%") }
    /// A share given in permille, rounded to the nearest percent; a share that is real but under half a percent reads "<1%", never "0%".
    static func sharePermille(_ permille: Int) -> String {
        let percent = (permille + 5) / 10
        return permille > 0 && percent == 0 ? String(localized: "<1%") : share(percent)
    }
    /// The same rounding for a sentence that takes a whole percent.
    static func percentOf(permille: Int) -> Int { (permille + 5) / 10 }

    static var genres: String { String(localized: "Genres") }
    static var eras: String { String(localized: "Eras") }
    static func decade(_ decade: Int) -> String { String(localized: "\(decade)s") }

    static var day: String { String(localized: "Through the day") }
    static var morning: String { String(localized: "Mornings") }
    static var afternoon: String { String(localized: "Afternoons") }
    static var evening: String { String(localized: "Evenings") }
    static var night: String { String(localized: "Nights") }
    static func daypartLine(_ daypart: String, _ island: String) -> String { String(localized: "\(daypart): most often \(island)") }

    static var months: String { String(localized: "Over months") }
    static func monthLine(_ month: String, _ plays: Int) -> String {
        plays == 1 ? String(localized: "\(month) · \(plays) play") : String(localized: "\(month) · \(plays) plays")
    }

    static var newAndFamiliar: String { String(localized: "New and familiar") }
    static func novelty(_ percent: Int) -> String { String(localized: "Last week \(percent)% of what you played was new to you.") }

    static var model: String { String(localized: "How well I know you") }
    static var modelGetting: String { String(localized: "Still getting to know you") }
    static func modelGettingCount(_ count: Int, _ needed: Int) -> String { String(localized: "\(count) of \(needed) plays so far") }
    static var modelStandard: String { String(localized: "Your picks use the standard recipe for now.") }
    static func modelStandardAccuracy(_ percent: Int) -> String {
        String(localized: "On plays I could check, the standard recipe gets \(percent)% of your finishes and skips right.")
    }
    /// The one line that says the model is learning: shown only while the learned weights are in use.
    static func modelLearning(_ count: Int) -> String {
        count == 1 ? String(localized: "Learning from \(count) play.") : String(localized: "Learning from \(count) plays.")
    }
    static func modelAccuracy(_ percent: Int) -> String { String(localized: "On plays I could check, I get \(percent)% of your finishes and skips right.") }
    static func modelAccuracyBefore(_ percent: Int) -> String { String(localized: "A month ago it was \(percent)%.") }
    static func modelAccuracyPrior(_ percent: Int) -> String { String(localized: "The standard recipe gets \(percent)% of the same plays.") }
    static func control(_ standard: Int, _ inUse: Int) -> String {
        String(localized: "One session in ten uses the standard recipe as a check. Over the same weeks, \(standard)% of its picks were finished, against \(inUse)% of the picks made with the weights in use.")
    }
    static func controlWaiting(_ plays: Int) -> String {
        String(localized: "One session in ten uses the standard recipe as a check. The two rates show once each side has \(plays) plays over the same weeks.")
    }

    static var controls: String { String(localized: "Controls") }
    static var reset: String { String(localized: "Reset what I've learned") }
    static var resetSubtitle: String {
        String(localized: "Your plays, blocked artists and taste changes stay. The weights go back to the standard recipe, and what you played still counts.")
    }
    static var resetTitle: String { String(localized: "Reset what I've learned?") }
    static var resetBody: String {
        String(localized: "The weights go back to the standard recipe and start again from now. What you played still counts, and nothing is deleted.")
    }
    static var resetConfirm: String { String(localized: "Reset") }
    static var resetDone: String { String(localized: "Back to the standard recipe.") }
    static var tasteChanges: String { String(localized: "Ask Taizo's taste changes") }
    static var footer: String { String(localized: "All of this is worked out on your phone.") }

    // MARK: Genre page (8.7)

    static var genreComesFrom: String { String(localized: "Comes from") }
    static var genreBranches: String { String(localized: "Branches") }
    static var genreCloseTo: String { String(localized: "Close to") }
    static var genreShapedBy: String { String(localized: "Shaped by") }
    static var genrePlayStation: String { String(localized: "Play station") }

    // MARK: Stage 3 completion: Lately, the genre tree, the island sheet, the genre page's own sections (8.6, 8.7)

    static var lately: String { String(localized: "Lately") }
    static func latelyUp(_ names: String) -> String { String(localized: "Up: \(names)") }
    static func latelyDown(_ names: String) -> String { String(localized: "Down: \(names)") }
    static var islandArtists: String { String(localized: "Top artists") }
    static var islandSongs: String { String(localized: "Top songs") }
    static var islandPlayStation: String { String(localized: "Play station") }
    static var islandMore: String { String(localized: "More of this") }
    static var islandLess: String { String(localized: "Less of this") }
    static var islandClose: String { String(localized: "Close") }
    static var familyOpen: String { String(localized: "Show the genres inside") }
    static var genreKeyArtists: String { String(localized: "Key artists") }
    static var genreFromLibrary: String { String(localized: "From your library") }
    static var genreYou: String { String(localized: "You and this genre") }
    static func genreYouFirst(_ date: String) -> String { String(localized: "First played \(date)") }
    static func genreYouShare(_ share: String, _ plays: Int) -> String {
        plays == 1 ? String(localized: "\(share) of your listening, \(plays) play") : String(localized: "\(share) of your listening, \(plays) plays")
    }
    static var genreUnavailable: String { String(localized: "Nothing to show for this genre.") }
    static var genreYouTop: String { String(localized: "Played most") }
    static var genreMore: String { String(localized: "More of this") }
    static var genreLess: String { String(localized: "Less of this") }
    static func genreMoreDone(_ name: String) -> String { String(localized: "Got it. You will hear more \(name).") }
    static func genreLessDone(_ name: String) -> String { String(localized: "Got it. You will hear less \(name).") }
    static var genreAdjustFailed: String { String(localized: "That change could not be saved.") }

    static func daypartName(_ daypart: Int) -> String {
        switch Int32(daypart) {
        case HomePlanner.daypartMorning: morning
        case HomePlanner.daypartAfternoon: afternoon
        case HomePlanner.daypartEvening: evening
        default: night
        }
    }
}
