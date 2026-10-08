// "Your instrumentals are ready": which batches finished while PixlAudio wasn't on screen, and the words of the local
// notification. Pure; the app posts it with UserNotifications (never a push: product rule 5).
//
// A batch is only announced when it was outstanding at the previous check and is finished now, so batches that were
// already done at launch (or whose jobs the person cancelled themselves) never produce one, and a batch is announced
// once (`alreadyNotified` is kept by the app).

import Foundation

/// How a finished batch turned out.
public struct CloudBatchOutcome: Sendable, Equatable {
    public var batchId: String
    public var total: Int
    public var imported: Int
    /// Failed or expired: needs the person.
    public var needsAttention: Int
    public var instrumentals: Int
    public var lyrics: Int
    /// The only song's title when the batch had one song.
    public var singleTitle: String?

    public init(batchId: String, total: Int, imported: Int, needsAttention: Int, instrumentals: Int, lyrics: Int,
                singleTitle: String?) {
        self.batchId = batchId
        self.total = total
        self.imported = imported
        self.needsAttention = needsAttention
        self.instrumentals = instrumentals
        self.lyrics = lyrics
        self.singleTitle = singleTitle
    }
}

public enum CloudBatchNotifier {
    /// The batches that still have a job outstanding.
    public static func incompleteBatchIds(_ jobs: [CloudJobRecord]) -> Set<String> {
        Set(jobs.filter { $0.state.isPending }.map(\.batchId))
    }

    /// Batches from `previouslyIncomplete` that are finished now and worth a notification: at least one song came back
    /// or failed (a batch the person cancelled is not news), and not announced before. Oldest batch first.
    public static func completions(previouslyIncomplete: Set<String>, jobs: [CloudJobRecord],
                                   alreadyNotified: Set<String>) -> [CloudBatchOutcome] {
        var order: [String] = []
        var groups: [String: [CloudJobRecord]] = [:]
        for record in jobs {
            if groups[record.batchId] == nil { order.append(record.batchId) }
            groups[record.batchId, default: []].append(record)
        }
        var result: [CloudBatchOutcome] = []
        for batchId in order where previouslyIncomplete.contains(batchId) && !alreadyNotified.contains(batchId) {
            let members = groups[batchId] ?? []
            guard !members.isEmpty, members.allSatisfy({ $0.state.isFinished }) else { continue }
            let counted = members.filter { $0.state != .cancelled }
            let imported = counted.filter { $0.state == .imported }
            let attention = counted.filter { $0.state == .failed || $0.state == .expired }.count
            guard !imported.isEmpty || attention > 0 else { continue }
            result.append(CloudBatchOutcome(
                batchId: batchId, total: counted.count, imported: imported.count, needsAttention: attention,
                instrumentals: imported.filter(\.importedInstrumental).count,
                lyrics: imported.filter(\.importedLyrics).count,
                singleTitle: counted.count == 1 ? counted[0].title : nil))
        }
        return result
    }
}

/// The notification's words.
public enum CloudNotificationCopy {
    public static func title(_ outcome: CloudBatchOutcome) -> String {
        if outcome.imported == 0 { return "Cloud processing needs you" }
        let many = outcome.imported > 1
        switch (outcome.instrumentals > 0, outcome.lyrics > 0) {
        case (true, true): return "Your instrumentals and lyrics are ready"
        case (true, false): return many ? "Your instrumentals are ready" : "Your instrumental is ready"
        case (false, true): return "Your word-timed lyrics are ready"
        case (false, false): return many ? "Your songs are ready" : "Your song is ready"
        }
    }

    public static func body(_ outcome: CloudBatchOutcome) -> String {
        if outcome.imported == 0 {
            let n = outcome.needsAttention
            return n == 1 ? "1 song couldn't be processed. Tap to see why."
                : "\(n) songs couldn't be processed. Tap to see why."
        }
        if outcome.needsAttention > 0 {
            let verb = outcome.needsAttention == 1 ? "needs" : "need"
            return "\(outcome.imported) of \(outcome.total) ready, \(outcome.needsAttention) \(verb) you. Tap to see which."
        }
        if let title = outcome.singleTitle { return "\(title) is ready to use. Tap to open the queue." }
        return "\(outcome.imported) songs processed. Tap to open the queue."
    }
}
