// The per-device monthly budget of the built-in Claude key (spec A2, owner update 2026-10-23: default $50, developer
// slider $0–$200). Usage is priced at Claude Sonnet 5.5's rates: input $2 / MTok, output $10 / MTok, cache writes
// (5 minutes) $2.50 / MTok, cache reads $0.20 / MTok, web search $10 per 1,000 searches (web fetch has no fee of its
// own). Money is counted in integer tenths of a micro-dollar (1e-7 $) so sums never drift.

import Foundation

/// Sonnet 5.5 prices, in tenths of a micro-dollar per token / per search.
public enum ClaudePricing {
    /// $2 / MTok = 2 µ$ per token.
    public static let inputPerToken: Int64 = 20
    /// $10 / MTok.
    public static let outputPerToken: Int64 = 100
    /// $2.50 / MTok (5-minute cache write).
    public static let cacheWritePerToken: Int64 = 25
    /// $0.20 / MTok.
    public static let cacheReadPerToken: Int64 = 2
    /// $10 / 1,000 searches = 1 cent each.
    public static let perWebSearch: Int64 = 100_000
    /// Units per dollar.
    public static let unitsPerDollar: Int64 = 10_000_000

    /// What a response cost.
    public static func cost(_ usage: ClaudeUsage) -> Int64 {
        usage.inputTokens * inputPerToken + usage.outputTokens * outputPerToken
            + usage.cacheCreationInputTokens * cacheWritePerToken + usage.cacheReadInputTokens * cacheReadPerToken
            + usage.webSearchRequests * perWebSearch
    }

    public static func dollars(_ units: Int64) -> Double { Double(units) / Double(unitsPerDollar) }
}

/// The month's spend on this device. Stored by the app (UserDefaults) as `month` + `spentUnits`.
public struct ClaudeBudget: Sendable, Hashable {
    public static let defaultCapDollars: Double = 50
    public static let maxCapDollars: Double = 200

    /// "2026-10" (the calendar month in the device's time zone).
    public var month: String
    public var spentUnits: Int64

    public init(month: String, spentUnits: Int64) {
        self.month = month
        self.spentUnits = spentUnits
    }

    /// "yyyy-MM" of `date` in `timeZone`.
    public static func monthKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 1970, month = parts.month ?? 1
        return "\(year)-" + (month < 10 ? "0\(month)" : "\(month)")
    }

    /// This month's view: a stored budget from an earlier month starts again at zero.
    public func current(month now: String) -> ClaudeBudget {
        now == month ? self : ClaudeBudget(month: now, spentUnits: 0)
    }

    /// Adds a response's cost (rolling over to a new month first).
    public func recording(_ usage: ClaudeUsage, month now: String) -> ClaudeBudget {
        var next = current(month: now)
        next.spentUnits += max(ClaudePricing.cost(usage), 0)
        return next
    }

    /// The cap clamped to the slider's range.
    public static func clampCap(_ dollars: Double) -> Double {
        guard dollars.isFinite else { return defaultCapDollars }
        return min(max(dollars, 0), maxCapDollars)
    }

    /// Used up: the month's spend reached the cap (a $0 cap means the built-in key is off).
    public func isExhausted(capDollars: Double, month now: String) -> Bool {
        let cap = Int64((Self.clampCap(capDollars) * Double(ClaudePricing.unitsPerDollar)).rounded())
        return current(month: now).spentUnits >= cap
    }

    public func spentDollars(month now: String) -> Double { ClaudePricing.dollars(current(month: now).spentUnits) }
}
