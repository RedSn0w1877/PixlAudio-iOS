// Built-in cloud keys (2026-10-08, owner request: cloud instrumentals work out of the box, nothing to fill in).
// The app bundles `CloudDefaults.enc`, an AES-256-GCM blob holding the owner's RunPod endpoint, a Restricted RunPod key
// and a bucket-scoped R2 key pair; the 32-byte key that opens it is not in the repository: CI writes it into the build
// from the `CLOUD_DEFAULTS_KEY` secret, split into XOR shares (`App/Generated/CloudDefaultsKey.swift`). Builds without
// the secret (forks, pull requests, local builds) simply have no built-in keys and behave as before.
//
// This file is the pure part (the blob's layout, the JSON inside, the shares and which keys win); the decryption
// itself is CryptoKit's `AES.GCM.open` in the app (`CloudDefaultsCrypto`), since PixlCore has no CryptoKit.
// Writers: `tools/cloud/bake-cloud-keys.mjs` (Node's crypto) and the tests. The Android app reads the same format.

import Foundation

/// The bundled blob: ASCII `PXCD1`, a 12-byte random nonce, then the AES-256-GCM ciphertext followed by its 16-byte
/// tag (what Node's `cipher.final()` + `getAuthTag()` and CryptoKit's `combined` minus the nonce both give).
public struct CloudDefaultsBlob: Sendable, Equatable {
    public static let magic: [UInt8] = Array("PXCD1".utf8)
    public static let nonceLength = 12
    public static let tagLength = 16
    /// AES-256.
    public static let keyLength = 32
    /// The blob is a few hundred bytes; anything this big isn't one (the loader never reads more).
    public static let maxBytes = 16_384

    public let nonce: [UInt8]
    public let ciphertext: [UInt8]
    public let tag: [UInt8]

    public init(nonce: [UInt8], ciphertext: [UInt8], tag: [UInt8]) {
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }

    /// Splits a blob read from disk; nil when it isn't one (wrong magic, too short, nothing encrypted, too big).
    public init?(bytes: [UInt8]) {
        let header = Self.magic.count + Self.nonceLength
        guard bytes.count <= Self.maxBytes, bytes.count > header + Self.tagLength,
              Array(bytes.prefix(Self.magic.count)) == Self.magic else { return nil }
        nonce = Array(bytes[Self.magic.count..<header])
        ciphertext = Array(bytes[header..<(bytes.count - Self.tagLength)])
        tag = Array(bytes.suffix(Self.tagLength))
    }

    /// The file's bytes.
    public var bytes: [UInt8] { Self.magic + nonce + ciphertext + tag }
}

/// What the blob decrypts to (UTF-8 JSON, schema `v` 1). `description` never shows a key: the values must not reach a
/// log, a crash report or a test failure message.
public struct CloudDefaultsPayload: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public static let version = 1

    public var v: Int
    public var runpodEndpointId: String
    public var runpodKey: String
    /// `https://<account-id>.r2.cloudflarestorage.com` (or the bare account ID, like the settings field).
    public var r2Endpoint: String
    public var bucket: String
    public var r2AccessKeyId: String
    public var r2SecretAccessKey: String

    public init(runpodEndpointId: String, runpodKey: String, r2Endpoint: String, bucket: String, r2AccessKeyId: String,
                r2SecretAccessKey: String) {
        v = Self.version
        self.runpodEndpointId = runpodEndpointId
        self.runpodKey = runpodKey
        self.r2Endpoint = r2Endpoint
        self.bucket = bucket
        self.r2AccessKeyId = r2AccessKeyId
        self.r2SecretAccessKey = r2SecretAccessKey
    }

    /// The decrypted bytes as a payload, or nil when they aren't a complete v1 one (any field missing, empty or not
    /// usable by the clients). A blob that opens but is unusable counts as no built-in keys at all.
    public static func decode(_ bytes: [UInt8]) -> CloudDefaultsPayload? {
        guard let payload = try? JSONDecoder().decode(CloudDefaultsPayload.self, from: Data(bytes)),
              payload.v == version, payload.configInput.isComplete else { return nil }
        return payload
    }

    /// The JSON the writers produce (sorted keys, so a blob's plaintext is reproducible in tests).
    public func encoded() -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { Array($0) } ?? []
    }

    /// The fields as the settings screen would hold them.
    public var configInput: CloudConfigInput {
        CloudConfigInput(endpointId: runpodEndpointId, runpodKey: runpodKey, endpoint: r2Endpoint, bucket: bucket,
                         accessKeyId: r2AccessKeyId, secretAccessKey: r2SecretAccessKey)
    }

    public var description: String { "CloudDefaultsPayload(v\(v), redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["v": v], displayStyle: .struct) }
}

