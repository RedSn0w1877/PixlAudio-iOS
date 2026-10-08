// AWS Signature Version 4 for S3-compatible storage (Cloudflare R2 first; design §1, §4, §7.1). Two modes:
// - query presigning (`X-Amz-*` in the URL, payload `UNSIGNED-PAYLOAD`, only `host` signed): every R2 transfer the
//   phone and the worker make. A presigned URL carries no reusable secret, so it may sit in a RunPod job input or in
//   the system's background-transfer daemon.
// - header signing (`Authorization: AWS4-HMAC-SHA256 …`): the RunPod network-volume fallback, whose S3 API has no
//   presigned URLs.
// Pure Swift: SHA-256 and HMAC-SHA-256 are injected (CryptoKit in the app, test implementations in PixlNetTests).
// Reference: docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html and sig-v4-header-based-auth.html.

import Foundation

/// HMAC-SHA-256(key, message).
public typealias HMACSHA256Function = @Sendable (_ key: [UInt8], _ message: [UInt8]) -> [UInt8]

/// An S3 access key pair (R2: a bucket-scoped API token's Access Key ID and Secret).
public struct S3Credentials: Sendable, Hashable {
    public var accessKeyId: String
    public var secretAccessKey: String

    public init(accessKeyId: String, secretAccessKey: String) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
    }

    public var isComplete: Bool {
        !accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Where the bucket lives. R2: endpoint `https://<account-id>.r2.cloudflarestorage.com`, region `auto`, path-style.
public struct S3Location: Sendable, Hashable {
    /// `https://host[:port]` (a trailing slash or path is ignored).
    public var endpoint: String
    public var bucket: String
    public var region: String
    /// `true`: `https://<bucket>.<host>/<key>` (AWS's examples); `false`: `https://<host>/<bucket>/<key>` (R2).
    public var virtualHosted: Bool

    public init(endpoint: String, bucket: String, region: String = "auto", virtualHosted: Bool = false) {
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.virtualHosted = virtualHosted
    }

    /// `https` scheme and host (with port) of `endpoint`, or nil when it isn't an `https://` URL with a host.
    public var endpointHost: String? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("https://") else { return nil }
        let rest = trimmed.dropFirst("https://".count)
        let host = String(rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !host.isEmpty, !host.contains("@"), !host.contains(" ") else { return nil }
        return host.lowercased()
    }

    /// A valid S3 bucket name (3–63 of `a-z 0-9 . -`, starting and ending with a letter or digit).
    public var hasValidBucket: Bool {
        let bytes = Array(bucket.utf8)
        guard (3...63).contains(bytes.count) else { return false }
        func ok(_ b: UInt8) -> Bool {
            switch b {
            case 0x61...0x7A, 0x30...0x39, 0x2E, 0x2D: true
            default: false
            }
        }
        func alnum(_ b: UInt8) -> Bool {
            switch b {
            case 0x61...0x7A, 0x30...0x39: true
            default: false
            }
        }
        return bytes.allSatisfy(ok) && alnum(bytes[0]) && alnum(bytes[bytes.count - 1])
    }

    public var isValid: Bool { endpointHost != nil && hasValidBucket && !region.isEmpty }

    /// The host requests go to.
    var requestHost: String? {
        guard let host = endpointHost else { return nil }
        return virtualHosted ? "\(bucket).\(host)" : host
    }

    /// The URI path of an object (`key` empty = the bucket itself, for ListObjectsV2).
    func path(forKey key: String) -> String {
        let encodedKey = S3Signer.uriEncode(key, encodeSlash: false)
        if virtualHosted { return "/" + encodedKey }
        return key.isEmpty ? "/" + S3Signer.uriEncode(bucket, encodeSlash: true)
            : "/" + S3Signer.uriEncode(bucket, encodeSlash: true) + "/" + encodedKey
    }
}

/// SigV4 signer for one location and key pair.
public struct S3Signer: Sendable {
    /// R2 and S3 accept presigned URLs valid for at most 7 days.
    public static let maximumExpirySeconds = 604_800
    public static let algorithm = "AWS4-HMAC-SHA256"
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"
    /// SHA-256 of an empty body (header signing of GET/HEAD/DELETE).
    public static let emptyPayloadSHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    public let credentials: S3Credentials
    public let location: S3Location
    public let service: String
    private let sha256: SHA256Function
    private let hmac: HMACSHA256Function

    public init(credentials: S3Credentials, location: S3Location, service: String = "s3",
                sha256: @escaping SHA256Function, hmac: @escaping HMACSHA256Function) {
        self.credentials = credentials
        self.location = location
        self.service = service
        self.sha256 = sha256
        self.hmac = hmac
    }

    // MARK: Presigned URLs

    /// A presigned URL for `method` on `key` (empty key = the bucket, e.g. ListObjectsV2 with `query`), valid for
    /// `expiresSeconds` (clamped to 1 s…7 d) from `nowSeconds` (Unix time). Only `host` is signed, so the client may
    /// send any other header (Content-Type, Range).
    public func presignedURL(method: HTTPMethod, key: String, query: [(String, String)] = [], expiresSeconds: Int,
                             nowSeconds: Int64) -> String? {
        guard let host = location.requestHost else { return nil }
        let amzDate = Self.amzDate(nowSeconds)
        let date = String(amzDate.prefix(8))
        let scope = "\(date)/\(location.region)/\(service)/aws4_request"
        let expires = min(max(expiresSeconds, 1), Self.maximumExpirySeconds)
        var parameters = query
        parameters.append(("X-Amz-Algorithm", Self.algorithm))
        parameters.append(("X-Amz-Credential", "\(credentials.accessKeyId)/\(scope)"))
        parameters.append(("X-Amz-Date", amzDate))
        parameters.append(("X-Amz-Expires", String(expires)))
        parameters.append(("X-Amz-SignedHeaders", "host"))
        let canonicalQuery = Self.canonicalQuery(parameters)
        let path = location.path(forKey: key)
        let canonicalRequest = [method.rawValue, path, canonicalQuery, "host:\(host)\n", "host", Self.unsignedPayload]
            .joined(separator: "\n")
        let signature = sign(canonicalRequest: canonicalRequest, amzDate: amzDate, scope: scope, date: date)
        return "https://\(host)\(path)?\(canonicalQuery)&X-Amz-Signature=\(signature)"
    }

    // MARK: Header signing (volume fallback)

    /// A request signed in the `Authorization` header. `payloadSHA256` is the lower-case hex SHA-256 of the body
    /// (`emptyPayloadSHA256` for none, or `UNSIGNED-PAYLOAD`). `headers` are added and signed too (names any case).
    public func signedRequest(method: HTTPMethod, key: String, query: [(String, String)] = [],
                              headers: [HTTPHeader] = [], body: Data? = nil, payloadSHA256: String,
                              nowSeconds: Int64) -> HTTPRequest? {
        guard let host = location.requestHost else { return nil }
        let amzDate = Self.amzDate(nowSeconds)
        let date = String(amzDate.prefix(8))
        let scope = "\(date)/\(location.region)/\(service)/aws4_request"
        var signed: [(name: String, value: String)] = [("host", host), ("x-amz-content-sha256", payloadSHA256),
                                                       ("x-amz-date", amzDate)]
        for header in headers {
            let name = header.name.lowercased()
            signed.removeAll { $0.name == name }
            signed.append((name, Self.trimHeaderValue(header.value)))
        }
        signed.sort { $0.name < $1.name }
        let canonicalHeaders = signed.map { "\($0.name):\($0.value)\n" }.joined()
        let signedHeaders = signed.map(\.name).joined(separator: ";")
        let canonicalQuery = Self.canonicalQuery(query)
        let path = location.path(forKey: key)
        let canonicalRequest = [method.rawValue, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadSHA256]
            .joined(separator: "\n")
        let signature = sign(canonicalRequest: canonicalRequest, amzDate: amzDate, scope: scope, date: date)
        let authorization = "\(Self.algorithm) Credential=\(credentials.accessKeyId)/\(scope),"
            + "SignedHeaders=\(signedHeaders),Signature=\(signature)"
        var request = HTTPRequest(method: method,
                                  url: "https://\(host)\(path)" + (canonicalQuery.isEmpty ? "" : "?\(canonicalQuery)"),
                                  body: body)
        for header in signed where header.name != "host" { request.addHeader(header.name, header.value) }
        request.addHeader("Authorization", authorization)
        return request
    }

    // MARK: Parts (internal for the test vectors)

    func sign(canonicalRequest: String, amzDate: String, scope: String, date: String) -> String {
        let stringToSign = [Self.algorithm, amzDate, scope, Self.hex(sha256(Array(canonicalRequest.utf8)))]
            .joined(separator: "\n")
        return Self.hex(hmac(signingKey(date: date), Array(stringToSign.utf8)))
    }

    func signingKey(date: String) -> [UInt8] {
        let kDate = hmac(Array("AWS4\(credentials.secretAccessKey)".utf8), Array(date.utf8))
        let kRegion = hmac(kDate, Array(location.region.utf8))
        let kService = hmac(kRegion, Array(service.utf8))
        return hmac(kService, Array("aws4_request".utf8))
    }

    /// Query parameters URI-encoded and sorted by encoded name, then value.
    static func canonicalQuery(_ parameters: [(String, String)]) -> String {
        // Spelled out with explicit types: the chained-closure version made the type checker time out.
        var encoded: [(name: String, value: String)] = []
        encoded.reserveCapacity(parameters.count)
        for (name, value) in parameters {
            encoded.append((uriEncode(name, encodeSlash: true), uriEncode(value, encodeSlash: true)))
        }
        encoded.sort { (a: (name: String, value: String), b: (name: String, value: String)) -> Bool in
            a.name == b.name ? a.value < b.value : a.name < b.name
        }
        var pairs: [String] = []
        pairs.reserveCapacity(encoded.count)
        for pair in encoded { pairs.append(pair.name + "=" + pair.value) }
        return pairs.joined(separator: "&")
    }

    /// AWS `UriEncode`: every byte except `A–Z a–z 0–9 - _ . ~` as `%XX` (upper-case hex); `/` kept in paths.
    static func uriEncode(_ text: String, encodeSlash: Bool) -> String {
        let hexDigits = Array("0123456789ABCDEF")
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            if isUnreserved(byte) || (byte == 0x2F && !encodeSlash) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out.append("%")
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return out
    }

    /// `A–Z a–z 0–9 - _ . ~` (a switch: the long `||` chain made the type checker time out).
    static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E, 0x7E: true
        default: false
        }
    }

    /// Header values: leading/trailing spaces removed, inner runs of spaces collapsed to one.
    static func trimHeaderValue(_ value: String) -> String {
        value.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// `yyyyMMdd'T'HHmmss'Z'` in UTC for a Unix time (no calendar API, so it is the same on every platform).
    public static func amzDate(_ unixSeconds: Int64) -> String {
        let days = unixSeconds >= 0 ? unixSeconds / 86_400 : (unixSeconds - 86_399) / 86_400
        let secondsOfDay = unixSeconds - days * 86_400
        // Howard Hinnant's civil_from_days.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        func pad(_ v: Int64, _ width: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return pad(year, 4) + pad(month, 2) + pad(day, 2) + "T" + pad(secondsOfDay / 3600, 2)
            + pad(secondsOfDay % 3600 / 60, 2) + pad(secondsOfDay % 60, 2) + "Z"
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return out
    }
}

