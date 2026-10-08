import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

/// Cloud Studio fixtures. `Fixtures/cloud/` holds only byte-for-byte copies of the worker's golden examples
/// (`cloud/runpod-worker/schema/v1/examples/`; the worker's `ci/check_fixtures.py` and `ci/check-cloud-fixtures.sh`
/// both fail when they drift); `Fixtures/cloud-phone/` holds RunPod's own responses, a bucket listing and
/// hand-written lyrics edge cases.
enum CloudFixtures {
    static func data(_ name: String, _ ext: String = "json") throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/cloud-phone")
            ?? Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/cloud")
        return try Data(contentsOf: try #require(url))
    }

    /// One of the worker's golden examples (never a hand-written stand-in).
    static func worker(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/cloud"))
        return try Data(contentsOf: url)
    }

    static func text(_ name: String, _ ext: String = "json") throws -> String {
        String(decoding: try data(name, ext), as: UTF8.self)
    }

    /// JSON with object keys sorted, `null` members dropped and numbers compared by value: the shape both sides must
    /// agree on (key order, spacing and explicit nulls are not part of the contract).
    static func canonical(_ data: Data) throws -> JSONValue {
        canonical(try JSONParser().parse(utf8: [UInt8](data)))
    }

    static func canonical(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var out = JSONObject()
            for member in object.members.sorted(by: { $0.key < $1.key }) where !member.value.isNull {
                out.append(member.key, canonical(member.value))
            }
            return .object(out)
        case .array(let items):
            return .array(items.map(canonical))
        case .number(let literal):
            return .number(Double(literal).map { $0 == $0.rounded() && abs($0) < 1e15 ? String(Int64($0)) : String($0) } ?? literal)
        default:
            return value
        }
    }

    /// The structure of a JSON value without its values: object keys (nulls dropped) and each value's kind; an array
    /// is the shape of its first element. Two bodies with the same shape use the same fields.
    static func shape(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var out = JSONObject()
            for member in object.members.sorted(by: { $0.key < $1.key }) where !member.value.isNull {
                out.append(member.key, shape(member.value))
            }
            return .object(out)
        case .array(let items):
            return .array(items.first.map { [shape($0)] } ?? [])
        case .number: return .string("number")
        case .string: return .string("string")
        case .bool: return .string("bool")
        default: return .string("null")
        }
    }

    /// Every worker example, by file name.
    static let workerInputs = ["job.input.process", "job.input.transcribe", "job.input.volume", "job.input.selftest",
                               "job.input.bench"]
    static let workerResults = ["job.result.ok", "job.result.partial", "job.result.error", "job.result.poisoned"]
    static let workerLyrics = ["lyrics.aligned", "lyrics.transcribed"]
}

/// The phone's schema types against the worker's golden examples (design §2.3, §7.6): every example decodes, and
/// encodes back to the same JSON (so no field the worker sends is dropped), and the bodies the app builds have
/// exactly the shape of the worker's `run.request.json`.
@Suite struct CloudSchemaTests {
    static let jobKey = "6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10"

    @Test(arguments: CloudFixtures.workerInputs)
    func workerInputsRoundTrip(_ name: String) throws {
        let data = try CloudFixtures.worker(name)
        let input = try CloudJSON.decode(CloudJobInput.self, from: data)
        #expect(input.v == CloudSchema.version)
        #expect(try CloudFixtures.canonical(try CloudJSON.encode(input)) == CloudFixtures.canonical(data))
    }

    @Test func workerRunRequestRoundTrips() throws {
        let data = try CloudFixtures.worker("run.request")
        let request = try CloudJSON.decode(CloudJobRequest.self, from: data)
        #expect(request.policy == CloudJobPolicy(ttl: 259_200_000, executionTimeout: 900_000))
        #expect(try CloudFixtures.canonical(try CloudJSON.encode(request)) == CloudFixtures.canonical(data))
        // run.request.json is job.input.process.json wrapped with the policy.
        let process = try CloudJSON.decode(CloudJobInput.self, from: CloudFixtures.worker("job.input.process"))
        #expect(request.input == process)
    }

    @Test(arguments: CloudFixtures.workerResults)
    func workerResultsRoundTrip(_ name: String) throws {
        let data = try CloudFixtures.worker(name)
        let result = try CloudJSON.decode(CloudJobResult.self, from: data)
        #expect(result.schema == CloudSchema.result && result.v == 1)
        #expect(CloudKeys.isValidJobKey(result.jobKey))
        #expect(try CloudFixtures.canonical(try CloudJSON.encode(result)) == CloudFixtures.canonical(data))
    }

