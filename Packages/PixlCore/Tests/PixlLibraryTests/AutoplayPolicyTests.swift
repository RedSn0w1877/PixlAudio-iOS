import Foundation
import Testing
@testable import PixlLibrary

/// Port of Android's `AutoplayPolicyTest`: the trigger, the filters of 6.1 and the hard list constraints of 6.4.
@Suite("Autoplay policy")
struct AutoplayPolicyTests {
    private typealias Candidate = AutoplayPolicy.Candidate
    private typealias Slot = AutoplayPolicy.Slot

    private let repeatOff: Int32 = 0
    private let repeatOne: Int32 = 1
    private let repeatAll: Int32 = 2

    private func decide(enabled: Bool = true, repeatMode: Int32 = 0, remote: Bool = false, restoring: Bool = false,
                        size: Int, index: Int) -> AutoplayPolicy.Decision {
        AutoplayPolicy.decide(autoplayEnabled: enabled, repeatMode: repeatMode, isRemoteSession: remote,
                              isRestoring: restoring, fullQueueSize: size, currentAbsoluteIndex: index)
    }

    private final class Counter { var id: Int64 = 1_000; var media = 0 }
    private let counter = Counter()

    private func candidate(_ artist: String, album: String? = nil, mediaId: String? = nil, rid: Int64? = nil,
                           durationMs: Int64 = 200_000, flags: Int32 = 0, officialAudio: Bool = true,
                           inLibrary: Bool = false, rank: Int32 = 1) -> Candidate {
        counter.media += 1
        counter.id += 1
        return Candidate(mediaId: mediaId ?? "m\(counter.media)", rid: rid ?? counter.id, artistKey: artist,
                         albumKey: album, durationMs: durationMs, versionFlags: flags, officialAudio: officialAudio,
                         inLibrary: inLibrary, arm: inLibrary ? Arm.fav : Arm.radio, radioRank: rank)
    }

    private func pick(_ pool: [Candidate], tail: [Slot] = [], media: Set<String> = [], rids: Set<Int64> = [],
                      count: Int = AutoplayPolicy.batchSize) -> [String] {
        AutoplayPolicy.pickBatch(pool: pool, engineTail: tail, excludedMediaIds: Set(media.map(BrainKey.init)),
                                 excludedRids: rids, count: count).map(\.mediaId)
    }

    // MARK: Trigger

    @Test func topsUpWhenTwoOrFewerTracksAreLeftAfterTheCurrentOne() {
        #expect(decide(size: 1, index: 0) == .topUp)
        #expect(decide(size: 10, index: 9) == .topUp)
        #expect(decide(size: 10, index: 8) == .topUp)
        #expect(decide(size: 10, index: 7) == .topUp)
        #expect(decide(size: 10, index: 6) == .enoughQueued)
        #expect(decide(size: 10, index: 0) == .enoughQueued)
        #expect(decide(size: 0, index: 0) == .noQueue)
        #expect(decide(size: 5, index: -1) == .noQueue)
    }

    @Test func theCountIsTheFullQueue() {
        #expect(AutoplayPolicy.remainingAfterCurrent(fullQueueSize: 260, currentAbsoluteIndex: 150) == 109)
        #expect(decide(size: 260, index: 150) == .enoughQueued)
        #expect(AutoplayPolicy.remainingAfterCurrent(fullQueueSize: 260, currentAbsoluteIndex: 248) == 11)
        #expect(decide(size: 260, index: 258) == .topUp)
        #expect(AutoplayPolicy.remainingAfterCurrent(fullQueueSize: 200, currentAbsoluteIndex: 199) == 0)
        #expect(AutoplayPolicy.remainingAfterCurrent(fullQueueSize: 260, currentAbsoluteIndex: 199) == 60)
        // An index past the end never counts below zero.
        #expect(AutoplayPolicy.remainingAfterCurrent(fullQueueSize: 3, currentAbsoluteIndex: 7) == 0)
    }

