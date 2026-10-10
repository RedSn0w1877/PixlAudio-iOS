// Pure rules behind "a job that fails must end, say why and let go" (docs/handoff/2026-10-09-many-jobs-fix.md): the
// words a failure is shown in, a retry budget that gives up, and a watchdog that notices a transfer that stopped
// moving (an offline background download never reports an error by itself). No clocks and no threads in here: the
// callers pass what happened and do the waiting, so everything is testable on any platform.

import Foundation

/// The plain-words reason a failed job shows in Active jobs and on its own screen.
public enum JobFailureText {
    /// One line is enough for a row; the full text stays in the logs.
    public static let maxLength = 140

    /// What a row shows when nothing better is known.
    public static let generic = "Something went wrong."

    /// One tidy line: runs of whitespace (newlines included) become one space, the ends are trimmed and the text is cut
    /// at `limit` characters with an ellipsis. Never empty.
    public static func short(_ message: String, limit: Int = maxLength) -> String {
        let collapsed = message.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return generic }
        guard collapsed.count > limit else { return collapsed }
        let cut = String(collapsed.prefix(max(limit - 1, 1))).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }

    /// What an HTTP status means for a download, in words (404 is "no source", the case the owner hit).
    public static func httpStatus(_ status: Int) -> String {
        switch status {
        case 404, 410: "There is nothing to download at the source any more (HTTP \(status))."
        case 401, 403: "The source refused the download (HTTP \(status))."
        case 408: "The source took too long to answer (HTTP 408)."
        case 429: "The source is busy right now, try again later (HTTP 429)."
        case 500...599: "The source had a problem (HTTP \(status)). Try again later."
        default: "The source answered HTTP \(status)."
        }
    }

    /// A `URLError` code (its raw value; PixlModel does not import the networking module) as words, or nil for a code
    /// that is not worth a sentence of its own (and for "cancelled", which is not a failure at all).
    public static func urlError(code: Int) -> String? {
        switch code {
        case -1009, -1020, -1018: "No internet connection."
        case -1001: "The connection timed out."
        case -1005: "The connection was lost."
        case -1003, -1004, -1006: "Couldn't reach the server."
        case -1200, -1201, -1202, -1203, -1204, -1205, -1206: "Couldn't make a secure connection."
        case -1008, -1100: "The file isn't available at the source."
        default: nil
        }
    }

    /// The error's own words when it has some, else a generic line; always one tidy line.
    public static func describe(_ message: String?, urlErrorCode: Int? = nil) -> String {
        if let urlErrorCode, let words = urlError(code: urlErrorCode) { return words }
        return short(message ?? "")
    }
}

/// How often a job may try again before it is failed: a ladder of waits, then the end. Used where a job retries by
/// itself (the Spotify matcher after network trouble), so "try again later" can never go on for ever.
public struct RetryBudget: Sendable, Equatable {
    /// Failures in a row (the first included) after which the job gives up.
    public let maxAttempts: Int
    /// The wait after the first failure, the second, …; the last one repeats.
    public let delaysMs: [Int64]
    public private(set) var attempts = 0

    public init(maxAttempts: Int = 5, delaysMs: [Int64] = [60_000, 120_000, 240_000, 480_000]) {
        self.maxAttempts = max(1, maxAttempts)
        self.delaysMs = delaysMs.isEmpty ? [60_000] : delaysMs
    }

    /// A try failed: how long to wait before the next one, or nil when the budget is spent (fail the job now).
    public mutating func failed() -> Int64? {
        attempts += 1
        guard attempts < maxAttempts else { return nil }
        return delaysMs[min(attempts - 1, delaysMs.count - 1)]
    }

    /// Something went right (progress was made): the next failure starts the ladder again.
    public mutating func reset() {
        attempts = 0
    }

    public var isExhausted: Bool { attempts >= maxAttempts }
}

/// Notices a transfer that stopped moving. A background download task waits for connectivity without a deadline (up to
/// seven days), so with the phone offline it never fails by itself and the job would sit at "running" for ever: the
/// owner of the transfer ticks this at a fixed interval with a mark that changes whenever data moves (bytes written),
/// and fails the job when `limitTicks` ticks in a row saw the same mark.
public struct StallWatchdog: Sendable, Equatable {
    public let limitTicks: Int
    private var lastMark: Int64?
    public private(set) var stalledTicks = 0

    public init(limitTicks: Int = 6) {
        self.limitTicks = max(1, limitTicks)
    }

    /// One interval passed. Returns true when the transfer has made no progress for `limitTicks` intervals.
    public mutating func tick(mark: Int64) -> Bool {
        if mark != lastMark {
            lastMark = mark
            stalledTicks = 0
            return false
        }
        stalledTicks += 1
        return stalledTicks >= limitTicks
    }

    public mutating func reset() {
        lastMark = nil
        stalledTicks = 0
    }
}
