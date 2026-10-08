import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

@Suite struct RunPodJobsClientTests {
    static let endpoint = "abc123xyz"

    static func client(_ http: FixtureHTTPClient, clock: Box<Int64> = Box(1_000_000),
                       slept: Box<[Int64]> = Box([])) -> RunPodJobsClient {
        RunPodJobsClient(http: http, endpointId: endpoint, apiKey: " rpa_KEY ",
                         nowMs: { clock.value },
                         sleep: { ms in slept.mutate { $0.append(ms) }; clock.mutate { $0 += ms } })
    }

    static func sampleRequest() -> CloudJobRequest {
        CloudJobRequest(input: CloudJobInput(jobKey: "6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10", storage: "presigned",
                                             tasks: ["instrumental"]),
                        policy: CloudJobPolicy(ttl: CloudTiming.ttlMs, executionTimeout: CloudTiming.executionTimeoutMs))
    }

    @Test func runPostsTheJobWithTheKey() async throws {
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: #"{"id":"job-1","status":"IN_QUEUE"}"#) }
        let job = try await Self.client(http).run(Self.sampleRequest())
        #expect(job.id == "job-1")
        #expect(job.typedStatus == .inQueue)
        let request = try #require(http.requests.first)
        #expect(request.method == .post)
        #expect(request.url == "https://api.runpod.ai/v2/abc123xyz/run")
        #expect(request.header("Authorization") == "Bearer rpa_KEY")
        #expect(request.header("Content-Type") == "application/json")
        let body = try JSONParser().parse(utf8: [UInt8](try #require(request.body)))
        #expect(body["input"]?["jobKey"]?.stringValue == "6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10")
        #expect(body["policy"]?["executionTimeout"]?.int64Value == 900_000)
    }

    @Test func runsAreAtLeast100msApart() async throws {
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: #"{"id":"j","status":"IN_QUEUE"}"#) }
        let slept = Box<[Int64]>([])
        let client = Self.client(http, slept: slept)
        _ = try await client.run(Self.sampleRequest())
        _ = try await client.run(Self.sampleRequest())
        #expect(slept.value == [100])
        #expect(http.requests.count == 2)
    }

    @Test func runIsNeverRetried() async throws {
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 502, text: "bad gateway") }
        await #expect(throws: RunPodError.server(status: 502)) { try await Self.client(http).run(Self.sampleRequest()) }
        #expect(http.requests.count == 1)
    }

