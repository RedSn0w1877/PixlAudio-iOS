import Foundation
import Testing
@testable import PixlNet

/// HMAC-SHA-256 (RFC 2104) on the test SHA-256; the app injects CryptoKit's `HMAC<SHA256>`.
enum TestHMAC {
    static func sha256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var k = key.count > 64 ? TestSHA256.hash(key) : key
        k += [UInt8](repeating: 0, count: 64 - k.count)
        let inner = TestSHA256.hash(k.map { $0 ^ 0x36 } + message)
        return TestSHA256.hash(k.map { $0 ^ 0x5c } + inner)
    }
}

/// AWS's published SigV4 examples for S3 (docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html and
/// sigv4-query-string-auth.html): bucket `examplebucket`, us-east-1, 2013-05-24T00:00:00Z.
@Suite struct S3SignerTests {
    static let awsCredentials = S3Credentials(accessKeyId: "AKIAIOSFODNN7EXAMPLE",
                                              secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    static let awsLocation = S3Location(endpoint: "https://s3.amazonaws.com", bucket: "examplebucket",
                                        region: "us-east-1", virtualHosted: true)
    static let may24: Int64 = 1_369_353_600

    static func signer(_ location: S3Location = awsLocation, _ credentials: S3Credentials = awsCredentials) -> S3Signer {
        S3Signer(credentials: credentials, location: location, sha256: { TestSHA256.hash($0) },
                 hmac: { TestHMAC.sha256(key: $0, message: $1) })
    }

    @Test func hmacMatchesRFC4231Case2() {
        let mac = TestHMAC.sha256(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8))
        #expect(hexString(mac) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    @Test func presignedGetMatchesAWSExample() {
        let url = Self.signer().presignedURL(method: .get, key: "test.txt", expiresSeconds: 86_400, nowSeconds: Self.may24)
        #expect(url == "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256"
            + "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
            + "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host"
            + "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
    }

