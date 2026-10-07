import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

/// Cloud Studio fixtures (`Fixtures/cloud/`): copies of the worker's schema v1 examples, written from design §2.3.
enum CloudFixtures {
    static func data(_ name: String, _ ext: String = "json") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/cloud"))
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
}

@Suite struct CloudSchemaTests {
    @Test func processInputDecodesFieldForField() throws {
        let request = try CloudJSON.decode(CloudJobRequest.self, from: CloudFixtures.data("job.input.process"))
        let input = request.input
        #expect(input.schema == "pixl.cloudstudio.job")
        #expect(input.v == 1)
        #expect(input.op == "process")
        #expect(input.jobKey == "6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10")
        #expect(input.client == CloudClientInfo(build: "1.0 (412)"))
        #expect(input.storage == "presigned")
        #expect(input.audio?.ext == "m4a")
        #expect(input.audio?.bytes == 7_712_345)
        #expect(input.audio?.durationMs == 241_000)
        #expect(input.audio?.get?.contains("/in/6f1c2a9e") == true)
        #expect(input.typedTasks == [.instrumental, .lyrics])
        #expect(input.separation?.quality == "standard")
        #expect(input.lyrics?.mode == "auto")
        #expect(input.lyrics?.language == "ko")
        #expect(input.lyrics?.synced == true)
        #expect(input.lyrics?.lines?.first == CloudLyricsInputLine(startMs: 12_340, endMs: 15_800, text: "원문 가사"))
        #expect(input.output?.codec == "aac")
        #expect(input.output?.kbps == 256)
        #expect(Set(input.output.map { Array($0.put.keys) } ?? []) == ["instrumental", "lyrics", "manifest"])
        #expect(input.guard?.attemptPut.contains("attempt.json") == true)
        #expect(request.policy == CloudJobPolicy(ttl: 259_200_000, executionTimeout: 900_000))
    }

    @Test(arguments: ["job.input.process", "job.input.selftest", "job.result.ok", "job.result.partial", "job.result.error"])
    func fixturesRoundTripWithoutLosingFields(_ name: String) throws {
        let data = try CloudFixtures.data(name)
        let encoded: Data
        if name.hasPrefix("job.input") {
            encoded = try CloudJSON.encode(try CloudJSON.decode(CloudJobRequest.self, from: data))
        } else {
            encoded = try CloudJSON.encode(try CloudJSON.decode(CloudJobResult.self, from: data))
        }
        #expect(try CloudFixtures.canonical(encoded) == CloudFixtures.canonical(data))
    }

    @Test(arguments: ["lyrics.aligned", "lyrics.transcribed"])
    func lyricsFixturesRoundTrip(_ name: String) throws {
        let data = try CloudFixtures.data(name)
        let encoded = try CloudJSON.encode(try CloudJSON.decode(CloudLyricsDocument.self, from: data))
        #expect(try CloudFixtures.canonical(encoded) == CloudFixtures.canonical(data))
    }

    @Test func okManifestDecodes() throws {
        let result = try CloudJSON.decode(CloudJobResult.self, from: CloudFixtures.data("job.result.ok"))
        #expect(result.typedStatus == .ok)
        #expect(result.hasResults)
        #expect(result.error == nil)
        #expect(result.worker?.gpu == "NVIDIA L4")
        #expect(result.worker?.vramGB == 24)
        #expect(result.models?.stems4 == nil)
        #expect(result.models?.aligner == "qwen3-forced-aligner-0.6b")
        #expect(result.input?.decodedSamples == 10_628_100)
        let instrumental = try #require(result.outputs?["instrumental"])
        #expect(instrumental.key == "out/6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10/instrumental.m4a")
        #expect(instrumental.samples == 10_628_100)
        #expect(result.lyrics?.wordTimedLines == 46)
        #expect(result.timings?.coldStartMs == 18_400)
        #expect(result.timings?.totalMs == 19_400)
        #expect(!result.isDuplicate)
    }

