// What a signed offer is and how it is checked (Song Tap). The cryptography itself (ECDSA P-256) is injected by each
// app through `SongTapSignatureVerifier` (CryptoKit on iOS, java.security on Android); the core only fixes the bytes
// that are signed and the frame that carries them, so both platforms sign and verify the same thing. A
// transliteration of `SongTapSigning.kt`.
//
// What this proves: the payload was not changed on the way and was made for this challenge, so it cannot be replayed
// to another receiver or later. What it does not prove: that the sender is honest. There is no server and no account,
// so anyone can make a key; the defences against a hostile sender are the strict payload rules, the host allow-list
// for art, the rate limits and the first-beam consent card.

/// Checks a signature; the app supplies the real one.
public protocol SongTapSignatureVerifier: Sendable {
    /// `publicKey` is an uncompressed P-256 point (65 bytes), `signature` is r then s (64 bytes).
    func verify(publicKey: [UInt8], message: [UInt8], signature: [UInt8]) -> Bool
}

public struct SongTapSignedOffer: Sendable, Equatable {
    public var payload: [UInt8]
    public var timestampMs: Int64
    public var publicKey: [UInt8]
    public var signature: [UInt8]

    public init(payload: [UInt8], timestampMs: Int64, publicKey: [UInt8], signature: [UInt8]) {
        self.payload = payload
        self.timestampMs = timestampMs
        self.publicKey = publicKey
        self.signature = signature
    }
}

public enum SongTapOfferCheck: String, Sendable {
    case ok = "ok"
    case badFrame = "bad_frame"
    case badPayload = "bad_payload"
    case stale = "stale"
    case badSignature = "bad_signature"

    public var code: String { rawValue }
}

public enum SongTapSigning {
    public static let challengeBytes = 16
    public static let publicKeyBytes = 65
    public static let signatureBytes = 64
    public static let frameVersion = 1
    public static let maxFrameBytes = 512

    /// How far a signed offer's timestamp may be from the receiver's clock.
    public static let offerWindowMs: Int64 = 30_000

    /// How far a QR code's payload timestamp may be from the receiver's clock. A code has no challenge to answer (nothing
    /// travels back), so freshness is all that limits a photographed code; the sender makes a new code before this runs out.
    public static let qrWindowMs: Int64 = 300_000

    /// True when `tsMs` is within `windowMs` of `nowMs`, either side.
    public static func isFresh(tsMs: Int64, nowMs: Int64, windowMs: Int64) -> Bool {
        let skew = nowMs &- tsMs
        return skew <= windowMs && 0 &- skew <= windowMs
    }

    /// `payload || challenge || timestamp`, the timestamp as 8 bytes big endian. Nil when the challenge is not 16 bytes.
    public static func signingBytes(payload: [UInt8], challenge: [UInt8], timestampMs: Int64) -> [UInt8]? {
        if challenge.count != challengeBytes { return nil }
        var out = payload
        out.append(contentsOf: challenge)
        appendLong(&out, timestampMs)
        return out
    }

    /// Frame: version, payload length (2 bytes), payload, timestamp (8), key length (1), key, signature length (1), signature.
    public static func encodeFrame(_ offer: SongTapSignedOffer) -> [UInt8]? {
        if offer.publicKey.count != publicKeyBytes || offer.signature.count != signatureBytes { return nil }
        if offer.payload.isEmpty || offer.payload.count > SongTapPayloads.maxBytes { return nil }
        let size = 1 + 2 + offer.payload.count + 8 + 1 + publicKeyBytes + 1 + signatureBytes
        if size > maxFrameBytes { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(size)
        out.append(UInt8(frameVersion))
        out.append(UInt8(truncatingIfNeeded: offer.payload.count >> 8))
        out.append(UInt8(truncatingIfNeeded: offer.payload.count))
        out.append(contentsOf: offer.payload)
        appendLong(&out, offer.timestampMs)
        out.append(UInt8(publicKeyBytes))
        out.append(contentsOf: offer.publicKey)
        out.append(UInt8(signatureBytes))
        out.append(contentsOf: offer.signature)
        return out
    }

    public static func decodeFrame(_ frame: [UInt8]) -> SongTapSignedOffer? {
        if frame.count < 4 || frame.count > maxFrameBytes { return nil }
        var i = 0
        if Int(frame[i]) != frameVersion { return nil }
        i += 1
        let payloadLen = (Int(frame[i]) << 8) | Int(frame[i + 1])
        i += 2
        if payloadLen == 0 || payloadLen > SongTapPayloads.maxBytes { return nil }
        if frame.count != 1 + 2 + payloadLen + 8 + 1 + publicKeyBytes + 1 + signatureBytes { return nil }
        let payload = Array(frame[i..<(i + payloadLen)]); i += payloadLen
        let ts = getLong(frame, i); i += 8
        if Int(frame[i]) != publicKeyBytes { return nil }
        i += 1
        let key = Array(frame[i..<(i + publicKeyBytes)]); i += publicKeyBytes
        if Int(frame[i]) != signatureBytes { return nil }
        i += 1
        let sig = Array(frame[i..<(i + signatureBytes)])
        return SongTapSignedOffer(payload: payload, timestampMs: ts, publicKey: key, signature: sig)
    }

    /// Checks `offer` against the `challenge` this receiver handed out: the payload is a valid payload, the timestamp is
    /// close to `nowMs`, and the signature covers payload, challenge and timestamp. Single use of the challenge is the
    /// caller's job.
    public static func check(_ offer: SongTapSignedOffer, challenge: [UInt8], nowMs: Int64, verifier: any SongTapSignatureVerifier) -> SongTapOfferCheck {
        guard case .ok = SongTapPayloads.decode(offer.payload) else { return .badPayload }
        if !isFresh(tsMs: offer.timestampMs, nowMs: nowMs, windowMs: offerWindowMs) { return .stale }
        guard let message = signingBytes(payload: offer.payload, challenge: challenge, timestampMs: offer.timestampMs) else {
            return .badFrame
        }
        return verifier.verify(publicKey: offer.publicKey, message: message, signature: offer.signature) ? .ok : .badSignature
    }

    /// A short stable number for a sender's key, used to mute one sender: the first 4 bytes of the key's tail, as a
    /// signed 32-bit number (the Android `Int`).
    public static func senderKey(_ publicKey: [UInt8]) -> Int32 {
        if publicKey.count < 4 { return 0 }
        let n = publicKey.count
        let bits = (UInt32(publicKey[n - 4]) << 24) | (UInt32(publicKey[n - 3]) << 16) | (UInt32(publicKey[n - 2]) << 8) | UInt32(publicKey[n - 1])
        return Int32(bitPattern: bits)
    }

    private static func appendLong(_ out: inout [UInt8], _ v: Int64) {
        for k in 0..<8 { out.append(UInt8(truncatingIfNeeded: v >> Int64(56 - 8 * k))) }
    }

    private static func getLong(_ b: [UInt8], _ at: Int) -> Int64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(b[at + k]) }
        return Int64(bitPattern: v)
    }
}
