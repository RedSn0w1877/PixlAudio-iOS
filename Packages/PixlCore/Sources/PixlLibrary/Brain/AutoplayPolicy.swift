// The decisions of Autoplay (docs/brain-spec.md, 7.1, the filters of 6.1, the hard constraints of 6.4), as pure
// functions: when the queue is topped up, when a queue edit must wait, and which tracks of the pool go in, in what
// order. No player, no clock, no I/O: the app's `AutoplayController` supplies the facts and carries out the answer.
// A transliteration of Android's `AutoplayPolicy.kt`.
//
// Stage 1a has no scorer. The pool arrives in radio order and leaves in radio order; this file only removes what
// must never be played and what would break a list rule.

/// The decisions of Autoplay.
public enum AutoplayPolicy {
    /// Top up when this many tracks or fewer are left after the current one.
    public static let triggerRemaining = 2
    /// Tracks appended per queue edit: one edit, because each edit re-plans what plays next.
    public static let batchSize = 5
    /// A radio request starts no earlier than this far into a track: nothing competes with its first bytes.
    public static let settleMs: Int64 = 1_500
    /// After the queue ended with no picks ready, picks that land within this window resume playback.
    public static let backstopWindowMs: Int64 = 10_000
    /// The pool is refilled in the background when it drops under this.
    public static let poolRefillBelow = 15
    /// Session anchors: the last tracks the listener chose.
    public static let maxAnchors = 3

    public static let minDurationMs: Int64 = 60_000
    public static let maxDurationMs: Int64 = 900_000

    /// 6.4: the same primary artist not within this many slots.
    public static let artistGap = 4
    /// 6.4: the same album not within this many slots.
    public static let albumGap = 8

    static let repeatModeOff: Int32 = 0

    // MARK: Trigger

    public enum Decision: Sendable, Equatable {
        case topUp
        /// The Autoplay switch is off.
        case off
        /// Repeat-one or repeat-all is on: the queue already never ends.
        case repeating
        /// Spotify Connect plays: autoplay is off during remote sessions in stage 1.
        case remote
        /// A saved queue is being restored; its own engine items come back with it.
        case restoring
        case noQueue
        case enoughQueued
    }

    /// How many tracks are left after the current one, counted on the full queue.
    public static func remainingAfterCurrent(fullQueueSize: Int, currentAbsoluteIndex: Int) -> Int {
        max(fullQueueSize - currentAbsoluteIndex - 1, 0)
    }

    public static func decide(autoplayEnabled: Bool, repeatMode: Int32, isRemoteSession: Bool, isRestoring: Bool,
                              fullQueueSize: Int, currentAbsoluteIndex: Int) -> Decision {
        if !autoplayEnabled { return .off }
        if isRemoteSession { return .remote }
        if isRestoring { return .restoring }
        if repeatMode != repeatModeOff { return .repeating }
        if fullQueueSize <= 0 || currentAbsoluteIndex < 0 { return .noQueue }
        if remainingAfterCurrent(fullQueueSize: fullQueueSize, currentAbsoluteIndex: currentAbsoluteIndex)
            > triggerRemaining { return .enoughQueued }
        return .topUp
    }

    /// A queue edit must not land while one deck hands over to the other (a crossfade in progress, or a gapless
    /// hand-over already scheduled on the host clock): it is held and released when the hand-over is done.
    public static func mustDeferQueueEdit(isTransitionRunning: Bool) -> Bool { isTransitionRunning }

    /// The current track is far enough in for a radio request not to compete with its first bytes.
    public static func isSettled(positionMs: Int64) -> Bool { positionMs >= settleMs }

    /// Whether a pool may be built from the network at all. Offline, or with the YouTube source switched off, the
    /// pool is the cache and then the library, and the queue says so.
    public static func mayUseNetwork(online: Bool, youTubeSourceEnabled: Bool) -> Bool { online && youTubeSourceEnabled }

    /// The backstop: the queue ended before any pick was ready. Picks that arrive now are appended and playback
    /// resumes only inside the window and only if the listener did not touch play or pause meanwhile.
    public static func backstopMayResume(endedAtMs: Int64, nowMs: Int64, playWhenReady: Bool) -> Bool {
        playWhenReady && nowMs >= endedAtMs && nowMs - endedAtMs <= backstopWindowMs
    }

    // MARK: Candidates