    @Test func noTopUpUnderRepeat() {
        #expect(decide(repeatMode: repeatOne, size: 1, index: 0) == .repeating)
        #expect(decide(repeatMode: repeatAll, size: 10, index: 9) == .repeating)
        #expect(decide(repeatMode: repeatOff, size: 10, index: 9) == .topUp)
    }

    @Test func offWhenSwitchedOffDuringARemoteSessionAndWhileAQueueIsRestored() {
        #expect(decide(enabled: false, size: 1, index: 0) == .off)
        #expect(decide(remote: true, size: 1, index: 0) == .remote)
        #expect(decide(restoring: true, size: 1, index: 0) == .restoring)
        // The switch wins over everything else, so a disabled autoplay never reports another reason.
        #expect(decide(enabled: false, repeatMode: repeatAll, remote: true, size: 1, index: 0) == .off)
    }

    @Test func aQueueEditIsDeferredDuringATransition() {
        #expect(AutoplayPolicy.mustDeferQueueEdit(isTransitionRunning: true))
        #expect(!AutoplayPolicy.mustDeferQueueEdit(isTransitionRunning: false))
    }

    @Test func aRadioRequestWaitsForTheSettleTimeAndNeedsTheSource() {
        #expect(!AutoplayPolicy.isSettled(positionMs: 0))
        #expect(!AutoplayPolicy.isSettled(positionMs: 1_499))
        #expect(AutoplayPolicy.isSettled(positionMs: 1_500))
        #expect(AutoplayPolicy.mayUseNetwork(online: true, youTubeSourceEnabled: true))
        // Offline, or with the YouTube source switched off, the pool is library-only.
        #expect(!AutoplayPolicy.mayUseNetwork(online: false, youTubeSourceEnabled: true))
        #expect(!AutoplayPolicy.mayUseNetwork(online: true, youTubeSourceEnabled: false))
    }

    @Test func theBackstopResumesOnlyInsideTenSecondsAndOnlyIfTheListenerDidNotPause() {
        #expect(AutoplayPolicy.backstopMayResume(endedAtMs: 1_000, nowMs: 1_000, playWhenReady: true))
        #expect(AutoplayPolicy.backstopMayResume(endedAtMs: 1_000, nowMs: 11_000, playWhenReady: true))
        #expect(!AutoplayPolicy.backstopMayResume(endedAtMs: 1_000, nowMs: 11_001, playWhenReady: true))
        #expect(!AutoplayPolicy.backstopMayResume(endedAtMs: 1_000, nowMs: 3_000, playWhenReady: false))
        // A clock that went backwards never resumes.
        #expect(!AutoplayPolicy.backstopMayResume(endedAtMs: 5_000, nowMs: 1_000, playWhenReady: true))
    }

    // MARK: Anchors

