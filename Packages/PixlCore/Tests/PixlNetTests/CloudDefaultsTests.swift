import Foundation
import Testing
@testable import PixlNet

/// Built-in cloud keys, the pure half (2026-10-08): the blob's layout, the JSON inside it, the key's XOR shares and
/// which keys win. The AES-GCM round trip itself is CryptoKit's and is tested in AppTests (`CloudDefaultsTests`).
/// Every value here is a dummy.
@Suite struct CloudDefaultsTests {
    static let account = "0123456789abcdef0123456789abcdef"
    static let payload = CloudDefaultsPayload(runpodEndpointId: "dummyendpoint01", runpodKey: "rpa_DUMMY0000",
                                              r2Endpoint: "https://\(account).r2.cloudflarestorage.com",
                                              bucket: "pixl-cloud-studio", r2AccessKeyId: "DUMMYKEYID",
                                              r2SecretAccessKey: "dummy-secret")

    // MARK: Blob layout

    @Test func blobSplitsIntoNonceCiphertextAndTag() throws {
        let nonce = Array(1...12).map(UInt8.init)
        let ciphertext: [UInt8] = [0xAA, 0xBB, 0xCC]
        let tag = Array(repeating: UInt8(0x5A), count: 16)
        let bytes = Array("PXCD1".utf8) + nonce + ciphertext + tag
        let blob = try #require(CloudDefaultsBlob(bytes: bytes))
        #expect(blob.nonce == nonce)
        #expect(blob.ciphertext == ciphertext)
        #expect(blob.tag == tag)
        #expect(blob.bytes == bytes, "writing it back gives the same file")
    }

