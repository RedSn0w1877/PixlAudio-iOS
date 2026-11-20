// The clock that lines the two animations up (Song Tap). The receiver acknowledges the offer, the sender answers with
// `go` carrying a start time a little ahead on the sender's clock, and the receiver starts at its own receipt time plus
// the same delay minus half the measured round trip. An error of a few tens of milliseconds is invisible because the
// motion is symmetric and eased. A transliteration of `SongTapHandshake.kt`.

public enum SongTapHandshake {
    /// How far ahead of the `go` message both animations start.
    public static let goDelayMs: Int64 = 150

    /// A round trip longer than this is not trusted for the correction.
    public static let maxRttMs: Int64 = 1_000

    /// The sender's animation start, on the sender's clock.
    public static func senderStartMs(_ nowMs: Int64) -> Int64 { nowMs + goDelayMs }

    /// The receiver's animation start, on the receiver's clock; `rttMs` is the receiver's measured round trip of its ack.
    public static func receiverStartMs(receiptMs: Int64, rttMs: Int64) -> Int64 {
        let rtt = rttMs < 0 ? 0 : (rttMs > maxRttMs ? maxRttMs : rttMs)
        return receiptMs + goDelayMs - rtt / 2
    }

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
