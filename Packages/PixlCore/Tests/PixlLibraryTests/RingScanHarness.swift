import Foundation
import Testing
@testable import PixlLibrary

/// Shared helpers for the image-side tests of the ring code: random codes, rendering, scanning, and a tally of a sweep (the
/// Android `ScanHarness.kt`).
enum RingScanHarness {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    static let deg = Double.pi / 180.0

    struct Case {
        let payload: RingCodePayload
        let bits: [UInt8]
    }

    static func randomCase(_ rng: inout RingRng) -> Case {
        var chars: [Character] = []
        for _ in 0..<11 { chars.append(alphabet[rng.int(64)]) }
        let bucket = rng.int(64)
        let random = rng.int(256)
        let p = RingCodePayload(videoId: String(chars), minuteBucket: bucket, random: random)
        return Case(payload: p, bits: RingCodePayloads.encodeSlots(videoId: p.videoId, minuteBucket: p.minuteBucket, random: p.random) ?? [])
    }

    static func frameOf(_ r: Rendered, withHue: Bool = true) -> RingFrame {
        RingFrame(width: r.image.width, height: r.image.height, luma: r.image.luma, hue: withHue ? r.image.orange : nil)
    }

    static func scan(_ scanner: RingScanner, _ c: Case, _ p: RenderParams, withHue: Bool = true) -> RingScanResult {
        let r = RingCodeRenderer.render(c.bits, p)
        return scanner.scan(frameOf(r, withHue: withHue))
    }

    static func ok(_ result: RingScanResult, _ c: Case) -> Bool { result.payload == c.payload }

    static func describe(_ result: RingScanResult, _ scanner: RingScanner) -> String {
        let d = scanner.diagnostics
        let what: String
        switch result {
        case .decoded(_, let corrected, let erasures): what = "decoded corrected=\(corrected) erasures=\(erasures)"
        case .failed(let reason): what = "failed \(reason.code)"
        }
        return "\(what) | found=\(d.found) marker=\(d.markerFound) matched=\(d.matched) resid=\(d.residualPx)px cand=\(d.candidates)"
    }

    /// Counts how many scenes of a sweep were read, remembers the first failures, and prints one line per sweep.
    final class Sweep {
        let name: String
        var total = 0
        var good = 0
        var wrong = 0
        var failures: [String] = []

        init(_ name: String) { self.name = name }

        func record(_ result: RingScanResult, _ c: Case, _ label: String, _ scanner: RingScanner) {
            total += 1
            if RingScanHarness.ok(result, c) {
                good += 1
            } else {
                if result.isDecoded { wrong += 1 }
                if failures.count < 6 { failures.append("\(label): \(RingScanHarness.describe(result, scanner))") }
            }
        }

        func line() -> String { "\(name): \(good) / \(total) read (\(Double(good * 1000 / max(1, total)) / 10.0) percent), \(wrong) wrong" }

        func report() {
            print(line())
            for f in failures { print("  \(f)") }
        }

        var message: String { line() + "\n" + failures.joined(separator: "\n") }
    }
}