    @Test func statusReadsProgress() async throws {
        let body = try CloudFixtures.text("runpod.status.inprogress")
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: body) }
        let job = try await Self.client(http).status(jobId: "1f2e3d4c-aaaa-bbbb-cccc-1234567890ab-u1")
        #expect(job.typedStatus == .inProgress)
        #expect(job.progress == CloudProgress(stage: "separate", percent: 40))
        #expect(job.progress?.label == "Separating vocals")
        #expect(job.delayTimeMs == 2_210)
        #expect(http.requests.first?.url == "https://api.runpod.ai/v2/abc123xyz/status/1f2e3d4c-aaaa-bbbb-cccc-1234567890ab-u1")
        #expect(http.requests.first?.method == .get)
    }

    @Test func completedStatusCarriesTheManifest() async throws {
        let manifest = try CloudFixtures.text("job.result.ok")
        let body = #"{"id":"j1","status":"COMPLETED","executionTime":19400,"output":"# + manifest + "}"
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: body) }
        let job = try await Self.client(http).status(jobId: "j1")
        #expect(job.typedStatus == .completed)
        #expect(job.typedStatus?.isFinal == true)
        #expect(job.result?.typedStatus == .ok)
        #expect(job.result?.outputs?["instrumental"]?.bytes == 7_801_234)
    }

    @Test func failedStatusCarriesTheWorkerCode() async throws {
        let body = try CloudFixtures.text("runpod.status.failed")
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: body) }
        let job = try await Self.client(http).status(jobId: "j-failed-1")
        #expect(job.typedStatus == .failed)
        #expect(job.errorCode == .poisoned)
    }

    @Test func statusNotFoundMeansExpired() async throws {
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 404, text: "") }
        await #expect(throws: RunPodError.jobNotFound) { try await Self.client(http).status(jobId: "gone") }
        await #expect(throws: RunPodError.endpointNotFound) { try await Self.client(http).health() }
    }

    @Test func unauthorizedIsReported() async throws {
        for code in [401, 403] {
            let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: code, text: "") }
            await #expect(throws: RunPodError.unauthorized(status: code)) { try await Self.client(http).health() }
        }
    }

    @Test func rateLimitGateFailsFastUntilItEnds() async throws {
        let calls = Box(0)
        let http = FixtureHTTPClient { _ in
            calls.mutate { $0 += 1 }
            return calls.value == 1 ? HTTPResponse(statusCode: 429, headers: [HTTPHeader("Retry-After", "7")], text: "")
                : HTTPResponse(statusCode: 200, text: #"{"id":"j","status":"IN_QUEUE"}"#)
        }
        let clock = Box<Int64>(1_000_000)
        let client = Self.client(http, clock: clock)
        await #expect(throws: RunPodError.rateLimited(retryAfterMs: 7_000)) { try await client.status(jobId: "j") }
        clock.value += 3_000
        await #expect(throws: RunPodError.rateLimited(retryAfterMs: 4_000)) { try await client.status(jobId: "j") }
        #expect(http.requests.count == 1)
        clock.value += 4_000
        #expect(try await client.status(jobId: "j").id == "j")
    }

    @Test func readsRetryServerErrorsWithBackoff() async throws {
        let calls = Box(0)
        let http = FixtureHTTPClient { _ in
            calls.mutate { $0 += 1 }
            if calls.value < 3 { return HTTPResponse(statusCode: 503, text: "") }
            return HTTPResponse(statusCode: 200, text: try CloudFixtures.text("runpod.health"))
        }
        let slept = Box<[Int64]>([])
        let health = try await Self.client(http, slept: slept).health()
        #expect(slept.value == [1_000, 3_000])
        #expect(health.inQueue == 3)
        #expect(health.runningWorkers == 1)
        #expect(health.idleWorkers == 0)
    }

    @Test func readsGiveUpAfterThreeTries() async throws {
        let http = FixtureHTTPClient { _ in throw HTTPTransportError(message: "offline") }
        await #expect(throws: RunPodError.network("IOException: offline")) { try await Self.client(http).health() }
        #expect(http.requests.count == 3)
    }

    @Test func selftestUsesRunsync() async throws {
        let body = try CloudFixtures.text("runpod.selftest")
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: body) }
        let job = try await Self.client(http).selftest(build: "1.0 (1)")
        #expect(http.requests.first?.url == "https://api.runpod.ai/v2/abc123xyz/runsync")
        #expect(job.result == nil)
        #expect(job.outputJSON?["worker"]?["gpu"]?.stringValue == "NVIDIA L4")
        #expect(job.outputJSON?["supported"]?.arrayValue?.first?.int64Value == 1)
        let sent = try JSONParser().parse(utf8: [UInt8](try #require(http.requests.first?.body)))
        #expect(sent["input"]?["op"]?.stringValue == "selftest")
        #expect(sent["input"]?["audio"] == nil)
    }

    @Test func badIdentifiersNeverReachTheNetwork() async throws {
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: "{}") }
        let bad = RunPodJobsClient(http: http, endpointId: "../billing", apiKey: "k")
        await #expect(throws: RunPodError.notConfigured) { try await bad.health() }
        let noKey = RunPodJobsClient(http: http, endpointId: "abc", apiKey: "  ")
        await #expect(throws: RunPodError.notConfigured) { try await noKey.health() }
        await #expect(throws: RunPodError.jobNotFound) { try await Self.client(http).status(jobId: "a/b") }
        #expect(http.requests.isEmpty)
        #expect(RunPodJobsClient.isValidEndpointId("kjoa5h86wrpf2q"))
    }

    @Test func progressParsing() {
        #expect(CloudProgress.parse("lyrics:100") == CloudProgress(stage: "lyrics", percent: 100))
        #expect(CloudProgress.parse("encode") == CloudProgress(stage: "encode", percent: nil))
        #expect(CloudProgress.parse("separate:140")?.percent == 100)
        #expect(CloudProgress.parse("{\"a\":1}") == nil)
        #expect(CloudProgress.parse("") == nil)
    }
}

