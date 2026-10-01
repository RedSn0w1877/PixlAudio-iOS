// The transport seam. PixlNet never opens a socket: every client takes an `HTTPClient`, which the app implements
// with URLSession (or uses `URLSessionHTTPClient` below) and tests implement with fixtures. Requests and
// responses are plain values so every request body the ports build can be checked byte for byte.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP request method.
public enum HTTPMethod: String, Sendable, Hashable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case head = "HEAD"
}

/// One header line (names compare case-insensitively).
public struct HTTPHeader: Sendable, Hashable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// An HTTP request.
public struct HTTPRequest: Sendable, Hashable {
    public var method: HTTPMethod
    /// Absolute URL, already encoded.
    public var url: String
    /// Headers in the order they are sent.
    public var headers: [HTTPHeader]
    public var body: Data?
    /// Overall timeout in seconds (nil = the client's default).
    public var timeout: Double?

    public init(method: HTTPMethod = .get, url: String, headers: [HTTPHeader] = [], body: Data? = nil, timeout: Double? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// The value of a header (the last one with that name).
    public func header(_ name: String) -> String? {
        headers.last { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// OkHttp `header(name, value)`: replaces every header with this name.
    public mutating func setHeader(_ name: String, _ value: String) {
        headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        headers.append(HTTPHeader(name, value))
    }

    /// OkHttp `addHeader(name, value)`.
    public mutating func addHeader(_ name: String, _ value: String) {
        headers.append(HTTPHeader(name, value))
    }

    /// The body as UTF-8 text (for tests and logs that never include secrets).
    public var bodyText: String? { body.map { String(decoding: $0, as: UTF8.self) } }
}

/// An HTTP response.
public struct HTTPResponse: Sendable, Hashable {
    public var statusCode: Int
    public var headers: [HTTPHeader]
    public var body: Data

    public init(statusCode: Int, headers: [HTTPHeader] = [], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Convenience for fixtures.
    public init(statusCode: Int, headers: [HTTPHeader] = [], text: String) {
        self.init(statusCode: statusCode, headers: headers, body: Data(text.utf8))
    }

    /// OkHttp `isSuccessful`: 200...299.
    public var isSuccessful: Bool { (200...299).contains(statusCode) }

    /// A header value (the last one with that name).
    public func header(_ name: String) -> String? {
        headers.last { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The body decoded as UTF-8.
    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// A transport failure (no HTTP response). `message` is what Android would log as `e.message`.
public struct HTTPTransportError: Error, Sendable, Hashable, CustomStringConvertible {
    public var kind: String
    public var message: String

    public init(kind: String = "IOException", message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { "\(kind): \(message)" }
}

/// Sends HTTP requests. Implementations must honour `HTTPRequest.timeout` and cancellation.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

// MARK: - URLSession adapter

/// `HTTPClient` over `URLSession` — the app's default transport (works with FoundationNetworking off Apple
/// platforms too, though PixlCore's tests never use the network).
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The `URLRequest` for a request value.
    public static func makeURLRequest(_ request: HTTPRequest) -> URLRequest? {
        guard let url = URL(string: request.url) else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        for header in request.headers { urlRequest.addValue(header.value, forHTTPHeaderField: header.name) }
        urlRequest.httpBody = request.body
        if let timeout = request.timeout { urlRequest.timeoutInterval = timeout }
        return urlRequest
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let urlRequest = Self.makeURLRequest(request) else {
            throw HTTPTransportError(kind: "IllegalArgumentException", message: "Invalid URL")
        }
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, any Error>) in
                let task = session.dataTask(with: urlRequest) { data, response, error in
                    if let error {
                        continuation.resume(throwing: HTTPTransportError(kind: "IOException", message: error.localizedDescription))
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: HTTPTransportError(message: "No HTTP response"))
                        return
                    }
                    var headers: [HTTPHeader] = []
                    for (key, value) in http.allHeaderFields {
                        headers.append(HTTPHeader(String(describing: key), String(describing: value)))
                    }
                    continuation.resume(returning: HTTPResponse(statusCode: http.statusCode, headers: headers, body: data ?? Data()))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false

        func set(_ task: URLSessionDataTask) {
            lock.lock()
            self.task = task
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }
}
