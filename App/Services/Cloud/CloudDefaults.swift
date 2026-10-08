import CryptoKit
import Foundation
import PixlNet

/// PixlAudio's built-in cloud keys (2026-10-08): the owner's RunPod endpoint, a Restricted RunPod key and a
/// bucket-scoped R2 key pair, bundled encrypted (`CloudDefaults.enc`) and opened with the key CI put into this build
/// (`CloudDefaultsKey`). Cloud processing uses them whenever the person hasn't chosen their own keys. The values are
/// never logged, shown or written anywhere; they live in memory only, after the first use.
nonisolated protocol CloudBuiltInKeysProviding: Sendable {
    /// Cheap and synchronous (no decryption): this build carries a key and the app bundles a blob. Whether they
    /// match is only known after `load()`.
    var isBundled: Bool { get }
    /// The built-in keys, decrypted once off the main actor and kept in memory; nil when the build has none or the
    /// blob doesn't open (another key, damaged, incomplete).
    func load() async -> CloudConfigInput?
}

/// AES-256-GCM over the blob's layout (`CloudDefaultsBlob`), with CryptoKit.
nonisolated enum CloudDefaultsCrypto {
    /// The payload inside `blob`, or nil for a wrong key, a tampered or truncated blob, or an unusable payload.
    static func open(_ blob: [UInt8], key: [UInt8]) -> CloudDefaultsPayload? {
        guard key.count == CloudDefaultsBlob.keyLength, let parsed = CloudDefaultsBlob(bytes: blob) else { return nil }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: parsed.nonce), ciphertext: parsed.ciphertext,
                                            tag: parsed.tag)
            let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key))
            return CloudDefaultsPayload.decode(Array(plaintext))
        } catch {
            return nil
        }
    }

    /// A blob for `payload` (tests; the real ones come from tools/cloud/bake-cloud-keys.mjs).
    static func seal(_ payload: CloudDefaultsPayload, key: [UInt8]) throws -> [UInt8] {
        let box = try AES.GCM.seal(Data(payload.encoded()), using: SymmetricKey(data: key), nonce: AES.GCM.Nonce())
        let nonce = box.nonce.withUnsafeBytes { Array($0) }
        return CloudDefaultsBlob(nonce: nonce, ciphertext: Array(box.ciphertext), tag: Array(box.tag)).bytes
    }
}

/// The app's built-in keys: `CloudDefaults.enc` from the bundle and the build's key shares.
actor CloudBuiltInKeys: CloudBuiltInKeysProviding {
    nonisolated let isBundled: Bool
    private let blobURL: URL?
    private let shares: [[UInt8]]
    private var loaded = false
    private var cached: CloudConfigInput?

    /// The app's: the bundled blob and the shares CI wrote.
    init(bundle: Bundle = .main, shares: [[UInt8]] = CloudDefaultsKey.shares) {
        let url = bundle.url(forResource: "CloudDefaults", withExtension: "enc")
        self.shares = shares
        blobURL = url
        isBundled = Self.isUsable(url, shares)
    }

    /// Any blob file and shares (AppTests).
    init(blobURL: URL?, shares: [[UInt8]]) {
        self.shares = shares
        self.blobURL = blobURL
        isBundled = Self.isUsable(blobURL, shares)
    }

    private nonisolated static func isUsable(_ url: URL?, _ shares: [[UInt8]]) -> Bool {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return false }
        return CloudDefaultsKeyShares.combine(shares) != nil
    }

    func load() -> CloudConfigInput? {
        if loaded { return cached }
        loaded = true
        guard isBundled, let blobURL, let key = CloudDefaultsKeyShares.combine(shares),
              let data = try? Data(contentsOf: blobURL), data.count <= CloudDefaultsBlob.maxBytes else { return nil }
        cached = CloudDefaultsCrypto.open(Array(data), key: key)?.configInput
        return cached
    }
}

/// Fixed built-in keys (AppTests and the UI-test demo), or none.
nonisolated struct CloudFixedBuiltInKeys: CloudBuiltInKeysProviding {
    let config: CloudConfigInput?
    var isBundled: Bool { config != nil }
    func load() async -> CloudConfigInput? { config }
}
