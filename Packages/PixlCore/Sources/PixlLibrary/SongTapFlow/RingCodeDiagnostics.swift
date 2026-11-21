import Foundation

// What the ring scanner saw in the last frame it looked at, for Developer mode > Ring code diagnostics (the Android
// `RingCodeDiagnostics.kt`). Picture-sized values are copied here (a small upright grey picture, the plate's circle, the start dot,
// 200 confidences) and published at most five times a second, and only while the diagnostics screen is open: with it closed
// `record` returns at once, so a normal scan pays nothing for this.

public struct RingDiagSnapshot: Sendable, Equatable {
    public var serial = 0
    /// The frame the scanner saw, small, grey and upright (rotated by the camera's rotation).
    public var previewWidth = 0
    public var previewHeight = 0
    public var preview: [UInt8] = []
    public var found = false
    /// The plate's centre and outline radius as fractions of the upright picture's width and height (radius: of the width).
    public var centreX = 0.0
    public var centreY = 0.0
    public var radius = 0.0
    public var markerFound = false
    public var markerX = 0.0
    public var markerY = 0.0
    public var matched = 0
    public var residualPx = 0.0
    public var rsCorrected = 0
    public var erasures = 0
    public var scanMicros: Int64 = 0
    public var candidates = 0
    /// "decoded <id> ...", or the failure reason.
    public var outcome = ""
    public var confidence = [Int](repeating: 0, count: RingCodeLayout.slots)
    public var bits = [UInt8](repeating: 0, count: RingCodeLayout.slots)
    public var framesPerSecond = 0
    public var scansPerSecond = 0
    public var frameWidth = 0
    public var frameHeight = 0
    public var tooSlow = false

    public init() {}

    public static let empty = RingDiagSnapshot()
}

/// Fixed-point text without a formatting API, so every platform prints the same.
public enum RingText {
    /// `value` with `decimals` places ("12.5", "0.07"), rounded half away from zero.
    public static func fixed(_ value: Double, decimals: Int) -> String {
        var scale = 1.0
        for _ in 0..<decimals { scale *= 10 }
        let scaled = Int((abs(value) * scale).rounded())
        let whole = scaled / Int(scale)
        var part = String(scaled % Int(scale))
        while part.count < decimals { part = "0" + part }
        let sign = value < 0 && scaled > 0 ? "-" : ""
        return decimals == 0 ? sign + String(whole) : sign + String(whole) + "." + part
    }

    /// Microseconds as milliseconds with one decimal ("7.4").
    public static func millis(_ micros: Int64) -> String { fixed(Double(micros) / 1000.0, decimals: 1) }

    /// `value` padded with zeros to `width` digits.
    public static func padded(_ value: Int64, width: Int) -> String {
        var text = String(value)
        while text.count < width { text = "0" + text }
        return text
    }

    /// "mm:ss.mmm" of a clock reading.
    public static func stamp(_ ms: Int64) -> String {
        let s = (ms / 1000) % 3600
        return padded(s / 60, width: 2) + ":" + padded(s % 60, width: 2) + "." + padded(ms % 1000, width: 3)
    }
}

public final class RingCodeDiagnostics: @unchecked Sendable {
    public static let logSize = 20
    public static let publishGapMs: Int64 = 200
    public static let previewSide = 320

    private let lock = NSLock()
    private var enabled = false
    private var current = RingDiagSnapshot.empty
    private var lines: [String] = []
    private var serial = 0
    private var lastPublishMs: Int64 = 0
    private var lastLogMs: Int64?
    private var lastLogKey = ""
    private var secondStartMs: Int64 = 0
    private var framesThisSecond = 0
    private var scansThisSecond = 0
    private var framesPerSecond = 0
    private var scansPerSecond = 0
    private var slow = false

    /// Called on the camera's queue after a new snapshot or log line was published (a screen asks for them again on the main actor).
    public var onChange: (@Sendable () -> Void)?

    public init() {}

    public var snapshot: RingDiagSnapshot { lock.withLock { current } }

    /// The last `logSize` results, newest last.
    public var log: [String] { lock.withLock { lines } }

    public var isEnabled: Bool { lock.withLock { enabled } }

