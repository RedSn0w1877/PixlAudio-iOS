import CryptoKit
import Foundation
import PixlNet

/// CryptoKit for Cloud Studio (design §7.1 `CloudPlatform`): PixlNet's SigV4 signer takes SHA-256 and HMAC-SHA-256
/// injected (PixlCore has no CryptoKit), and the preparer and importer hash whole files in 1 MiB slices.
nonisolated enum CloudPlatform {
    static let sha256: SHA256Function = { bytes in Array(SHA256.hash(data: Data(bytes))) }

    static let hmac: HMACSHA256Function = { key, message in
        Array(HMAC<SHA256>.authenticationCode(for: Data(message), using: SymmetricKey(data: Data(key))))
    }

    /// The lower-case hex SHA-256 and byte length of a file, read in slices (never the whole song in memory).
    static func fileDigest(_ url: URL) throws -> (sha256: String, bytes: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, total)
    }

    /// The lower-case hex SHA-256 of a small payload (`lyrics.json`).
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The signer for the bucket in `config`, or nil when it isn't filled in.
    static func signer(_ config: CloudConfigInput) -> S3Signer? {
        guard let location = config.location, config.credentials.isComplete else { return nil }
        return S3Signer(credentials: config.credentials, location: location, sha256: sha256, hmac: hmac)
    }

    /// RunPod and the bucket's small requests: no cookies, no cache (responses can carry job details).
    static let apiSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    /// Start of the local calendar month containing `ms` (the monthly cap resets on the 1st, here).
    static func localMonthStartMs(_ ms: Int64) -> Int64 {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let start = Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
        return Int64((start.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// `CFBundleShortVersionString (CFBundleVersion)` for `client.build`.
    static var build: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let number = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(number))"
    }
}
