import CryptoKit
import Foundation
import PixlLibrary

/// The cryptography Song Tap's core leaves to the app: ECDSA P-256 with SHA-256, keys as an uncompressed point (65 bytes,
/// `x963Representation`) and signatures as r then s (64 bytes, `rawRepresentation`). The Android `SongTapSigner` writes and
/// reads the same two forms (java.security), so a Pixel and an iPhone verify each other.
///
/// A `SongTapSigner` is made per session and thrown away: no key outlives it, so nothing stable identifies a phone from one
/// beam to the next. What a signature proves is that the payload was not changed and was made for this receiver's challenge;
/// it does not prove the sender is honest (see `SongTapSigning`).
nonisolated struct SongTapSigner {
    private let key = P256.Signing.PrivateKey()

    /// The uncompressed point, 65 bytes.
    var publicKey: [UInt8] { Array(key.publicKey.x963Representation) }

    /// r then s, 32 bytes each. Nil only if CryptoKit refuses to sign.
    func sign(_ message: [UInt8]) -> [UInt8]? {
        guard let signature = try? key.signature(for: Data(message)) else { return nil }
        return Array(signature.rawRepresentation)
    }
}

/// Checks a signature made by a `SongTapSigner` or by the Android signer. False for anything malformed.
nonisolated struct SongTapVerifier: SongTapSignatureVerifier {
    func verify(publicKey: [UInt8], message: [UInt8], signature: [UInt8]) -> Bool {
        guard publicKey.count == SongTapSigning.publicKeyBytes, publicKey.first == 4,
              signature.count == SongTapSigning.signatureBytes else { return false }
        guard let key = try? P256.Signing.PublicKey(x963Representation: Data(publicKey)),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: Data(signature)) else { return false }
        return key.isValidSignature(sig, for: Data(message))
    }
}
