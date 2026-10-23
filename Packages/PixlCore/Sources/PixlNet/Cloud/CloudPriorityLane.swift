// The priority lane (Sing, and one song sent by hand): the pure rules for letting one job go to the GPU ahead of the
// rest. The orchestrator (`CloudStudio.prioritizeQueue`) only sequences the I/O around them.
//
// How it works. A job that RunPod has not started is cancelled there (never a running one), goes back to `uploaded`
// with its upload kept, and is sent again right after the priority job in the same burst, so only the final job of the
// burst carries `last_in_batch`. Nothing is cancelled while the priority job is still preparing or uploading: the GPU
// keeps working through the queue until the priority job is really ready to go.
//
// Who is a priority job: a `sing` job, and a manual job that is the only one of its batch (one song sent by hand).
// Who steps aside: every other job waiting at RunPod, auto ones and the songs of a manual batch alike.

import Foundation

/// What a cancel at RunPod turned out to be.
public enum QueueCancelOutcome: Equatable, Sendable {
    /// The job was still waiting in the queue and is gone from it.
    case cancelledFromQueue
    /// The worker had it (or it had finished) before the cancel landed; the status is what RunPod said.
    case alreadyStarted(RunPodJobStatus)
    /// RunPod's answer could not be read.
    case failed
}

public enum CloudPriorityLane {
    /// Words for a job that stepped aside (Active jobs, the queue).
    public static let pausedLabel = "Paused for a song you're singing"

    // MARK: Who is a priority job

    /// The pending jobs that go first: Sing jobs, and manual jobs that are alone in their batch.
    public static func priorityJobKeys(_ jobs: [CloudJobRecord]) -> Set<String> {
        var batchSizes: [String: Int] = [:]
        for record in jobs { batchSizes[record.batchId, default: 0] += 1 }
        var keys = Set<String>()
        for record in jobs where record.state.isPending {
            switch record.effectiveOrigin {
            case .sing: keys.insert(record.jobKey)
            case .manual: if batchSizes[record.batchId] == 1 { keys.insert(record.jobKey) }
            case .auto: break
            }
        }
        return keys
    }

    /// 0 for Sing, 1 for one song sent by hand, 2 for a manual batch, 3 for auto: the order jobs are prepared and
    /// uploaded in.
    public static func tier(of record: CloudJobRecord, priorityKeys: Set<String>) -> Int {
        switch record.effectiveOrigin {
        case .sing: return 0
        case .manual: return priorityKeys.contains(record.jobKey) ? 1 : 2
        case .auto: return 3
        }
    }