// MARK: - ListObjectsV2

/// One page of `ListObjectsV2` (`list-type=2`).
public struct S3ListResult: Sendable, Hashable {
    public struct Object: Sendable, Hashable {
        public var key: String
        public var size: Int64
        public var lastModified: String?

        public init(key: String, size: Int64, lastModified: String?) {
            self.key = key
            self.size = size
            self.lastModified = lastModified
        }
    }

    public var objects: [Object]
    /// `CommonPrefixes/Prefix` (with `delimiter=/`: the `out/<jobKey>/` folders).
    public var commonPrefixes: [String]
    public var isTruncated: Bool
    public var nextContinuationToken: String?

    public init(objects: [Object], commonPrefixes: [String], isTruncated: Bool, nextContinuationToken: String?) {
        self.objects = objects
        self.commonPrefixes = commonPrefixes
        self.isTruncated = isTruncated
        self.nextContinuationToken = nextContinuationToken
    }

    /// The query of a ListObjectsV2 request.
    public static func query(prefix: String, delimiter: String?, continuationToken: String?, maxKeys: Int = 1000)
        -> [(String, String)] {
        var query: [(String, String)] = [("list-type", "2"), ("prefix", prefix), ("max-keys", String(maxKeys))]
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let continuationToken { query.append(("continuation-token", continuationToken)) }
        return query
    }