/// The decryption key as the build carries it: several XOR shares of 32 bytes each (`App/Generated/CloudDefaultsKey
/// .swift`, written on CI by `ci/write-cloud-defaults-key.sh`), so it never sits in the binary as one string. Light
/// obfuscation, not protection: anyone with the app can rebuild it (see the README's "Built-in cloud keys").
public enum CloudDefaultsKeyShares {
    /// The key: every share XORed together. Nil when there are no shares (the committed stub: no built-in keys in
    /// this build) or a share isn't 32 bytes.
    public static func combine(_ shares: [[UInt8]]) -> [UInt8]? {
        guard let first = shares.first, first.count == CloudDefaultsBlob.keyLength,
              shares.allSatisfy({ $0.count == CloudDefaultsBlob.keyLength }) else { return nil }
        var key = first
        for share in shares.dropFirst() {
            for index in key.indices { key[index] ^= share[index] }
        }
        return key
    }

    /// `count` shares of `key`: `count - 1` from `random`, the last one the key XOR all of them (what the CI script
    /// does in bash; here for the tests).
    public static func split(_ key: [UInt8], count: Int, random: () -> UInt8) -> [[UInt8]] {
        guard count >= 1 else { return [] }
        var shares: [[UInt8]] = []
        var last = key
        for _ in 1..<count {
            let share = key.map { _ in random() }
            for index in last.indices { last[index] ^= share[index] }
            shares.append(share)
        }
        shares.append(last)
        return shares
    }
}

/// Whose keys a job goes out with.
public enum CloudKeySource: String, Sendable, Hashable {
    /// PixlAudio's built-in keys (the owner's endpoint and bucket).
    case builtIn
    /// The person's own, typed in Cloud processing (the only kind before 2026-10-08).
    case own
}

/// The rules between built-in and own keys (Settings › Developer › Experimental › Cloud processing).
public enum CloudKeyChoice {
    /// Built-in keys may spend at most this much a month on one phone, whatever the cap field says (the app's $3
    /// monthly cap stays; own keys keep the person's own cap).
    public static let builtInMonthlyCapMicroUSD: Int64 = 3_000_000

    /// Own keys win whenever the person chose them; otherwise the built-in ones when this build has them; otherwise
    /// own (the old behaviour: the fields, empty until filled in).
    public static func source(useOwnKeys: Bool, builtInAvailable: Bool) -> CloudKeySource {
        !useOwnKeys && builtInAvailable ? .builtIn : .own
    }

    /// "Use my own keys" before the person ever touched it: on for someone who set the feature up with their own
    /// keys before built-in ones existed (saved keys, or an Endpoint ID typed in), so their setup keeps working.
    public static func defaultUseOwnKeys(keysSaved: Bool, endpointId: String) -> Bool {
        keysSaved || !endpointId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The consent switch before the person ever touched it: on when the build has built-in keys (jobs still only go
    /// when the person sends songs), off otherwise (nothing configured, as before).
    public static func defaultEnabled(builtInAvailable: Bool) -> Bool { builtInAvailable }

    /// The cap the money guards use.
    public static func effectiveMonthlyCap(_ capMicroUSD: Int64, source: CloudKeySource) -> Int64 {
        source == .builtIn ? min(max(capMicroUSD, 0), builtInMonthlyCapMicroUSD) : capMicroUSD
    }
}

extension CloudConfigInput {
    /// No fields at all (built-in keys chosen but not decrypted, or unusable): never complete, so nothing is sent.
    public static let empty = CloudConfigInput(endpointId: "", runpodKey: "", endpoint: "", bucket: "", accessKeyId: "",
                                               secretAccessKey: "")
}
