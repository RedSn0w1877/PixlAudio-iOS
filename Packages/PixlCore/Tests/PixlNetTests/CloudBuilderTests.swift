import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

/// Settings fields, the `/run` body builder and "Test connection" (design §2.3, §3.5 E, §7.2).
@Suite struct CloudBuilderTests {
    static let jobKey = "6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10"
    static let account = "0123456789abcdef0123456789abcdef"

    // MARK: Settings fields

    @Test func endpointAcceptsAURLOrABareAccountId() {
        #expect(CloudConfig.normalizedEndpoint(Self.account) == "https://\(Self.account).r2.cloudflarestorage.com")
        #expect(CloudConfig.normalizedEndpoint(" 0123456789ABCDEF0123456789ABCDEF ")
            == "https://\(Self.account).r2.cloudflarestorage.com")
        #expect(CloudConfig.normalizedEndpoint("https://\(Self.account).r2.cloudflarestorage.com/")
            == "https://\(Self.account).r2.cloudflarestorage.com")
        #expect(CloudConfig.normalizedEndpoint("https://\(Self.account).r2.cloudflarestorage.com/pixl-cloud-studio")
            == "https://\(Self.account).r2.cloudflarestorage.com")
        #expect(CloudConfig.normalizedEndpoint("\(Self.account).r2.cloudflarestorage.com")
            == "https://\(Self.account).r2.cloudflarestorage.com")
        #expect(CloudConfig.normalizedEndpoint("http://\(Self.account).r2.cloudflarestorage.com") == nil)
        #expect(CloudConfig.normalizedEndpoint("") == nil)
        #expect(CloudConfig.normalizedEndpoint("not a url") == nil)
        #expect(CloudConfig.normalizedEndpoint("0123") == nil)
        #expect(CloudConfig.r2AccountId(endpoint: Self.account) == Self.account)
        #expect(CloudConfig.r2AccountId(endpoint: "https://s3.example.com") == nil)
    }

    @Test func problemsListEveryMissingFieldInScreenOrder() {
        let empty = CloudConfigInput(endpointId: "", runpodKey: "", endpoint: "", bucket: "", accessKeyId: "",
                                     secretAccessKey: "")
        #expect(CloudConfig.problems(empty).count == 6)
        #expect(CloudConfig.problems(empty).first == "Paste the RunPod Endpoint ID.")
        let full = CloudConfigInput(endpointId: "abc123xyz", runpodKey: "rpa_X", endpoint: Self.account,
                                    bucket: CloudConfig.defaultBucket, accessKeyId: "AKID", secretAccessKey: "SECRET")
        #expect(CloudConfig.problems(full).isEmpty)
        #expect(full.isComplete)
        #expect(full.location?.endpoint == "https://\(Self.account).r2.cloudflarestorage.com")
        var bad = full
        bad.endpointId = "https://api.runpod.ai/v2/abc"
        bad.bucket = "Pixl"
        #expect(CloudConfig.problems(bad).count == 2)
        #expect(!bad.isComplete)
    }

    // MARK: /run body

    static func uploadedRecord(tasks: [CloudTask] = [.instrumental, .lyrics]) -> CloudJobRecord {
        var record = CloudJobRecord(jobKey: jobKey, songId: "f:root/a.mp3", title: "A", artist: "B", batchId: "b1",
                                    tasks: tasks, lyricsMode: tasks.contains(.lyrics) ? .align : nil, quality: .best,
                                    createdAtMs: 1_000)
        record.inputExt = "flac"
        record.sha256 = "AB12"
        record.bytes = 30_000_000
        record.durationMs = 600_000
        return record
    }

    /// Signs as `<METHOD> <key> <seconds>`, so every URL in the body can be checked by eye.
    static let fakePresign: CloudPresign = { method, key, seconds in "https://r2.test/\(key)?m=\(method.rawValue)&s=\(seconds)" }

    @Test func requestCarriesEveryURLTheWorkerNeeds() throws {
        let record = Self.uploadedRecord()
        let lyrics = CloudJobBuilder.lyricsRequest(mode: .align, lines: [CloudLyricsInputLine(startMs: 1000, endMs: 2000, text: "x")],
                                                   hasLineTimes: true, language: "en", lyricsReferenceDurationMs: 600_500,
                                                   audioDurationMs: 600_000)
        let request = try #require(CloudJobBuilder.request(for: record, build: "1.0 (7)", lyrics: lyrics, presign: Self.fakePresign))
        let input = request.input
        let s = CloudTiming.workerPresignSeconds
        #expect(input.schema == CloudSchema.job && input.v == 1 && input.op == "process")
        #expect(input.storage == "presigned")
        #expect(input.client == CloudClientInfo(build: "1.0 (7)"))
        #expect(input.audio?.get == "https://r2.test/in/\(Self.jobKey).flac?m=GET&s=\(s)")
        #expect(input.audio?.delete == "https://r2.test/in/\(Self.jobKey).flac?m=DELETE&s=\(s)")
        #expect(input.audio?.sha256 == "ab12")
        #expect(input.audio?.ext == "flac")
        #expect(input.typedTasks == [.instrumental, .lyrics])
        // `best` falls back to `standard` above 8 minutes.
        #expect(input.separation?.quality == "standard")
        #expect(input.output?.codec == "aac" && input.output?.kbps == 256)
        #expect(input.output?.put == [
            "instrumental": "https://r2.test/out/\(Self.jobKey)/instrumental.m4a?m=PUT&s=\(s)",
            "lyrics": "https://r2.test/out/\(Self.jobKey)/lyrics.json?m=PUT&s=\(s)",
            "manifest": "https://r2.test/out/\(Self.jobKey)/manifest.json?m=PUT&s=\(s)",
        ])
        #expect(input.guard == CloudJobGuard(manifestGet: "https://r2.test/out/\(Self.jobKey)/manifest.json?m=GET&s=\(s)",
                                             attemptGet: "https://r2.test/out/\(Self.jobKey)/attempt.json?m=GET&s=\(s)",
                                             attemptPut: "https://r2.test/out/\(Self.jobKey)/attempt.json?m=PUT&s=\(s)"))
        #expect(input.lyrics?.mode == "align" && input.lyrics?.synced == true && input.lyrics?.language == "en")
        #expect(request.policy == CloudJobPolicy(ttl: 259_200_000, executionTimeout: 900_000))
        // The body is the design's shape: decodes as the fixture type, nothing extra.
        let decoded = try CloudJSON.decode(CloudJobRequest.self, from: try CloudJSON.encode(request))
        #expect(decoded == request)
    }

    @Test func flacRedoAsksForFlacOutputs() throws {
        var record = Self.uploadedRecord(tasks: [.instrumental])
        record.outputCodec = .flac
        let request = try #require(CloudJobBuilder.request(for: record, build: "1", lyrics: nil, presign: Self.fakePresign))
        #expect(request.input.output?.codec == "flac")
        #expect(request.input.output?.kbps == nil)
        #expect(request.input.output?.put?["instrumental"]?.contains("/instrumental.flac?") == true)
        #expect(request.input.lyrics == nil)
    }

    @Test func requestNeedsAPreparedInputAndLyricsForTheLyricsTask() {
        var record = Self.uploadedRecord()
        #expect(CloudJobBuilder.request(for: record, build: "1", lyrics: nil, presign: Self.fakePresign) == nil)
        record.sha256 = nil
        let lyrics = CloudLyricsRequest(mode: .transcribe, language: nil, synced: false, lines: nil)
        #expect(CloudJobBuilder.request(for: record, build: "1", lyrics: lyrics, presign: Self.fakePresign) == nil)
        let unsigned: CloudPresign = { _, _, _ in nil }
        #expect(CloudJobBuilder.request(for: Self.uploadedRecord(), build: "1", lyrics: lyrics, presign: unsigned) == nil)
    }

    @Test func lyricsRequestRules() {
        let line = CloudLyricsInputLine(startMs: 0, endMs: 10, text: "a")
        // Durations 3 s apart: the catalog's times can't be trusted against this audio.
        let shifted = CloudJobBuilder.lyricsRequest(mode: .align, lines: [line], hasLineTimes: true, language: "",
                                                    lyricsReferenceDurationMs: 200_000, audioDurationMs: 203_000)
        #expect(shifted.synced == false && shifted.language == nil && shifted.mode == "align")
        let vanished = CloudJobBuilder.lyricsRequest(mode: .align, lines: [], hasLineTimes: false, language: nil,
                                                     lyricsReferenceDurationMs: nil, audioDurationMs: 1)
        #expect(vanished.mode == "auto" && vanished.lines == nil)
        let transcribe = CloudJobBuilder.lyricsRequest(mode: .transcribe, lines: [line], hasLineTimes: true, language: "ko",
                                                       lyricsReferenceDurationMs: nil, audioDurationMs: 1)
        #expect(transcribe.lines == nil && transcribe.mode == "transcribe")
    }

    @Test func objectKeysStayInsideTheJobFolder() {
        var record = Self.uploadedRecord()
        record.outputs = ["instrumental": CloudOutputFile(key: "out/\(Self.jobKey)/instrumental.m4a", bytes: 1, sha256: "a",
                                                          codec: "aac", kbps: 256, samples: 1),
                          "evil": CloudOutputFile(key: "in/someone-else.m4a", bytes: 1, sha256: "a", codec: nil, kbps: nil,
                                                  samples: nil)]
        record.lyricsKey = "out/\(Self.jobKey)/../x.json"
        let keys = CloudJobBuilder.objectKeys(for: record)
        #expect(keys == ["in/\(Self.jobKey).flac", "out/\(Self.jobKey)/instrumental.m4a", "out/\(Self.jobKey)/lyrics.json",
                         "out/\(Self.jobKey)/manifest.json", "out/\(Self.jobKey)/attempt.json"])
    }

    // MARK: Test connection

    static func store(_ http: FixtureHTTPClient) -> CloudObjectClient {
        let signer = S3Signer(credentials: S3Credentials(accessKeyId: "AKID", secretAccessKey: "SECRET"),
                              location: S3Location(endpoint: CloudConfig.r2Endpoint(accountId: account),
                                                   bucket: CloudConfig.defaultBucket),
                              sha256: { TestSHA256.hash($0) }, hmac: { TestHMAC.sha256(key: $0, message: $1) })
        return CloudObjectClient(http: http, signer: signer, nowSeconds: { 1_790_000_000 })
    }

    @Test func storageCheckWritesFindsAndDeletesTheProbe() async {
        let http = FixtureHTTPClient { request in
            HTTPResponse(statusCode: request.method == .delete ? 204 : 200,
                         headers: request.method == .head ? [HTTPHeader("Content-Length", "1")] : [], text: "")
        }
        let check = await CloudConnectionTest.checkStorage(Self.store(http), probeId: "p-1")
        #expect(check.ok)
        #expect(http.requests.map(\.method) == [.put, .head, .delete])
        let prefix = "https://\(Self.account).r2.cloudflarestorage.com/pixl-cloud-studio/probe/p-1?"
        #expect(http.requests.allSatisfy { $0.url.hasPrefix(prefix) && $0.url.contains("X-Amz-Signature=") })
        #expect(http.requests.allSatisfy { $0.header("Authorization") == nil })
    }

    @Test func storageCheckNamesTheFailingStep() async {
        let refused = FixtureHTTPClient { _ in HTTPResponse(statusCode: 403, text: "<Error><Code>SignatureDoesNotMatch</Code></Error>") }
        let a = await CloudConnectionTest.checkStorage(Self.store(refused), probeId: "p")
        #expect(!a.ok && a.message.contains("refused the key"))
        let noBucket = FixtureHTTPClient { _ in HTTPResponse(statusCode: 404, text: "<Error><Code>NoSuchBucket</Code></Error>") }
        let b = await CloudConnectionTest.checkStorage(Self.store(noBucket), probeId: "p")
        #expect(!b.ok && b.message.contains("bucket doesn't exist"))
        let noDelete = FixtureHTTPClient { request in
            request.method == .delete ? HTTPResponse(statusCode: 403, text: "")
                : HTTPResponse(statusCode: 200, headers: [HTTPHeader("Content-Length", "1")], text: "")
        }
        let c = await CloudConnectionTest.checkStorage(Self.store(noDelete), probeId: "p")
        #expect(!c.ok && c.message.contains("delete"))
        let unset = await CloudConnectionTest.checkStorage(nil, probeId: "p")
        #expect(!unset.ok)
    }

    static func runpod(_ http: FixtureHTTPClient) -> RunPodJobsClient {
        RunPodJobsClient(http: http, endpointId: "abc123xyz", apiKey: "rpa_X", nowMs: { 0 }, sleep: { _ in })
    }

    @Test func runPodCheckReadsHealthAndExplainsFailures() async throws {
        let health = try CloudFixtures.text("runpod.health")
        let ok = await CloudConnectionTest.checkRunPod(Self.runpod(FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: health) }))
        #expect(ok.ok)
        #expect(ok.detail == "3 songs waiting · 1 worker running")
        let key = await CloudConnectionTest.checkRunPod(Self.runpod(FixtureHTTPClient { _ in HTTPResponse(statusCode: 401, text: "") }))
        #expect(!key.ok && key.message.contains("refused the key"))
        let id = await CloudConnectionTest.checkRunPod(Self.runpod(FixtureHTTPClient { _ in HTTPResponse(statusCode: 404, text: "") }))
        #expect(!id.ok && id.message.contains("Endpoint ID"))
        let unset = await CloudConnectionTest.checkRunPod(nil)
        #expect(!unset.ok)
        #expect(CloudConnectionTest.healthSummary(RunPodHealth()) == "0 songs waiting · no worker awake (normal when idle)")
    }

    @Test func selftestReportsTheWorker() async throws {
        let body = try CloudFixtures.text("runpod.selftest")
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: body) }
        let check = await CloudConnectionTest.selftest(Self.runpod(http), build: "1.0 (1)")
        #expect(check.ok)
        #expect(check.detail == "Worker 1.0.0 on NVIDIA L4")
        #expect(http.requests.first?.url == "https://api.runpod.ai/v2/abc123xyz/runsync")
    }
}