    /// Parses the XML body. A tiny scanner rather than `XMLParser` (FoundationXML isn't on every platform PixlCore
    /// builds for); S3 list bodies are flat and well-formed.
    public static func parse(_ xml: String) -> S3ListResult? {
        guard xml.contains("<ListBucketResult") else { return nil }
        var objects: [Object] = []
        for block in elements("Contents", in: xml) {
            guard let key = elements("Key", in: block).first.map(xmlUnescape) else { continue }
            let size = elements("Size", in: block).first.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            objects.append(Object(key: key, size: size, lastModified: elements("LastModified", in: block).first))
        }
        var prefixes: [String] = []
        for block in elements("CommonPrefixes", in: xml) {
            if let prefix = elements("Prefix", in: block).first { prefixes.append(xmlUnescape(prefix)) }
        }
        // Top-level flags only (a <Contents> never holds these names).
        let truncated = elements("IsTruncated", in: xml).first?.trimmingCharacters(in: .whitespaces).lowercased() == "true"
        let token = elements("NextContinuationToken", in: xml).first.map(xmlUnescape)
        return S3ListResult(objects: objects, commonPrefixes: prefixes, isTruncated: truncated,
                            nextContinuationToken: token)
    }

    /// The inner text of every `<name>…</name>` (no attributes expected; `<name/>` yields "").
    static func elements(_ name: String, in xml: String) -> [String] {
        var out: [String] = []
        let open = "<\(name)>", close = "</\(name)>", empty = "<\(name)/>"
        var rest = Substring(xml)
        while true {
            let openRange = rest.range(of: open)
            let emptyRange = rest.range(of: empty)
            if let emptyRange, openRange.map({ emptyRange.lowerBound < $0.lowerBound }) ?? true {
                out.append("")
                rest = rest[emptyRange.upperBound...]
                continue
            }
            guard let openRange, let closeRange = rest.range(of: close, range: openRange.upperBound..<rest.endIndex) else {
                break
            }
            out.append(String(rest[openRange.upperBound..<closeRange.lowerBound]))
            rest = rest[closeRange.upperBound...]
        }
        return out
    }

    static func xmlUnescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
}
