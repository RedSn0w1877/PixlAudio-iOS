// Expressive SF Pro: the pure decisions behind the app's weight × width type toolkit
// (`App/DesignSystem/ExpressiveType.swift`). SF Pro is a variable font with a width axis (compressed … expanded) and
// nine weights; the app picks stops on both axes here and only turns them into `Font` / `UIFont` values itself.
//
// - `WidthFit` keeps a hero title's size and steps its width down (expanded → standard → condensed → compressed)
//   until the text fits, measuring lazily from the widest stop, so a name that already fits is measured once.
// - `CollapseStops` turns a scroll-collapse fraction into a few typographic stops with hysteresis, so a collapsing
//   title re-renders a handful of times per collapse (and never flickers on a boundary) instead of every frame.
// - `ScrollCollapse` maps a scroll offset to a quantized 0…1 fraction, so scroll callbacks fire only on visible
//   changes.

import Foundation

/// A stop on SF Pro's width axis, narrowest first.
public enum TypeWidthStop: Int, Sendable, Hashable, CaseIterable, Comparable {
    case compressed = 0
    case condensed
    case standard
    case expanded

    public static func < (lhs: TypeWidthStop, rhs: TypeWidthStop) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The stop `steps` narrower (negative: wider), clamped to `range`.
    public func narrowed(by steps: Int, within range: ClosedRange<TypeWidthStop> = .compressed ... .expanded)
        -> TypeWidthStop {
        let raw = min(max(rawValue - steps, range.lowerBound.rawValue), range.upperBound.rawValue)
        return TypeWidthStop(rawValue: raw) ?? self
    }
}

/// A stop on SF Pro's weight axis, lightest first.
public enum TypeWeightStop: Int, Sendable, Hashable, CaseIterable, Comparable {
    case ultraLight = 0
    case thin
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy
    case black

    public static func < (lhs: TypeWeightStop, rhs: TypeWeightStop) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The stop `steps` lighter (negative: heavier), clamped to `range`.
    public func lightened(by steps: Int, within range: ClosedRange<TypeWeightStop> = .ultraLight ... .black)
        -> TypeWeightStop {
        let raw = min(max(rawValue - steps, range.lowerBound.rawValue), range.upperBound.rawValue)
        return TypeWeightStop(rawValue: raw) ?? self
    }
}

/// Fit-by-width: the widest width stop at which a title fits its space without changing its size.
public enum WidthFit {
    /// A title measured at one width stop: its single-line advance and its longest word's advance, in points.
    public struct Measurement: Sendable, Equatable {
        public var line: Double
        public var longestWord: Double

        public init(line: Double, longestWord: Double) {
            self.line = line
            self.longestWord = longestWord
        }
    }

    /// How full the lines of a wrapped title may be on average: word breaks waste the end of each line, so a title
    /// whose single-line advance is just under `lines × width` would still truncate.
    public static let multiLineFill = 0.88

    /// Whether a measured title fits `available` points within `lines` lines with no word broken or truncated.
    public static func fits(_ measurement: Measurement, available: Double, lines: Int) -> Bool {
        guard available > 0 else { return false }
        if lines <= 1 { return measurement.line <= available }
        return measurement.longestWord <= available
            && measurement.line <= available * Double(lines) * multiLineFill
    }

    /// The widest stop in `range` at which the title fits, measuring from the widest stop down and stopping at the
    /// first fit. When none fits, the narrowest stop (the title then truncates, as small as it can).
    public static func widestFitting(available: Double, lines: Int,
                                     range: ClosedRange<TypeWidthStop> = .compressed ... .expanded,
                                     measure: (TypeWidthStop) -> Measurement) -> TypeWidthStop {
        var stop = range.upperBound
        while true {
            if fits(measure(stop), available: available, lines: lines) { return stop }
            guard stop > range.lowerBound, let narrower = TypeWidthStop(rawValue: stop.rawValue - 1) else { return stop }
            stop = narrower
        }
    }
}

/// Typographic stops of a collapsing title: `count` equal bands of the collapse fraction (0 open … 1 collapsed),
/// entered only once the fraction is `hysteresis` past a band edge, so a scroll resting on an edge can't flip the
/// title back and forth.
public struct CollapseStops: Sendable, Equatable {
    public let count: Int
    public let hysteresis: Double
    /// The current stop, 0 (open) … `count - 1` (collapsed).
    public private(set) var index: Int

    public init(count: Int, hysteresis: Double = 0.04, index: Int = 0) {
        let count = max(1, count)
        self.count = count
        // Never wider than half a band, or a band could become unreachable.
        self.hysteresis = min(max(0, hysteresis), 0.5 / Double(count) - 0.001)
        self.index = min(max(0, index), count - 1)
    }

    /// The band a fraction falls in, ignoring hysteresis.
    public func band(of fraction: Double) -> Int {
        let clamped = min(max(fraction, 0), 1)
        return min(count - 1, Int(clamped * Double(count)))
    }

    /// Feeds a collapse fraction. Returns the new stop when it changes, `nil` to leave it.
    public mutating func update(fraction: Double) -> Int? {
        guard count > 1 else { return nil }
        let clamped = min(max(fraction, 0), 1)
        let target = band(of: clamped)
        guard target != index else { return nil }
        var next = target
        if target > index {
            // Entering band `next` from below: its lower edge is next / count.
            while next > index, clamped < Double(next) / Double(count) + hysteresis { next -= 1 }
        } else {
            // Leaving band `next + 1` downwards: its lower edge is (next + 1) / count.
            while next < index, clamped > Double(next + 1) / Double(count) - hysteresis { next += 1 }
        }
        guard next != index else { return nil }
        index = next
        return next
    }

    /// Jumps to the stop of `fraction` with no hysteresis (a new page, a restored scroll position).
    public mutating func reset(fraction: Double) {
        index = band(of: fraction)
    }
}

/// Scroll offset → collapse fraction.
public enum ScrollCollapse {
    /// The fraction 0…1 of `offset` across `start ... start + distance`, rounded to `quantum` so a scroll callback
    /// returning it fires only when it visibly changes.
    public static func fraction(offset: Double, start: Double = 0, distance: Double, quantum: Double = 0.01) -> Double {
        guard distance > 0 else { return offset >= start ? 1 : 0 }
        let raw = min(max((offset - start) / distance, 0), 1)
        guard quantum > 0 else { return raw }
        return min(1, (raw / quantum).rounded() * quantum)
    }

    /// Linear interpolation from `a` to `b` by `t`.
    public static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
