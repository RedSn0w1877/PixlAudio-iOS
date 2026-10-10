// Pure rules for the in-app diagnostics log: what may be written (no personal data), how the file stays small (a ring
// of whole lines) and how an event line looks. The app owns the file; these functions only turn text into text.

import Foundation

public enum LogRedactor {
    /// Text safe to keep and to send: URLs lose their path and query, file paths become "<path>", e-mail addresses,
    /// bearer tokens and long token-like strings become "<redacted>". Song titles are never passed in the first place
    /// (callers log opaque ids and job kinds); this is the second line of defence for error texts that quote them.
    public static func redact(_ text: String) -> String {
        var result = text
        result = replace("(?i)bearer\\s+[A-Za-z0-9._~+/=-]+", in: result, with: "bearer <redacted>")
        result = replace("https?://([^/\\s?#\"')]+)[^\\s\"')]*", in: result, with: "https://$1/…")
        result = replace("file://[^\\s\"']*", in: result, with: "<path>")
        result = replace("(?<![A-Za-z0-9])(/(?:private/)?(?:var|Users|Library|tmp|Applications|System|private)/[^\\s\"',;)]*)",
                         in: result, with: "<path>")
        result = replace("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", in: result, with: "<redacted>")
        result = replace("(?<![A-Za-z0-9])[A-Za-z0-9_-]{32,}(?![A-Za-z0-9])", in: result, with: "<redacted>")
        return result
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// One log line: a single line, redacted, at most `limit` characters.
    public static func line(_ text: String, limit: Int = 300) -> String {
        let flat = redact(text).split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}

public enum LogRing {
    /// The default cap of the event log file.
    public static let defaultLimitBytes = 1_000_000

    /// `existing` plus `addition`, trimmed from the front (whole lines only) when it would pass `limitBytes`: the
    /// newest lines survive and a marker line says how many bytes were dropped. Never longer than the limit.
    public static func appending(_ addition: String, to existing: String, limitBytes: Int = defaultLimitBytes) -> String {
        let combined = existing + addition
        let size = combined.utf8.count
        guard size > limitBytes else { return combined }
        // Keep 70 % so the next appends do not rewrite the file again at once.
        let keep = max(limitBytes * 7 / 10, 1)
        var bytes = Array(combined.utf8)
        var cut = min(size - keep, bytes.count)
        // Move to the next line start so no line is half-kept.
        while cut < bytes.count, bytes[cut] != 0x0A { cut += 1 }
        if cut < bytes.count { cut += 1 }
        let dropped = cut
        bytes.removeFirst(cut)
        let marker = "… earlier events dropped (\(dropped) bytes) …\n"
        return marker + String(decoding: bytes, as: UTF8.self)
    }

    /// `2026-10-10T08:15:30Z  lifecycle  active`: time, a category and the redacted message.
    public static func format(timestamp: Date, category: String, message: String) -> String {
        "\(iso(timestamp))  \(LogRedactor.line(category, limit: 24))  \(LogRedactor.line(message))\n"
    }

    private static func iso(_ date: Date) -> String {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        let days = Int(seconds / 86_400), rem = Int(seconds % 86_400)
        // Civil-from-days (Howard Hinnant), so no formatter state is shared between threads.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let year = m <= 2 ? y + 1 : y
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(year)-\(two(m))-\(two(d))T\(two(rem / 3_600)):\(two(rem % 3_600 / 60)):\(two(rem % 60))Z"
    }
}

/// How the shared report starts: one block of facts, then the log.
public enum DiagnosticReport {
    public static func assemble(identity: String, status: [(String, String)], safeMode: String, log: String,
                                metricKit: [String]) -> String {
        var out = "PixlAudio diagnostics\n=====================\n\(identity)\n\nStatus\n------\n"
        for (name, value) in status { out += "\(name): \(value)\n" }
        out += "Safe mode: \(safeMode)\n\nEvent log\n---------\n"
        out += log.isEmpty ? "(empty)\n" : (log.hasSuffix("\n") ? log : log + "\n")
        out += "\nMetricKit payloads\n------------------\n"
        if metricKit.isEmpty {
            out += "(none received yet; iOS delivers them up to a day after a crash)\n"
        } else {
            for item in metricKit { out += "\n\(item)\n" }
        }
        return out
    }
}