    @Test func anythingElseIsNotABlob() {
        let body = Array(repeating: UInt8(1), count: 12 + 8 + 16)
        #expect(CloudDefaultsBlob(bytes: Array("PXCD2".utf8) + body) == nil, "another format version")
        #expect(CloudDefaultsBlob(bytes: Array("pxcd1".utf8) + body) == nil)
        #expect(CloudDefaultsBlob(bytes: []) == nil)
        #expect(CloudDefaultsBlob(bytes: Array("PXCD1".utf8) + Array(repeating: 0, count: 28)) == nil,
                "nonce and tag but nothing encrypted")
        #expect(CloudDefaultsBlob(bytes: Array("PXCD1".utf8) + Array(repeating: 0, count: CloudDefaultsBlob.maxBytes))
                == nil, "too big to be one")
    }

    // MARK: The JSON inside

    @Test func payloadRoundTripsAndBecomesACompleteConfig() throws {
        let decoded = try #require(CloudDefaultsPayload.decode(Self.payload.encoded()))
        #expect(decoded == Self.payload)
        let config = decoded.configInput
        #expect(config.isComplete)
        #expect(config.trimmedEndpointId == "dummyendpoint01")
        #expect(config.location?.endpoint == "https://\(Self.account).r2.cloudflarestorage.com")
        #expect(config.location?.bucket == "pixl-cloud-studio")
        #expect(config.credentials == S3Credentials(accessKeyId: "DUMMYKEYID", secretAccessKey: "dummy-secret"))
    }

    @Test func theWritersJSONDecodes() throws {
        // Exactly what tools/cloud/bake-cloud-keys.mjs writes (JSON.stringify, its key order).
        let json = """
        {"v":1,"runpodEndpointId":"dummyendpoint01","runpodKey":"rpa_DUMMY0000","r2Endpoint":"https://\(Self.account).r2.cloudflarestorage.com","bucket":"pixl-cloud-studio","r2AccessKeyId":"DUMMYKEYID","r2SecretAccessKey":"dummy-secret"}
        """
        #expect(CloudDefaultsPayload.decode(Array(json.utf8)) == Self.payload)
    }

    @Test func anIncompleteOrNewerPayloadIsNoKeysAtAll() {
        var newer = Self.payload
        newer.v = 2
        #expect(CloudDefaultsPayload.decode(newer.encoded()) == nil)
        var noKey = Self.payload
        noKey.runpodKey = " "
        #expect(CloudDefaultsPayload.decode(noKey.encoded()) == nil)
        var badEndpoint = Self.payload
        badEndpoint.runpodEndpointId = "https://api.runpod.ai/v2/x"
        #expect(CloudDefaultsPayload.decode(badEndpoint.encoded()) == nil)
        var noSecret = Self.payload
        noSecret.r2SecretAccessKey = ""
        #expect(CloudDefaultsPayload.decode(noSecret.encoded()) == nil)
        #expect(CloudDefaultsPayload.decode(Array(#"{"v":1,"runpodKey":"rpa_X"}"#.utf8)) == nil, "fields missing")
        #expect(CloudDefaultsPayload.decode(Array("not json".utf8)) == nil)
        #expect(CloudDefaultsPayload.decode([]) == nil)
    }

    @Test func descriptionsNeverShowAKey() {
        for text in [String(describing: Self.payload), String(reflecting: Self.payload), "\(Self.payload)"] {
            #expect(!text.contains("rpa_DUMMY0000"))
            #expect(!text.contains("DUMMYKEYID"))
            #expect(!text.contains("dummy-secret"))
            #expect(!text.contains("dummyendpoint01"))
        }
        var dumped = ""
        dump(Self.payload, to: &dumped)
        #expect(!dumped.contains("dummy-secret") && !dumped.contains("rpa_DUMMY0000"))
    }

    // MARK: Key shares

    @Test func sharesCombineBackToTheKey() {
        let key = (0..<32).map { UInt8(($0 * 37 + 11) & 0xFF) }
        var seed: UInt8 = 7
        let shares = CloudDefaultsKeyShares.split(key, count: 4) {
            seed = seed &* 29 &+ 113
            return seed
        }
        #expect(shares.count == 4)
        #expect(shares.allSatisfy { $0.count == 32 })
        #expect(!shares.contains(key), "no share is the key itself")
        #expect(CloudDefaultsKeyShares.combine(shares) == key)
        #expect(CloudDefaultsKeyShares.combine([key]) == key, "one share is the key")
    }

    @Test func noSharesOrBadSharesAreNoKey() {
        #expect(CloudDefaultsKeyShares.combine([]) == nil, "the committed stub: no built-in keys in this build")
        #expect(CloudDefaultsKeyShares.combine([Array(repeating: 1, count: 32), Array(repeating: 2, count: 31)]) == nil)
        #expect(CloudDefaultsKeyShares.combine([Array(repeating: 1, count: 16)]) == nil, "AES-128 sized")
    }

    // MARK: Which keys win

    @Test func ownKeysWinOverBuiltInOnes() {
        #expect(CloudKeyChoice.source(useOwnKeys: true, builtInAvailable: true) == .own)
        #expect(CloudKeyChoice.source(useOwnKeys: false, builtInAvailable: true) == .builtIn)
        #expect(CloudKeyChoice.source(useOwnKeys: false, builtInAvailable: false) == .own,
                "no built-in keys in this build: the fields, as before")
        #expect(CloudKeyChoice.source(useOwnKeys: true, builtInAvailable: false) == .own)
    }

    @Test func anEarlierOwnSetupKeepsItsKeys() {
        #expect(!CloudKeyChoice.defaultUseOwnKeys(keysSaved: false, endpointId: ""))
        #expect(!CloudKeyChoice.defaultUseOwnKeys(keysSaved: false, endpointId: "  "))
        #expect(CloudKeyChoice.defaultUseOwnKeys(keysSaved: true, endpointId: ""))
        #expect(CloudKeyChoice.defaultUseOwnKeys(keysSaved: false, endpointId: "abc123xyz"))
        #expect(CloudKeyChoice.defaultEnabled(builtInAvailable: true))
        #expect(!CloudKeyChoice.defaultEnabled(builtInAvailable: false))
    }

    @Test func builtInKeysNeverSpendMoreThanThreeDollarsAMonth() {
        let cap = CloudKeyChoice.builtInMonthlyCapMicroUSD
        #expect(cap == CloudCost.defaultMonthlyCapMicroUSD)
        #expect(CloudKeyChoice.effectiveMonthlyCap(50_000_000, source: .builtIn) == cap)
        #expect(CloudKeyChoice.effectiveMonthlyCap(1_000_000, source: .builtIn) == 1_000_000, "a lower cap stays")
        #expect(CloudKeyChoice.effectiveMonthlyCap(50_000_000, source: .own) == 50_000_000, "own keys, own cap")
        #expect(CloudKeyChoice.effectiveMonthlyCap(-5, source: .builtIn) == 0)
    }

    @Test func builtInKeysNeverEstimateBelowTheEndpointsPrice() {
        let price = CloudCost.defaultPricePerSecondMicroUSD
        #expect(CloudKeyChoice.effectivePricePerSecond(1, source: .builtIn) == price, "a price typed lower")
        #expect(CloudKeyChoice.effectivePricePerSecond(price * 3, source: .builtIn) == price * 3, "a higher one stays")
        #expect(CloudKeyChoice.effectivePricePerSecond(1, source: .own) == 1, "own keys, own price")
    }

    @Test func theEmptyConfigIsNeverComplete() {
        #expect(!CloudConfigInput.empty.isComplete)
        #expect(!CloudConfigInput.empty.hasRunPod && !CloudConfigInput.empty.hasStorage)
    }
}
