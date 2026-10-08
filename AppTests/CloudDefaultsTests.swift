import CryptoKit
import Foundation
import PixlNet
import XCTest
@testable import PixlAudio

/// Built-in cloud keys (2026-10-08): the AES-GCM blob opened with CryptoKit, the loader, and how Cloud processing
/// chooses between built-in and own keys. Every key and value here is a dummy; nothing touches the network or the
/// Keychain. The pure half (layout, JSON, shares, rules) is PixlNet's `CloudDefaultsTests`.
@MainActor
final class CloudDefaultsTests: XCTestCase {
    static let dummyKey = (0..<32).map { UInt8(($0 * 13 + 5) & 0xFF) }
    static let otherKey = (0..<32).map { UInt8(($0 * 7 + 1) & 0xFF) }
    static let account = "0123456789abcdef0123456789abcdef"
    static let payload = CloudDefaultsPayload(runpodEndpointId: "builtin0endpoint", runpodKey: "rpa_BUILTIN0DUMMY",
                                              r2Endpoint: "https://\(account).r2.cloudflarestorage.com",
                                              bucket: "pixl-cloud-studio", r2AccessKeyId: "BUILTINKEYID",
                                              r2SecretAccessKey: "builtin-secret")
    /// The public throwaway key the committed placeholder blob uses (tools/cloud/bake-cloud-keys.mjs).
    static let placeholderKey = "8So6sYvJwxeya05DKvPe8+SXf78b9qOdon/a66BjyQw="
    /// The dummy key of `Fixtures/cloud_defaults_node.enc`, written by the bake script (Node's crypto) in --dry-run.
    static let nodeFixtureKey = "edmNcr6tlCGxCRzgO33ozLQN7WpOURGN7Xh6Md0YxzE="

    static func bytes(base64: String) -> [UInt8] { Array(Data(base64Encoded: base64) ?? Data()) }

    // MARK: Decryption

    func testRoundTripWithADummyKey() throws {
        let blob = try CloudDefaultsCrypto.seal(Self.payload, key: Self.dummyKey)
        XCTAssertEqual(Array(blob.prefix(5)), Array("PXCD1".utf8))
        XCTAssertEqual(blob.count, 5 + 12 + Self.payload.encoded().count + 16)
        let opened = try XCTUnwrap(CloudDefaultsCrypto.open(blob, key: Self.dummyKey))
        XCTAssertEqual(opened, Self.payload)
        XCTAssertTrue(opened.configInput.isComplete)
        let again = try CloudDefaultsCrypto.seal(Self.payload, key: Self.dummyKey)
        XCTAssertNotEqual(again, blob, "every blob has its own random nonce")
    }

    func testAWrongKeyOrATamperedBlobFailsSafely() throws {
        let blob = try CloudDefaultsCrypto.seal(Self.payload, key: Self.dummyKey)
        XCTAssertNil(CloudDefaultsCrypto.open(blob, key: Self.otherKey), "another key")
        XCTAssertNil(CloudDefaultsCrypto.open(blob, key: Array(Self.dummyKey.prefix(16))), "a 16-byte key")
        XCTAssertNil(CloudDefaultsCrypto.open(blob, key: []))
        for index in [5, 5 + 12, blob.count / 2, blob.count - 1] {  // nonce, ciphertext, middle, tag
            var tampered = blob
            tampered[index] ^= 0x01
            XCTAssertNil(CloudDefaultsCrypto.open(tampered, key: Self.dummyKey), "byte \(index) flipped")
        }
        XCTAssertNil(CloudDefaultsCrypto.open(Array(blob.dropLast()), key: Self.dummyKey), "truncated")
        XCTAssertNil(CloudDefaultsCrypto.open(blob + [0], key: Self.dummyKey), "a byte added")
        var magic = blob
        magic[4] = UInt8(ascii: "2")
        XCTAssertNil(CloudDefaultsCrypto.open(magic, key: Self.dummyKey), "another format")
        XCTAssertNil(CloudDefaultsCrypto.open([], key: Self.dummyKey))
        // Opens, but the JSON isn't a usable payload: no keys at all, not half of them.
        var incomplete = Self.payload
        incomplete.r2SecretAccessKey = ""
        let incompleteBlob = try CloudDefaultsCrypto.seal(incomplete, key: Self.dummyKey)
        XCTAssertNil(CloudDefaultsCrypto.open(incompleteBlob, key: Self.dummyKey))
    }

