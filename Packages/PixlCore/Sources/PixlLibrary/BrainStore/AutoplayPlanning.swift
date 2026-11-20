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

    public init(entry: AutoplayPoolEntry, tag: BrainItemTag) {
        self.entry = entry
        self.tag = tag
    }
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
    /// played in the last four hours (6.4). `batch` seeds the tie-break and names the list. `station` is the station
    /// the queue is (8.3), nil for plain autoplay; `noveltyFactor` the listener's Familiar / Blend / Discover switch
    /// (`Novelty.factor`).
    public static func inputs(queue: [AutoplayQueueItem], tailStart: Int, tailEntries: [AutoplayPoolEntry],
                              pool: [AutoplayPoolEntry], served: [BrainKey: AutoplayPoolEntry],
                              recentlyPlayed: Set<BrainKey>, seeds: [Retrieval.SeedList], nowMs: Int64,
                              tzOffsetMin: Int32, batch: Int64, station: Station? = nil,
                              noveltyFactor: Double = 1.0, stationBatches: Int = 1, stationSourceIds: Set<String> = [],
                              refreshing: Bool = false, stationReseeded: Bool = false) -> AutoplayPlanContext {
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
        // A station from an album or a playlist does not open with the album's or playlist's own songs (6.2).
        if station != nil, stationBatches == 0, !stationSourceIds.isEmpty {
            for entry in pool where stationSourceIds.contains(entry.candidate.mediaId) {
                if let candidate = entry.brain { excludedRids.insert(candidate.rid) }
            }
        }
        // "Refresh picks": what the tail holds now is not offered again by this plan.
        if refreshing { for entry in tailEntries { if let candidate = entry.brain { excludedRids.insert(candidate.rid) } } }
        let inputs = AutoplayPlanInputs(
            candidates: candidates,
            prior: prior.count > 50 ? Array(prior.suffix(50)) : prior,
            excludedRids: excludedRids,
            seeds: seeds,
            // After a single track the listener asked for "more like this"; after an album or a playlist autoplay
            // stays closer to home; a station leans further out (6.2). The listener's switch scales whichever applies.
            nuMultiplier: noveltyFactor * StationRules.surfaceNu(isStation: station != nil, listenerItems: listenerItems),
            nowMs: nowMs,
            tzOffsetMin: tzOffsetMin,
            batch: batch,
            station: station,
            closestOfSeeds: station.map { $0.seedMediaIds.count > 1 || stationReseeded } ?? false,
            replaceAll: refreshing)
        return AutoplayPlanContext(inputs: inputs, entriesByRid: entriesByRid)
    }

    /// The queue tag of one engine pick. `pick` nil is a pick in pool order (the library-only pool). A station's
    /// picks are logged under the station (`surface = station`, its hashed id), everything else under autoplay.
    public static func tag(entry: AutoplayPoolEntry, pick: StationPlanner.Pick?, recId: Int64, slot: Int, surfaceId: String,
                           artistNames: [Int64: String], likedTitles: [Int64: String],
                           station: Station? = nil, control: Bool = false, modelVersion: Int32 = 0) -> BrainItemTag {
        // The reason line (8.8): a key from the pure core and the name its argument stands for.
        var whyName = entry.whyArtist
        var whyKey: String?
        if let pick {
            if pick.whyKey == WhyLine.radioFans || pick.whyKey == WhyLine.artistMore || pick.whyKey == WhyLine.similarArtist {
                whyName = artistNames[pick.whyArg] ?? entry.whyArtist
            } else if pick.whyKey == WhyLine.becauseLiked {
                whyName = likedTitles[pick.whyArg] ?? ""
            } else {
                whyName = ""
            }
            if pick.whyKey != WhyLine.none { whyKey = WhyLine.nameOf(pick.whyKey) }
        } else if entry.candidate.radioRank > 0 && !BrainText.isBlank(whyName) {
            // Picked in pool order (no planner): a row of an anchor's radio is still what that anchor's artist's
            // listeners play. A plain library pick says nothing; the line says "From your library".
            whyKey = WhyLine.nameOf(WhyLine.radioFans)
        }
        let rank = pick.map { Int($0.radioRank) } ?? (entry.candidate.radioRank > 0 ? Int(entry.candidate.radioRank) : -1)
        return BrainItemTag(surface: Surface.nameOf(station != nil ? Surface.station : Surface.autoplay),
                            surfaceId: station?.id ?? surfaceId, recId: recId, slot: slot,
                            arm: Arm.nameOf(pick?.arm ?? entry.candidate.arm),
                            whyArg: BrainText.isBlank(whyName) ? nil : whyName, radioRank: rank,
                            retrQ: pick.map { Int($0.retrQ) } ?? -1, whyKey: whyKey,
                            primaryArtist: BrainText.isBlank(entry.primaryArtist) ? nil : entry.primaryArtist,
                            // How the list was ranked, fixed when it was built (5.12 point 8); a pick taken in pool order was
                            // ranked by nothing: the prior, no control. A novel slot the arm bandit drew is an exploration slot (5.10).
                            control: control, modelVersion: Int(modelVersion), explore: pick?.explore == true)
    }

    /// `items` without what the queue already holds. A plan is made off the main actor; meanwhile another edit (a
    /// re-score, the listener's own "Add to queue") can have put one of its picks in the queue.
    public static func notQueued(_ items: [AutoplayPlannedItem], queuedIds: Set<BrainKey>) -> [AutoplayPlannedItem] {
        var seen = queuedIds
        return items.filter { seen.insert(BrainKey($0.entry.candidate.mediaId)).inserted }
    }

    /// The picks of `plan` as queue items, in plan order. `recId` names the list (`nowMs << 8 | batch`).
    public static func items(plan: StationPlanner.Plan, context: AutoplayPlanContext, surfaceId: String,
                             artistNames: [Int64: String], likedTitles: [Int64: String],
                             station: Station? = nil) -> [AutoplayPlannedItem] {
        let recId = (context.inputs.nowMs << 8) | (context.inputs.batch & 0xff)
        var out: [AutoplayPlannedItem] = []
        out.reserveCapacity(plan.picks.count)
        for pick in plan.picks {
            guard let entry = context.entriesByRid[pick.rid] else { continue }
            out.append(AutoplayPlannedItem(entry: entry, tag: tag(entry: entry, pick: pick, recId: recId,
                                                                  slot: Int(pick.slot), surfaceId: surfaceId,
                                                                  artistNames: artistNames, likedTitles: likedTitles,
                                                                  station: station, control: plan.control,
                                                                  modelVersion: plan.modelVersion)))
        }
        return out
    }
}

