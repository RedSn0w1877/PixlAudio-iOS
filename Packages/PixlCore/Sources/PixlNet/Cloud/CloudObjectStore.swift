// Small-object access to the Cloud Studio bucket through short-lived presigned URLs (design §2.5, §7.2, §7.5): HEAD
// and GET of manifests, the KB-sized lyrics.json, the connection probe, DELETE after import, and ListObjectsV2 of
// `out/`. Large transfers (the song upload, the instrumental download) don't go through here: the app hands their
// presigned URLs to a background URLSession.

import Foundation

/// What the orchestrator needs from the bucket. `CloudObjectClient` is the real one; app tests use fakes.
public protocol CloudObjectStoring: Sendable {
    /// A presigned URL for one object and method, valid for `expiresSeconds`.
    func presignedURL(_ method: HTTPMethod, key: String, expiresSeconds: Int) -> String?
    /// The object's size, or nil when it doesn't exist (404).
    func head(key: String) async throws -> Int64?
    /// The object's bytes, or nil when it doesn't exist (404).
    func get(key: String) async throws -> Data?
    func put(key: String, data: Data, contentType: String) async throws
    /// Deleting a missing object succeeds (S3 answers 204 either way).
    func delete(key: String) async throws
    /// Every key under `prefix` (all pages), or with a delimiter the common prefixes too.
    func list(prefix: String, delimiter: String?) async throws -> S3ListResult
}

/// A bucket request failed.
public enum CloudStorageError: Error, Sendable, Hashable, CustomStringConvertible {
    /// 401/403: the token is wrong, revoked, or not scoped to this bucket.
    case unauthorized(status: Int)
    /// The endpoint or bucket doesn't exist (404 on a bucket-level request, or `NoSuchBucket`).
    case bucketNotFound
    case http(status: Int)
    case network(String)
    case badResponse(String)
    /// The endpoint, bucket or keys aren't filled in correctly.
    case notConfigured

    public var description: String {
        switch self {
        case .unauthorized(let status): "Storage refused the key (HTTP \(status))"
        case .bucketNotFound: "Bucket not found"
        case .http(let status): "Storage answered HTTP \(status)"
        case .network(let message): "Network error: \(message)"
        case .badResponse(let message): "Unexpected storage answer: \(message)"
        case .notConfigured: "Storage isn't set up"
        }
    }
}

/// `CloudObjectStoring` over an `HTTPClient` with presigned URLs (no `Authorization` header is ever sent).
public struct CloudObjectClient: CloudObjectStoring {
    /// Presigned URLs for the phone's own small requests live this long.
    public static let requestExpirySeconds = 900

    private let http: any HTTPClient
    private let signer: S3Signer
    private let nowSeconds: @Sendable () -> Int64

    public init(http: any HTTPClient, signer: S3Signer,
                nowSeconds: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.http = http
        self.signer = signer
        self.nowSeconds = nowSeconds
    }

    public func presignedURL(_ method: HTTPMethod, key: String, expiresSeconds: Int) -> String? {
        signer.presignedURL(method: method, key: key, expiresSeconds: expiresSeconds, nowSeconds: nowSeconds())
    }

    public func head(key: String) async throws -> Int64? {
        let response = try await send(.head, key: key)
        if response.statusCode == 404 { return nil }
        try check(response)
        return response.header("Content-Length").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? 0
    }

    public func get(key: String) async throws -> Data? {
        let response = try await send(.get, key: key)
        if response.statusCode == 404 {
            if response.text.contains("NoSuchBucket") { throw CloudStorageError.bucketNotFound }
            return nil
        }
        try check(response)
        return response.body
    }

    public func put(key: String, data: Data, contentType: String) async throws {
        let response = try await send(.put, key: key, body: data, headers: [HTTPHeader("Content-Type", contentType)])
        if response.statusCode == 404 { throw CloudStorageError.bucketNotFound }
        try check(response)
    }

    public func delete(key: String) async throws {
        let response = try await send(.delete, key: key)
        if response.statusCode == 404 {
            if response.text.contains("NoSuchBucket") { throw CloudStorageError.bucketNotFound }
            return
        }
        try check(response)
    }

    public func list(prefix: String, delimiter: String?) async throws -> S3ListResult {
        var objects: [S3ListResult.Object] = []
        var prefixes: [String] = []
        var token: String?
        for _ in 0..<50 { // 50 pages × 1000 keys is far beyond what the app ever leaves in the bucket
            let query = S3ListResult.query(prefix: prefix, delimiter: delimiter, continuationToken: token)
            guard let url = signer.presignedURL(method: .get, key: "", query: query,
                                                expiresSeconds: Self.requestExpirySeconds, nowSeconds: nowSeconds()) else {
                throw CloudStorageError.notConfigured
            }
            let response = try await transport(HTTPRequest(method: .get, url: url, timeout: 30))
            if response.statusCode == 404 { throw CloudStorageError.bucketNotFound }
            try check(response)
            guard let page = S3ListResult.parse(response.text) else {
                throw CloudStorageError.badResponse("unreadable bucket listing")
            }
            objects += page.objects
            prefixes += page.commonPrefixes
            guard page.isTruncated, let next = page.nextContinuationToken, !next.isEmpty else { break }
            token = next
        }
        return S3ListResult(objects: objects, commonPrefixes: prefixes, isTruncated: false, nextContinuationToken: nil)
    }

    // MARK: Transport

    private func send(_ method: HTTPMethod, key: String, body: Data? = nil, headers: [HTTPHeader] = []) async throws
        -> HTTPResponse {
        guard let url = signer.presignedURL(method: method, key: key, expiresSeconds: Self.requestExpirySeconds,
                                            nowSeconds: nowSeconds()) else {
            throw CloudStorageError.notConfigured
        }
        return try await transport(HTTPRequest(method: method, url: url, headers: headers, body: body, timeout: 60))
    }

    private func transport(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await http.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw CloudStorageError.network(Self.redacted(String(describing: error)))
        }
    }

    private func check(_ response: HTTPResponse) throws {
        if response.isSuccessful { return }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw CloudStorageError.unauthorized(status: response.statusCode)
        }
        throw CloudStorageError.http(status: response.statusCode)
    }

    /// Error text never carries a signature (URLSession errors can quote the URL).
    static func redacted(_ text: String) -> String { CloudRedaction.redact(text) }
}

/// Removes presigned-URL queries from text that may be logged or shown.
public enum CloudRedaction {
    public static func redact(_ text: String) -> String {
        guard text.contains("X-Amz-") else { return text }
        var out = ""
        var rest = Substring(text)
        // Every `X-Amz-…` parameter up to the end of its URL (whitespace, quote or closing bracket) becomes "…".
        while let marker = rest.range(of: "X-Amz-") {
            out += rest[..<marker.lowerBound]
            out += "…"
            let tail = rest[marker.upperBound...]
            let end = tail.firstIndex { $0 == " " || $0 == "\"" || $0 == "'" || $0 == ")" || $0 == "\n" || $0 == ">" }
                ?? tail.endIndex
            rest = tail[end...]
        }
        return out + rest
    }
}