    public func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        if !on {
            current = .empty
            lines = []
            lastLogKey = ""
            lastLogMs = nil
            slow = false
        }
        lock.unlock()
    }

    public func onFrame(nowMs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if !enabled { return }
        framesThisSecond += 1
        roll(nowMs)
    }

    public func onSlow() {
        lock.lock()
        defer { lock.unlock() }
        if enabled { slow = true }
    }

    private func roll(_ nowMs: Int64) {
        if nowMs - secondStartMs >= 1000 {
            framesPerSecond = framesThisSecond
            scansPerSecond = scansThisSecond
            framesThisSecond = 0
            scansThisSecond = 0
            secondStartMs = nowMs
        }
    }

    /// One scan finished (the camera's queue).
    public func record(frame: RingFrame, result: RingScanResult, diagnostics d: RingScanDiagnostics, rotationDegrees: Int, nowMs: Int64) {
        lock.lock()
        if !enabled { lock.unlock(); return }
        scansThisSecond += 1
        roll(nowMs)
        let outcome = Self.describe(result)
        addLog(result, outcome, nowMs, d)
        if nowMs - lastPublishMs < Self.publishGapMs { lock.unlock(); onChange?(); return }
        lastPublishMs = nowMs
        let rot = ((rotationDegrees % 360) + 360) % 360
        let upW = rot == 90 || rot == 270 ? frame.height : frame.width
        let upH = rot == 90 || rot == 270 ? frame.width : frame.height
        let step = max(1, (max(upW, upH) + Self.previewSide - 1) / Self.previewSide)
        let pw = upW / step
        let ph = upH / step
        var preview = [UInt8](repeating: 0, count: max(0, pw * ph))
        for v in 0..<ph {
            for u in 0..<pw {
                let uu = u * step
                let vv = v * step
                let x: Int
                let y: Int
                switch rot {
                case 90: x = vv; y = frame.height - 1 - uu
                case 180: x = frame.width - 1 - uu; y = frame.height - 1 - vv
                case 270: x = frame.width - 1 - vv; y = uu
                default: x = uu; y = vv
                }
                preview[v * pw + u] = frame.luma[min(max(y, 0), frame.height - 1) * frame.width + min(max(x, 0), frame.width - 1)]
            }
        }
        let fw = Double(frame.width), fh = Double(frame.height)
        func nx(_ x: Double, _ y: Double) -> Double {
            switch rot {
            case 90: return 1.0 - y / fh
            case 180: return 1.0 - x / fw
            case 270: return y / fh
            default: return x / fw
            }
        }
        func ny(_ x: Double, _ y: Double) -> Double {
            switch rot {
            case 90: return x / fw
            case 180: return 1.0 - y / fh
            case 270: return 1.0 - x / fw
            default: return y / fh
            }
        }
        serial += 1
        var s = RingDiagSnapshot()
        s.serial = serial
        s.previewWidth = pw
        s.previewHeight = ph
        s.preview = preview
        s.found = d.found
        s.centreX = nx(d.centreX, d.centreY)
        s.centreY = ny(d.centreX, d.centreY)
        s.radius = d.bezelRadiusPx / Double(upW)
        s.markerFound = d.markerFound
        s.markerX = nx(d.markerX, d.markerY)
        s.markerY = ny(d.markerX, d.markerY)
        s.matched = d.matched
        s.residualPx = d.residualPx
        s.rsCorrected = d.rsCorrected
        s.erasures = d.erasuresUsed
        s.scanMicros = d.scanMicros
        s.candidates = d.candidates
        s.outcome = outcome
        s.confidence = d.slotConfidence
        s.bits = d.slotBits
        s.framesPerSecond = framesPerSecond
        s.scansPerSecond = scansPerSecond
        s.frameWidth = frame.width
        s.frameHeight = frame.height
        s.tooSlow = slow
        current = s
        lock.unlock()
        onChange?()
    }

    public static func describe(_ result: RingScanResult) -> String {
        switch result {
        case .decoded(let payload, let corrected, let erasures):
            return "decoded \(payload.videoId) tag \(payload.tag()) (fixed \(corrected), erasures \(erasures))"
        case .failed(let reason):
            return reason.code
        }
    }

    /// Decodes are always logged; a failure only when it differs from the last line or a second has passed. Called with the lock held.
    private func addLog(_ result: RingScanResult, _ text: String, _ nowMs: Int64, _ d: RingScanDiagnostics) {
        var key = "ok"
        if case .failed(let reason) = result { key = reason.code }
        let decoded = result.isDecoded
        if !decoded, key == lastLogKey, let last = lastLogMs, nowMs - last < 1000 { return }
        lastLogKey = key
        lastLogMs = nowMs
        let line = "\(RingText.stamp(nowMs))  \(text)  dots \(d.matched)/\(RingCodeLayout.slots)  \(RingText.millis(d.scanMicros)) ms"
        lines.append(line)
        if lines.count > Self.logSize { lines.removeFirst(lines.count - Self.logSize) }
    }

    /// Everything worth pasting into a message: the numbers and the last results.
    public func copyText(device: String) -> String {
        let s = snapshot
        let log = self.log
        var out = "Ring code diagnostics\n"
        out += "device: \(device)\n"
        out += "frame: \(s.frameWidth) x \(s.frameHeight), \(s.framesPerSecond) frames/s, \(s.scansPerSecond) scans/s, last scan \(RingText.millis(s.scanMicros)) ms\n"
        out += "plate found: \(s.found), start dot found: \(s.markerFound), dots matched \(s.matched)/\(RingCodeLayout.slots), residual \(RingText.fixed(s.residualPx, decimals: 2)) px\n"
        out += "reed-solomon: fixed \(s.rsCorrected), erasures \(s.erasures), outline candidates \(s.candidates)\n"
        out += "scanner too slow for this phone: \(s.tooSlow)\n"
        out += "last outcome: \(s.outcome)\n"
        let low = s.confidence.filter { $0 >= 1 && $0 <= 39 }.count
        let zero = s.confidence.filter { $0 == 0 }.count
        out += "slot confidence: \(zero) unknown, \(low) weak, \(s.confidence.count - zero - low) clear\n"
        out += "last results:\n"
        for line in log { out += line + "\n" }
        return out
    }
}
