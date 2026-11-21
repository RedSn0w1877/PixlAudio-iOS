// The one-sided tap (Song Tap, spec 6): what a phone does with the other phone's tap message. A transliteration of
// `SongTapPeerTap.kt`.
//
// When a phone's detector fires (the first haptic tick) it tells the other phone at once over the existing link, and the
// other phone commits without waiting for its own detector, but only when every condition here holds. Both phones therefore
// beam from whichever one felt the tap first.
//
// Wire: a receiver tells the sender with a Control write `04 aa aa aa aa` (`SongTapWire.encodeTap`, `aa` = the age of its last
// jerk); the sender tells the receiver with an Event notification `04` (`SongTapWire.encodeTapEvent`). The consent and the offer
// checks are untouched: this only removes the wait for the second detector.

public enum SongTapPeerTapVerdict: String, Sendable, CaseIterable {
    /// Commit now: haptic, save or ack, beam, without waiting for this phone's own detector.
    case accept = "accept"
    /// This phone's own signal for that phone is below the tap near gate: the message is not believed.
    case tooWeak = "too_weak"
    /// The message did not come from the phone this one is following / armed with.
    case notFollowed = "not_followed"
    /// The sender has not said yes to "Song drop to X?" for this pair.
    case noYes = "no_yes"
    /// Another tap was taken (or this phone's own detector fired) less than `SongTapPeerTap.minGapMs` ago.
    case tooSoon = "too_soon"

    public var code: String { rawValue }
}

public enum SongTapPeerTap {
    /// At most one accepted peer tap in this long (also counted from this phone's own last fire).
    public static let minGapMs: Int64 = 1_200

    /// Judges one tap message from the peer, in this order: followed, said yes, signal at least the near gate, gap.
    ///
    /// - ownFastDbm: this phone's own smoothed signal for the peer, whole dBm, at this moment.
    /// - followed: the message came from the phone this one follows (a sender: the phone it is armed to; a receiver: the
    ///   sender it is connected to and near).
    /// - saidYes: the sender said yes to this pair (a sender: it holds an offer that this reader read; a receiver: it holds
    ///   a checked offer fetched ahead).
    /// - lastTapMs: when this phone last fired itself or took a peer tap, -1 for never (any clock, only the difference matters).
    public static func judge(ownFastDbm: Int, followed: Bool, saidYes: Bool, nowMs: Int64, lastTapMs: Int64) -> SongTapPeerTapVerdict {
        if !followed { return .notFollowed }
        if !saidYes { return .noYes }
        if ownFastDbm < SongTapTuning.nearEnterDbm { return .tooWeak }
        if lastTapMs >= 0 && nowMs - lastTapMs < minGapMs { return .tooSoon }
        return .accept
    }
}
