// What goes over Bluetooth, fixed once so a Pixel and an iPhone speak the same thing (Song Tap). A transliteration of
// `SongTapWire.kt`; every constant is the same string and the same number.
//
// Each phone, while Song Tap is armed on screen, advertises exactly one 128-bit service UUID and scans for both. The UUID
// says which side it is on: `serviceSend` (this phone offers a song) or `serviceReceive` (this phone waits for one). A
// phone that is sending also runs a GATT server with the five characteristics below; the receiving phone connects to it as
// the client and never serves anything, so a beam always travels over one connection in one direction. Spec 5 adds a short
// name next to the UUID (see `SongTapNames`): an iPhone advertises it as its local name, an Android phone in a manufacturer
// block (company id `advertCompanyId`) of its scan response; no identifier.
//
//   info     read    `encodeInfo`: version and how long ago the sender's last jerk was
//   offer    read    the signed frame (`SongTapSigning.encodeFrame`); an application error until an offer exists
//   control  write   a `SongTapControlMessage` from the receiver: hello (challenge), tap, ack, decline
//   name     read    `encodeName`: the sender's full name (spec 5)
//   event    notify  `eventOfferReady` when the sender has an offer to read, `eventOfferWithdrawn` when it has none any more,
//                    `eventTap` when the sender's detector fired (spec 6); `eventGo` is reserved and never sent
//
// The flow (spec 5, "prefetch"): the receiver connects while the sender is inside the near gate, writes Hello with a fresh 16
// byte challenge, subscribes to event, reads Name, and as soon as the sender has an offer for it (the sender's listener said
// yes; the sender says so with `eventOfferReady`) reads Offer: the sender signs payload, challenge and time with its
// per-session key on that read, and the receiver checks the signature and holds the result. Nothing slow is left for the
// tap: when a phone's detector fires the data is in hand, so both phones start the beam at once.
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
    public static let charName = "b7f3a1c0-5d2e-4c9a-8e61-3f4d7a2b9c15"

    /// The company id of the manufacturer-specific block that carries the short name in an Android phone's scan response
    /// (0xFFFF: no company, as the Bluetooth spec reserves it for tests and internal use).
    public static let advertCompanyId = 0xFFFF
    public static let advertVersion = 1

    /// The ATT application error a sender answers an Offer read with while it has nothing (yet) to give.
    public static let errorNotReady = 0x80

    /// The MTU a receiver asks for, so that one frame (at most `SongTapSigning.maxFrameBytes`) fits one read.
    public static let wantedMtu = 517

    public static let opHello = 0x01
    public static let opAck = 0x02
    public static let opDecline = 0x03
    public static let opTap = 0x04

    /// Reserved: spec 4 sent it to start the animations. No phone sends it any more and every phone ignores it.
    public static let eventGo = 0x01

    /// The sender has an offer (a new one) for the connected receiver to read.
    public static let eventOfferReady = 0x02

    /// The sender no longer offers anything (its listener cancelled, the time ran out, the beam is over): a receiver that
    /// holds an offer fetched ahead lets it go.
    public static let eventOfferWithdrawn = 0x03

    /// The sender's detector fired (spec 6, the one-sided tap): a one byte notification on Event, `04`, sent at once to the
    /// central that read the offer. The receiver commits only if `SongTapPeerTap.judge` accepts it. (The receiver's own tap
    /// message is the Control write `opTap`; the two share the number 4 on different characteristics.)
    public static let eventTap = 0x04

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

    public static func isOfferReady(_ bytes: [UInt8]) -> Bool { bytes.count == 1 && Int(bytes[0]) == eventOfferReady }

    public static func encodeOfferReady() -> [UInt8] { [UInt8(eventOfferReady)] }

    public static func isOfferWithdrawn(_ bytes: [UInt8]) -> Bool { bytes.count == 1 && Int(bytes[0]) == eventOfferWithdrawn }

    public static func encodeOfferWithdrawn() -> [UInt8] { [UInt8(eventOfferWithdrawn)] }

    public static func isTapEvent(_ bytes: [UInt8]) -> Bool { bytes.count == 1 && Int(bytes[0]) == eventTap }

    public static func encodeTapEvent() -> [UInt8] { [UInt8(eventTap)] }

    // MARK: Names

    /// `charName`: the version byte, then the clean name in UTF-8 (at most `SongTapNames.maxNameBytes` bytes).
    public static func encodeName(_ name: String) -> [UInt8] {
        [UInt8(version)] + SongTapText.encodeUtf8(SongTapText.toCodePoints(SongTapNames.orFallback(name)))
    }

    /// The clean name in a Name value; nil for a wrong version, bad UTF-8, too long or nothing usable.
    public static func decodeName(_ bytes: [UInt8]) -> String? {
        if bytes.count < 2 || bytes.count > 1 + SongTapNames.maxNameBytes || Int(bytes[0]) != version { return nil }
        guard let cps = SongTapText.decodeUtf8(bytes, from: 1, to: bytes.count) else { return nil }
        return SongTapNames.fromAdvert(SongTapText.fromCodePoints(cps))
    }

    /// The data of the manufacturer block (`advertCompanyId`) of an Android phone's scan response: `advertVersion`, then the
    /// short name in UTF-8. An iPhone never writes one (it advertises its local name); this is for the port's tests and for
    /// parity with Android.
    public static func encodeAdvertName(_ name: String) -> [UInt8] {
        [UInt8(advertVersion)] + SongTapText.encodeUtf8(SongTapText.toCodePoints(SongTapNames.advertName(SongTapNames.orFallback(name))))
    }

    /// The clean short name in a manufacturer block's data; nil for a wrong version, bad UTF-8, too long or nothing usable.
    public static func decodeAdvertName(_ bytes: [UInt8]) -> String? {
        if bytes.count < 2 || bytes.count > 1 + SongTapNames.advertNameMaxBytes || Int(bytes[0]) != advertVersion { return nil }
        guard let cps = SongTapText.decodeUtf8(bytes, from: 1, to: bytes.count) else { return nil }
        return SongTapNames.fromAdvert(SongTapText.fromCodePoints(cps))
    }

    /// The short name of a phone from what its advertisement carried (both platforms read it the same way): the Song Tap
    /// manufacturer block when there is one, else the local name, each through `SongTapNames.fromAdvert`. `manufacturerData` is
    /// CoreBluetooth's `CBAdvertisementDataManufacturerDataKey`: the company id first, two bytes little endian, then the data.
    public static func advertisedName(manufacturerData: [UInt8]?, localName: String?) -> String? {
        if let m = manufacturerData, m.count >= 3,
           Int(m[0]) | (Int(m[1]) << 8) == advertCompanyId,
           let name = decodeAdvertName(Array(m[2...])) {
            return name
        }
        guard let localName else { return nil }
        return SongTapNames.fromAdvert(localName)
    }

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