@Suite struct CloudObjectClientTests {
    static func client(_ http: FixtureHTTPClient) -> CloudObjectClient {
        let signer = S3Signer(credentials: S3Credentials(accessKeyId: "AKID", secretAccessKey: "SECRET"),
                              location: S3Location(endpoint: "https://acct.r2.cloudflarestorage.com", bucket: "pixl-cloud-studio"),
                              sha256: { TestSHA256.hash($0) }, hmac: { TestHMAC.sha256(key: $0, message: $1) })
        return CloudObjectClient(http: http, signer: signer, nowSeconds: { 1_790_812_800 })
    }

    @Test func headReturnsSizeOrNil() async throws {
        let http = FixtureHTTPClient { request in
            request.url.contains("missing") ? HTTPResponse(statusCode: 404, text: "")
                : HTTPResponse(statusCode: 200, headers: [HTTPHeader("Content-Length", "1234")], text: "")
        }
        let client = Self.client(http)
        #expect(try await client.head(key: "out/k/manifest.json") == 1234)
        #expect(try await client.head(key: "out/missing/manifest.json") == nil)
        let request = try #require(http.requests.first)
        #expect(request.method == .head)
        #expect(request.header("Authorization") == nil)
        #expect(request.url.hasPrefix("https://acct.r2.cloudflarestorage.com/pixl-cloud-studio/out/k/manifest.json?X-Amz-"))
    }

    @Test func putSendsTheBodyAndType() async throws {
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: "") }
        try await Self.client(http).put(key: "probe/x", data: Data([1]), contentType: "application/octet-stream")
        let request = try #require(http.requests.first)
        #expect(request.method == .put)
        #expect(request.body == Data([1]))
        #expect(request.header("Content-Type") == "application/octet-stream")
    }

    @Test func deleteOfAMissingObjectSucceeds() async throws {
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 404, text: "<Error><Code>NoSuchKey</Code></Error>") }
        try await Self.client(http).delete(key: "in/x.m4a")
        let bucketGone = FixtureHTTPClient { _ in HTTPResponse(statusCode: 404, text: "<Error><Code>NoSuchBucket</Code></Error>") }
        await #expect(throws: CloudStorageError.bucketNotFound) { try await Self.client(bucketGone).delete(key: "in/x.m4a") }
    }

    @Test func forbiddenIsUnauthorized() async throws {
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 403, text: "<Error><Code>AccessDenied</Code></Error>") }
        await #expect(throws: CloudStorageError.unauthorized(status: 403)) { _ = try await Self.client(http).get(key: "a") }
    }

    @Test func listFollowsContinuationTokens() async throws {
        let page1 = """
        <ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>tok/1</NextContinuationToken>\
        <Contents><Key>out/a/manifest.json</Key><Size>10</Size></Contents></ListBucketResult>
        """
        let page2 = "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>out/b/manifest.json</Key><Size>11</Size></Contents></ListBucketResult>"
        let http = FixtureHTTPClient { request in
            HTTPResponse(statusCode: 200, text: request.url.contains("continuation-token=tok%2F1") ? page2 : page1)
        }
        let result = try await Self.client(http).list(prefix: "out/", delimiter: nil)
        #expect(result.objects.map(\.key) == ["out/a/manifest.json", "out/b/manifest.json"])
        #expect(http.requests.count == 2)
    }

    @Test func redactionHidesSignatures() {
        let text = "failed: https://h/p?X-Amz-Algorithm=A&X-Amz-Signature=deadbeef and https://h/q?list-type=2&X-Amz-Credential=AK/x)"
        let redacted = CloudRedaction.redact(text)
        #expect(!redacted.contains("deadbeef"))
        #expect(!redacted.contains("AK/x"))
        #expect(redacted.contains("https://h/p?"))
        #expect(redacted.contains("list-type=2"))
        #expect(CloudRedaction.redact("plain") == "plain")
    }
}