    @Test(arguments: CloudFixtures.workerLyrics)
    func workerLyricsRoundTrip(_ name: String) throws {
        let data = try CloudFixtures.worker(name)
        let lyrics = try CloudJSON.decode(CloudLyricsDocument.self, from: data)
        #expect(lyrics.schema == CloudSchema.lyrics && lyrics.v == 1)
        #expect(try CloudFixtures.canonical(try CloudJSON.encode(lyrics)) == CloudFixtures.canonical(data))
    }

    @Test func workerSelftestAndAttemptRoundTrip() throws {
        let selftestData = try CloudFixtures.worker("selftest.result")
        let selftest = try CloudJSON.decode(CloudSelftestResult.self, from: selftestData)
        #expect(selftest.isOK)
        #expect(selftest.agreedVersion == 1)
        #expect(selftest.models?["anvuew-bs-roformer-ft1"] == .loaded)
        #expect(selftest.models?["qwen3-asr-1.7b"] == .lazy)
        #expect(selftest.models?.values.allSatisfy(\.isAvailable) == true)
        #expect(selftest.wordTimingLanguages?.contains("ko") == true)
        #expect(selftest.versions?["runpod"] == "1.12.0")
        #expect(selftest.caps == CloudWorkerCaps(maxInputMB: 160, maxAudioS: 900, bestMaxAudioS: 480, maxLyricsLines: 500,
                                                 maxLyricsChars: 20_000, maxBodyKB: 256, hostsConfigured: 1))
        // The worker's defaults are the app's own limits.
        #expect(Int64(selftest.caps?.maxInputMB ?? 0) * 1_048_576 == CloudLimits.maxInputBytes)
        #expect(Int64(selftest.caps?.maxAudioS ?? 0) * 1000 == CloudLimits.maxDurationMs)
        #expect(Int64(selftest.caps?.bestMaxAudioS ?? 0) * 1000 == CloudLimits.bestQualityMaxDurationMs)
        #expect(selftest.caps?.maxLyricsLines == CloudLimits.maxLyricsLines)
        #expect(selftest.caps?.maxLyricsChars == CloudLimits.maxLyricsChars)
        #expect(try CloudFixtures.canonical(try CloudJSON.encode(selftest)) == CloudFixtures.canonical(selftestData))

        let attemptData = try CloudFixtures.worker("attempt")
        let attempt = try CloudJSON.decode(CloudAttempt.self, from: attemptData)
        #expect(attempt.attempts == 1)
        #expect(try CloudFixtures.canonical(try CloudJSON.encode(attempt)) == CloudFixtures.canonical(attemptData))
    }

    @Test func processInputDecodesFieldForField() throws {
        let input = try CloudJSON.decode(CloudJobInput.self, from: CloudFixtures.worker("job.input.process"))
        #expect(input.schema == "pixl.cloudstudio.job")
        #expect(input.op == "process")
        #expect(input.jobKey == Self.jobKey)
        #expect(input.client == CloudClientInfo(build: "1.0 (412)"))
        #expect(input.storage == "presigned")
        #expect(input.audio?.ext == "m4a")
        #expect(input.audio?.bytes == 7_712_345)
        #expect(input.audio?.durationMs == 241_000)
        #expect(input.audio?.get?.contains("/in/\(Self.jobKey).m4a?") == true)
        #expect(input.typedTasks == [.instrumental, .lyrics])
        #expect(input.separation?.quality == "standard")
        #expect(input.lyrics?.mode == "auto")
        #expect(input.lyrics?.language == "ko")
        #expect(input.lyrics?.synced == true)
        #expect(input.lyrics?.lines?.first == CloudLyricsInputLine(startMs: 12_340, endMs: 15_800, text: "별빛 아래 우리 둘이"))
        // The last line has no end: the worker uses the next line's start (or the song's end).
        #expect(input.lyrics?.lines?.last == CloudLyricsInputLine(startMs: 23_050, endMs: nil, text: ""))
        #expect(input.output?.codec == "aac")
        #expect(input.output?.kbps == 256)
        #expect(Set(input.output?.put.map { Array($0.keys) } ?? []) == ["instrumental", "lyrics", "manifest"])
        #expect(input.guard?.attemptPut.contains("attempt.json") == true)
    }

    @Test func volumeAndBenchInputs() throws {
        let volume = try CloudJSON.decode(CloudJobInput.self, from: CloudFixtures.worker("job.input.volume"))
        #expect(volume.storage == "volume")
        #expect(volume.audio?.key == "in/\(Self.jobKey).m4a")
        #expect(volume.audio?.get == nil)
        #expect(volume.output?.put == nil)
        let bench = try CloudJSON.decode(CloudJobInput.self, from: CloudFixtures.worker("job.input.bench"))
        #expect(bench.op == "bench")
        #expect(bench.bench?.seconds == 240)
        #expect(bench.bench?.stages?.contains("separate") == true)
        let transcribe = try CloudJSON.decode(CloudJobInput.self, from: CloudFixtures.worker("job.input.transcribe"))
        #expect(transcribe.output?.codec == "flac" && transcribe.output?.kbps == nil)
        #expect(transcribe.lyrics?.synced == false && transcribe.lyrics?.lines == [])
        #expect(transcribe.audio?.ext == "flac")
    }

    @Test func okManifestDecodes() throws {
        let result = try CloudJSON.decode(CloudJobResult.self, from: CloudFixtures.worker("job.result.ok"))
        #expect(result.typedStatus == .ok)
        #expect(result.hasResults)
        #expect(result.error == nil && result.errorCode == nil)
        #expect(result.worker?.gpu == "NVIDIA L4")
        #expect(result.worker?.vramGB == 22.5)
        #expect(result.models?.stems4 == nil)
        #expect(result.models?.aligner == "qwen3-forced-aligner-0.6b")
        #expect(result.input?.decodedSamples == 10_628_100)
        // The worker names the input it verified (its duplicate guard compares it too).
        #expect(result.input?.sha256 == "b66e21bfd056b5178586fbde94ebdb66c9ba669e7e4504f5da92f154ee9d28be")
        let process = try CloudJSON.decode(CloudJobInput.self, from: CloudFixtures.worker("job.input.process"))
        #expect(CloudImportCheck.manifestDescribesUpload(result, uploadedSHA256: process.audio?.sha256))
        let instrumental = try #require(result.outputs?["instrumental"])
        #expect(instrumental.key == "out/\(Self.jobKey)/instrumental.m4a")
        #expect(instrumental.sampleRate == 44_100)
        #expect(instrumental.samples == 10_628_100)
        let lyrics = try #require(result.lyrics)
        #expect(lyrics.key == "out/\(Self.jobKey)/lyrics.json")
        #expect(lyrics.bytes == 2_210)
        #expect(lyrics.sha256?.count == 64)
        #expect(lyrics.offsetMs == 0)
        #expect(lyrics.wordTimedLines == 3)
        #expect(result.timings?.coldStartMs == 18_400)
        #expect(result.timings?.totalMs == 19_400)
        #expect(!result.isDuplicate)
    }

    @Test func partialErrorAndPoisonedManifests() throws {
        let partial = try CloudJSON.decode(CloudJobResult.self, from: CloudFixtures.worker("job.result.partial"))
        #expect(partial.typedStatus == .partial)
        #expect(partial.hasResults)
        #expect(partial.lyrics == nil)
        #expect(partial.outputs?["instrumental"] != nil)
        let error = try CloudJSON.decode(CloudJobResult.self, from: CloudFixtures.worker("job.result.error"))
        #expect(error.typedStatus == .error)
        #expect(!error.hasResults)
        #expect(error.errorCode == .inputMismatch)
        #expect(error.errorCode?.needsReupload == true)
        #expect(error.outputs?.isEmpty == true)
        #expect(error.input == nil)
        let poisoned = try CloudJSON.decode(CloudJobResult.self, from: CloudFixtures.worker("job.result.poisoned"))
        #expect(poisoned.errorCode == .poisoned)
        #expect(poisoned.errorCode?.isRetryable == false)
    }

    @Test func unknownFieldsAndValuesAreTolerated() throws {
        let json = """
        {"schema":"pixl.cloudstudio.result","v":1,"jobKey":"k","status":"queued-later","futureField":{"a":[1,2]},
         "error":{"code":"SOMETHING_NEW","message":"x"},
         "worker":{"gpu":"X","newThing":true},"outputs":{"instrumental":{"key":"k","bytes":1,"sha256":"aa","extra":1}}}
        """
        let result = try CloudJSON.decode(CloudJobResult.self, from: Data(json.utf8))
        #expect(result.typedStatus == .error) // an unknown status is never imported
        #expect(result.errorCode == .internal) // an unknown code reads as INTERNAL (the schema's rule)
        #expect(result.worker?.gpu == "X")
        #expect(result.outputs?["instrumental"]?.samples == nil)
    }

    /// The body the app builds uses exactly the fields of the worker's example: nothing missing, nothing extra.
    @Test func builtRequestHasTheWorkerExampleShape() throws {
        var record = CloudJobRecord(jobKey: Self.jobKey, songId: "f:root/a.m4a", title: "A", artist: "B", batchId: "b",
                                    tasks: [.instrumental, .lyrics], lyricsMode: .align, quality: .standard,
                                    createdAtMs: 0, language: "ko")
        record.inputExt = "m4a"
        record.sha256 = "b66e21bfd056b5178586fbde94ebdb66c9ba669e7e4504f5da92f154ee9d28be"
        record.bytes = 7_712_345
        record.durationMs = 241_000
        let lines = [CloudLyricsInputLine(startMs: 12_340, endMs: 15_800, text: "별빛 아래 우리 둘이")]
        let lyrics = CloudJobBuilder.lyricsRequest(mode: .align, lines: lines, hasLineTimes: true, language: "ko",
                                                   lyricsReferenceDurationMs: nil, audioDurationMs: 241_000)
        let presign: CloudPresign = { method, key, seconds in
            "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/pixl-cloud-studio/\(key)?X-Amz-Expires=\(seconds)&X-Amz-Signature=\(method.rawValue)"
        }
        let request = try #require(CloudJobBuilder.request(for: record, build: "1.0 (412)", lyrics: lyrics, presign: presign))
        let built = try JSONParser().parse(utf8: [UInt8](try CloudJSON.encode(request)))
        let example = try JSONParser().parse(utf8: [UInt8](try CloudFixtures.worker("run.request")))
        #expect(CloudFixtures.shape(built) == CloudFixtures.shape(example))
        // `auto` in the example, `align` here: both are valid modes; everything else matches field for field.
        #expect(built["input"]?["lyrics"]?["mode"]?.stringValue == "align")
        // Every URL ends in the object the worker expects for its slot.
        let put = try #require(request.input.output?.put)
        #expect(put["instrumental"]?.contains("/out/\(Self.jobKey)/instrumental.m4a?") == true)
        #expect(put["lyrics"]?.contains("/out/\(Self.jobKey)/lyrics.json?") == true)
        #expect(put["manifest"]?.contains("/out/\(Self.jobKey)/manifest.json?") == true)
        #expect(request.input.audio?.get?.contains("/in/\(Self.jobKey).m4a?") == true)
    }

    @Test func selftestBodyMatchesTheWorkerExample() throws {
        let body = try JSONParser().parse(utf8: [UInt8](try CloudJSON.encode(CloudOpRequest(op: .selftest, build: "1.0 (412)"))))
        let example = try JSONParser().parse(utf8: [UInt8](try CloudFixtures.worker("job.input.selftest")))
        // The app adds `client` (optional in the schema); the rest is the example.
        #expect(body["input"]?["schema"] == example["schema"])
        #expect(body["input"]?["v"]?.int64Value == example["v"]?.int64Value)
        #expect(body["input"]?["op"] == example["op"])
        #expect(body["input"]?["audio"] == nil)
        #expect(body["input"]?["client"]?["app"]?.stringValue == "pixlaudio-ios")
    }

    @Test func languageHintsFollowTheWorkerPattern() {
        #expect(CloudJobBuilder.normalizedLanguage("ko") == "ko")
        #expect(CloudJobBuilder.normalizedLanguage("EN") == "en")
        #expect(CloudJobBuilder.normalizedLanguage("zh-Hant") == "zh-Hant")
        #expect(CloudJobBuilder.normalizedLanguage("pt_BR") == "pt-BR")
        #expect(CloudJobBuilder.normalizedLanguage("und") == nil)
        #expect(CloudJobBuilder.normalizedLanguage("") == nil)
        #expect(CloudJobBuilder.normalizedLanguage("k") == nil)
        #expect(CloudJobBuilder.normalizedLanguage("en-x") == "en")
    }

    @Test func errorCodesCoverTheWorkerList() {
        let names = Set(CloudErrorCode.allCases.map(\.rawValue))
        // The worker schema's "Known v1 codes".
        #expect(names == ["BAD_SCHEMA", "UNSUPPORTED_VERSION", "BAD_OP", "BAD_URL", "INPUT_TOO_LARGE", "INPUT_MISMATCH",
                          "INPUT_MISSING", "DOWNLOAD_FAILED", "TOO_LONG", "UNSUPPORTED_FORMAT", "DECODE_FAILED", "GPU_OOM",
                          "DEADLINE", "UPLOAD_FAILED", "POISONED", "INTERNAL"])
        #expect(!CloudErrorCode.poisoned.isRetryable)
        #expect(CloudErrorCode.gpuOOM.isRetryable)
        #expect(CloudErrorCode.downloadFailed.isRetryable)
        #expect(CloudTask.stems4.outputSlots == ["drums", "bass", "other"])
    }

    @Test func modelAvailabilityReadsBoolsAndLazy() throws {
        let json = #"{"a":true,"b":false,"c":"lazy","d":"warming"}"#
        let models = try JSONDecoder().decode([String: CloudModelAvailability].self, from: Data(json.utf8))
        #expect(models == ["a": .loaded, "b": .missing, "c": .lazy, "d": .other("warming")])
        #expect(models["b"]?.isAvailable == false && models["c"]?.isAvailable == true)
    }
}
