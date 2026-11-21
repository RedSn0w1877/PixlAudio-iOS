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

    // MARK: Status while two phones find each other

    static var statusLooking: String { String(localized: "Looking for the other phone") }
    static var statusFound: String { String(localized: "Phone nearby. Hold the backs together.") }
    static var statusNear: String { String(localized: "Almost there. Touch the phones together.") }
    static var statusSent: String { String(localized: "Sent") }
    static var sendHint: String { String(localized: "Pick a phone below, then touch the phones together.") }
    static var receiveHint: String { String(localized: "Touch the back of your phone to the one playing the song.") }
    static var useCode: String { String(localized: "Use a code instead") }
    static var scanCode: String { String(localized: "Scan a code instead") }
    static var backToTap: String { String(localized: "Back to touching phones") }

    // MARK: Bluetooth

    static var btPermission: String { String(localized: "Song Tap needs Bluetooth to find the other phone.") }
    static var btOff: String { String(localized: "Bluetooth is off. Turn it on to find the other phone.") }
    static var btUnsupported: String { String(localized: "This phone can't use Bluetooth for Song Tap. A code still works.") }
    static var beamArtwork: String { String(localized: "Artwork of the song being sent") }

    // MARK: Developer mode: Song Tap diagnostics

    static var diagTitle: String { String(localized: "Song Tap diagnostics") }
    static var diagSettingsSubtitle: String { String(localized: "Live signal, baseline and jerk, to tune the tap on real phones") }
    static var diagNeedOn: String { String(localized: "Turn on Song Tap to see live numbers.") }
    static var diagSignal: String { String(localized: "Signal") }
    static var diagMotion: String { String(localized: "Motion") }
    static var diagDetector: String { String(localized: "Detector") }
    static var diagMarks: String { String(localized: "Mark the signal") }
    static var diagMarksHint: String { String(localized: "Hold the phones at a distance, then press the matching button. The numbers go into the log.") }
    static var diagEvents: String { String(localized: "Last 20 events") }
    static var diagCopy: String { String(localized: "Copy log") }
    static var diagCopied: String { String(localized: "Copied") }
    static var diagClear: String { String(localized: "Clear") }
    static var diagTuning: String { String(localized: "Thresholds") }
    static var diagScale: String { String(localized: "Signal scale") }
    static var diagScaleHint: String {
        String(localized: "This iPhone is the reference scale, so its readings go in as they are, with an offset of 0: touching about -33 dBm, resting 20 to 30 cm apart about -60.")
    }
    static var diagProfile: String { String(localized: "Sensitivity profile") }
    static var diagGateNow: String { String(localized: "Gate now") }
    static var diagHoldLevel: String { String(localized: "Gentle hold fires at") }
    static var diagPeerTap: String { String(localized: "One-sided tap") }

    // MARK: Sensitivity (Settings > Song Tap, and the diagnostics screen)

    static var sensitivityTitle: String { String(localized: "Sensitivity") }
    static func sensitivitySubtitle(_ value: String) -> String { String(localized: "How little it takes to count as a tap: \(value)") }
    static var sensitivityNormal: String { String(localized: "Normal") }
    static var sensitivityHigh: String { String(localized: "High") }
    static var sensitivityDialogTitle: String { String(localized: "Sensitivity") }
    static var sensitivityDialogBody: String { String(localized: "High reacts to a smaller, quicker touch. Normal needs a firmer one.") }

    static func sensitivityName(_ value: SongTapSensitivity) -> String {
        value == .high ? sensitivityHigh : sensitivityNormal
    }

    // MARK: Your name (Settings > Song Tap)

    static var nameTitle: String { String(localized: "Your name") }
    static func nameSubtitle(_ name: String) -> String { String(localized: "Other phones see \(name)") }
    static var nameDialogTitle: String { String(localized: "Your name") }
    static var nameDialogBody: String { String(localized: "Other phones show this when you share a song with them. Up to 20 characters.") }
    static func nameCounter(_ used: Int, _ max: Int) -> String { String(localized: "\(used) of \(max)") }
    static var nameSave: String { String(localized: "Save") }
    static var nameUseDevice: String { String(localized: "Use my phone's name") }
    static func from(_ name: String) -> String { String(localized: "From \(name)") }

    // MARK: Song Drop

    static var dropButton: String { String(localized: "Song Drop") }
    static var dropButtonLabel: String { String(localized: "Song Drop: share this song with a phone nearby") }
    static var dropNearbyTitle: String { String(localized: "Phones nearby") }
    static var dropNearbyEmpty: String { String(localized: "No phones nearby yet. Ask them to open Song Tap and choose Receive.") }
    static var dropSignalClose: String { String(localized: "Close") }
    static var dropSignalNearby: String { String(localized: "Nearby") }
    static func dropConfirmTitle(_ name: String) -> String { String(localized: "Song drop to \(name)?") }
    static func dropConfirmBody(_ title: String) -> String { String(localized: "\(title) will be shared when you touch the phones together.") }
    static var dropYes: String { String(localized: "Yes") }
    static var dropNo: String { String(localized: "No") }
    static var dropArmedTitle: String { String(localized: "Tap phones together to share") }
    static func dropArmedTo(_ name: String) -> String { String(localized: "Sharing with \(name)") }
    static var dropArmedCancel: String { String(localized: "Cancel") }
    static func dropWaiting(_ name: String) -> String { String(localized: "Waiting for \(name)") }
    static var dropOtherPhone: String { String(localized: "the other phone") }

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
