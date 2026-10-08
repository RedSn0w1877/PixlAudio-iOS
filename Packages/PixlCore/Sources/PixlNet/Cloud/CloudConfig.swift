// Settings › Developer › Experimental › Cloud processing (design §3.5 E, §7.2): what the person types, checked and
// normalised before anything is signed or sent. The six fields, in screen order: Endpoint ID, RunPod key (Restricted),
// R2 endpoint or account ID, bucket, access key ID, secret access key.

import Foundation

/// The values of the Cloud processing fields.
public struct CloudConfigInput: Sendable, Hashable {
    public var endpointId: String
    public var runpodKey: String
    /// `https://<account-id>.r2.cloudflarestorage.com`, or the bare 32-hex account ID.
    public var endpoint: String
    public var bucket: String
    public var accessKeyId: String
    public var secretAccessKey: String

    public init(endpointId: String, runpodKey: String, endpoint: String, bucket: String, accessKeyId: String,
                secretAccessKey: String) {
        self.endpointId = endpointId
        self.runpodKey = runpodKey
        self.endpoint = endpoint
        self.bucket = bucket
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
    }

    /// The trimmed Endpoint ID.
    public var trimmedEndpointId: String { endpointId.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedRunpodKey: String { runpodKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedBucket: String { bucket.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The S3 key pair.
    public var credentials: S3Credentials {
        S3Credentials(accessKeyId: accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines),
                      secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Where the bucket lives (path-style, region `auto`), or nil when the endpoint or bucket is unusable.
    public var location: S3Location? {
        guard let endpoint = CloudConfig.normalizedEndpoint(endpoint) else { return nil }
        let location = S3Location(endpoint: endpoint, bucket: trimmedBucket)
        return location.isValid ? location : nil
    }

    /// RunPod is filled in well enough to call.
    public var hasRunPod: Bool {
        RunPodJobsClient.isValidEndpointId(trimmedEndpointId) && !trimmedRunpodKey.isEmpty
    }

    /// Storage is filled in well enough to sign.
    public var hasStorage: Bool { location != nil && credentials.isComplete }

    public var isComplete: Bool { hasRunPod && hasStorage }
}

public enum CloudConfig {
    /// The bucket name the owner creates (design §3.5 D7).
    public static let defaultBucket = "pixl-cloud-studio"

    /// R2's S3 endpoint for a Cloudflare account.
    public static func r2Endpoint(accountId: String) -> String {
        "https://\(accountId.lowercased()).r2.cloudflarestorage.com"
    }

    /// A Cloudflare account ID: 32 hex characters.
    public static func isAccountId(_ text: String) -> Bool {
        guard text.utf8.count == 32 else { return false }
        return text.utf8.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x61...0x66, 0x41...0x46: true
            default: false
            }
        }
    }

    /// The endpoint for what was typed: a bare account ID becomes R2's URL; `https://host[:port][/…]` keeps only its
    /// scheme and host; a bare `host` gets `https://`. Nil for anything else (plain `http://`, spaces, an empty field).
    public static func normalizedEndpoint(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isAccountId(trimmed) { return r2Endpoint(accountId: trimmed) }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") { return nil }
        let candidate = lower.hasPrefix("https://") ? trimmed : "https://" + trimmed
        guard let host = S3Location(endpoint: candidate, bucket: defaultBucket).endpointHost,
              host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              host.unicodeScalars.allSatisfy(isHostScalar) else { return nil }
        return "https://\(host)"
    }

    /// ASCII letters, digits, `.`, `-` and `:` (a port).
    static func isHostScalar(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        switch scalar {
        case ".", "-", ":": return true
        default: return CharacterSet.alphanumerics.contains(scalar)
        }
    }

    /// The account ID inside an R2 endpoint, if it is one (shown under the field so a wrong paste is easy to spot).
    public static func r2AccountId(endpoint: String) -> String? {
        guard let normalized = normalizedEndpoint(endpoint) else { return nil }
        let host = normalized.dropFirst("https://".count)
        let suffix = ".r2.cloudflarestorage.com"
        guard host.hasSuffix(suffix) else { return nil }
        let id = String(host.dropLast(suffix.count))
        return isAccountId(id) ? id : nil
    }

    /// What is still missing or wrong, in plain English and field order (empty = ready to test).
    public static func problems(_ input: CloudConfigInput) -> [String] {
        var problems: [String] = []
        let endpointId = input.trimmedEndpointId
        if endpointId.isEmpty {
            problems.append("Paste the RunPod Endpoint ID.")
        } else if !RunPodJobsClient.isValidEndpointId(endpointId) {
            problems.append("The Endpoint ID should be letters and digits only (no https://, no slashes).")
        }
        if input.trimmedRunpodKey.isEmpty { problems.append("Paste the Restricted RunPod key.") }
        let endpoint = input.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.isEmpty {
            problems.append("Paste the R2 endpoint or your Cloudflare account ID.")
        } else if normalizedEndpoint(endpoint) == nil {
            problems.append("The R2 endpoint should look like https://<account-id>.r2.cloudflarestorage.com.")
        }
        let bucket = input.trimmedBucket
        if bucket.isEmpty {
            problems.append("Fill in the bucket name.")
        } else if !S3Location(endpoint: "https://example.com", bucket: bucket).hasValidBucket {
            problems.append("Bucket names are 3–63 lower-case letters, digits, dots or dashes.")
        }
        if input.accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("Paste the R2 access key ID.")
        }
        if input.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("Paste the R2 secret access key.")
        }
        return problems
    }
}
