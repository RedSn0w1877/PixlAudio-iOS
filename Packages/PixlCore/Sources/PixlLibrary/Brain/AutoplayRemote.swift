// How Autoplay and stations behave on an output that is not this phone's own speaker (docs/brain-spec.md, 14.6, owner
// question 7), as pure functions. A port of Android's `AutoplayPolicy.remoteRule` and its trace; the iOS trace is in
// docs/handoff/2026-11-18-music-brain-stage2a.md.
//
// Two outputs on iOS, and they could not be more different:
//
//  - AirPlay is a ROUTE. The phone's own player decodes and streams the audio and the system sends the sound to the
//    speaker, so a track from outside the library plays exactly as it does on the phone's speaker, and so does a
//    queue edit. There is nothing to do for it: it is `RemoteOutput.none` (`PlaybackStore.isRemoteActive` is false).
//  - Spotify Connect is a REMOTE OUTPUT (`RemotePlaybackOutput`). The device streams from Spotify and is told what to
//    play by this phone's queue, as Spotify track URIs. A queue entry with a real Spotify id plays directly; any
//    other (an engine pick is `yt:<videoId>` with none) is looked up by ISRC, then by title, artist and length, and
//    is skipped when Spotify has no strict match. So picks can run there, limited to what Spotify has.

/// Where the queue is sounding.
public enum RemoteOutput: Sendable, Equatable {
    /// This phone, including an AirPlay route: the phone plays the audio itself.
    case none
    /// A Spotify Connect device: it streams from Spotify, told what to play by this phone's queue.
    case connect
}

/// What the engine may do while the queue sounds on a remote output.
public struct RemoteRule: Sendable, Equatable {
    /// Autoplay may append picks, and a station may run.
    public let picks: Bool
    /// Only picks the output can play go in: on Spotify Connect a pick needs a Spotify track (its own id, or a strict
    /// search match), so it is looked up before it is queued and left out when Spotify does not have it.
    public let onlyWhatTheOutputPlays: Bool
    /// The engine's tail may be re-scored (replaced in one edit). Not on a remote output: replacing what the device
    /// was already told to play means sending it the list again, which is audible.
    public let rescore: Bool
    /// The 1.5 s settle rule reads this phone's player. On a remote output the phone streams nothing and its player
    /// sits paused at the start of the track, so the wait is a plain delay there.
    public let settleOnLocalPlayer: Bool

    public init(picks: Bool, onlyWhatTheOutputPlays: Bool, rescore: Bool, settleOnLocalPlayer: Bool) {
        self.picks = picks
        self.onlyWhatTheOutputPlays = onlyWhatTheOutputPlays
        self.rescore = rescore
        self.settleOnLocalPlayer = settleOnLocalPlayer
    }
}

extension AutoplayPolicy {
    /// Autoplay and stations on a Spotify Connect device (14.6, owner question 7). On: the phone's queue is what the
    /// device plays, and a pick is queued only when Spotify has it. The one place to turn it off if a speaker
    /// misbehaves.
    public static let autoplayOnConnect = true

    public static func remoteRule(_ output: RemoteOutput, connectAllowed: Bool = autoplayOnConnect) -> RemoteRule {
        switch output {
        case .none:
            return RemoteRule(picks: true, onlyWhatTheOutputPlays: false, rescore: true, settleOnLocalPlayer: true)
        case .connect:
            return RemoteRule(picks: connectAllowed, onlyWhatTheOutputPlays: true, rescore: false,
                              settleOnLocalPlayer: false)
        }
    }

    /// True for an id Spotify itself gave out: 22 base62 characters that are not all lower-case hex (the app's own
    /// ids for tracks saved from YouTube Music are 22 hex characters). Such a track plays on Spotify Connect with no
    /// lookup. The same rule as `SpotifyConnect.isTrackId` (PixlNet, which this module cannot import).
    public static func isSpotifyTrackId(_ id: String?) -> Bool {
        guard let id else { return false }
        let scalars = Array(id.unicodeScalars)
        if scalars.count != 22 { return false }
        var allLowerHex = true
        for c in scalars {
            let v = c.value
            let digit = v >= 0x30 && v <= 0x39
            let upper = v >= 0x41 && v <= 0x5A
            let lower = v >= 0x61 && v <= 0x7A
            if !(digit || upper || lower) { return false }
            if !(digit || (v >= 0x61 && v <= 0x66)) { allLowerHex = false }
        }
        return !allLowerHex
    }

    /// Which of a planned batch go into the queue on an output that plays only some tracks: the ones the output
    /// answered yes for, in the planned order. `playable` is parallel to `mediaIds`.
    public static func keepPlayable(mediaIds: [String], playable: [Bool]) -> [String] {
        var kept: [String] = []
        var seen: Set<BrainKey> = []
        for i in mediaIds.indices where i < playable.count && playable[i] && seen.insert(BrainKey(mediaIds[i])).inserted {
            kept.append(mediaIds[i])
        }
        return kept
    }
}
