import Foundation
import PixlLibrary

/// Every word Song Tap puts on screen (Android `strings_songtap.xml`): the same sentences, in one file, so they are checked
/// in one place. `SongTapCopyTests` (PixlCore) reads this folder as text: no string may use a word the app never says, and
/// none may say "Apple". English only for now, as keys.
nonisolated enum SongTapStrings {
    static var title: String { String(localized: "Song Tap") }

    // MARK: Player menu row

    static var menuSupporting: String { String(localized: "Send this song to a phone nearby") }
    static var menuOn: String { String(localized: "On") }
    static var menuOff: String { String(localized: "Off") }

    // MARK: Settings

    static var settingsTitle: String { String(localized: "Song Tap") }
    static var settingsSubtitle: String { String(localized: "Share songs with a phone nearby") }
    static var allowTitle: String { String(localized: "Allow Song Tap") }
    static var allowSubtitle: String {
        String(localized: "Send the song that is playing to another phone with PixlAudio, and take songs from theirs. Nothing is sent without you opening Song Tap.")
    }
    static var settingsOpen: String { String(localized: "Open Song Tap") }
    static var settingsOpenSubtitle: String { String(localized: "Show a code, or scan one") }

    // MARK: Turn on

    static var offHeadline: String { String(localized: "Share songs with a phone nearby") }
    static var offBody: String {
        String(localized: "Song Tap sends the song that is playing to another phone with PixlAudio, and adds it to their library. Only the song's name goes across: each phone plays it for itself. It works only while this screen is open.")
    }
    static var turnOn: String { String(localized: "Turn on Song Tap") }

    // MARK: Modes

    static var modeSend: String { String(localized: "Send") }
    static var modeReceive: String { String(localized: "Receive") }

    // MARK: Send

    static var sendNowPlaying: String { String(localized: "Now playing") }
    static var sendNothing: String { String(localized: "Play a song to send it.") }
    static var sendCant: String { String(localized: "This song can't be shared yet.") }
    static var showCode: String { String(localized: "Show code") }
    static var hideCode: String { String(localized: "Done") }
    static var codeHint: String { String(localized: "Hold this up for the other phone to scan.") }
    static var codeDescription: String { String(localized: "Code for the song that is playing") }

    // MARK: Receive

    static var scanHint: String { String(localized: "Point the camera at the other phone's code.") }
    static var cameraNeeded: String { String(localized: "Song Tap needs the camera to read a code.") }
    static var allowCamera: String { String(localized: "Allow camera") }
    static var cameraBlocked: String { String(localized: "The camera is off for PixlAudio. Turn it on in Settings to scan a code.") }
    static var openSettings: String { String(localized: "Open Settings") }

    // MARK: The card

    static var cardAsk: String { String(localized: "Add to your library?") }
    static var cardAdd: String { String(localized: "Add") }
    static var cardNotNow: String { String(localized: "Not now") }
    static var cardAdding: String { String(localized: "Adding") }
    static var cardSaved: String { String(localized: "Added to your library") }
    static var cardAlready: String { String(localized: "Already in your library") }
    static var cardUndo: String { String(localized: "Undo") }
    static var cardOk: String { String(localized: "OK") }
    static var declined: String { String(localized: "Not added") }
    static var cancelled: String { String(localized: "Cancelled") }

    // MARK: Things that did not work

    static func notice(_ notice: SongTapNotice) -> String {
        switch notice {
        case .invalidCode: String(localized: "That isn't a PixlAudio song code.")
        case .notFound: String(localized: "Couldn't find this one here")
        case .saveFailed: String(localized: "Something went wrong. Try again.")
        case .timeout: String(localized: "That took too long. Try again.")
        case .tooSoon: String(localized: "Slow down a little.")
        case .limit: String(localized: "That's a lot of songs. Try again in a bit.")
        case .duplicate: String(localized: "You just got that one.")
        case .muted: String(localized: "Songs from that phone are paused for now.")
        case .bothSending: String(localized: "Both phones are sending. Switch one to Receive.")
        case .peerLost: String(localized: "The other phone moved away.")
        case .invalidOffer: String(localized: "That song couldn't be read.")
        case .nothingToSend: String(localized: "Play a song to send it.")
        }
    }
}
