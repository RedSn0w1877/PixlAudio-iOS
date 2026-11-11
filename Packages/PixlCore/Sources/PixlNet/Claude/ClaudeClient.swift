// Sends Claude requests: non-streaming over `HTTPClient`, streaming over a line source (the app's URLSession
// `bytes(for:)`), with the retry rules of the spec â€” 429, 5xx (529 overloaded included), a stream `error` event and
// network failures are retried with backoff (honouring `retry-after`), at most twice; 400/401/403 are never retried
// (the caller falls back to the on-device model and says "Cloud AI isn't available right now").

import Foundation
import PixlFoundation

/// A Claude call that failed.
public enum ClaudeError: Error, Sendable, Hashable, CustomStringConvertible {
    /// No HTTP response (offline, DNS, reset, timeout).
    case network(String)
    /// An HTTP error status with the API's `error.type` / `error.message`.
    case http(status: Int, type: String?, message: String?, retryAfterSeconds: Double?)
    /// An `error` event inside a stream.
    case stream(type: String, message: String)
    /// The body was not a message, or the stream ended before `message_stop` with nothing usable.
    case invalidResponse
    /// No built-in key in this build.
    case noKey
    /// The stream broke after text was shown: never retried (it would repeat the text); the caller falls back.
    case interrupted(String)

    public var description: String {
        switch self {
        case .network(let message): "Cloud AI network error: \(message)"
        case .http(let status, let type, let message, _): "Cloud AI HTTP \(status) \(type ?? ""): \(message ?? "")"
        case .stream(let type, let message): "Cloud AI stream error \(type): \(message)"
        case .invalidResponse: "Cloud AI returned an unreadable response"
        case .noKey: "No built-in cloud AI key in this build"
        case .interrupted(let message): "Cloud AI stream interrupted: \(message)"
        }
    }

    /// 429, 5xx, a stream error (overloaded / api_error) and network failures may succeed when tried again.
    public var isRetryable: Bool {
        switch self {
        case .network: true
        case .http(let status, _, _, _): status == 429 || status >= 500
        case .stream(let type, _): type == "overloaded_error" || type == "api_error" || type == "rate_limit_error"
        case .invalidResponse, .noKey, .interrupted: false
        }
    }

    /// The plain message for normal users (developer details stay in Diagnostics).
    public static let unavailableMessage = "Cloud AI isn't available right now"

    public var retryAfterSeconds: Double? {
        if case .http(_, _, _, let retryAfter) = self { return retryAfter }
        return nil
    }

    /// Reads an error response.
    public static func fromResponse(_ response: HTTPResponse) -> ClaudeError {
        let parsed = AiProviderSupport.parseError(response.text)
        let retryAfter = response.header("retry-after").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return .http(status: response.statusCode, type: parsed.type, message: parsed.message, retryAfterSeconds: retryAfter)
    }
}

/// When to try a failed request again.
public enum ClaudeRetryPolicy {
    public static let maxRetries = 2
    /// The longest `retry-after` honoured; a longer one gives up (the on-device model answers instead).
    public static let maxRetryAfterSeconds: Double = 20

    /// The wait before retry number `attempt` (1-based), or nil to give up.
    public static func delay(for error: ClaudeError, attempt: Int) -> Double? {
        guard error.isRetryable, attempt <= maxRetries else { return nil }
        if let retryAfter = error.retryAfterSeconds {
            return retryAfter <= maxRetryAfterSeconds ? max(retryAfter, 0) : nil
        }
        return attempt == 1 ? 1 : 2.5
    }
}

/// A streamed response: the lines, or the error response when the status isn't 2xx.
public enum ClaudeStreamOpening: Sendable {
    case lines(AsyncThrowingStream<String, any Error>)
    case failure(HTTPResponse)
}

/// Opens a streaming request (the app: `URLSession.bytes(for:)`, lines; tests: fixtures).
public protocol ClaudeLineStreaming: Sendable {
    func open(_ request: HTTPRequest) async throws -> ClaudeStreamOpening
}

