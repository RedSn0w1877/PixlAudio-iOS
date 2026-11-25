import Foundation
import PixlLibrary

/// The words of redesign batch 3 (Android `values/strings_home_redesign.xml`): Home's wordplay, the mix pages, Endless Listening's
/// intro, station and host. Same sentences as Android. Greeting lines come in pairs (`a` = the wide first line, `b` = the narrow second
/// line) and keep the same length; `HomeWordplay` (PixlLibrary) picks the index. Nothing here may claim a number that is not the
/// listener's own.
nonisolated enum HomeRedesignStrings {
    // MARK: Greeting

    static var morningA: [String] { [String(localized: "Rise and grind…"), String(localized: "Good mornin',"), String(localized: "Wake up,")] }
    static var morningB: [String] { [String(localized: "the bass."), String(localized: "sunshine on repeat."), String(localized: "turn it up.")] }
    static var afternoonA: [String] { [String(localized: "Lunch break?"), String(localized: "Midday,"), String(localized: "Afternoon")] }
    static var afternoonB: [String] { [String(localized: "Beat break."), String(localized: "mid-tempo."), String(localized: "delight.")] }
    static var eveningA: [String] { [String(localized: "Golden hour,"), String(localized: "Dinner's on."), String(localized: "Evening,")] }
    static var eveningB: [String] { [String(localized: "golden oldies?"), String(localized: "So's the music."), String(localized: "even better.")] }
    static var lateA: [String] { [String(localized: "Owl be"), String(localized: "Up late?"), String(localized: "Midnight")] }
    static var lateB: [String] { [String(localized: "listening."), String(localized: "Same."), String(localized: "snacks: songs.")] }
    static var streakA: [String] { [String(localized: "Make it"), String(localized: "Once more,"), String(localized: "Hit repeat.")] }
    static var streakB: [String] { [String(localized: "a double."), String(localized: "with feeling."), String(localized: "Then again.")] }

    static func lines(_ set: HomeWordplay.GreetingSet) -> (a: [String], b: [String]) {
        switch set {
        case .morning: (morningA, morningB)
        case .afternoon: (afternoonA, afternoonB)
        case .evening: (eveningA, eveningB)
        case .lateNight: (lateA, lateB)
        case .streak: (streakA, streakB)
        }
    }

    /// The chip above the greeting: the time, and the song on repeat when there is one.
    static func chipRepeat(_ time: String, _ song: String) -> String { String(localized: "\(time) · \(song) on repeat") }

    /// Under the greeting: this week's real play count, three ways (`home_wp_plays_0/1/2`).
    static func plays(_ variant: Int, _ count: Int) -> String {
        switch variant {
        case 0: count == 1 ? String(localized: "\(count) play this week. Just warming up.")
            : String(localized: "\(count) plays this week. No judgement. Mostly.")
        case 1: count == 1 ? String(localized: "\(count) play this week. Every legend starts somewhere.")
            : String(localized: "\(count) plays this week. Who's counting? Us.")
        default: count == 1 ? String(localized: "\(count) play this week. Off to a start.")
            : String(localized: "\(count) plays this week and counting.")
        }
    }

    // MARK: Section titles (wide part + narrow accent part; the accent keeps its leading space)

    static var mixesA: [String] { [String(localized: "Mix"), String(localized: "Mixed"), String(localized: "Remix,")] }
    static var mixesB: [String] { [String(localized: " & match"), String(localized: " feelings"), String(localized: " repeat")] }
    static var recentA: [String] { [String(localized: "Rewind,"), String(localized: "Run it"), String(localized: "Back")] }
    static var recentB: [String] { [String(localized: " replay"), String(localized: " back"), String(localized: " for more")] }
    static var freshA: [String] { [String(localized: "Fresh"), String(localized: "New"), String(localized: "Fresh")] }
    static var freshB: [String] { [String(localized: " finds"), String(localized: " to you"), String(localized: " off the press")] }
    static var freshSubtitle: String { String(localized: "New to you, not to the world.") }

    static var seeAll: String { String(localized: "See all") }
    static var showLess: String { String(localized: "Show less") }
    static var yourMixTag: String { String(localized: "FRESH-PRESSED DAILY") }
    static var yourMixName: String { String(localized: "Your mix") }
    static var yourMixLine: String { String(localized: "Mixed to taste. Shaken, not skipped.") }
    static var yourMixPlay: String { String(localized: "Play your mix") }
    static var endlessLine: String { String(localized: "The never-ending story. Tap in, never tap out.") }
    static var endlessHow: String { String(localized: "Long press for how it works") }
    static var taizoCardTitle: String { String(localized: "Can't find the vibe? Ask Taizo") }
    static func taizoCardExample(_ song: String) -> String { String(localized: "“Something like \(song), but slower”") }
    static var taizoCardExamplePlain: String { String(localized: "“Something for a late drive”") }
    static var whatsNew: String { String(localized: "What's new") }
    static var betaInfo: String { String(localized: "About the beta") }
    static var spatialEntry: String { String(localized: "Spatial") }
    static var shuffleAllLink: String { String(localized: "Shuffle all") }
    static var statsLink: String { String(localized: "Your stats") }
    static var askTaizo: String { String(localized: "Ask Taizo") }
    static var settings: String { String(localized: "Settings") }
    static var activeJobs: String { String(localized: "Active jobs") }

    // MARK: Mix page

    static var mixTagDaily: String { String(localized: "DAILY MIX") }
    static var mixTagYour: String { String(localized: "YOUR MIX") }
    static var mixTagMadeForYou: String { String(localized: "MADE FOR YOU") }
    static var mixMadeForYou: String { String(localized: "Made for you") }
    static func mixSongCount(_ n: Int) -> String { n == 1 ? String(localized: "\(n) song") : String(localized: "\(n) songs") }
    static func mixDurationHours(_ h: Int, _ m: Int) -> String { String(localized: "\(h) h \(m) min") }
    static func mixDurationMinutes(_ m: Int) -> String { String(localized: "\(m) min") }
    static var mixWhyThese: String { String(localized: "Why these?") }
    static func mixWhyNew(_ n: Int) -> String {
        n == 1 ? String(localized: "Picked from what you play, plus \(n) song you haven't heard yet.")
            : String(localized: "Picked from what you play, plus \(n) songs you haven't heard yet.")
    }
    static var mixWhyFamiliar: String { String(localized: "Picked from what you play, all songs you know.") }
    static var mixRemix: String { String(localized: "Remix this mix") }
    static var mixSave: String { String(localized: "Save mix to a playlist") }
    static var mixMore: String { String(localized: "More options") }
    static func mixPlay(_ title: String) -> String { String(localized: "Play \(title)") }
    static var shuffle: String { String(localized: "Shuffle") }
    static var back: String { String(localized: "Back") }

    // MARK: Endless Listening intro

    static var endlessEyebrow: String { String(localized: "ENDLESS LISTENING") }
    static var introSkip: String { String(localized: "Skip") }
    static var introNext: String { String(localized: "Next") }
    static var introClose: String { String(localized: "Close") }
    static var intro1a: String { String(localized: "Press play.") }
    static var intro1b: String { String(localized: "Done. Forever.") }
    static var intro1Body: String {
        String(localized: "A station that keeps going, picked one song at a time from what you actually like. No queue to babysit.")
    }
    static var intro2a: String { String(localized: "Meet your") }
    static var intro2b: String { String(localized: "hype host.") }
    static var intro2Body: String {
        String(localized: "Between songs your host drops a quick note: why this one, what's coming, a bit of backstory. Swipe it away, or turn notes off.")
    }
    static var intro3a: String { String(localized: "Steer it") }
    static var intro3b: String { String(localized: "out loud.") }
    static var intro3Body: String {
        String(localized: "Ask the host for “more upbeat” or “something new” and the station bends to fit. Every like and skip counts too.")
    }
    /// The three pages: wide line, narrow line, body.
    static var introPages: [(a: String, b: String, body: String)] {
        [(intro1a, intro1b, intro1Body), (intro2a, intro2b, intro2Body), (intro3a, intro3b, intro3Body)]
    }
    // Illustration words (examples, not data).
    static var artUpNext: String { String(localized: "UP NEXT") }
    static var artNote1: String { String(localized: "Easing off the gas. You skipped two bangers in a row.") }
    static var artNote2: String { String(localized: "Same bass energy as the last one, just after midnight.") }
    static var artAsk: String { String(localized: "more upbeat, no sad songs pls") }
    static var artReply: String { String(localized: "Say less. Turning it up.") }
    static var artChip1: String { String(localized: "Energy up") }
    static var artChip2: String { String(localized: "Sad songs out") }
    static var artChip3: String { String(localized: "Same vibe") }

    // MARK: Endless Listening station

    static var stationMinimise: String { String(localized: "Minimise") }
    static var stationOptions: String { String(localized: "Station options") }
    static var onAir: String { String(localized: "ON AIR") }
    static func trackOf(_ n: Int) -> String { String(localized: "Track \(n) of ∞") }
    static func like(_ title: String) -> String { String(localized: "Like \(title)") }
    static func unlike(_ title: String) -> String { String(localized: "Unlike \(title)") }
    static var lessLikeThis: String { String(localized: "Less like this") }
    static var previous: String { String(localized: "Previous") }
    static var next: String { String(localized: "Next") }
    static var play: String { String(localized: "Play") }
    static var pause: String { String(localized: "Pause") }
    static var upNext: String { String(localized: "Up next") }
    static var hostNotesA: String { String(localized: "Host") }
    static var hostNotesB: String { String(localized: " notes") }
    static var noteEyebrow: String { String(localized: "FROM YOUR HOST") }
    static var noteDismiss: String { String(localized: "Swipe to dismiss the note") }
    static var noNote: String { String(localized: "No note for this one. Ask the host anything.") }
    static var openPlayer: String { String(localized: "Open the player") }
    static var notesOn: String { String(localized: "Turn host notes off") }
    static var notesOff: String { String(localized: "Turn host notes on") }
    static var upNextEmpty: String { String(localized: "Picking the next songs…") }
    static func notesCount(_ n: Int) -> String { n == 1 ? String(localized: "\(n) note") : String(localized: "\(n) notes") }
    static func seek(_ position: String, _ duration: String) -> String { String(localized: "\(position) of \(duration)") }
    static var voice: String { String(localized: "Speak to the host") }

    // MARK: Ask the host

    static var hostTitleA: String { String(localized: "Your") }
    static var hostTitleB: String { String(localized: " host") }
    static var hostName: String { String(localized: "Host") }
    static var hostInputHint: String { String(localized: "Ask the host anything") }
    static var backToStation: String { String(localized: "Back to station") }
}
