// What is left of the clock alignment (Song Tap). Spec 4 had the sender wait for the receiver's acknowledgement, answer with
// `go` and start both animations `goDelayMs` later, which made a tap feel late. From spec 5 the data is fetched before the
// tap, so each phone starts its own beam at its own commit (the first haptic) and nothing waits for the other: there is no
// `go` and no start delay (`goDelayMs` is 0 and kept only so the ports have the same name). The two animations differ by
// the difference of the two commit times (tens of ms, rarely over 150); the motion is symmetric and eased and the phones
// are touching, so it is not visible and not corrected. A transliteration of `SongTapHandshake.kt`.

public enum SongTapHandshake {
    /// No wait: both animations start at the moment each phone commits.
    public static let goDelayMs: Int64 = 0

    /// A round trip longer than this is not trusted for the correction.
    public static let maxRttMs: Int64 = 1_000

    /// How long ago, on a phone's own clock, its last impulse was, so the other phone can place it on its clock.
    public static func impulseAgeMs(nowMs: Int64, impulseMs: Int64) -> Int64 {
        impulseMs < 0 || impulseMs > nowMs ? -1 : nowMs - impulseMs
    }

    /// The impulse the peer reported, as a time on this phone's clock (less half the one way trip).
    public static func peerImpulseLocalMs(receiptMs: Int64, ageMs: Int64, rttMs: Int64) -> Int64 {
        if ageMs < 0 { return -1 }
        let rtt = rttMs < 0 ? 0 : (rttMs > maxRttMs ? maxRttMs : rttMs)
        return receiptMs - ageMs - rtt / 2
    }
}