/// Sends one Claude request (with retries) and returns the assembled message.
public protocol ClaudeMessaging: Sendable {
    func send(_ request: ClaudeRequest, onUpdate: @escaping @Sendable (ClaudeStreamUpdate) async -> Void) async throws -> ClaudeMessage
}

/// The client: non-streaming requests over `http`, streaming ones over `streamer`.
public struct ClaudeClient: ClaudeMessaging {
    public let apiKey: String
    public let http: any HTTPClient
    public let streamer: (any ClaudeLineStreaming)?
    /// Waits between retries (tests pass a no-op).
    public let sleep: @Sendable (Double) async throws -> Void

    public init(apiKey: String, http: any HTTPClient, streamer: (any ClaudeLineStreaming)? = nil,
                sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                }) {
        self.apiKey = apiKey
        self.http = http
        self.streamer = streamer
        self.sleep = sleep
    }

    public func send(_ request: ClaudeRequest,
                     onUpdate: @escaping @Sendable (ClaudeStreamUpdate) async -> Void = { _ in }) async throws -> ClaudeMessage {
        guard !apiKey.isEmpty else { throw ClaudeError.noKey }
        var attempt = 0
        while true {
            do {
                if request.stream, let streamer {
                    return try await sendStreaming(request, streamer: streamer, onUpdate: onUpdate)
                }
                var plain = request
                plain.stream = false
                return try await sendPlain(plain)
            } catch let error as ClaudeError {
                attempt += 1
                guard let wait = ClaudeRetryPolicy.delay(for: error, attempt: attempt) else { throw error }
                try await sleep(wait)
            }
        }
    }

    private func sendPlain(_ request: ClaudeRequest) async throws -> ClaudeMessage {
        let response: HTTPResponse
        do {
            response = try await http.send(request.httpRequest(apiKey: apiKey))
        } catch is CancellationError {
            throw CancellationError()
        } catch let transport as HTTPTransportError {
            throw ClaudeError.network(transport.message)
        } catch {
            throw ClaudeError.network(String(describing: error))
        }
        guard response.isSuccessful else { throw ClaudeError.fromResponse(response) }
        guard let message = ClaudeMessage.parse(response.text) else { throw ClaudeError.invalidResponse }
        return message
    }

    private func sendStreaming(_ request: ClaudeRequest, streamer: any ClaudeLineStreaming,
                               onUpdate: @escaping @Sendable (ClaudeStreamUpdate) async -> Void) async throws -> ClaudeMessage {
        let opening: ClaudeStreamOpening
        do {
            opening = try await streamer.open(request.httpRequest(apiKey: apiKey))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClaudeError {
            throw error
        } catch {
            throw ClaudeError.network(Self.describe(error))
        }
        switch opening {
        case .failure(let response):
            throw ClaudeError.fromResponse(response)
        case .lines(let lines):
            let parser = ClaudeSSEParser()
            var accumulator = ClaudeStreamAccumulator()
            var sawText = false
            do {
                for try await line in lines {
                    guard let event = parser.parse(line: line) else { continue }
                    if let update = try accumulator.apply(event) {
                        if case .text = update { sawText = true }
                        await onUpdate(update)
                    }
                    if accumulator.isComplete { break }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ClaudeError {
                // After text was shown a retry would repeat it: the caller handles the break instead.
                if sawText { throw ClaudeError.interrupted(error.description) }
                throw error
            } catch {
                if sawText { throw ClaudeError.interrupted(Self.describe(error)) }
                throw ClaudeError.network(Self.describe(error))
            }
            let message = accumulator.message()
            guard accumulator.isComplete || message.stopReason != nil else {
                throw sawText ? ClaudeError.interrupted("stream ended early") : ClaudeError.network("stream ended early")
            }
            return message
        }
    }

    static func describe(_ error: any Error) -> String {
        (error as? HTTPTransportError)?.message ?? String(describing: error)
    }
}
