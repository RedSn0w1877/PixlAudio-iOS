// The candidate arms and play surfaces of the music brain (docs/brain-spec.md, 6.1 and 4.1), with the integer codes
// the event log stores and the names a queue item carries. A transliteration of the Android `:brain` module's
// `Arms.kt`. Codes are part of the event log: never renumber.

import PixlModel

/// The candidate arms of 6.1.
public enum Arm {
    public static let fav: Int32 = 0
    public static let deep: Int32 = 1
    public static let back: Int32 = 2
    public static let radio: Int32 = 3
    public static let sim: Int32 = 4
    public static let artist: Int32 = 5
    public static let new: Int32 = 6
    public static let edge: Int32 = 7
    public static let ask: Int32 = 8
    public static let none: Int32 = 9

    static let names = ["FAV", "DEEP", "BACK", "RADIO", "SIM", "ARTIST", "NEW", "EDGE", "ASK", "NONE"]

    public static func nameOf(_ code: Int32) -> String {
        code >= 0 && Int(code) < names.count ? names[Int(code)] : names[Int(none)]
    }

    /// The code for `name`; `none` for nil or anything unknown.
    public static func codeOf(_ name: String?) -> Int32 {
        guard let name else { return none }
        for i in names.indices where BrainKey.sameBytes(names[i], name) { return Int32(i) }
        return none
    }

    /// True for the arms that serve music the listener does not have.
    public static func isNovel(_ code: Int32) -> Bool {
        code == radio || code == sim || code == artist || code == new || code == edge || code == ask || code == back
    }
}

/// Where a play was started from (4.1 `surface`).
public enum Surface {
    public static let homeShelf: Int32 = 0
    public static let dailyMix: Int32 = 1
    public static let yourMix: Int32 = 2
    public static let namedMix: Int32 = 3
    public static let station: Int32 = 4
    public static let autoplay: Int32 = 5
    public static let album: Int32 = 6
    public static let playlist: Int32 = 7
    public static let liked: Int32 = 8
    public static let artist: Int32 = 9
    public static let search: Int32 = 10
    public static let assistant: Int32 = 11
    public static let manualQueue: Int32 = 12
    public static let external: Int32 = 13
    public static let unknown: Int32 = 14

    static let names = [
        "homeShelf", "dailyMix", "yourMix", "namedMix", "station", "autoplay", "album", "playlist",
        "liked", "artist", "search", "assistant", "manualQueue", "external", "unknown",
    ]

    public static func nameOf(_ code: Int32) -> String {
        code >= 0 && Int(code) < names.count ? names[Int(code)] : names[Int(unknown)]
    }

    public static func codeOf(_ name: String?) -> Int32 {
        guard let name else { return unknown }
        for i in names.indices where BrainKey.sameBytes(names[i], name) { return Int32(i) }
        return unknown
    }
}

extension BrainItemTag {
    /// True when the engine put the item in the queue: it sits under the Autoplay line, and only the engine may
    /// reorder or replace it. An item without an arm was chosen by the listener and is never touched.
    public var isEngineOwned: Bool {
        guard let arm else { return false }
        return Arm.codeOf(arm) != Arm.none
    }
}
