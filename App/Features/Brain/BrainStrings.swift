import Foundation
import PixlLibrary

/// Every word the music brain puts on screen in stage 1 (docs/brain-spec.md, section 8; Android
/// `strings_brain.xml`): the same sentences as Android, in one file, so they are checked in one place.
/// `BrainCopyTests` (PixlCore) reads this file as text: no string here may use a word the app never says, and none
/// may claim more than "based on what you play" before stage 3 (decision D15). English only for now, as keys.
nonisolated enum BrainStrings {
    // MARK: Stations (8.3)

    static var startStation: String { String(localized: "Start station") }
    static var startStationSongSupporting: String { String(localized: "Keeps playing music like this song") }
    static var startStationArtistSupporting: String { String(localized: "Keeps playing music like this artist") }
    static func stationTitle(_ title: String) -> String { String(localized: "Station · \(title)") }
    static var stationSubtitleSong: String { String(localized: "Music like this song, picked as you listen") }
    static var stationSubtitleArtist: String { String(localized: "This artist and music close to them") }
    static func stationNothingToStart(_ artist: String) -> String {
        String(localized: "Nothing to start from yet. Add a song by \(artist) first.")
    }

    // MARK: Familiar / Blend / Discover (8.3)

    static var noveltyFamiliar: String { String(localized: "Familiar") }
    static var noveltyBlend: String { String(localized: "Blend") }
    static var noveltyDiscover: String { String(localized: "Discover") }
    static var noveltyDescription: String { String(localized: "How much new music the picks hold") }

    static func novelty(_ level: Int) -> String {
        switch level {
        case Novelty.familiar: noveltyFamiliar
        case Novelty.discover: noveltyDiscover
        default: noveltyBlend
        }
    }

    // MARK: Why this song (8.8)

    /// The sentence of a reason line. The key and its one argument come from the pure core (decision D16).
    static func whyLine(_ line: WhyLineText.Line) -> String {
        switch line {
        case .radioFans(let name): String(localized: "Fans of \(name) also play this")
        case .becauseLiked(let name): String(localized: "Because you liked \(name)")
        case .becauseListened(let name): String(localized: "Because you listened to \(name)")
        case .artistMore(let name): String(localized: "More from \(name)")
        case .onRepeat: String(localized: "On repeat lately")
        }
    }

    static var whySheetTitle: String { String(localized: "Why this song") }
    static var whySheetBasis: String { String(localized: "Picks are based on what you play.") }
    static var whyDescription: String { String(localized: "Why this song was picked") }

    // MARK: Feedback (8.5)

    static var notForMe: String { String(localized: "Not for me") }
    static var notForMeSupporting: String { String(localized: "Skips it and keeps it out of your mixes") }
    static var notForMeDone: String { String(localized: "Got it. You won't hear this in mixes again.") }
    static var notForMeFailed: String { String(localized: "Couldn't save that. Remove a few taste changes first.") }
    static func lessFrom(_ artist: String) -> String { String(localized: "Less from \(artist)") }
    static func lessFromDone(_ artist: String) -> String { String(localized: "You'll hear less from \(artist).") }
    static var undo: String { String(localized: "Undo") }
    static var undone: String { String(localized: "Undone") }
    static var like: String { String(localized: "Like") }
    static var liked: String { String(localized: "Liked") }

    /// What the bar after a piece of feedback says.
    static func notice(_ notice: BrainNotice) -> String {
        switch notice.kind {
        case .notForMe: notForMeDone
        case .notSaved: notForMeFailed
        case .lessFrom: lessFromDone(notice.artistName)
        case .undone: undone
        }
    }

    // MARK: Home (8.1)

    static func homeBecauseListened(_ name: String) -> String { String(localized: "Because you listened to \(name)") }
    static var homeBecauseListenedSubtitle: String { String(localized: "Music you don't have yet") }

    // MARK: Daily Mix and Your Mix (8.2)

    static var mixSave: String { String(localized: "Save") }
    static var mixSaved: String { String(localized: "Saved") }

    // MARK: Developer mode: the engine that ranks the mixes, and the background search

    static var engineTitle: String { String(localized: "Music engine") }
    static var engineSubtitle: String {
        String(localized: "Rank Daily Mix and Your Mix with the new engine. Off uses the old one. Regenerate the daily mix to see the change.")
    }
    static var refreshTitle: String { String(localized: "Background music search") }
    static var refreshSubtitle: String {
        String(localized: "Looks up music like your favourites once a day on Wi-Fi, so your mixes have new songs in them")
    }

    // MARK: How picks work (8.9)

    static var howPicksWork: String { String(localized: "How picks work") }
    static var howIntro: String {
        String(localized: "Picks are based on what you play: what you finish, what you skip and what you save.")
    }
    static var promisePaidTitle: String { String(localized: "Nobody can pay to be in your picks") }
    static var promiseRepeatTitle: String { String(localized: "Less repetition") }
    static var promiseRepeatBody: String {
        String(localized: "A song is never in two mixes on the same day, and a new song you skipped three times stays away for 60 days.")
    }
    static var promiseWhyTitle: String { String(localized: "You can see why, and change it") }
    static var promiseWhyBody: String {
        String(localized: "A pick shows why it is there when there is a reason to give. Changes apply from the next track and can be undone.")
    }
    static var promisePlaylistsTitle: String { String(localized: "Nothing is slipped into your playlists") }
    static var promisePlaylistsBody: String {
        String(localized: "Picks are never added to your playlists or your library. Autoplay has an off switch, and a station plays until you start something else.")
    }
    static var promisePhoneTitle: String { String(localized: "It stays on your phone") }
    static var promisePhoneBody: String {
        String(localized: "Looking up songs and facts contacts public music catalogues without an account; they see an IP address and the artist or song looked up. The assistant's cloud mode sends the conversation.")
    }
    static var howAutoplayTitle: String { String(localized: "Autoplay") }
    static var howAutoplayBody: String { String(localized: "Keeps playing when your queue ends") }
    static var howTasteChanges: String { String(localized: "Taste changes") }
    static var howTasteChangesBody: String { String(localized: "Everything you told the picks, with undo") }
}
