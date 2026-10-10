// Cloud Studio's rows in the Home "Active jobs" sheet (Android shows one `CLOUD_STUDIO` job for the whole pass): one row
// per batch, so a 200-song playlist is a single line with a bar, not 200 rows. Pure: the app hands over the job records
// and the transfer fractions it holds; everything it shows is computed here and tested.

import Foundation
import PixlModel

public enum CloudActiveJobMapper {
    /// How far along a job is, 0…1, from what is really known. A state with nothing to measure (waiting for a GPU)
    /// takes the step's start, so a batch's bar still moves when jobs change step.
    public static func weight(_ record: CloudJobRecord, transfer: Double?) -> Double {
        let t = min(max(transfer ?? 0, 0), 1)
        switch record.state {
        case .queued: return 0
        case .preparing: return 0.05
        case .uploading: return 0.1 + 0.3 * t
        case .uploaded: return 0.4
        case .submitted: return 0.45
        case .running:
            let p = Double(min(max(record.progressPercent ?? 0, 0), 100)) / 100
            return 0.5 + 0.4 * p
        case .resultsReady: return 0.9
        case .downloading: return 0.9 + 0.1 * t
        case .imported: return 1
        case .failed, .cancelled, .expired: return 0
        }
    }

    /// The step the job is in, in plain words, with a percentage only when one is real.
    public static func status(_ record: CloudJobRecord, transfer: Double?) -> String {
        switch record.state {
        case .uploading, .downloading:
            if let transfer { return "\(record.state.label) \(Int((min(max(transfer, 0), 1) * 100).rounded(.down)))%" }
            return record.state.label
        case .running:
            if let stage = record.progressStage {
                let progress = CloudProgress(stage: stage, percent: record.progressPercent)
                return record.progressPercent.map { "\(progress.label) \($0)%" } ?? progress.label
            }
            return record.state.label
        case .failed:
            if let code = record.lastErrorCode, !code.isEmpty { return "Failed · \(code)" }
            return record.state.label
        default:
            if record.nextAttemptAtMs != nil, let error = record.lastError, !error.isEmpty { return "Trying again soon" }
            return record.state.label
        }
    }

    /// One real percentage for a lone job: the transfer or the worker's own, nothing for steps that have none.
    static func singlePercent(_ record: CloudJobRecord, transfer: Double?) -> Int? {
        switch record.state {
        case .uploading, .downloading: transfer.map { Int((min(max($0, 0), 1) * 100).rounded(.down)) }
        case .running: record.progressPercent
        case .imported: 100
        default: nil
        }
    }

    /// A job doing something now (not waiting its turn, for a GPU or out a retry).
    static func isWorking(_ record: CloudJobRecord) -> Bool {
        switch record.state {
        case .preparing, .uploading, .running, .resultsReady, .downloading: record.nextAttemptAtMs == nil
        default: false
        }
    }

    /// What the Home button needs, without building any row: how many batches have a job outstanding (the same
    /// number of active rows `rows` gives) and whether any job is working. Cheap enough to run on every change.
    public static func activeSummary(_ jobs: [CloudJobRecord]) -> (count: Int, working: Bool) {
        var batches = Set<String>()
        var working = false
        for record in jobs where record.state.isPending {
            batches.insert(record.batchId)
            if !working, isWorking(record) { working = true }
        }
        return (batches.count, working)
    }

    /// Every batch as a row: active ones (queued or running) and, for the "Recently finished" part, done and
    /// needs-attention ones. A batch that was only cancelled leaves no row.
    public static func rows(_ jobs: [CloudJobRecord], transfer: [String: Double]) -> [ActiveJob] {
        var order: [String] = []
        var groups: [String: [CloudJobRecord]] = [:]
        for record in jobs {
            if groups[record.batchId] == nil { order.append(record.batchId) }
            groups[record.batchId, default: []].append(record)
        }
        return order.compactMap { batchId in row(batchId: batchId, members: groups[batchId] ?? [], transfer: transfer) }
    }

    private static func row(batchId: String, members: [CloudJobRecord], transfer: [String: Double]) -> ActiveJob? {
        let counted = members.filter { $0.state != .cancelled }
        guard !counted.isEmpty else { return nil }
        let id = "cloud.\(batchId)"
        let updated = members.map { $0.updatedAtMs ?? $0.importedAtMs ?? $0.completedAtMs ?? $0.createdAtMs }.max() ?? 0
        let pending = counted.filter { $0.state.isPending }
        let imported = counted.filter { $0.state == .imported }.count

        if !pending.isEmpty {
            // Doing something now, or only waiting (for its turn, for a GPU, for a retry).
            let working = pending.contains(where: isWorking)
            if counted.count == 1, let record = counted.first {
                let fraction = transfer[record.jobKey]
                return ActiveJob(id: id, kind: .cloud,
                                 subtitle: "\(record.title) · \(status(record, transfer: fraction))",
                                 percent: singlePercent(record, transfer: fraction),
                                 state: working ? .running : .queued, destination: .cloudQueue, updatedAtMs: updated)
            }
            let total = counted.reduce(0.0) { $0 + weight($1, transfer: transfer[$1.jobKey]) } / Double(counted.count)
            return ActiveJob(id: id, kind: .cloud, subtitle: batchSummary(counted),
                             percent: ActiveJobBoard.percent(fraction: total),
                             state: working ? .running : .queued, destination: .cloudQueue, updatedAtMs: updated)
        }

        let attention = counted.filter { $0.state == .failed || $0.state == .expired }.count
        if attention == 0 {
            let line = counted.count == 1 ? "\(counted[0].title) is ready" : "\(imported) songs processed"
            return ActiveJob(id: id, kind: .cloud, subtitle: line, percent: 100, state: .done,
                             destination: .cloudQueue, updatedAtMs: updated)
        }
        let line = counted.count == 1
            ? "\(counted[0].title) · \(status(counted[0], transfer: nil))"
            : "\(imported) of \(counted.count) ready · \(attention) \(attention == 1 ? "needs" : "need") you"
        return ActiveJob(id: id, kind: .cloud, subtitle: line, state: .failed, destination: .cloudQueue,
                         updatedAtMs: updated, canRetry: true)
    }

    /// "3 of 12 ready · 5 uploading · 2 waiting for a GPU · 2 processing": only the steps that have jobs.
    static func batchSummary(_ members: [CloudJobRecord]) -> String {
        var parts = ["\(members.filter { $0.state == .imported }.count) of \(members.count) ready"]
        func count(_ states: Set<CloudJobState>) -> Int { members.filter { states.contains($0.state) }.count }
        let steps: [(Set<CloudJobState>, String)] = [
            ([.queued], "waiting"), ([.preparing], "preparing"), ([.uploading], "uploading"),
            ([.uploaded, .submitted], "waiting for a GPU"), ([.running], "processing"),
            ([.resultsReady, .downloading], "downloading"),
        ]
        for (states, label) in steps {
            let n = count(states)
            if n > 0 { parts.append("\(n) \(label)") }
        }
        let attention = count([.failed, .expired])
        if attention > 0 { parts.append("\(attention) \(attention == 1 ? "needs" : "need") you") }
        return parts.joined(separator: " · ")
    }
}
