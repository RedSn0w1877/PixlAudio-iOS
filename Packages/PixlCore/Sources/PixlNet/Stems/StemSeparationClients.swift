// Cloud stem separation (the "BS-RoFormer Render Backend" in Experimental settings), ported from
// data/tais/stems/BsRoformerApiClient.kt (a Gradio Space's queue API) and DirectPostStemApiClient.kt (one multipart
// POST that answers with audio). The protocol logic lives here so it is testable; the app supplies the transport and
// writes the returned bytes to disk.

import Foundation
import PixlFoundation

/// A cloud render's audio (`RoformerResult`, as bytes): the instrumental, and the vocals when the backend returned
/// them too.
public struct StemRenderResult: Sendable, Hashable {
    public var instrumental: Data
    public var vocals: Data?

    public init(instrumental: Data, vocals: Data?) {
        self.instrumental = instrumental
        self.vocals = vocals
    }
}

/// Which backend protocol the Experimental settings point at (`TaisRoformerBackendType`, stored as its name).
public enum StemBackendType: String, Sendable, CaseIterable {
    case gradioSpace = "GRADIO_SPACE"
    case directPost = "DIRECT_POST"
}

/// The `tais_roformer_*` settings.
public struct StemBackendSettings: Sendable, Hashable {
    public var type: StemBackendType
    public var baseURL: String
    public var apiName: String
    public var apiKey: String?
    public var extraArgument: String?

    public init(type: StemBackendType, baseURL: String, apiName: String, apiKey: String?, extraArgument: String?) {
        self.type = type
        self.baseURL = baseURL
        self.apiName = apiName
        self.apiKey = apiKey
        self.extraArgument = extraArgument
    }

    /// Blank base URL = the cloud render stays disabled (Android hint text).
    public var isConfigured: Bool { !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A file part for a multipart upload.
public struct MultipartFile: Sendable, Hashable {
    public var fieldName: String
    public var fileName: String
    public var contentType: String
    public var data: Data

    public init(fieldName: String, fileName: String, contentType: String = "audio/*", data: Data) {
        self.fieldName = fieldName
        self.fileName = fileName
        self.contentType = contentType
        self.data = data
    }

    /// `multipart/form-data` body with one file part (OkHttp `MultipartBody` layout) and its Content-Type.
    public func formBody(boundary: String) -> (body: Data, contentType: String) {
        var body = Data()
        let safeName = fileName.replacingOccurrences(of: "\"", with: "%22")
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n".utf8))
        body.append(Data("Content-Length: \(data.count)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }
}

/// Coarse stage text for the progress card (a single GPU call has no per-percent signal).
public typealias StemStageReporter = @Sendable (String) async -> Void

/// `BsRoformerApiClient`: the Gradio ≥ 4 queue protocol — upload, submit, read the SSE result stream (reconnecting
/// when the connection drops mid-render), download the file outputs. Two file outputs = vocals then instrumental; one
/// = the instrumental. Returns nil on any failure so the caller can fall back.
public struct GradioStemClient: Sendable {
    public let http: any HTTPClient
    public var boundary: String
    /// Sleeps between reconnects (tests pass a no-op).
    public var backoff: @Sendable () async -> Void

    public init(http: any HTTPClient, boundary: String = "pixlaudio-\(UUID().uuidString)",
                backoff: @escaping @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 1_000_000_000) }) {
        self.http = http
        self.boundary = boundary
        self.backoff = backoff
    }

    public func separate(settings: StemBackendSettings, audio: MultipartFile, pollTimeout: TimeInterval = 15 * 60,
                         onStage: StemStageReporter = { _ in }) async -> StemRenderResult? {
        var base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        var route = settings.apiName.trimmingCharacters(in: .whitespacesAndNewlines)
        while route.hasPrefix("/") { route.removeFirst() }
        let key = settings.apiKey
        await onStage("Connecting to BS-RoFormer GPU…")
        guard let uploaded = await upload(base: base, apiKey: key, audio: audio),
              let eventId = await submit(base: base, route: route, apiKey: key, uploadedPath: uploaded,
                                         extraArg: settings.extraArgument) else { return nil }
        await onStage("Isolating stems…")
        guard let outputs = await poll(base: base, route: route, apiKey: key, eventId: eventId, timeout: pollTimeout),
              let instrumentalURL = outputs.last else { return nil }
        await onStage("Downloading the isolated instrumental…")
        guard let instrumental = await download(instrumentalURL, apiKey: key) else { return nil }
        let vocals: Data? = outputs.count > 1 ? await download(outputs[0], apiKey: key) : nil
        return StemRenderResult(instrumental: instrumental, vocals: vocals)
    }

    func upload(base: String, apiKey: String?, audio: MultipartFile) async -> String? {
        var file = audio
        file.fieldName = "files"
        let form = file.formBody(boundary: boundary)
        var request = authed(HTTPRequest(method: .post, url: "\(base)/gradio_api/upload", body: form.body,
                                         timeout: 300), apiKey)
        request.setHeader("Content-Type", form.contentType)
        guard let response = try? await http.send(request), response.isSuccessful,
              let first = OrgJSON.parse(response.body)?.arrayValue?.first?.stringValue, !first.isEmpty else { return nil }
        return first
    }

    func submit(base: String, route: String, apiKey: String?, uploadedPath: String, extraArg: String?) async -> String? {
        var meta = JSONObject()
        meta.append("_type", .string("gradio.FileData"))
        var fileData = JSONObject()
        fileData.append("path", .string(uploadedPath))
        fileData.append("meta", .object(meta))
        var data: [JSONValue] = [.object(fileData)]
        if let extraArg, !extraArg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { data.append(.string(extraArg)) }
        var payload = JSONObject()
        payload.append("data", .array(data))
        var request = authed(HTTPRequest(method: .post, url: "\(base)/gradio_api/call/\(route)",
                                         body: Data(JSONWriter.write(.object(payload)).utf8), timeout: 60), apiKey)
        request.setHeader("Content-Type", "application/json")
        guard let response = try? await http.send(request), response.isSuccessful,
              let id = OrgJSON.parse(response.body)?["event_id"]?.stringValue, !id.isEmpty else { return nil }
        return id
    }

    /// Reads the stream until `event: complete` / `event: error`; a dropped connection or a stream that ends
    /// without either reconnects until `timeout`.
    func poll(base: String, route: String, apiKey: String?, eventId: String, timeout: TimeInterval) async -> [String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return nil }
            var request = authed(HTTPRequest(url: "\(base)/gradio_api/call/\(route)/\(eventId)",
                                             timeout: max(deadline.timeIntervalSinceNow, 1)), apiKey)
            request.setHeader("Accept", "text/event-stream")
            do {
                let response = try await http.send(request)
                guard response.isSuccessful else { return nil }
                switch Self.readEvents(response.text) {
                case .complete(let urls): return urls
                case .error: return nil
                case .incomplete: break
                }
            } catch {
                if Task.isCancelled { return nil }
            }
            await backoff()
        }
        return nil
    }

    /// The outcome of one SSE body.
    public enum StreamOutcome: Sendable, Hashable {
        case complete([String])
        case error(String)
        case incomplete
    }

    /// Parses `event:` / `data:` lines (`pollOnce`). Some builds omit `event:` lines; those keep reading.
    public static func readEvents(_ text: String) -> StreamOutcome {
        var currentEvent: String?
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.hasPrefix("event:") {
                currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                switch currentEvent {
                case "complete": return .complete(fileURLs(data))
                case "error": return .error(data)
                default: continue
                }
            }
        }
        return .incomplete
    }