    /// `records` by tier, each tier in the order it came (the list is oldest first). Inside a tier a Sing's preview piece
    /// (`CloudSingClip`) comes before whole songs: it is what the person hears first.
    public static func ordered(_ records: [CloudJobRecord], priorityKeys: Set<String>) -> [CloudJobRecord] {
        records.enumerated().sorted { lhs, rhs in
            let a = tier(of: lhs.element, priorityKeys: priorityKeys), b = tier(of: rhs.element, priorityKeys: priorityKeys)
            if a != b { return a < b }
            if lhs.element.isClip != rhs.element.isClip { return lhs.element.isClip }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// URLSessionTask priority (0…1) of a job's upload: the priority job first, auto work last.
    public static func transferPriority(for record: CloudJobRecord, priorityKeys: Set<String>) -> Float {
        if priorityKeys.contains(record.jobKey) { return 1.0 }
        return record.effectiveOrigin == .auto ? 0.3 : 0.5
    }

    // MARK: Pausing

    /// The priority job that is uploaded and about to be sent: the one the others step aside for. Not one that is
    /// itself paused, waiting out a retry, or whose upload is too old to send.
    public static func readyPriorityJob(_ jobs: [CloudJobRecord], priorityKeys: Set<String>, nowMs: Int64) -> CloudJobRecord? {
        ordered(jobs.filter { priorityKeys.contains($0.jobKey) }, priorityKeys: priorityKeys).first { record in
            record.state == .uploaded && !record.isPaused && record.isDue(nowMs: nowMs)
                && !CloudRetention.inputTooOldToSubmit(uploadedAtMs: record.uploadedAtMs, nowMs: nowMs)
        }
    }

    /// The jobs that can step aside: waiting at RunPod (never a running one) and not priority jobs themselves.
    public static func pausable(_ jobs: [CloudJobRecord], priorityKeys: Set<String>) -> [CloudJobRecord] {
        jobs.filter { $0.state == .submitted && $0.runpodJobId != nil && !priorityKeys.contains($0.jobKey) }
    }

    /// The jobs that step aside for `priority`: `pausable`, and — when `priority` is a Sing's preview piece — the song's
    /// own full job too while it only waits in RunPod's queue (a Sing tap that joined a job already sent): the minute
    /// the person is about to sing goes first, the whole song right behind it.
    public static func pausable(_ jobs: [CloudJobRecord], priorityKeys: Set<String>,
                                for priority: CloudJobRecord) -> [CloudJobRecord] {
        guard priority.isClip else { return pausable(jobs, priorityKeys: priorityKeys) }
        return jobs.filter { record in
            guard record.state == .submitted, record.runpodJobId != nil, record.jobKey != priority.jobKey else { return false }
            if !priorityKeys.contains(record.jobKey) { return true }
            return !record.isClip && record.songId == priority.songId
        }
    }

    /// Cancelled from the tail of the queue to its head: the newest submission first.
    public static func newestFirst(_ candidates: [CloudJobRecord]) -> [CloudJobRecord] {
        candidates.enumerated().sorted { lhs, rhs in
            let a = lhs.element.submittedAtMs ?? 0, b = rhs.element.submittedAtMs ?? 0
            return a != b ? a > b : lhs.offset > rhs.offset
        }.map(\.element)
    }

    /// Jobs whose pause has to end: their priority job is gone (cancelled, failed, removed), or — for a cancel not yet
    /// sent or answered — it has started, so there is nothing left to step aside for.
    public static func pausesToEnd(_ jobs: [CloudJobRecord]) -> [String] {
        var byKey: [String: CloudJobRecord] = [:]
        for record in jobs where byKey[record.jobKey] == nil { byKey[record.jobKey] = record }
        return jobs.compactMap { record in
            guard let by = record.pausedBy else { return nil }
            guard let priority = byKey[by], !priority.state.isFinished else { return record.jobKey }
            if record.hasPauseIntent, !(priority.state.isBeforeSubmit || priority.state == .submitted) { return record.jobKey }
            return nil
        }
    }

    // MARK: Pre-check and answer of a cancel

    /// What the fresh `/status` taken just before the cancel says: nil when the job is still waiting in the queue (go
    /// on and cancel it), else the job is not ours to cancel — the worker has it, it ended, or it is already cancelled.
    public static func outcome(afterStatus job: RunPodJob) -> QueueCancelOutcome? {
        guard let status = job.typedStatus else { return .failed }
        switch status {
        case .inQueue: return nil
        // The cancel landed earlier and only its answer was lost.
        case .cancelled: return .cancelledFromQueue
        case .inProgress, .completed, .failed, .timedOut: return .alreadyStarted(status)
        }
    }

    /// `/cancel`'s answer: only `CANCELLED` counts as stepped aside; anything else means the worker got there first.
    public static func outcome(afterCancel job: RunPodJob) -> QueueCancelOutcome {
        guard let status = job.typedStatus else { return .failed }
        return status == .cancelled ? .cancelledFromQueue : .alreadyStarted(status)
    }

    // MARK: Sending

    /// Jobs that wait for the priority job instead of going out in this pass:
    /// - a job paused for a priority job that has not gone out yet (and is not part of this pass), for at most
    ///   `maxHoldMs`;
    /// - auto jobs, while a priority job is still getting ready (new auto jobs must not slip ahead of it and then
    ///   have to be cancelled again).
    public static func heldBack(ready: [String], jobs: [CloudJobRecord], nowMs: Int64,
                                maxHoldMs: Int64 = CloudTiming.priorityHoldMaxMs) -> Set<String> {
        var byKey: [String: CloudJobRecord] = [:]
        for record in jobs where byKey[record.jobKey] == nil { byKey[record.jobKey] = record }
        let inThisPass = Set(ready)
        let holdsAuto = shouldHoldAutoSubmissions(jobs, nowMs: nowMs, excluding: inThisPass, maxHoldMs: maxHoldMs)
        var held = Set<String>()
        for key in ready {
            guard let record = byKey[key] else { continue }
            if record.isPaused, let by = record.pausedBy {
                guard let priority = byKey[by], !priority.state.isFinished, !inThisPass.contains(by),
                      priority.state.isBeforeSubmit, nowMs - (record.pausedAtMs ?? 0) < maxHoldMs else { continue }
                held.insert(key)
            } else if record.effectiveOrigin == .auto, holdsAuto {
                held.insert(key)
            }
        }
        return held
    }

    /// A priority job is still preparing, uploading or waiting to go (and is not part of this pass), and is younger
    /// than `maxHoldMs`.
    public static func shouldHoldAutoSubmissions(_ jobs: [CloudJobRecord], nowMs: Int64, excluding: Set<String> = [],
                                                 maxHoldMs: Int64 = CloudTiming.priorityHoldMaxMs) -> Bool {
        let priorityKeys = priorityJobKeys(jobs)
        return jobs.contains { record in
            priorityKeys.contains(record.jobKey) && record.state.isBeforeSubmit && !excluding.contains(record.jobKey)
                && nowMs - (record.priorityAtMs ?? record.createdAtMs) < maxHoldMs
        }
    }

    /// The order of one burst: the priority jobs first (a Sing's preview piece ahead of its full job), then the jobs
    /// that stepped aside in the order they were first sent, then everything else in queue order.
    public static func submitOrder(ready: [String], jobs: [CloudJobRecord]) -> [String] {
        var position: [String: Int] = [:]
        var byKey: [String: CloudJobRecord] = [:]
        for (index, record) in jobs.enumerated() where byKey[record.jobKey] == nil {
            position[record.jobKey] = index
            byKey[record.jobKey] = record
        }
        let priorityKeys = priorityJobKeys(jobs)
        var first: [(tier: Int, clip: Bool, index: Int, key: String)] = []
        var paused: [(index: Int, key: String)] = []
        var rest: [(index: Int, key: String)] = []
        for key in ready {
            guard let record = byKey[key], let index = position[key] else { continue }
            if priorityKeys.contains(key) {
                first.append((tier(of: record, priorityKeys: priorityKeys), record.isClip, index, key))
            } else if record.isPaused {
                paused.append((index, key))
            } else {
                rest.append((index, key))
            }
        }
        // A Sing's preview piece before its song's full job (and any other job of the same tier).
        first.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.clip != rhs.clip { return lhs.clip }
            return lhs.index < rhs.index
        }
        paused.sort { $0.index < $1.index }
        rest.sort { $0.index < $1.index }
        return first.map(\.key) + paused.map(\.key) + rest.map(\.key)
    }
}
