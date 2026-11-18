// The listener's explicit feedback on one track, and what the app says about a pick (docs/brain-spec.md, 8.5, 8.8,
// 5.11). Decisions only: which taste change "Not for me" and "Less from X" are, which sentence a reason key stands
// for, what the bar after a piece of feedback offers. The words themselves live in the app (decision D16). Ports of
// Android's `BrainFeedback.kt`, `WhyLineText.kt` and the state half of `BrainActionsStateHolder.kt`.

import Foundation
import PixlModel

/// "Not for me" is a mute in the existing taste changes, so it shows in the Taste changes screen and is undone
/// there or from the bar that follows it; the play in flight is flagged, which is what gives the recording and its
/// artist their negative in the event log. Nothing here deletes a song or a play.
public enum BrainFeedback {
    // Shown in the Taste changes screen as the reason of the change.
    public static let reasonNotForMe = "Not for me"
    public static let reasonLessFrom = "Less from this artist"

    /// ONE artist name for a taste change about `song`: its primary credit. A song rebuilt from a queue snapshot
    /// has no credit list, only a display line ("A, B"); its first part is taken. "" when it names nobody.
    public static func artistOf(_ song: Song) -> String {
        var name = (song.artists.first(where: \.isPrimary) ?? song.artists.first)?.name ?? ""
        if BrainText.isBlank(name) {
            name = song.artist.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        }
        name = BrainText.trim(name)
        return BrainText.isBlank(name) || BrainKey.sameBytes(name, EngineTrack.unknownArtist) ? "" : name
    }

    /// The mute behind "Not for me": this recording, in everything the app picks by itself.
    public static func muteChange(for song: Song) -> TasteChange {
        let artist = song.displayArtist
        let label = BrainText.isBlank(artist) ? song.title : "\(song.title) — \(artist)"
        return TasteChange(action: .mute, targetType: .song, key: TasteKey.recording(song), label: label,
                           reason: reasonNotForMe, source: .user)
    }

    /// "Less from X": the existing reduce on an artist at the default strength. Nil when the name folds to nothing.
    public static func lessFromChange(artistName: String) -> TasteChange? {
        let key = TasteKey.of(artistName)
        if key.isEmpty { return nil }
        return TasteChange(action: .reduce, targetType: .artist, key: key, label: artistName, reason: reasonLessFrom,
                           source: .user)
    }

    /// The id of the change an outcome stored (what Undo takes back); nil when nothing was stored.
    public static func adjustmentId(of outcome: TasteChangeOutcome?) -> String? {
        if case .set(let adjustment, _)? = outcome { return adjustment.id }
        return nil
    }
}

/// The bar that follows a piece of feedback: what happened, Undo, and after "Not for me" one more step.
public struct BrainNotice: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case notForMe, notSaved, lessFrom, undone
    }

    /// Grows with every notice, so the bar restarts its timer for a new one.
    public var serial: Int
    public var kind: Kind
    /// The taste change to take back with Undo; nil when nothing can be undone.
    public var adjustmentId: String?
    /// ONE artist name, for "Less from ..."; blank when the track names nobody.
    public var artistName: String

    public var id: Int { serial }

    public init(serial: Int, kind: Kind, adjustmentId: String?, artistName: String) {
        self.serial = serial
        self.kind = kind
        self.adjustmentId = adjustmentId
        self.artistName = artistName
    }

    public var canUndo: Bool { adjustmentId != nil }
    /// After "Not for me" the bar offers the step to "Less from the artist".
    public var canLessFrom: Bool { kind == .notForMe && !BrainText.isBlank(artistName) }
    /// How long the bar stays.
    public var visibleMs: Int64 { kind == .undone ? 2_500 : 7_000 }

    /// The notice after "Not for me": the mute was stored, or it could not be (too many active changes).
    public static func afterNotForMe(serial: Int, outcome: TasteChangeOutcome?, artistName: String) -> BrainNotice {
        let id = BrainFeedback.adjustmentId(of: outcome)
        return BrainNotice(serial: serial, kind: id != nil ? .notForMe : .notSaved, adjustmentId: id, artistName: artistName)
    }

    public static func afterLessFrom(serial: Int, outcome: TasteChangeOutcome?, artistName: String) -> BrainNotice {
        let id = BrainFeedback.adjustmentId(of: outcome)
        return BrainNotice(serial: serial, kind: id != nil ? .lessFrom : .notSaved, adjustmentId: id, artistName: artistName)
    }
}

/// The sentence behind a reason key (8.8, decision D16): the key and its one argument come from the pure core; the
/// words live in the app. A key whose sentence needs a name is not shown without one: a reason is a true statement
/// or it is nothing.
public enum WhyLineText {
    public enum Line: Sendable, Equatable {
        /// "Fans of X also play this"
        case radioFans(String)
        /// "Because you liked X"
        case becauseLiked(String)
        /// "Because you listened to X"
        case becauseListened(String)
        /// "More from X"
        case artistMore(String)
        /// "On repeat this month"
        case onRepeat
    }

    /// The line for a `WhyLine` key and its argument, or nil when there is nothing true to say. The other keys of
    /// 8.8 belong to arms that stage 1 does not serve.
    public static func line(key: Int32, arg: String?) -> Line? {
        if key == WhyLine.onRepeat { return .onRepeat }
        let name = BrainText.trim(arg ?? "")
        if name.isEmpty { return nil }
        if key == WhyLine.radioFans { return .radioFans(name) }
        if key == WhyLine.becauseLiked { return .becauseLiked(name) }
        if key == WhyLine.becauseListened { return .becauseListened(name) }
        if key == WhyLine.artistMore { return .artistMore(name) }
        return nil
    }

    /// The same by the key's name (`WhyLine.nameOf`), as a queue entry carries it.
    public static func line(keyName: String?, arg: String?) -> Line? {
        line(key: WhyLine.keyOf(keyName), arg: arg)
    }
}

/// The reason an engine pick is in the queue: its `WhyLine` key name and the name it is about.
public struct QueueWhy: Sendable, Hashable {
    public var key: String
    public var arg: String

    public init(key: String, arg: String) {
        self.key = key
        self.arg = arg
    }

    public var line: WhyLineText.Line? { WhyLineText.line(keyName: key, arg: arg) }

    /// The reason of every queue entry that has one, by media id.
    public static func map(_ entries: some Sequence<(mediaId: String, tag: BrainItemTag?)>) -> [String: QueueWhy] {
        var out: [String: QueueWhy] = [:]
        for entry in entries {
            guard let key = entry.tag?.whyKey, !key.isEmpty else { continue }
            let why = QueueWhy(key: key, arg: entry.tag?.whyArg ?? "")
            if why.line != nil { out[entry.mediaId] = why }
        }
        return out
    }
}