    @Test func anchorsAreTheLastThreeTracksTheListenerChose() {
        // u0 u1 u2 u3 | e4 e5 e6 (engine), playing e6.
        let ids = ["u0", "u1", "u2", "u3", "e4", "e5", "e6"]
        func anchors(_ index: Int) -> [Int] {
            AutoplayPolicy.anchorIndices(currentAbsoluteIndex: index, queueSize: ids.count, engineOwned: { $0 >= 4 },
                                         mediaIdAt: { ids[$0] })
        }
        #expect(anchors(6) == [3, 2, 1])
        // Tracks after the current one were not heard yet: they are not anchors.
        #expect(anchors(1) == [1, 0])
        // One song tapped: it is the only anchor.
        #expect(AutoplayPolicy.anchorIndices(currentAbsoluteIndex: 0, queueSize: 1, engineOwned: { _ in false },
                                             mediaIdAt: { _ in "only" }) == [0])
        // A queue of nothing but engine picks has no anchor.
        #expect(AutoplayPolicy.anchorIndices(currentAbsoluteIndex: 2, queueSize: 3, engineOwned: { _ in true },
                                             mediaIdAt: { "e\($0)" }).isEmpty)
        // The same track queued twice is one anchor.
        let twice = ["a", "b", "a", "a"]
        #expect(AutoplayPolicy.anchorIndices(currentAbsoluteIndex: 3, queueSize: twice.count, engineOwned: { _ in false },
                                             mediaIdAt: { twice[$0] }) == [3, 1])
    }

    // MARK: Filters

    @Test func onlyOfficialAudioBetweenOneAndFifteenMinutes() {
        #expect(AutoplayPolicy.passesFilters(candidate("a"), seedFlags: 0))
        #expect(!AutoplayPolicy.passesFilters(candidate("a", officialAudio: false), seedFlags: 0))
        #expect(!AutoplayPolicy.passesFilters(candidate("a", durationMs: 59_999), seedFlags: 0))
        #expect(AutoplayPolicy.passesFilters(candidate("a", durationMs: 60_000), seedFlags: 0))
        #expect(AutoplayPolicy.passesFilters(candidate("a", durationMs: 900_000), seedFlags: 0))
        #expect(!AutoplayPolicy.passesFilters(candidate("a", durationMs: 900_001), seedFlags: 0))
        // An unknown length (a Related-tab row) is not a reason to drop the track.
        #expect(AutoplayPolicy.passesFilters(candidate("a", durationMs: 0), seedFlags: 0))
    }

    @Test func karaokeCoverSpedUpAndSlowedNeverLiveAndRemixOnlyWithASeedThatIsOne() {
        for flag in [BrainText.flagKaraoke, BrainText.flagCover, BrainText.flagSpedUp, BrainText.flagSlowed] {
            #expect(!AutoplayPolicy.passesFilters(candidate("a", flags: flag), seedFlags: flag), "flag \(flag)")
        }
        for flag in [BrainText.flagLive, BrainText.flagInstrumental, BrainText.flagRemix] {
            #expect(!AutoplayPolicy.passesFilters(candidate("a", flags: flag), seedFlags: 0), "flag \(flag)")
            #expect(AutoplayPolicy.passesFilters(candidate("a", flags: flag), seedFlags: flag), "flag \(flag)")
        }
        // A live remix needs a seed that is both.
        let liveRemix = BrainText.flagLive | BrainText.flagRemix
        #expect(!AutoplayPolicy.passesFilters(candidate("a", flags: liveRemix), seedFlags: BrainText.flagLive))
        #expect(AutoplayPolicy.passesFilters(candidate("a", flags: liveRemix), seedFlags: liveRemix))
        // Remaster, acoustic and re-recorded versions are fine.
        #expect(AutoplayPolicy.passesFilters(candidate("a", flags: BrainText.flagRemaster), seedFlags: 0))
        #expect(AutoplayPolicy.passesFilters(candidate("a", flags: BrainText.flagAcoustic), seedFlags: 0))
        #expect(AutoplayPolicy.passesFilters(candidate("a", flags: BrainText.flagReRecorded), seedFlags: 0))
    }

    @Test func aLibraryTrackIsTheListenersOwnVersion() {
        #expect(AutoplayPolicy.passesFilters(candidate("a", flags: BrainText.flagLive, inLibrary: true), seedFlags: 0))
        #expect(AutoplayPolicy.passesFilters(candidate("a", flags: BrainText.flagCover, inLibrary: true), seedFlags: 0))
        #expect(!AutoplayPolicy.passesFilters(candidate("a", durationMs: 30_000, inLibrary: true), seedFlags: 0))
    }

    // MARK: Picking

    @Test func picksInPoolOrder() {
        let pool = (0..<12).map { candidate("artist\($0)", album: "album\($0)") }
        #expect(pick(pool) == pool.prefix(5).map(\.mediaId))
    }

    @Test func neverARecordingTwiceNeverWhatIsQueuedOrWasPlayed() {
        let a = candidate("a", mediaId: "ma", rid: 100)
        let sameRecording = candidate("b", mediaId: "mb", rid: 100)
        let queued = candidate("c", mediaId: "queued", rid: 101)
        let playedRecently = candidate("d", mediaId: "md", rid: 102)
        let fine = candidate("e", mediaId: "me", rid: 103)
        #expect(pick([a, sameRecording, queued, playedRecently, fine], media: ["queued"], rids: [102]) == ["ma", "me"])
    }

    @Test func theSamePrimaryArtistIsNotWithinFourSlots() {
        let a1 = candidate("a"), a2 = candidate("a")
        let others = (0..<6).map { candidate("o\($0)") }
        // a1, then four others, and only then a2.
        #expect(pick([a1, a2] + others, count: 6)
                == [a1, others[0], others[1], others[2], others[3], a2].map(\.mediaId))
    }

    @Test func atMostTwoTracksByOneArtistInTwentyAndThreeInFifty() {
        let byA = (0..<6).map { _ in candidate("a") }
        let others = (0..<60).map { candidate("o\($0)") }
        let picked = AutoplayPolicy.pickBatch(pool: byA + others, engineTail: [], excludedMediaIds: [], excludedRids: [],
                                              count: 50)
        #expect(picked.count == 50)
        let positions = picked.indices.filter { picked[$0].artistKey == "a" }
        #expect(positions.count == 3, "three in fifty")
        for start in 0...30 {
            #expect(positions.filter { $0 >= start && $0 < start + 20 }.count <= 2, "two in twenty from \(start): \(positions)")
        }
    }

    @Test func theEnginesOwnTailCountsForSpacing() {
        // The last engine item in the queue is by "a": the first pick cannot be.
        let a = candidate("a"), b = candidate("b")
        #expect(pick([a, b], tail: [Slot(artistKey: "a", albumKey: nil)], count: 2) == [b.mediaId])
        // Four slots later it can.
        let tail = ["a", "x", "y", "z", "w"].map { Slot(artistKey: $0, albumKey: nil) }
        #expect(pick([a, b], tail: tail, count: 2) == [a.mediaId, b.mediaId])
    }

    @Test func theSameAlbumIsNotWithinEightSlots() {
        let first = candidate("a", album: "album")
        let second = candidate("b", album: "album")
        let others = (0..<10).map { candidate("o\($0)", album: "other\($0)") }
        let picked = pick([first, second] + others, count: 10)
        #expect(picked.firstIndex(of: first.mediaId) == 0)
        #expect(picked.firstIndex(of: second.mediaId) == 9)
        // Unknown albums never collide with each other.
        let unknown = (0..<5).map { candidate("u\($0)", album: nil) }
        #expect(pick(unknown) == unknown.map(\.mediaId))
    }

    @Test func aPoolThatCannotFillTheBatchReturnsWhatFits() {
        let pool = (0..<5).map { _ in candidate("a") }
        #expect(pick(pool).count == 1)
        #expect(pick([]).isEmpty)
        #expect(pick(pool, count: 0).isEmpty)
    }

    @Test func interleaveMergesTheAnchorsRadiosRankByRank() {
        let a1 = candidate("a1", rid: 1), a2 = candidate("a2", rid: 2), a3 = candidate("a3", rid: 3)
        let b1 = candidate("b1", rid: 10)
        let b2same = candidate("b2", rid: 2) // the same recording as a2, under another audio id
        #expect(AutoplayPolicy.interleave([[a1, a2, a3], [b1, b2same]]).map(\.mediaId) == [a1, b1, a2, a3].map(\.mediaId))
        #expect(AutoplayPolicy.interleave([[a1, a2, a3]]).map(\.mediaId) == [a1, a2, a3].map(\.mediaId))
        #expect(AutoplayPolicy.interleave([]).isEmpty)
    }

    @Test func libraryTracksAreFavWhenEverPlayedAndDeepWhenNever() {
        #expect(AutoplayPolicy.libraryArm(everPlayed: true) == Arm.fav)
        #expect(AutoplayPolicy.libraryArm(everPlayed: false) == Arm.deep)
    }

    @Test func artistKeysAreComparedByTheirBytes() {
        // Precomposed Hangul and its jamo are two artists to Kotlin, so they are two artists here.
        let a = candidate("\u{AC00}"), b = candidate("\u{1100}\u{1161}")
        #expect(pick([a, b], count: 2) == [a.mediaId, b.mediaId])
    }
}
