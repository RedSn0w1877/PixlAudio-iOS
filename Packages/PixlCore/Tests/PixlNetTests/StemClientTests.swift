import Foundation
import Testing
@testable import PixlNet

/// `BsRoformerApiClient` / `DirectPostStemApiClient` behaviour (no Android unit tests exist for them): the Gradio
/// queue protocol including a dropped result stream, output ordering, failures, and the direct POST.
@Suite("Stem separation clients")
struct StemClientTests {
    static let gradio = StemBackendSettings(type: .gradioSpace, baseURL: "https://user-space.hf.space/",
                                            apiName: "/separate", apiKey: "hf_key", extraArgument: "Standard — Vocals")
    static let audio = MultipartFile(fieldName: "x", fileName: "song.m4a", data: Data([1, 2, 3]))

    @Test func gradioUploadsSubmitsReconnectsAndDownloads() async throws {
        let polls = Box(0)
        let http = FixtureHTTPClient { request in
            switch request.url {
            case "https://user-space.hf.space/gradio_api/upload":
                return HTTPResponse(statusCode: 200, text: "[\"/tmp/gradio/abc/song.m4a\"]")
            case "https://user-space.hf.space/gradio_api/call/separate":
                return HTTPResponse(statusCode: 200, text: "{\"event_id\":\"ev1\"}")
            case "https://user-space.hf.space/gradio_api/call/separate/ev1":
                polls.mutate { $0 += 1 }
                if polls.value == 1 { throw HTTPTransportError(message: "Software caused connection abort") }
                if polls.value == 2 { return HTTPResponse(statusCode: 200, text: "event: generating\ndata: null\n\n") }
                return HTTPResponse(statusCode: 200, text: """
                event: heartbeat
                data: null

                event: complete
                data: [{"path":"/v.wav","url":"https://user-space.hf.space/file=v.wav","meta":{"_type":"gradio.FileData"}},{"path":"/i.wav","url":"https://user-space.hf.space/file=i.wav"}]

                """)
            case "https://user-space.hf.space/file=v.wav": return HTTPResponse(statusCode: 200, text: "VOCALS")
            case "https://user-space.hf.space/file=i.wav": return HTTPResponse(statusCode: 200, text: "INSTRUMENTAL")
            default: return HTTPResponse(statusCode: 404, text: "")
            }
        }
        let stages = Box<[String]>([])
        let client = GradioStemClient(http: http, boundary: "B", backoff: {})
        let result = try #require(await client.separate(settings: Self.gradio, audio: Self.audio) { stage in
            stages.mutate { $0.append(stage) }
        })
        #expect(String(decoding: result.instrumental, as: UTF8.self) == "INSTRUMENTAL")
        #expect(result.vocals.map { String(decoding: $0, as: UTF8.self) } == "VOCALS")
        #expect(polls.value == 3)
        #expect(stages.value == ["Connecting to BS-RoFormer GPU…", "Isolating stems…", "Downloading the isolated instrumental…"])

        let requests = http.requests
        let upload = requests[0]
        #expect(upload.header("Authorization") == "Bearer hf_key")
        #expect(upload.header("Content-Type") == "multipart/form-data; boundary=B")
        #expect(upload.bodyText?.contains("name=\"files\"; filename=\"song.m4a\"") == true)
        #expect(requests[1].bodyText ==
                "{\"data\":[{\"path\":\"/tmp/gradio/abc/song.m4a\",\"meta\":{\"_type\":\"gradio.FileData\"}},\"Standard — Vocals\"]}")
        #expect(requests[2].header("Accept") == "text/event-stream")
    }

    @Test func singleOutputIsTheInstrumental() {
        #expect(GradioStemClient.readEvents("event: complete\ndata: [{\"path\":\"/only.wav\"}]\n") == .complete(["/only.wav"]))
        #expect(GradioStemClient.readEvents("event: error\ndata: \"boom\"\n") == .error("\"boom\""))
        #expect(GradioStemClient.readEvents("data: [1]\n") == .incomplete)
        #expect(GradioStemClient.fileURLs("[\"text\", {\"url\":\"\"}, {\"url\":\"u\"}]") == ["u"])
    }

    @Test func gradioErrorEventFailsWithoutRetrying() async {
        let polls = Box(0)
        let http = FixtureHTTPClient { request in
            if request.url.hasSuffix("/upload") { return HTTPResponse(statusCode: 200, text: "[\"p\"]") }
            if request.url.hasSuffix("/call/separate") { return HTTPResponse(statusCode: 200, text: "{\"event_id\":\"e\"}") }
            polls.mutate { $0 += 1 }
            return HTTPResponse(statusCode: 200, text: "event: error\ndata: null\n")
        }
        let result = await GradioStemClient(http: http, backoff: {}).separate(settings: Self.gradio, audio: Self.audio)
        #expect(result == nil)
        #expect(polls.value == 1)
    }

    @Test func gradioFailedUploadReturnsNil() async {
        let http = FixtureHTTPClient(routes: [("https://user-space.hf.space/gradio_api/upload", HTTPResponse(statusCode: 500, text: ""))])
        #expect(await GradioStemClient(http: http, backoff: {}).separate(settings: Self.gradio, audio: Self.audio) == nil)
    }

    @Test func directPostSendsOneFileAndAcceptsAudio() async throws {
        let settings = StemBackendSettings(type: .directPost, baseURL: "https://x.ngrok-free.app", apiName: "",
                                           apiKey: nil, extraArgument: nil)
        let http = FixtureHTTPClient { request in
            HTTPResponse(statusCode: 200, headers: [HTTPHeader("Content-Type", "audio/wav")], text: "RIFFDATA")
        }
        let result = try #require(await DirectPostStemClient(http: http, boundary: "Q").separate(settings: settings, audio: Self.audio))
        #expect(String(decoding: result.instrumental, as: UTF8.self) == "RIFFDATA")
        #expect(result.vocals == nil)
        let request = try #require(http.requests.first)
        #expect(request.url == "https://x.ngrok-free.app/predict")
        #expect(request.header("ngrok-skip-browser-warning") == "true")
        #expect(request.header("Authorization") == nil)
        #expect(request.bodyText?.contains("name=\"file\"; filename=\"song.m4a\"") == true)
    }

    @Test func directPostRejectsNonAudioAnswers() async {
        let settings = StemBackendSettings(type: .directPost, baseURL: "https://x", apiName: "run", apiKey: "k",
                                           extraArgument: nil)
        let http = FixtureHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [HTTPHeader("Content-Type", "text/html")], text: "<html>")
        }
        #expect(await DirectPostStemClient(http: http).separate(settings: settings, audio: Self.audio) == nil)
        #expect(http.requests.first?.url == "https://x/run")
    }
}
