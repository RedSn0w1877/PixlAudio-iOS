// `java.time.LocalDate` and the zone arithmetic the stats code uses (`Instant.atZone(zone).toLocalDate()`,
// `LocalDate.atStartOfDay(zone)`), on top of Foundation's `TimeZone` offsets so it behaves the same on Windows.

import Foundation

/// A proleptic-Gregorian calendar date (`java.time.LocalDate`).
public struct LocalDate: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// `LocalDate.ofEpochDay`.
    public init(epochDay: Int64) {
        var zeroDay = epochDay + 719_528 - 60
        var adjust: Int64 = 0
        if zeroDay < 0 {
            let adjustCycles = (zeroDay + 1) / 146_097 - 1
            adjust = adjustCycles * 400
            zeroDay += -adjustCycles * 146_097
        }
        var yearEst = (400 * zeroDay + 591) / 146_097
        var doyEst = zeroDay - (365 * yearEst + yearEst / 4 - yearEst / 100 + yearEst / 400)
        if doyEst < 0 {
            yearEst -= 1
            doyEst = zeroDay - (365 * yearEst + yearEst / 4 - yearEst / 100 + yearEst / 400)
        }
        yearEst += adjust
        let marchDoy0 = doyEst
        let marchMonth0 = (marchDoy0 * 5 + 2) / 153
        let month = (marchMonth0 + 2) % 12 + 1
        let dom = marchDoy0 - (marchMonth0 * 306 + 5) / 10 + 1
        yearEst += marchMonth0 / 10
        self.init(year: Int(yearEst), month: Int(month), day: Int(dom))
    }

    /// `toEpochDay`.
    public var epochDay: Int64 {
        let y = Int64(year), m = Int64(month)
        var total: Int64 = 365 * y
        if y >= 0 {
            total += (y + 3) / 4 - (y + 99) / 100 + (y + 399) / 400
        } else {
            total -= y / -4 - y / -100 + y / -400
        }
        total += (367 * m - 362) / 12
        total += Int64(day) - 1
        if m > 2 {
            total -= 1
            if !Self.isLeap(year) { total -= 1 }
        }
        return total - 719_528
    }

    public static func isLeap(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }

    public var lengthOfMonth: Int {
        switch month {
        case 2: Self.isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    public func plusDays(_ days: Int64) -> LocalDate { LocalDate(epochDay: epochDay + days) }

    /// ISO day of week: 1 = Monday … 7 = Sunday.
    public var dayOfWeek: Int {
        let r = (epochDay + 3) % 7
        return Int(r < 0 ? r + 7 : r) + 1
    }

    /// `with(TemporalAdjusters.previousOrSame(MONDAY))`.
    public var mondayOfWeek: LocalDate { plusDays(-Int64(dayOfWeek - 1)) }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// `LocalDate.toString()`.
    public var description: String {
        let absYear = abs(year)
        var y: String
        if absYear < 1000 {
            y = String(absYear)
            y = String(repeating: "0", count: 4 - y.count) + y
            if year < 0 { y = "-" + y }
        } else {
            y = String(year)
            if year > 9999 { y = "+" + y }
        }
        return "\(y)-\(month < 10 ? "0" : "")\(month)-\(day < 10 ? "0" : "")\(day)"
    }

    /// `LocalDate.parse(value)` for the plain `yyyy-MM-dd` form (strict: a real date, ASCII digits).
    public static func parseISO(_ value: String) -> LocalDate? {
        let b = Array(value.utf8)
        guard b.count == 10, b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-") else { return nil }
        func digits(_ r: Range<Int>) -> Int? {
            var n = 0
            for i in r {
                guard b[i] >= 0x30, b[i] <= 0x39 else { return nil }
                n = n * 10 + Int(b[i] - 0x30)
            }
            return n
        }
        guard let y = digits(0..<4), let m = digits(5..<7), let d = digits(8..<10), (1...12).contains(m) else { return nil }
        let date = LocalDate(year: y, month: m, day: 1)
        guard d >= 1, d <= date.lengthOfMonth else { return nil }
        return LocalDate(year: y, month: m, day: d)
    }
}

/// Converts between instants (epoch milliseconds) and local dates in one time zone, with java.time's rules.
public struct ZoneClock: Sendable {
    public let timeZone: TimeZone
    static let dayMs: Int64 = 86_400_000

    public init(_ timeZone: TimeZone) { self.timeZone = timeZone }

    /// The zone offset at an instant, in milliseconds.
    public func offsetMs(at epochMs: Int64) -> Int64 {
        Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(epochMs) / 1000))) * 1000
    }

    /// Local wall-clock milliseconds since 1970 (as if UTC) at an instant.
    public func localMs(at epochMs: Int64) -> Int64 { epochMs &+ offsetMs(at: epochMs) }

    /// `Instant.ofEpochMilli(ms).atZone(zone).toLocalDate()`.
    public func localDate(at epochMs: Int64) -> LocalDate {
        LocalDate(epochDay: floorDiv(localMs(at: epochMs), Self.dayMs))
    }

    /// The local hour (0–23) at an instant.
    public func localHour(at epochMs: Int64) -> Int {
        Int(floorMod(localMs(at: epochMs), Self.dayMs) / 3_600_000)
    }

    /// `date.atStartOfDay(zone).toInstant().toEpochMilli()`: local midnight; in an overlap the earlier instant, in
    /// a gap the first instant after it (java.time's `ZonedDateTime.ofLocal` rules).
    public func startOfDay(_ date: LocalDate) -> Int64 {
        let local = date.epochDay * Self.dayMs
        let span: Int64 = 14 * 3_600_000
        let early = offsetMs(at: local - span), late = offsetMs(at: local + span)
        var best: Int64?
        for offset in [early, late] where offsetMs(at: local - offset) == offset {
            let instant = local - offset
            best = best.map { min($0, instant) } ?? instant
        }
        return best ?? (local - early)
    }

    func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    func floorMod(_ a: Int64, _ b: Int64) -> Int64 { a - floorDiv(a, b) * b }
}
