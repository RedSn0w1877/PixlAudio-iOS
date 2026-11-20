import Foundation
import Testing
@testable import PixlLibrary

/// Test 6 of docs/brain-spec.md, section 11 (the learned weights against the frozen prior), on a REAL listening export. Local only: it
/// runs when the owner points it at a file, prints what it measured, and never asserts a number. In CI (no file) it is skipped. The iOS
/// twin of Android's `RealExportTest6`.
///
/// ```
/// PIXLAUDIO_EVAL_EXPORT="C:\path\to\play-events.jsonl" cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainRealExportTest6"
/// ```
///
/// The file is the event log, one `PlayEvent.encode()` line per play, oldest first (the Android Developer mode action "Export play events"
/// writes it). A `play_event.pbl` copied from this app's `Application Support/Brain/` is read too (its records are the same lines). Nothing
/// is uploaded, and the file stays out of git. The report goes to `PIXLAUDIO_EVAL_REPORT`, else `.build/reports/brain-test6.txt` under the
/// package.
///
/// What the report says: how many graded plays the file holds, the log-loss of the learned weights and of the prior over the last 2,000,
/// their relative gain, the interval of the per-play gain over resampled sessions, the accuracy of both, and whether the test passes (at
/// least 2,000 graded plays, a gain of at least 1%, an interval above 0). Until someone has run this on a real export there is NO real-data
/// number for the learner anywhere in this repository, and the legacy engine stays. The favourites are not in the file, so feature 8 (liked)
/// is 0 here: the figure is a little conservative for a listener who likes a lot.
@Suite("Brain test 6 on a real export (local only)")
struct BrainRealExportTest6 {
    static let path = ProcessInfo.processInfo.environment["PIXLAUDIO_EVAL_EXPORT"] ?? ""

    static func events(at path: String) -> [PlayEvent] {
        var out: [PlayEvent] = []
        if path.hasSuffix(".pbl") {
            KeyedLogStore(url: URL(fileURLWithPath: path)).open { _, payload in
                if let event = PlayEvent.decode(String(decoding: payload, as: UTF8.self)) { out.append(event) }
            }
        } else if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                if let event = PlayEvent.decode(String(line)) { out.append(event) }
            }
        }
        return out.sorted { $0.eventId < $1.eventId }
    }

    static func fmt(_ v: Double) -> String { String(format: "%.4f", v) }

    @Test(.enabled(if: !path.isEmpty, "set PIXLAUDIO_EVAL_EXPORT to a play-events.jsonl to run test 6 on real data"))
    func test6OnARealExport() throws {
        let events = Self.events(at: Self.path)
        try #require(events.count >= 200, "an export of \(events.count) events is too short to say anything")
        let nowMs = events[events.count - 1].startedAtMs + 3_600_000
        let started = Date()
        let run = LearnReplay.run(events, facts: .empty, nowMs: nowMs, likedRids: [], tzNowMin: 0)
        let millis = Int(Date().timeIntervalSince(started) * 1000)
        let summary = Gate.summarize(run.predictions, nowMs: nowMs)
        let t6 = LearnReplay.test6(run.predictions)
        var text = ""
        text += "Test 6: learned weights against the frozen prior (real export: \(Self.path))\n"
        text += "events replayed:        \(run.events)   (replay took \(millis) ms)\n"
        text += "graded plays:           \(run.predictions.size)   (finished or skipped; the last \(Gate.window) are compared)\n"
        text += "log-loss learned:       \(Self.fmt(t6.logLossLearned))\n"
        text += "log-loss prior:         \(Self.fmt(t6.logLossPrior))\n"
        text += "gain:                   \(Self.fmt(t6.improvement * 100.0)) %  (needs at least \(LearnReplay.test6MinImprovement * 100.0) %)\n"
        text += "per-play gain interval: [\(Self.fmt(t6.gainLow)), \(Self.fmt(t6.gainHigh))]  (needs the low end above 0)\n"
        text += "accuracy learned:       \(Self.fmt(summary.accLearned * 100.0)) %   prior: \(Self.fmt(summary.accPrior * 100.0)) %  (finishes and skips)\n"
        text += "enough graded plays:    \(t6.enoughPlays)  (needs \(LearnReplay.test6MinPlays))\n"
        text += "test 6 passes:          \(t6.passes)\n"
        text += "weights moved by:       \(run.model.updates) plays\n"
        text += "This is one listener's one export. It is the only real-data number; nothing else in the repository is.\n"
        print(text)
        let reportPath = ProcessInfo.processInfo.environment["PIXLAUDIO_EVAL_REPORT"] ?? ".build/reports/brain-test6.txt"
        let url = URL(fileURLWithPath: reportPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