    /// One track the pool could play, reduced to what the rules read.
    public struct Candidate: Sendable {
        /// The media id it would play under.
        public var mediaId: String
        /// Recording id; two candidates with one rid are the same recording. 0 = unknown.
        public var rid: Int64
        /// Folded primary artist; "" when unknown.
        public var artistKey: String
        /// Folded album name; nil when unknown.
        public var albumKey: String?
        /// 0 when unknown (Related-tab rows carry no length).
        public var durationMs: Int64
        /// `BrainText` version flags of the title.
        public var versionFlags: Int32
        public var officialAudio: Bool
        /// True when the recording is a library track (it plays from the library row).
        public var inLibrary: Bool
        /// `Arm` code.
        public var arm: Int32
        /// 1-based rank in the radio that produced it; 0 when it did not come from a radio.
        public var radioRank: Int32

        public init(mediaId: String, rid: Int64, artistKey: String, albumKey: String?, durationMs: Int64,
                    versionFlags: Int32, officialAudio: Bool, inLibrary: Bool, arm: Int32, radioRank: Int32) {
            self.mediaId = mediaId
            self.rid = rid
            self.artistKey = artistKey
            self.albumKey = albumKey
            self.durationMs = durationMs
            self.versionFlags = versionFlags
            self.officialAudio = officialAudio
            self.inLibrary = inLibrary
            self.arm = arm
            self.radioRank = radioRank
        }
    }

    /// One engine-owned slot already in the queue, oldest first.
    public struct Slot: Sendable {
        public var artistKey: String
        public var albumKey: String?

        public init(artistKey: String, albumKey: String?) {
            self.artistKey = artistKey
            self.albumKey = albumKey
        }
    }

    static let neverFlags = BrainText.flagKaraoke | BrainText.flagCover | BrainText.flagSpedUp | BrainText.flagSlowed
    static let seedMatchedFlags = BrainText.flagLive | BrainText.flagInstrumental | BrainText.flagRemix

    /// The filters of 6.1 that depend only on the candidate and the seeds. `seedFlags` is the union of the anchors'
    /// version flags: a live, instrumental or remix candidate is allowed only when a seed is one. A library track is
    /// the listener's own choice of version, so the version filters do not apply to it.
    public static func passesFilters(_ candidate: Candidate, seedFlags: Int32) -> Bool {
        if candidate.durationMs != 0
            && (candidate.durationMs < minDurationMs || candidate.durationMs > maxDurationMs) { return false }
        if candidate.inLibrary { return true }
        if !candidate.officialAudio { return false }
        if candidate.versionFlags & neverFlags != 0 { return false }
        let needsSeed = candidate.versionFlags & seedMatchedFlags
        if needsSeed != 0 && needsSeed & seedFlags != needsSeed { return false }
        return true
    }

    /// Picks up to `count` tracks from `pool`, in pool order, under the hard list constraints of 6.4: no recording
    /// twice, nothing in `excludedMediaIds` or `excludedRids` (already queued, played in the last 4 hours, ignored
    /// three times), the same primary artist not within `artistGap` slots and at most 2 per 20 and 3 per 50, the
    /// same album not within `albumGap` slots.
    ///
    /// The spacing rules run over the engine's own list: `engineTail` (engine items already in the queue, oldest
    /// first) followed by what this call picks. Tracks the listener queued are not part of it. Returns fewer than
    /// `count` when the pool cannot fill the batch without breaking a rule.
    public static func pickBatch(pool: [Candidate], engineTail: [Slot], excludedMediaIds: Set<BrainKey>,
                                 excludedRids: Set<Int64>, count: Int = batchSize) -> [Candidate] {
        if count <= 0 || pool.isEmpty { return [] }
        var list = engineTail
        var picked: [Candidate] = []
        var usedRids = Set<Int64>()
        var usedMediaIds = Set<BrainKey>()
        while picked.count < count {
            var chosen: Candidate?
            for candidate in pool {
                let mediaKey = BrainKey(candidate.mediaId)
                if excludedMediaIds.contains(mediaKey) || usedMediaIds.contains(mediaKey) { continue }
                if candidate.rid != 0 && (excludedRids.contains(candidate.rid) || usedRids.contains(candidate.rid)) {
                    continue
                }
                if !fitsAfter(list, candidate) { continue }
                chosen = candidate
                break
            }
            guard let next = chosen else { break }
            picked.append(next)
            usedMediaIds.insert(BrainKey(next.mediaId))
            if next.rid != 0 { usedRids.insert(next.rid) }
            list.append(Slot(artistKey: next.artistKey, albumKey: next.albumKey))
        }
        return picked
    }