    @Test func headerSignedGetObjectMatchesAWSExample() throws {
        let request = try #require(Self.signer().signedRequest(method: .get, key: "test.txt",
                                                               headers: [HTTPHeader("Range", "bytes=0-9")],
                                                               payloadSHA256: S3Signer.emptyPayloadSHA256,
                                                               nowSeconds: Self.may24))
        #expect(request.url == "https://examplebucket.s3.amazonaws.com/test.txt")
        #expect(request.header("Authorization") == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"
            + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,"
            + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        #expect(request.header("x-amz-date") == "20130524T000000Z")
        #expect(request.header("range") == "bytes=0-9")
    }

    @Test func headerSignedListObjectsMatchesAWSExample() throws {
        let request = try #require(Self.signer().signedRequest(method: .get, key: "", query: [("max-keys", "2"), ("prefix", "J")],
                                                               payloadSHA256: S3Signer.emptyPayloadSHA256,
                                                               nowSeconds: Self.may24))
        #expect(request.url == "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")
        #expect(request.header("Authorization")?.hasSuffix(
            "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true)
    }

    @Test func headerSignedBucketLifecycleMatchesAWSExample() throws {
        let request = try #require(Self.signer().signedRequest(method: .get, key: "", query: [("lifecycle", "")],
                                                               payloadSHA256: S3Signer.emptyPayloadSHA256,
                                                               nowSeconds: Self.may24))
        #expect(request.header("Authorization")?.hasSuffix(
            "Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543") == true)
    }

    @Test func r2UsesPathStyleAndAutoRegion() throws {
        let location = S3Location(endpoint: "https://0123abc.r2.cloudflarestorage.com/", bucket: "pixl-cloud-studio")
        #expect(location.isValid)
        let url = try #require(Self.signer(location).presignedURL(method: .put, key: "in/6f1c.m4a", expiresSeconds: 3600,
                                                                  nowSeconds: Self.may24))
        #expect(url.hasPrefix("https://0123abc.r2.cloudflarestorage.com/pixl-cloud-studio/in/6f1c.m4a?"))
        #expect(url.contains("X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fauto%2Fs3%2Faws4_request"))
        #expect(url.contains("X-Amz-Expires=3600"))
        #expect(url.contains("X-Amz-SignedHeaders=host"))
        // Only the query carries the signature; nothing else secret is in the URL.
        #expect(!url.contains(Self.awsCredentials.secretAccessKey))
    }

    @Test func presignedListKeepsItsQueryInTheSignature() throws {
        let location = S3Location(endpoint: "https://acct.r2.cloudflarestorage.com", bucket: "pixl-cloud-studio")
        let signer = Self.signer(location)
        let query = S3ListResult.query(prefix: "out/", delimiter: "/", continuationToken: nil)
        let a = try #require(signer.presignedURL(method: .get, key: "", query: query, expiresSeconds: 900, nowSeconds: Self.may24))
        let b = try #require(signer.presignedURL(method: .get, key: "", query: [("list-type", "2")], expiresSeconds: 900,
                                                 nowSeconds: Self.may24))
        #expect(a.hasPrefix("https://acct.r2.cloudflarestorage.com/pixl-cloud-studio?X-Amz-Algorithm="))
        #expect(a.contains("&delimiter=%2F&list-type=2&max-keys=1000&prefix=out%2F&X-Amz-Signature="))
        #expect(a.suffix(64) != b.suffix(64))
    }

    @Test func expiryIsClampedToSevenDays() throws {
        let url = try #require(Self.signer().presignedURL(method: .get, key: "a", expiresSeconds: 10_000_000, nowSeconds: Self.may24))
        #expect(url.contains("X-Amz-Expires=604800"))
        #expect(CloudTiming.workerPresignSeconds == 259_200 + 900 + 3_600)
        #expect(CloudTiming.workerPresignSeconds <= S3Signer.maximumExpirySeconds)
    }

    @Test func uriEncodingFollowsAWSRules() {
        #expect(S3Signer.uriEncode("a b/c~d_e.f-g", encodeSlash: false) == "a%20b/c~d_e.f-g")
        #expect(S3Signer.uriEncode("a/b", encodeSlash: true) == "a%2Fb")
        #expect(S3Signer.uriEncode("가$", encodeSlash: true) == "%EA%B0%80%24")
    }

    @Test func amzDateIsUTC() {
        #expect(S3Signer.amzDate(0) == "19700101T000000Z")
        #expect(S3Signer.amzDate(Self.may24) == "20130524T000000Z")
        #expect(S3Signer.amzDate(1_790_812_799) == "20260930T235959Z")
        #expect(S3Signer.amzDate(951_782_400) == "20000229T000000Z")
    }

    @Test func locationValidation() {
        #expect(!S3Location(endpoint: "http://x.r2.cloudflarestorage.com", bucket: "abc").isValid)
        #expect(!S3Location(endpoint: "https://", bucket: "abc").isValid)
        #expect(!S3Location(endpoint: "https://x.com", bucket: "AB").isValid)
        #expect(!S3Location(endpoint: "https://x.com", bucket: "-abc").isValid)
        #expect(S3Location(endpoint: "https://x.com:8443/path", bucket: "a.b-c").endpointHost == "x.com:8443")
    }

    @Test func listResultParses() throws {
        let result = try #require(S3ListResult.parse(try CloudFixtures.text("s3.list", "xml")))
        #expect(result.objects == [S3ListResult.Object(key: "out/readme&notes.txt", size: 12,
                                                       lastModified: "2026-10-07T10:00:00.000Z")])
        #expect(result.commonPrefixes == ["out/6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10/", "out/0a1b2c3d-0000-4000-8000-000000000001/"])
        #expect(!result.isTruncated)
        #expect(result.commonPrefixes.compactMap(CloudKeys.jobKey(fromOutputKey:)).count == 2)
        #expect(S3ListResult.parse("<Error><Code>AccessDenied</Code></Error>") == nil)
    }
}
