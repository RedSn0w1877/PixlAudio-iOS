import Foundation
import MetricKit
import PixlModel

/// Keeps what the system reports about the app: `MXDiagnosticPayload`s (crash, hang, CPU-exception and disk-write-
/// exception diagnostics, usually delivered the next day or at the next launch) and `MXMetricPayload` summaries, as JSON
/// files in Application Support/Diagnostics/metrickit, newest few only, for Share logs. A crash payload also tells
/// `AppHealth` that the previous run ended abnormally, even when the clean-exit marker said otherwise.
///
/// The JSON is Apple's own and carries call stacks and counters; it holds no song titles (the app never puts them in a
/// crash). Nothing is uploaded: the owner sends it from Share logs.
nonisolated final class MetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitCollector()

    /// Called on an arbitrary queue with whether a diagnostic payload held a crash, hang or exception.
    var onDiagnostics: (@Sendable (_ crashLike: Bool) -> Void)?

    private static let keepDiagnostics = 10
    private static let keepMetrics = 5
    private let queue = DispatchQueue(label: "io.github.redsn0w1877.pixlaudio.metrickit", qos: .utility)

    /// Subscribes (once, at launch). Past payloads the system kept for the app are delivered at once.
    func start() {
        MXMetricManager.shared.add(self)
        DiagnosticsLog.shared.log("metrickit", "subscribed; past payloads: \(MXMetricManager.shared.pastDiagnosticPayloads.count) diagnostics")
        // The system keeps the last payloads: take what arrived while the app was not running.
        let past = MXMetricManager.shared.pastDiagnosticPayloads
        if !past.isEmpty { store(diagnostics: past) }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let items = payloads.map { (Date(), $0.jsonRepresentation()) }
        queue.async { Self.write(items, prefix: "metrics", keep: Self.keepMetrics) }
        DiagnosticsLog.shared.log("metrickit", "received \(payloads.count) metric payload(s)")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        store(diagnostics: payloads)
    }

    private func store(diagnostics payloads: [MXDiagnosticPayload]) {
        var crashLike = false
        var items: [(Date, Data)] = []
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpu = payload.cpuExceptionDiagnostics?.count ?? 0
            let disk = payload.diskWriteExceptionDiagnostics?.count ?? 0
            if crashes + hangs + cpu + disk > 0 { crashLike = true }
            DiagnosticsLog.shared.log("metrickit", "diagnostic payload: crashes \(crashes), hangs \(hangs), cpu \(cpu), disk writes \(disk)")
            items.append((payload.timeStampEnd, payload.jsonRepresentation()))
        }
        queue.async { Self.write(items, prefix: "diagnostic", keep: Self.keepDiagnostics) }
        if crashLike { onDiagnostics?(true) }
    }

    // MARK: Files

    private static func write(_ items: [(Date, Data)], prefix: String, keep: Int) {
        guard let directory = DiagnosticsFiles.metricKit else { return }
        let fm = FileManager.default
        for (date, data) in items {
            let stamp = Int(date.timeIntervalSince1970)
            try? data.write(to: directory.appendingPathComponent("\(prefix)-\(stamp).json"), options: .atomic)
        }
        // Newest `keep` files of this kind stay.
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(keep) { try? fm.removeItem(at: old) }
    }

    /// What Share logs includes: each stored payload's file name, then its JSON (a payload can be long; each is cut at
    /// 60 KB, the call stacks are at the start).
    static func storedSummaries() -> [String] {
        guard let directory = DiagnosticsFiles.metricKit,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.sorted { $0.lastPathComponent > $1.lastPathComponent }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let text = String(decoding: data.prefix(60_000), as: UTF8.self)
            let cut = data.count > 60_000 ? "\n… cut at 60 KB (\(data.count) bytes in the file)" : ""
            return "\(url.lastPathComponent):\n\(text)\(cut)"
        }
    }
}
