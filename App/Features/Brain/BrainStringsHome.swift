import Foundation
import PixlLibrary

/// The words of the new Home, the made-for-you lists, the artist picker and the setup page (docs/brain-spec.md, 8.1, 8.2,
/// 8.10; Android `strings_brain.xml`, stage 2b milestone 2): the same sentences as Android. `BrainCopyTests` reads this file
/// as text: no string here may use a word the app never says, and none may claim more than "based on what you play".
nonisolated extension BrainStrings {
    // MARK: Home (8.1)

    static var homeMadeForYou: String { String(localized: "Made for you") }
    static var homeNewFromLoved: String { String(localized: "New from artists you love") }
    static var homeNewFromLovedSubtitle: String { String(localized: "Fresh releases from music in your library") }
    static var homeOnRepeatSubtitle: String { String(localized: "What you have played most in the last month") }
    static var homeRediscoverSubtitle: String { String(localized: "Songs you loved and have not played in a while") }
    static var homeStations: String { String(localized: "Stations for you") }
    static var homeStationsSubtitle: String { String(localized: "Start one from a genre or a mood in your library") }
    static var homeStepSideways: String { String(localized: "A step sideways") }
    static func homeStepSidewaysSubtitle(_ genre: String) -> String {
        String(localized: "\(genre) sits next to what you play, and you have not played any of it yet")
    }
    static func homeMoreLikeAlbum(_ album: String) -> String { String(localized: "More like \(album)") }
    static var homeMoreLikeAlbumSubtitle: String { String(localized: "Music close to an album you just finished") }

    // Stage 3 completion: the daypart mix shelf (8.1). `bucket` is `ContextLift.bucket`: 0..3 weekday morning to night, 4..7 weekend.
    // The buckets are weekday and weekend, so the titles say so and never name one weekday the data does not make a claim about.
    static func homeDaypart(_ bucket: Int) -> String {
        switch bucket {
        case 0: String(localized: "Your weekday mornings")
        case 1: String(localized: "Your weekday afternoons")
        case 2: String(localized: "Your weekday evenings")
        case 3: String(localized: "Your weeknights")
        case 4: String(localized: "Your weekend mornings")
        case 5: String(localized: "Your weekend afternoons")
        case 6: String(localized: "Your weekend evenings")
        default: String(localized: "Your weekend nights")
        }
    }
    static var homeDaypartSubtitle: String { String(localized: "Music from the side of your taste you play at this time of the week") }
    static var homeCouldNotPlay: String { String(localized: "Could not play that right now. Try again in a moment.") }
    static var whyAdjacentGenre: String { String(localized: "A genre next to what you play") }

    static var daypartMorning: String { String(localized: "morning") }
    static var daypartAfternoon: String { String(localized: "afternoon") }
    static var daypartEvening: String { String(localized: "evening") }
    static var daypartNight: String { String(localized: "night") }

    static var chipForYou: String { String(localized: "For you") }
    static var chipMixes: String { String(localized: "Mixes") }
    static var chipSpatial: String { String(localized: "Spatial") }
    static var chipNew: String { String(localized: "New") }
    static var jumpBackIn: String { String(localized: "Jump back in") }
    static func songsCount(_ count: Int) -> String { String(localized: "\(count) songs") }
    static func gettingToKnow(_ done: Int, _ total: Int) -> String {
        String(localized: "Getting to know your music · \(done) of \(total)")
    }
    static var artistPickerCard: String { String(localized: "Tell us three artists and Home has something to start from.") }

    // MARK: The lists (8.2)

    static var mixDaily: String { String(localized: "Daily Mix") }
    static func mixDailyNumber(_ number: Int) -> String { String(localized: "Daily Mix \(number)") }
    static var mixYour: String { String(localized: "Your Mix") }
    static var mixYourSubtitle: String { String(localized: "Everything you play, in one list") }
    static var mixFirstListen: String { String(localized: "First Listen") }
    static func mixFirstListenWeek(_ week: String) -> String { String(localized: "Week of \(week)") }
    static var mixJustDropped: String { String(localized: "Just Dropped") }
    static var mixJustDroppedSubtitle: String { String(localized: "New releases from artists you play") }
    static var mixOnRepeat: String { String(localized: "On Repeat") }
    static var mixRediscover: String { String(localized: "Rediscover") }
    static var mixNothingYet: String {
        String(localized: "There is nothing in this list yet. It fills in as the app finds music close to what you play.")
    }

    // MARK: Genre and mood stations (8.3)

    static var stationSubtitleGenre: String { String(localized: "Music like your songs in this genre, picked as you listen") }
    static func stationGenreNothing(_ name: String) -> String {
        String(localized: "No songs in your library under \(name) yet. Add one and a station can start from it.")
    }

    // MARK: The artist picker (8.10)

    static var pickArtistsTitle: String { String(localized: "Pick three artists you love") }
    static var pickArtistsSubtitle: String { String(localized: "Search for an artist, pick up to three, and your mixes start from them.") }
    static var pickArtistsSearch: String { String(localized: "Search for an artist") }
    static func pickArtistsStart(_ count: Int) -> String { String(localized: "Start with \(count)") }
    static var pickArtistsStarting: String { String(localized: "Starting") }
    static var pickArtistsFailed: String {
        String(localized: "Could not reach those artists right now. Check your connection and try again.")
    }

    // MARK: The setup page (8.10)

    static var setupTasteTitle: String { String(localized: "How much new music?") }
    static var setupTasteSubtitle: String {
        String(localized: "Pick how much of what you hear should be new to you. You can change it later from the queue.")
    }
    static var setupTasteFamiliarHint: String { String(localized: "Mostly songs you already know") }
    static var setupTasteBlendHint: String { String(localized: "A mix of your music and new music") }
    static var setupTasteDiscoverHint: String { String(localized: "As much new music as it can find") }
    static var setupTasteImportHistory: String { String(localized: "Import your listening history") }
    static var setupTasteImportQueued: String { String(localized: "It opens when you finish setup") }
    static var setupTasteFooter: String { String(localized: "There are no questions to answer. Picks follow what you play from here.") }

    static func daypart(_ code: Int32) -> String {
        switch code {
        case HomePlanner.daypartMorning: daypartMorning
        case HomePlanner.daypartAfternoon: daypartAfternoon
        case HomePlanner.daypartEvening: daypartEvening
        default: daypartNight
        }
    }

    static func tasteHint(_ level: Int) -> String {
        switch level {
        case Novelty.familiar: setupTasteFamiliarHint
        case Novelty.discover: setupTasteDiscoverHint
        default: setupTasteBlendHint
        }
    }
}
