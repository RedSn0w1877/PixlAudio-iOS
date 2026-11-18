// What one autoplay plan reads from the queue and the pool, and what the queue gets back (docs/brain-spec.md, 7.1,
// 7.3). Plain values in, plain values out: the app's controller gathers the queue on the main actor, the plan itself
// runs on `BrainEngine`, and the answer is one queue edit. A port of `planInputs`, `commit` and the tail half of
// `rescoreTail` in Android's `AutoplayController.kt`.

import Foundation
import PixlModel

/// One queue item as a plan reads it.
public struct AutoplayQueueItem: Sendable, Equatable {
    public var mediaId: String
    public var engineOwned: Bool

    public init(mediaId: String, engineOwned: Bool) {
        self.mediaId = mediaId
        self.engineOwned = engineOwned
    }
}

/// Everything a plan reads, with the way back from a recording id to the pool entry it stands for.
public struct AutoplayPlanContext: Sendable {
    public var inputs: AutoplayPlanInputs
    public var entriesByRid: [Int64: AutoplayPoolEntry]
}

/// One track a plan put in the queue.
public struct AutoplayPlannedItem: Sendable {
    public var entry: AutoplayPoolEntry
    public var tag: BrainItemTag
}

public enum AutoplayPlanning {
    /// A re-score needs the unbroken run of engine items at the end of the queue as pool entries. Nil when one of
    /// them is not known to this process (a restored queue) or has no recording id: the tail is then left alone.
    public static func tailEntries(queue: [AutoplayQueueItem], start: Int,
                                   served: [BrainKey: AutoplayPoolEntry]) -> [AutoplayPoolEntry]? {
        if start < 0 || start >= queue.count { return nil }
        var out: [AutoplayPoolEntry] = []
        out.reserveCapacity(queue.count - start)
        for i in start..<queue.count {
            guard let entry = served[BrainKey(queue[i].mediaId)], entry.brain != nil else { return nil }
            out.append(entry)
        }
        return out
    }

    /// `tailStart` is the first index a re-score replaces (`queue.count` for a top-up); `tailEntries` its tracks.
    /// `served` are the engine items this process put in a queue, by media id; `recentlyPlayed` the media ids
    /// played in the last four hours (6.4). `batch` seeds the tie-break and names the list.
    public static func inputs(queue: [AutoplayQueueItem], tailStart: Int, tailEntries: [AutoplayPoolEntry],
                              pool: [AutoplayPoolEntry], served: [BrainKey: AutoplayPoolEntry],
                              recentlyPlayed: Set<BrainKey>, seeds: [Retrieval.SeedList], nowMs: Int64,
                              tzOffsetMin: Int32, batch: Int64) -> AutoplayPlanContext {
        var queuedIds = recentlyPlayed
        var prior: [ListBuilder.Prior] = []
        var excludedRids: Set<Int64> = []
        var listenerItems = 0
        for (i, item) in queue.enumerated() {
            if !item.engineOwned { listenerItems += 1 }
            if i >= tailStart { continue }
            queuedIds.insert(BrainKey(item.mediaId))
            guard let candidate = served[BrainKey(item.mediaId)]?.brain else { continue }
            excludedRids.insert(candidate.rid)
            if item.engineOwned {
                prior.append(ListBuilder.Prior(rid: candidate.rid, aid: candidate.aid, albumKey: candidate.albumKey,
                                               novel: !candidate.inLibrary))
            }
        }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(pool.count + tailEntries.count)
        var entriesByRid: [Int64: AutoplayPoolEntry] = [:]
        for entry in tailEntries {
            guard let candidate = entry.brain, entriesByRid[candidate.rid] == nil else { continue }
            entriesByRid[candidate.rid] = entry
            candidates.append(candidate)
        }
        for entry in pool {
            guard let candidate = entry.brain else { continue }
            if queuedIds.contains(BrainKey(entry.candidate.mediaId)) {
                // A track the listener queued themselves is also in the pool: it may not be picked again.
                excludedRids.insert(candidate.rid)
                continue
            }
            if entriesByRid[candidate.rid] == nil {
                entriesByRid[candidate.rid] = entry
                candidates.append(candidate)
            }
        }
        let inputs = AutoplayPlanInputs(
            candidates: candidates,
            prior: prior.count > 50 ? Array(prior.suffix(50)) : prior,
            excludedRids: excludedRids,
            seeds: seeds,
            // After a single track the listener asked for "more like this"; after an album or a playlist autoplay
            // stays closer to home (6.2).
            nuMultiplier: listenerItems <= 1 ? 1.0 : 0.8,
            nowMs: nowMs,
            tzOffsetMin: tzOffsetMin,
            batch: batch)
        return AutoplayPlanContext(inputs: inputs, entriesByRid: entriesByRid)
    }

    /// The queue tag of one engine pick. `pick` nil is a pick in pool order (the library-only pool).
    public static func tag(entry: AutoplayPoolEntry, pick: StationPlanner.Pick?, recId: Int64, slot: Int, surfaceId: String,
                           artistNames: [Int64: String], likedTitles: [Int64: String]) -> BrainItemTag {
        // The reason line (8.8): a key from the pure core and the name its argument stands for.
        var whyName = entry.whyArtist
        var whyKey: String?
        if let pick {
            if pick.whyKey == WhyLine.radioFans || pick.whyKey == WhyLine.artistMore {
                whyName = artistNames[pick.whyArg] ?? entry.whyArtist
            } else if pick.whyKey == WhyLine.becauseLiked {
                whyName = likedTitles[pick.whyArg] ?? ""
            } else {
                whyName = ""
            }
            if pick.whyKey != WhyLine.none { whyKey = WhyLine.nameOf(pick.whyKey) }
        }
        let rank = pick.map { Int($0.radioRank) } ?? (entry.candidate.radioRank > 0 ? Int(entry.candidate.radioRank) : -1)
        return BrainItemTag(surface: Surface.nameOf(Surface.autoplay), surfaceId: surfaceId, recId: recId, slot: slot,
                            arm: Arm.nameOf(pick?.arm ?? entry.candidate.arm),
                            whyArg: BrainText.isBlank(whyName) ? nil : whyName, radioRank: rank,
                            retrQ: pick.map { Int($0.retrQ) } ?? -1, whyKey: whyKey,
                            primaryArtist: BrainText.isBlank(entry.primaryArtist) ? nil : entry.primaryArtist)
    }

    /// The picks of `plan` as queue items, in plan order. `recId` names the list (`nowMs << 8 | batch`).
    public static func items(plan: StationPlanner.Plan, context: AutoplayPlanContext, surfaceId: String,
                             artistNames: [Int64: String], likedTitles: [Int64: String]) -> [AutoplayPlannedItem] {
        let recId = (context.inputs.nowMs << 8) | (context.inputs.batch & 0xff)
        var out: [AutoplayPlannedItem] = []
        out.reserveCapacity(plan.picks.count)
        for pick in plan.picks {
            guard let entry = context.entriesByRid[pick.rid] else { continue }
            out.append(AutoplayPlannedItem(entry: entry, tag: tag(entry: entry, pick: pick, recId: recId,
                                                                  slot: Int(pick.slot), surfaceId: surfaceId,
                                                                  artistNames: artistNames, likedTitles: likedTitles)))
        }
        return out
    }
}