extension AutoplayPlanning {
    /// The pool entry of every pick of `plan`, in plan order (a pick the context does not know is left out).
    public static func pickedEntries(plan: StationPlanner.Plan, context: AutoplayPlanContext) -> [AutoplayPoolEntry] {
        plan.picks.compactMap { context.entriesByRid[$0.rid] }
    }

    /// `plan` with only the picks whose media id is in `kept`: what goes into the queue on an output that plays only
    /// some tracks (Spotify Connect, `AutoplayPolicy.remoteRule`). The planned order is kept; a like's scheduled slot
    /// and the second-skip slot count as used only while something of the plan is left.
    public static func narrowed(_ plan: StationPlanner.Plan, context: AutoplayPlanContext, kept: Set<BrainKey>) -> StationPlanner.Plan {
        let picks = plan.picks.filter { pick in
            guard let entry = context.entriesByRid[pick.rid] else { return false }
            return kept.contains(BrainKey(entry.candidate.mediaId))
        }
        var narrowedPlan = StationPlanner.Plan(picks: picks, usedLiked: plan.usedLiked && !picks.isEmpty,
                                               usedFamiliarNext: plan.usedFamiliarNext && !picks.isEmpty, poolSize: plan.poolSize)
        narrowedPlan.control = plan.control
        narrowedPlan.modelVersion = plan.modelVersion
        return narrowedPlan
    }
}

/// What a taste change takes out of the engine's hands at once (docs/brain-spec.md, 8.5): "Not for me", "Less from
/// ...", a mute or a block. A port of the decision half of `onTasteChanged` in Android's `AutoplayController.kt`.
public enum AutoplayTasteFilter {
    /// The media ids among `held` (the pool and what was served) that the listener's changes now exclude. Folds
    /// every artist name: call it off the main actor.
    public static func excludedIds(held: [AutoplayPoolEntry], blocked: BlockedArtistMatcher,
                                   adjustments: TasteAdjustmentSet) -> Set<String> {
        var out: Set<String> = []
        if blocked.isEmpty && adjustments.isEmpty { return out }
        for entry in held {
            guard let song = entry.librarySong ?? entry.engineTrack?.song() else { continue }
            if blocked.isBlocked(song) || adjustments.isExcluded(song) || adjustments.isBlocked(song) {
                out.insert(entry.candidate.mediaId)
            }
        }
        return out
    }

    /// The listener's boost or reduce for every track the engine holds that the planner scores, by media id: the
    /// value the planner adds (`ln` of the factor, 0 for none). A pool is built once per set of anchors, so "Less
    /// from X" would otherwise change nothing until the anchors do. Folds artist names: call it off the main actor.
    public static func boosts(held: [AutoplayPoolEntry], adjustments: TasteAdjustmentSet) -> [String: Double] {
        var out: [String: Double] = [:]
        out.reserveCapacity(held.count)
        for entry in held where entry.brain != nil {
            guard let song = entry.librarySong ?? entry.engineTrack?.song() else { continue }
            out[entry.candidate.mediaId] = AutoplayPool.boostLn(adjustments, song)
        }
        return out
    }

    /// `entries` with the boosts of `boosts` written in. True in `changed` when any score moved.
    public static func applying(_ boosts: [String: Double], to entries: [AutoplayPoolEntry]) -> (entries: [AutoplayPoolEntry], changed: Bool) {
        var out = entries
        var changed = false
        for i in out.indices {
            guard let boost = boosts[out[i].candidate.mediaId], let brain = out[i].brain, brain.boostLn != boost else { continue }
            out[i].brain!.boostLn = boost
            changed = true
        }
        return (out, changed)
    }
}
