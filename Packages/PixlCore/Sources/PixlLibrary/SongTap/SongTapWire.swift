// What goes over Bluetooth, fixed once so a Pixel and an iPhone speak the same thing (Song Tap). A transliteration of
// `SongTapWire.kt`; every constant is the same string and the same number.
//
// Each phone, while Song Tap is armed on screen, advertises exactly one 128-bit service UUID and scans for both. The UUID
// says which side it is on: `serviceSend` (this phone offers the song that is playing) or `serviceReceive` (this phone
// waits for one). A phone that is sending also runs a GATT server with the four characteristics below; the receiving
// phone connects to it as the client and never serves anything, so a beam always travels over one connection in one
// direction. Nothing sits in the advertisement but the UUID (an iPhone can advertise nothing else), no device name, no
// identifier.
//
//   info     read    `encodeInfo`: version and how long ago the sender's last jerk was
//   offer    read    the signed frame (`SongTapSigning.encodeFrame`); an application error until an offer exists
//   control  write   a `SongTapControlMessage` from the receiver: hello (challenge), tap, ack, decline
//   event    notify  `eventGo` once, when the sender starts the beam
//
// The signature itself is ECDSA P-256 over SHA-256, written as the raw 64 bytes r then s (not DER); the public key is the
// 65 byte x9.63 point. That is CryptoKit's `rawRepresentation` / `x963Representation`, and Android's own encoding.

public enum SongTapControlMessage: Sendable, Equatable {
    case hello(challenge: [UInt8])
    case ack
    case decline
    /// The receiver's detector fired; `ageMs` is how long ago its last jerk was, -1 for none.
    case tap(ageMs: Int64)
}

public enum SongTapWire {
    public static let version = 1

    public static let serviceSend = "b7f3a1c0-5d2e-4c9a-8e61-3f4d7a2b9c01"
    public static let serviceReceive = "b7f3a1c0-5d2e-4c9a-8e61-3f4d7a2b9c02"
    public static let charInfo = "b7f3a1c0-5d2e-4c9a-8e61-3f4d7a2b9c11"
    public static let charOffer = "b7f3a1c0-5d2e-4c9a-8e61-3f4d7a2b9c12"
    public static let charControl = "b7f3a1c0-5d2e-4c9a-8e61-3f4d7a2b9c13"
    public static let charEvent = "b7f3a1c0-5d2e-4c9a-8e61-3f4d7a2b9c14"

    /// The ATT application error a sender answers an Offer read with while it has nothing (yet) to give.
    public static let errorNotReady = 0x80

    /// The MTU a receiver asks for, so that one frame (at most `SongTapSigning.maxFrameBytes`) fits one read.
    public static let wantedMtu = 517

    public static let opHello = 0x01
    public static let opAck = 0x02
    public static let opDecline = 0x03
    public static let opTap = 0x04

    /// The one thing `charEvent` says.
    public static let eventGo = 0x01

    /// "No jerk to report" in an age field.
    public static let noAge: Int64 = 0xFFFF_FFFF

    /// A jerk older than this is not worth reporting.
    public static let maxReportedAgeMs: Int64 = 5_000

    public static func roleOfService(_ uuid: String) -> SongTapRole? {
        if uuid == serviceSend { return .send }
        if uuid == serviceReceive { return .receive }
        return nil
    }

    public static func serviceOf(_ role: SongTapRole) -> String { role == .send ? serviceSend : serviceReceive }

    // MARK: Info

    /// Five bytes: the version, then the age of the last jerk in ms as 4 bytes big endian (`noAge` for none).
    public static func encodeInfo(ageMs: Int64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 5)
        out[0] = UInt8(version)
        putU32(&out, 1, clampedAge(ageMs))
        return out
    }

    /// The age of the peer's last jerk in ms, -1 when it reports none; nil when the bytes are not an Info value.
    public static func decodeInfo(_ bytes: [UInt8]) -> Int64? {
        if bytes.count != 5 || Int(bytes[0]) != version { return nil }
        let age = getU32(bytes, 1)
        return age == noAge || age > maxReportedAgeMs ? -1 : age
    }

    // MARK: Control

    public static func encodeHello(challenge: [UInt8]) -> [UInt8]? {
        if challenge.count != SongTapSigning.challengeBytes { return nil }
        return [UInt8(opHello)] + challenge
    }

    public static func encodeAck() -> [UInt8] { [UInt8(opAck)] }

    public static func encodeDecline() -> [UInt8] { [UInt8(opDecline)] }

    public static func encodeTap(ageMs: Int64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 5)
        out[0] = UInt8(opTap)
        putU32(&out, 1, clampedAge(ageMs))
        return out
    }

    /// Nil for anything that is not exactly one well-formed message.
    public static func decodeControl(_ bytes: [UInt8]) -> SongTapControlMessage? {
        guard let first = bytes.first else { return nil }
        switch Int(first) {
        case opHello:
            return bytes.count == 1 + SongTapSigning.challengeBytes ? .hello(challenge: Array(bytes[1...])) : nil
        case opAck:
            return bytes.count == 1 ? .ack : nil
        case opDecline:
            return bytes.count == 1 ? .decline : nil
        case opTap:
            if bytes.count != 5 { return nil }
            let age = getU32(bytes, 1)
            return .tap(ageMs: age == noAge || age > maxReportedAgeMs ? -1 : age)
        default:
            return nil
        }
    }

    public static func isGo(_ bytes: [UInt8]) -> Bool { bytes.count == 1 && Int(bytes[0]) == eventGo }

    public static func encodeGo() -> [UInt8] { [UInt8(eventGo)] }

    // MARK: Bytes

    private static func clampedAge(_ ageMs: Int64) -> Int64 {
        ageMs < 0 || ageMs > maxReportedAgeMs ? noAge : ageMs
    }

    private static func putU32(_ out: inout [UInt8], _ at: Int, _ v: Int64) {
        for k in 0..<4 { out[at + k] = UInt8(truncatingIfNeeded: v >> Int64(24 - 8 * k)) }
    }

    private static func getU32(_ b: [UInt8], _ at: Int) -> Int64 {
        var v: Int64 = 0
        for k in 0..<4 { v = (v << 8) | Int64(b[at + k]) }
        return v
    }
}
