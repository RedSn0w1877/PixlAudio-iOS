import Foundation

/// Which build is installed: version, build number, the commit it was built from and the day (`BuildStamp`, written by
/// CI). Shown at the top of Settings › About and Diagnostics, and first in every exported log.
nonisolated enum BuildIdentity {
    static let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["CFBundleShortVersionString"] as? String ?? "?"
    }()

    static let build: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["CFBundleVersion"] as? String ?? "?"
    }()

    /// "1.0.0 (1) · commit 9bbcf8b · built 2026-10-10"
    static var summary: String {
        "PixlAudio \(version) (\(build)) · commit \(BuildStamp.gitSHA) · built \(BuildStamp.builtOn)"
    }

    /// For the About line: "Build 1 · commit 9bbcf8b · 2026-10-10".
    static var shortLine: String {
        "Build \(build) · commit \(BuildStamp.gitSHA) · \(BuildStamp.builtOn)"
    }

    /// A file-name-safe stamp: "20261010-1530-9bbcf8b".
    static var fileStamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "\(formatter.string(from: Date()))-\(BuildStamp.gitSHA)"
    }
}