    /// Every FileData element's `url` (else `path`), in order.
    public static func fileURLs(_ dataText: String) -> [String] {
        guard let array = OrgJSON.parse(dataText)?.arrayValue else { return [] }
        return array.compactMap { element in
            guard let object = element.objectValue else { return nil }
            if let url = object["url"]?.stringValue, !url.isEmpty { return url }
            if let path = object["path"]?.stringValue, !path.isEmpty { return path }
            return nil
        }
    }

    func download(_ url: String, apiKey: String?) async -> Data? {
        guard let response = try? await http.send(authed(HTTPRequest(url: url, timeout: 600), apiKey)),
              response.isSuccessful, !response.body.isEmpty else { return nil }
        return response.body
    }
}

/// `DirectPostStemApiClient`: one `POST {base}{route}` with the file as `file`; the answer is the instrumental.
public struct DirectPostStemClient: Sendable {
    public let http: any HTTPClient
    public var boundary: String

    public init(http: any HTTPClient, boundary: String = "pixlaudio-\(UUID().uuidString)") {
        self.http = http
        self.boundary = boundary
    }

    public func separate(settings: StemBackendSettings, audio: MultipartFile, readTimeout: TimeInterval = 15 * 60,
                         onStage: StemStageReporter = { _ in }) async -> StemRenderResult? {
        var base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        var path = settings.apiName.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { path = "/predict" }
        if !path.hasPrefix("/") { path = "/" + path }
        await onStage("Connecting to render server…")
        var file = audio
        file.fieldName = "file"
        let form = file.formBody(boundary: boundary)
        var request = authed(HTTPRequest(method: .post, url: base + path, body: form.body, timeout: readTimeout),
                             settings.apiKey)
        request.setHeader("ngrok-skip-browser-warning", "true")
        request.setHeader("Content-Type", form.contentType)
        await onStage("Isolating stems…")
        guard let response = try? await http.send(request), response.isSuccessful, !response.body.isEmpty else {
            return nil
        }
        let type = (response.header("Content-Type") ?? "").lowercased()
        guard type.isEmpty || type.hasPrefix("audio") || type.contains("octet-stream") else { return nil }
        await onStage("Downloading the isolated instrumental…")
        return StemRenderResult(instrumental: response.body, vocals: nil)
    }
}

private func authed(_ request: HTTPRequest, _ apiKey: String?) -> HTTPRequest {
    var request = request
    if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        request.setHeader("Authorization", "Bearer \(apiKey)")
    }
    return request
}
