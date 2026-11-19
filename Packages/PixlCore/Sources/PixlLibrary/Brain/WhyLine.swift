// The reason shown under an engine pick (docs/brain-spec.md, 8.8, decision D16): a key and one argument from pure
// logic; the sentence itself lives in each app's resources. Stage 1 has the arm reasons. A key is only returned
// when its sentence is a true statement about the decision. A transliteration of the Android `:brain` module's
// `WhyLine.kt`.

/// Reason keys.
public enum WhyLine {
    public static let none: Int32 = 0
    /// "Fans of X also play this"; the argument is the seed's artist (aid).
    public static let radioFans: Int32 = 1
    /// "Because you liked X"; the argument is the liked track (rid).
    public static let becauseLiked: Int32 = 2
    /// "Because you listened to X"; the argument is the row's anchor track (rid).
    public static let becauseListened: Int32 = 3
    /// "More from X"; the argument is the pick's own artist (aid).
    public static let artistMore: Int32 = 4
    /// "On repeat lately"; no argument. Decided by `onRepeatAff` and `onRepeatMass`.
    public static let onRepeat: Int32 = 5
    public static let similarArtist: Int32 = 6
    public static let newRelease: Int32 = 7
    public static let forgotten: Int32 = 8
    public static let adjacentGenre: Int32 = 9
    public static let asked: Int32 = 10

    static let names = [
        "", "radio_fans", "because_liked", "because_listened", "artist_more", "on_repeat",
        "similar_artist", "new_release", "forgotten", "adjacent_genre", "asked",
    ]

    public static func nameOf(_ key: Int32) -> String { key >= 0 && Int(key) < names.count ? names[Int(key)] : "" }

    public static func keyOf(_ name: String?) -> Int32 {
        guard let name else { return none }
        for i in 1..<names.count where BrainKey.sameBytes(names[i], name) { return Int32(i) }
        return none
    }

    public struct Why: Sendable {
        public let key: Int32
        public let arg: Int64
    }

    /// A track's 21-day affinity must be above this to read as "on repeat".
    public static let onRepeatAff: Double = 1.0

    /// And its 21-day positive mass at least this much: about three finished plays of the listener's own choosing in
    /// the last three weeks (one finished play is worth 1.0, and the mass halves every 21 days). The rate alone is
    /// not enough: for a listener who rarely finishes a song, one finished play already lifts the rate above
    /// `onRepeatAff`, and "on repeat" would be untrue.
    public static let onRepeatMass: Double = 2.5

    /// `seedAid` is the primary artist of the seed whose radio ranked the pick best (0 when it came from no radio);
    /// `trackAffRecent` is the pick's own 21-day affinity and `trackPosRecent` its 21-day positive mass (0 for a track
    /// the listener has not played). In a `mix` the library tracks carry a line only when they are on repeat.
    public static func pick(arm: Int32, slotKind: Int32, homeRow: Bool, candidateAid: Int64, seedAid: Int64,
                            bestRank: Int32, likedRid: Int64, homeSeedRid: Int64, trackAffRecent: Double,
                            trackPosRecent: Double = 0.0, mix: Bool = false) -> Why {
        if slotKind == ListBuilder.slotLiked && likedRid != 0 { return Why(key: becauseLiked, arg: likedRid) }
        if homeRow && homeSeedRid != 0 { return Why(key: becauseListened, arg: homeSeedRid) }
        if arm == Arm.radio {
            return seedAid != 0 ? Why(key: radioFans, arg: seedAid) : Why(key: none, arg: 0)
        }
        if arm == Arm.artist {
            return candidateAid != 0 ? Why(key: artistMore, arg: candidateAid) : Why(key: none, arg: 0)
        }
        if arm == Arm.fav || arm == Arm.deep {
            if arm == Arm.fav && trackAffRecent > onRepeatAff && trackPosRecent >= onRepeatMass {
                return Why(key: onRepeat, arg: 0)
            }
            // A mix holds the listener's own music by the dozen: a line under each of them would be noise.
            if mix { return Why(key: none, arg: 0) }
            if bestRank > 0 && seedAid != 0 { return Why(key: radioFans, arg: seedAid) }
            if candidateAid != 0 { return Why(key: artistMore, arg: candidateAid) }
            return Why(key: none, arg: 0)
        }
        // "Close to X": X is the artist whose list brought the pick in; the pick's own artist when no list did.
        if arm == Arm.sim { return Why(key: similarArtist, arg: seedAid != 0 ? seedAid : candidateAid) }
        if arm == Arm.new { return Why(key: newRelease, arg: candidateAid) }
        if arm == Arm.back { return Why(key: forgotten, arg: 0) }
        if arm == Arm.edge { return Why(key: adjacentGenre, arg: 0) }
        if arm == Arm.ask { return Why(key: asked, arg: 0) }
        return Why(key: none, arg: 0)
    }
}
