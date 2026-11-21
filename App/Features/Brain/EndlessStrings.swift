import Foundation
import PixlLibrary

/// The words of Endless Listening, its card on Home, the host, the introduction and the settings rows (Android `strings_endless.xml`): the
/// same sentences, plain sentence case. `BrainCopyTests` reads this file as text: no string here may use a word the app never says, and
/// none may use the name of another service's feature.
nonisolated enum EndlessStrings {
    static var title: String { String(localized: "Endless Listening") }
    static var nothingYet: String { String(localized: "Play a few songs first. Endless Listening starts from what you play.") }

    // MARK: The card on Home

    static func cardFrom(_ names: String) -> String { String(localized: "Starts from \(names) and keeps going.") }
    static var cardPlain: String { String(localized: "Starts from what you play and keeps going.") }
    static var cardTag: String { String(localized: "Keeps going") }
    static var cardMenu: String { String(localized: "More about Endless Listening") }
    static var howItWorks: String { String(localized: "How it works") }

    // MARK: The queue header while it is the queue's station

    static var stationSubtitle: String { String(localized: "Keeps going from what you play, until you stop it") }

    // MARK: Ask the host

    static var askHost: String { String(localized: "Ask the host") }
    static var hostSheetHint: String { String(localized: "Say what you want next, or ask about a song.") }
    static var chipNew: String { String(localized: "Something new") }
    static var chipFamiliar: String { String(localized: "Back to familiar") }
    static var chipWhy: String { String(localized: "Why this song") }
    static var chipUpbeat: String { String(localized: "More upbeat") }
    static var chipSlower: String { String(localized: "Slower") }
    static var chipSurprise: String { String(localized: "Surprise me") }
    /// The words of a chip, as the listener's own line in the chat.
    static func label(of chip: HostChip) -> String {
        switch chip {
        case .new: chipNew
        case .familiar: chipFamiliar
        case .why: chipWhy
        case .upbeat: chipUpbeat
        case .slower: chipSlower
        case .surprise: chipSurprise
        }
    }
    static var replyNew: String { String(localized: "Okay. The next songs lean towards new music.") }
    static var replyFamiliar: String { String(localized: "Okay. The next songs lean towards what you know.") }
    static var replySurprise: String { String(localized: "Okay. Five songs that lean new are next.") }
    static var replyUpbeat: String { String(localized: "Okay. Five livelier songs are next.") }
    static var replySlower: String { String(localized: "Okay. Five slower songs are next.") }
    static var replyWhy: String { String(localized: "Here is why it is on.") }
    static var replyNoWhy: String { String(localized: "You picked this one yourself, so there is no reason to give.") }
    static var replyNothing: String { String(localized: "I could not change the queue just now.") }
    static var replyNoSong: String { String(localized: "Nothing is playing yet.") }

    // MARK: The introduction: three pages

    static var introTitle1: String { String(localized: "Music that keeps going.") }
    static var introBody1: String {
        String(localized: "Endless Listening starts from what you play and keeps adding more until you stop it.")
    }
    static var introTitle2: String { String(localized: "A host, if you want one.") }
    static var introBody2: String {
        String(localized: "Short notes between songs say why something is here. Ask for something new, or why a song was picked.")
    }
    static var introTitle3: String { String(localized: "You decide.") }
    static var introBody3: String {
        String(localized: "Choose how much is new, skip anything, and turn the notes off any time.")
    }
    static var introStart: String { String(localized: "Start listening") }
    static var introNotNow: String { String(localized: "Not now") }
    static func introPage(_ page: Int, of count: Int) -> String { String(localized: "Page \(page) of \(count)") }
    static var introBars: String { String(localized: "Five bars moving with the music") }

    // MARK: Settings

    static var settingsTitle: String { String(localized: "Endless Listening") }
    static var settingsSubtitle: String { String(localized: "Host notes, spoken notes and how it works") }
    static var settingsHostNotes: String { String(localized: "Host notes") }
    static var settingsHostNotesSummary: String { String(localized: "Short notes about the songs coming up in Endless Listening") }
    static var settingsHow: String { String(localized: "How it works") }
    static var settingsHowSummary: String { String(localized: "Replay the introduction") }
    static var settingsSpoken: String { String(localized: "Spoken host notes") }
    static var settingsSpokenSummary: String {
        String(localized: "The host says a note out loud now and then, with the music turned down. Uses the voice on this phone.")
    }
    static var settingsVoiceTest: String { String(localized: "Test the voice") }
    static var settingsVoiceTestSummary: String { String(localized: "Hear how the host sounds") }
    static var settingsVoiceTestRunning: String { String(localized: "Starting the voice") }
    static var voiceTestLine: String { String(localized: "This is how the host sounds.") }
    static var voiceTestNone: String { String(localized: "This phone has no English voice that works without the internet.") }
    static var voiceTestBusy: String { String(localized: "The host is talking right now.") }
    static var voiceTestCall: String { String(localized: "Not during a call.") }
    static var voiceTestError: String { String(localized: "The voice did not start. Try again.") }
    static var settingsVoiceLog: String { String(localized: "Host voice log") }
    static var settingsVoiceLogSummary: String { String(localized: "The last 20 notes: said or skipped, and why") }
    static var voiceLogEmpty: String { String(localized: "Nothing yet.") }
    static var voiceLogClose: String { String(localized: "Close") }

    /// The three pages of the introduction, in order.
    static var introPages: [(title: String, body: String)] {
        [(introTitle1, introBody1), (introTitle2, introBody2), (introTitle3, introBody3)]
    }
}