    /// True when `candidate` may take the slot after `list` without breaking an artist or album rule.
    public static func fitsAfter(_ list: [Slot], _ candidate: Candidate) -> Bool {
        let size = list.count
        let artist = candidate.artistKey
        if !artist.isEmpty {
            var within20 = 0
            var within50 = 0
            var back = 1
            while back <= 49 && size - back >= 0 {
                if BrainKey.sameBytes(list[size - back].artistKey, artist) {
                    if back <= artistGap { return false }
                    if back <= 19 { within20 += 1 }
                    within50 += 1
                }
                back += 1
            }
            // Counting this slot: at most 2 in any 20, 3 in any 50.
            if within20 >= 2 || within50 >= 3 { return false }
        }
        if let album = candidate.albumKey, !album.isEmpty {
            var back = 1
            while back <= albumGap && size - back >= 0 {
                if let other = list[size - back].albumKey, BrainKey.sameBytes(other, album) { return false }
                back += 1
            }
        }
        return true
    }

    /// Merges the radios of several anchors into one pool order: rank by rank, newest anchor first, so the first
    /// pick is the best row of the newest anchor and no anchor's radio drowns the others. A recording that several
    /// radios name keeps its first (best) position.
    public static func interleave(_ lists: [[Candidate]]) -> [Candidate] {
        if lists.isEmpty { return [] }
        if lists.count == 1 { return dedupe(lists[0]) }
        var longest = 0
        for list in lists where list.count > longest { longest = list.count }
        var merged: [Candidate] = []
        merged.reserveCapacity(longest * lists.count)
        for rank in 0..<longest {
            for list in lists where rank < list.count { merged.append(list[rank]) }
        }
        return dedupe(merged)
    }

    static func dedupe(_ candidates: [Candidate]) -> [Candidate] {
        var seenRids = Set<Int64>()
        var seenMediaIds = Set<BrainKey>()
        var out: [Candidate] = []
        out.reserveCapacity(candidates.count)
        for candidate in candidates {
            if !seenMediaIds.insert(BrainKey(candidate.mediaId)).inserted { continue }
            if candidate.rid != 0 && !seenRids.insert(candidate.rid).inserted { continue }
            out.append(candidate)
        }
        return out
    }

    /// The anchors of a queue (7.1, stage 1a form): the last `maxAnchors` distinct tracks the listener chose, at or
    /// before the current position, newest first. Tracks the engine picked are never anchors, so an hour of
    /// autoplay is still the radio of what the listener chose, not the radio of a radio. `engineOwned` says, per
    /// queue index, whether the engine put that item there.
    public static func anchorIndices(currentAbsoluteIndex: Int, queueSize: Int, engineOwned: (Int) -> Bool,
                                     mediaIdAt: (Int) -> String, max: Int = maxAnchors) -> [Int] {
        if queueSize <= 0 { return [] }
        var out: [Int] = []
        var seen = Set<BrainKey>()
        var i = min(currentAbsoluteIndex, queueSize - 1)
        while i >= 0 && out.count < max {
            if !engineOwned(i) && seen.insert(BrainKey(mediaIdAt(i))).inserted { out.append(i) }
            i -= 1
        }
        return out
    }

    // MARK: Re-scoring the tail (7.3, decision D8)

    /// How many tracks after the current one the prefetcher has warmed: the next one, or the next two on unmetered
    /// Wi-Fi. A re-score never replaces them.
    public static func warmedAhead(unmeteredWifi: Bool) -> Int { unmeteredWifi ? 2 : 1 }

    /// The first queue index a re-score may replace, or -1 when there is nothing to re-score. It lies after the
    /// current track and the `warmedAhead` ones, and after the last track the listener put in the queue: only an
    /// unbroken run of engine items at the very end is the engine's to change.
    public static func rescoreStart(queueSize: Int, currentAbsoluteIndex: Int, warmedAhead: Int,
                                    engineOwned: (Int) -> Bool) -> Int {
        if queueSize <= 0 || currentAbsoluteIndex < 0 { return -1 }
        var start = currentAbsoluteIndex + 1 + (warmedAhead < 1 ? 1 : warmedAhead)
        if start >= queueSize { return -1 }
        var i = queueSize - 1
        while i >= start {
            if !engineOwned(i) {
                start = i + 1
                break
            }
            i -= 1
        }
        return start >= queueSize ? -1 : start
    }

    /// The arm of a library track the pool plays: FAV when it was ever played, DEEP when it never was.
    public static func libraryArm(everPlayed: Bool) -> Int32 { everPlayed ? Arm.fav : Arm.deep }
}