    @Test func partialAndErrorManifests() throws {
        let partial = try CloudJSON.decode(CloudJobResult.self, from: CloudFixtures.data("job.result.partial"))
        #expect(partial.typedStatus == .partial)
        #expect(partial.hasResults)
        #expect(partial.lyrics == nil)
        let error = try CloudJSON.decode(CloudJobResult.self, from: CloudFixtures.data("job.result.error"))
        #expect(error.typedStatus == .error)
        #expect(!error.hasResults)
        #expect(error.errorCode == .inputMissing)
        #expect(error.errorCode?.needsReupload == true)
        #expect(error.outputs == nil)
    }

    @Test func unknownFieldsAndValuesAreTolerated() throws {
        let json = """
        {"schema":"pixl.cloudstudio.result","v":1,"jobKey":"k","status":"queued-later","futureField":{"a":[1,2]},
         "worker":{"gpu":"X","newThing":true},"outputs":{"instrumental":{"key":"k","bytes":1,"sha256":"aa","extra":1}}}
        """
        let result = try CloudJSON.decode(CloudJobResult.self, from: Data(json.utf8))
        #expect(result.typedStatus == .error) // an unknown status is never imported
        #expect(result.worker?.gpu == "X")
        #expect(result.outputs?["instrumental"]?.samples == nil)
    }

    @Test func requestEncodesTheDesignShape() throws {
        let input = CloudJobInput(jobKey: "6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10", client: CloudClientInfo(build: "1.0 (1)"),
                                  storage: CloudStorageMode.presigned.rawValue,
                                  audio: CloudAudioInput(get: "https://g", delete: "https://d", ext: "flac", bytes: 10,
                                                         sha256: "ab", durationMs: 1000),
                                  tasks: [CloudTask.instrumental.rawValue], separation: CloudSeparation(quality: .best),
                                  output: CloudOutputRequest(codec: .aac, kbps: 256,
                                                             put: ["instrumental": "https://i", "manifest": "https://m"]),
                                  guard: CloudJobGuard(manifestGet: "https://mg", attemptGet: "https://ag", attemptPut: "https://ap"))
        let request = CloudJobRequest(input: input, policy: CloudJobPolicy(ttl: CloudTiming.ttlMs,
                                                                           executionTimeout: CloudTiming.executionTimeoutMs))
        let json = try JSONParser().parse(utf8: [UInt8](try CloudJSON.encode(request)))
        #expect(json["input"]?["schema"]?.stringValue == "pixl.cloudstudio.job")
        #expect(json["input"]?["op"]?.stringValue == "process")
        #expect(json["input"]?["guard"]?["attemptPut"]?.stringValue == "https://ap")
        #expect(json["input"]?["separation"]?["quality"]?.stringValue == "best")
        #expect(json["input"]?["lyrics"] == nil) // nil fields are left out, never sent as null
        #expect(json["policy"]?["ttl"]?.int64Value == 259_200_000)
        // Slashes stay readable (URLs are compared by the worker's allowlist, not unescaped by hand).
        #expect(String(decoding: try CloudJSON.encode(request), as: UTF8.self).contains("https://i"))
    }

    @Test func selftestBodyHasNoAudio() throws {
        let body = try CloudJSON.encode(CloudOpRequest(op: .selftest, build: "1.0 (412)"))
        #expect(try CloudFixtures.canonical(body) == CloudFixtures.canonical(CloudFixtures.data("job.input.selftest")))
    }

    @Test func errorCodesCoverTheDesignList() {
        let names = Set(CloudErrorCode.allCases.map(\.rawValue))
        #expect(names == ["BAD_SCHEMA", "UNSUPPORTED_VERSION", "BAD_OP", "BAD_URL", "INPUT_TOO_LARGE", "INPUT_MISMATCH",
                          "TOO_LONG", "UNSUPPORTED_FORMAT", "DECODE_FAILED", "GPU_OOM", "DEADLINE", "UPLOAD_FAILED",
                          "INTERNAL", "POISONED", "INPUT_MISSING"])
        #expect(!CloudErrorCode.poisoned.isRetryable)
        #expect(CloudErrorCode.gpuOOM.isRetryable)
        #expect(CloudTask.stems4.outputSlots == ["drums", "bass", "other"])
    }
}