    /// The bake script's output (Node's AES-256-GCM) opens with CryptoKit: the two writers agree on the format.
    func testTheBakeScriptsBlobOpens() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cloud_defaults_node", withExtension: "enc"))
        let blob = Array(try Data(contentsOf: url))
        let payload = try XCTUnwrap(CloudDefaultsCrypto.open(blob, key: Self.bytes(base64: Self.nodeFixtureKey)))
        XCTAssertEqual(payload.runpodEndpointId, "fixture0endpoint")
        XCTAssertEqual(payload.runpodKey, "rpa_FIXTURE0NOT0REAL")
        XCTAssertEqual(payload.r2Endpoint, "https://\(Self.account).r2.cloudflarestorage.com")
        XCTAssertEqual(payload.bucket, "pixl-cloud-studio")
        XCTAssertEqual(payload.r2AccessKeyId, "aaaabbbbccccddddeeeeffff00001111")
        XCTAssertTrue(payload.configInput.isComplete)
        XCTAssertNil(CloudDefaultsCrypto.open(blob, key: Self.dummyKey))
    }

    /// The app bundles a blob, and it fits this build: with the CLOUD_DEFAULTS_KEY secret (CI) it opens with the
    /// build's key, unless it is still the committed placeholder; without it, it is at least a well-formed blob.
    func testTheBundledBlobFitsThisBuild() throws {
        let url = try XCTUnwrap(Bundle(for: CloudSettings.self).url(forResource: "CloudDefaults", withExtension: "enc"),
                                "App/Resources/CloudDefaults.enc is not in the app bundle")
        let blob = Array(try Data(contentsOf: url))
        XCTAssertNotNil(CloudDefaultsBlob(bytes: blob), "CloudDefaults.enc is not a PXCD1 blob")
        let isPlaceholder = CloudDefaultsCrypto.open(blob, key: Self.bytes(base64: Self.placeholderKey)) != nil
        guard let buildKey = CloudDefaultsKeyShares.combine(CloudDefaultsKey.shares) else {
            throw XCTSkip("This build has no CLOUD_DEFAULTS_KEY (the committed stub): no built-in keys to check.")
        }
        if CloudDefaultsCrypto.open(blob, key: buildKey) != nil { return }
        if isPlaceholder {
            throw XCTSkip("CloudDefaults.enc is still the placeholder: run tools/cloud/bake-cloud-keys.mjs.")
        }
        XCTFail("CloudDefaults.enc doesn't open with this build's CLOUD_DEFAULTS_KEY: run tools/cloud/bake-cloud-keys.mjs "
                + "again (it sets the secret and writes the blob together) and commit the blob")
    }

    // MARK: The loader

    private func blobFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CloudDefaults-\(UUID().uuidString).enc")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func shares(of key: [UInt8]) -> [[UInt8]] {
        CloudDefaultsKeyShares.split(key, count: 4) { UInt8.random(in: 0...255) }
    }

    func testTheLoaderOpensTheBlobOnceAndKeepsIt() async throws {
        let url = try blobFile(try CloudDefaultsCrypto.seal(Self.payload, key: Self.dummyKey))
        let keys = CloudBuiltInKeys(blobURL: url, shares: shares(of: Self.dummyKey))
        XCTAssertTrue(keys.isBundled)
        let config = await keys.load()
        XCTAssertEqual(config, Self.payload.configInput)
        try FileManager.default.removeItem(at: url)
        let cached = await keys.load()
        XCTAssertEqual(cached, Self.payload.configInput, "decrypted once, then kept in memory")
    }

    func testTheLoaderWithoutAKeyOrWithTheWrongOneHasNoKeys() async throws {
        let url = try blobFile(try CloudDefaultsCrypto.seal(Self.payload, key: Self.dummyKey))
        let stub = CloudBuiltInKeys(blobURL: url, shares: [])
        XCTAssertFalse(stub.isBundled, "the committed stub: no built-in keys in this build")
        let none = await stub.load()
        XCTAssertNil(none)
        let wrong = CloudBuiltInKeys(blobURL: url, shares: shares(of: Self.otherKey))
        XCTAssertTrue(wrong.isBundled, "a key and a blob, so it looks available until opened")
        let wrongResult = await wrong.load()
        XCTAssertNil(wrongResult)
        let noFile = CloudBuiltInKeys(blobURL: url.appendingPathExtension("missing"), shares: shares(of: Self.dummyKey))
        XCTAssertFalse(noFile.isBundled)
        XCTAssertFalse(CloudBuiltInKeys(blobURL: nil, shares: shares(of: Self.dummyKey)).isBundled)
    }

    // MARK: Which keys Cloud processing uses

    private func defaults() throws -> UserDefaults {
        let suite = "cloud-defaults-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    private static let ownSecrets = CloudSecrets(runpodKey: "rpa_OWN", accessKeyId: "OWNKEY", secretAccessKey: "OWNSECRET")
    private static var builtIn: CloudFixedBuiltInKeys { CloudFixedBuiltInKeys(config: payload.configInput) }

    func testBuiltInKeysWorkOutOfTheBox() async throws {
        let settings = CloudSettings(defaults: try defaults(), secrets: CloudMemorySecrets(), builtIn: Self.builtIn)
        XCTAssertTrue(settings.isEnabled, "on by default with built-in keys")
        XCTAssertTrue(settings.usesBuiltInKeys)
        XCTAssertFalse(settings.useOwnKeys)
        XCTAssertFalse(settings.configInput.isComplete, "nothing to send before the keys are opened")
        await settings.loadSecrets()
        XCTAssertEqual(settings.builtInState, .ready)
        XCTAssertEqual(settings.configInput, Self.payload.configInput)
        XCTAssertTrue(settings.isReady)
        XCTAssertEqual(settings.keySource, .builtIn)
        XCTAssertFalse(settings.keysMissing)
    }

    func testOwnKeysWinOverBuiltInOnes() async throws {
        let defaults = try defaults()
        let settings = CloudSettings(defaults: defaults, secrets: CloudMemorySecrets(Self.ownSecrets), builtIn: Self.builtIn)
        settings.endpointId = "own0endpoint"
        settings.r2Endpoint = Self.account
        await settings.loadSecrets()
        XCTAssertEqual(settings.configInput, Self.payload.configInput, "built-in until the person chooses their own")
        settings.useOwnKeys = true
        XCTAssertEqual(settings.keySource, .own)
        XCTAssertEqual(settings.configInput.trimmedEndpointId, "own0endpoint")
        XCTAssertEqual(settings.configInput.trimmedRunpodKey, "rpa_OWN")
        XCTAssertEqual(settings.configInput.credentials.accessKeyId, "OWNKEY")
        XCTAssertEqual(CloudSettings(defaults: defaults, secrets: CloudMemorySecrets(), builtIn: Self.builtIn).useOwnKeys,
                       true, "the choice is kept")
        settings.useOwnKeys = false
        XCTAssertEqual(settings.configInput, Self.payload.configInput)
    }

    func testAnEarlierOwnSetupKeepsUsingItsOwnKeys() async throws {
        let defaults = try defaults()
        // Set up with own keys before built-in keys existed.
        let before = CloudSettings(defaults: defaults, secrets: CloudMemorySecrets())
        before.isEnabled = true
        before.endpointId = "own0endpoint"
        before.r2Endpoint = Self.account
        let store = CloudMemorySecrets()
        await CloudSettings(defaults: defaults, secrets: store).updateSecrets(Self.ownSecrets)
        // The update with built-in keys.
        let after = CloudSettings(defaults: defaults, secrets: store, builtIn: Self.builtIn)
        XCTAssertTrue(after.useOwnKeys)
        await after.loadSecrets()
        XCTAssertEqual(after.keySource, .own)
        XCTAssertEqual(after.configInput.trimmedEndpointId, "own0endpoint")
        XCTAssertTrue(after.isEnabled)
    }

    func testWithoutBuiltInKeysNothingChanges() async throws {
        let settings = CloudSettings(defaults: try defaults(), secrets: CloudMemorySecrets())
        XCTAssertFalse(settings.isEnabled, "off until the person switches it on, as before")
        XCTAssertFalse(settings.builtInAvailable)
        XCTAssertFalse(settings.usesBuiltInKeys)
        await settings.loadSecrets()
        XCTAssertEqual(settings.builtInState, .none)
        XCTAssertEqual(settings.configInput, settings.ownConfigInput)
        XCTAssertFalse(settings.configInput.isComplete)
        XCTAssertEqual(settings.effectiveMonthlyCapMicroUSD, settings.monthlyCapMicroUSD)
    }

    func testABlobThatDoesntOpenFallsBackToTheOldBehaviour() async throws {
        let settings = CloudSettings(defaults: try defaults(), secrets: CloudMemorySecrets(), builtIn: FailingBuiltInKeys())
        XCTAssertTrue(settings.builtInAvailable, "bundled, not opened yet")
        await settings.loadSecrets()
        XCTAssertEqual(settings.builtInState, .failed)
        XCTAssertFalse(settings.builtInAvailable)
        XCTAssertFalse(settings.isEnabled, "the default follows the keys that actually opened")
        XCTAssertFalse(settings.usesBuiltInKeys)
        XCTAssertEqual(settings.configInput, settings.ownConfigInput)
    }

    func testTheConsentSwitchKeepsThePersonsChoice() throws {
        let defaults = try defaults()
        let settings = CloudSettings(defaults: defaults, secrets: CloudMemorySecrets(), builtIn: Self.builtIn)
        settings.isEnabled = false
        XCTAssertFalse(CloudSettings(defaults: defaults, secrets: CloudMemorySecrets(), builtIn: Self.builtIn).isEnabled)
        settings.isEnabled = true
        XCTAssertTrue(CloudSettings(defaults: defaults, secrets: CloudMemorySecrets()).isEnabled,
                      "a choice made stays, even in a build without built-in keys")
    }

    func testBuiltInKeysSpendAtMostThreeDollarsAMonth() throws {
        let settings = CloudSettings(defaults: try defaults(), secrets: CloudMemorySecrets(), builtIn: Self.builtIn)
        settings.monthlyCapMicroUSD = 25_000_000
        XCTAssertEqual(settings.effectiveMonthlyCapMicroUSD, 3_000_000)
        settings.monthlyCapMicroUSD = 1_000_000
        XCTAssertEqual(settings.effectiveMonthlyCapMicroUSD, 1_000_000)
        settings.monthlyCapMicroUSD = 25_000_000
        settings.useOwnKeys = true
        XCTAssertEqual(settings.effectiveMonthlyCapMicroUSD, 25_000_000, "own keys, own cap")
    }

    func testSwitchingKeysForgetsTheEndpointsLimits() throws {
        let settings = CloudSettings(defaults: try defaults(), secrets: CloudMemorySecrets(), builtIn: Self.builtIn)
        settings.workerCaps = CloudWorkerCaps(maxInputMB: 160, maxAudioS: 900, hostsConfigured: 1)
        settings.useOwnKeys = true
        XCTAssertNil(settings.workerCaps, "another endpoint's limits are unknown")
    }

    // MARK: The orchestrator with built-in keys

    func testASongGoesOutWithTheBuiltInKeys() async throws {
        let h = CloudHarness(builtIn: Self.builtIn, ownKeys: false)
        XCTAssertTrue(h.settings.usesBuiltInKeys)
        let key = try await h.submittedJob()
        XCTAssertEqual(h.studio.job(key)?.runpodJobId, "rp-1")
        XCTAssertEqual(h.configs.runpod.last, Self.payload.configInput, "RunPod was called with the built-in keys")
        XCTAssertEqual(h.configs.objects.last, Self.payload.configInput, "the bucket was signed with the built-in keys")
    }

    func testTheBuiltInCapIsWhatTheConfirmSheetChecks() async throws {
        let h = CloudHarness(builtIn: Self.builtIn, ownKeys: false)
        h.settings.monthlyCapMicroUSD = 100_000_000
        let song = h.addSong("f:root/a.m4a")
        let preview = await h.studio.preview(songs: [song], title: "One")
        XCTAssertEqual(preview.estimate.capMicroUSD, 3_000_000, "the field says $100, the built-in keys allow $3")
        XCTAssertTrue(preview.estimate.fitsCap)
    }

    func testNothingStartsAtLaunchWhenNothingWasSent() async throws {
        let h = CloudHarness(builtIn: Self.builtIn, ownKeys: false)
        h.studio.resume()
        await h.studio.pump()
        XCTAssertEqual(h.configs.transfersMade, 0, "no background session for nobody's songs")
        XCTAssertNil(h.studio.notice)
        let runs = await h.runpod.runs.count
        XCTAssertEqual(runs, 0)
    }

    func testBuiltInKeysThatDontOpenSendNothing() async throws {
        let h = CloudHarness(builtIn: FailingBuiltInKeys(), ownKeys: false)
        let song = h.addSong("f:root/a.m4a")
        await h.studio.send(await h.studio.preview(songs: [song], title: "Test"))
        await h.studio.pump()
        XCTAssertTrue(h.studio.jobs.isEmpty, "nothing is queued once the keys turned out not to open")
        XCTAssertEqual(h.studio.notice, .off)
        XCTAssertTrue(h.transfers.uploads.isEmpty)
        let runs = await h.runpod.runs.count
        XCTAssertEqual(runs, 0)
    }
}

/// Bundled but the blob doesn't open (another key, damaged).
nonisolated struct FailingBuiltInKeys: CloudBuiltInKeysProviding {
    var isBundled: Bool { true }
    func load() async -> CloudConfigInput? { nil }
}
