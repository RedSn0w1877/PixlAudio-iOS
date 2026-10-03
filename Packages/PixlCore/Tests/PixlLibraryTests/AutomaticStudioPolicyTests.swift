import Foundation
import Testing
@testable import PixlLibrary

/// Android `AutomaticStudioPolicyTest`, case for case.
@Suite("Automatic studio policy")
struct AutomaticStudioPolicyTests {
    private let healthy = AutomaticStudioPolicy.Conditions(appVisible: true, lyricsEnabled: true, instrumentalsEnabled: true,
                                                           batteryPercent: 75, charging: false, thermalStatus: 0,
                                                           freeBytes: 2_147_483_648)

    private func with(_ change: (inout AutomaticStudioPolicy.Conditions) -> Void) -> AutomaticStudioPolicy.Conditions {
        var conditions = healthy
        change(&conditions)
        return conditions
    }

    @Test func backgroundWorkIsAllowedAndEachDisabledFeatureIsIndependentlyBlocked() {
        #expect(AutomaticStudioPolicy.blockedReason(with { $0.appVisible = false }, .lyrics) == nil)
        let disabledLyrics = with { $0.lyricsEnabled = false }
        #expect(AutomaticStudioPolicy.blockedReason(disabledLyrics, .lyrics) != nil)
        #expect(AutomaticStudioPolicy.blockedReason(disabledLyrics, .instrumental) == nil)
        let disabledStems = with { $0.instrumentalsEnabled = false }
        #expect(AutomaticStudioPolicy.blockedReason(disabledStems, .instrumental) != nil)
        #expect(AutomaticStudioPolicy.blockedReason(disabledStems, .lyrics) == nil)
    }

    @Test func priorityKeepsNeverPlayedSongsBelowRecentFavorites() {
        let now: Int64 = 10_000_000
        let recent = AutomaticStudioPolicy.priority(songId: "recent", currentId: nil, favorite: false, playCount: 1,
                                                    lastPlayedMs: now - 2_000, nowMs: now)
        let never = AutomaticStudioPolicy.priority(songId: "never", currentId: nil, favorite: false, playCount: 0,
                                                   lastPlayedMs: 0, nowMs: now)
        let favorite = AutomaticStudioPolicy.priority(songId: "favorite", currentId: nil, favorite: true, playCount: 0,
                                                      lastPlayedMs: 0, nowMs: now)
        #expect(recent > never)
        #expect(favorite > never)
        #expect(AutomaticStudioPolicy.priority(songId: "current", currentId: "current", favorite: false, playCount: 0,
                                               lastPlayedMs: 0, nowMs: now) == 1_000_000)
    }

    @Test func lowOrUnknownBatteryDefersUntilCharging() {
        for battery in [-1, 0, 39] {
            #expect(AutomaticStudioPolicy.blockedReason(with { $0.batteryPercent = battery }, .instrumental) != nil)
            #expect(AutomaticStudioPolicy.blockedReason(with { $0.batteryPercent = battery; $0.charging = true },
                                                        .instrumental) == nil)
        }
        #expect(AutomaticStudioPolicy.blockedReason(with { $0.batteryPercent = 40 }, .instrumental) == nil)
    }

    @Test func moderateThermalPressureOrInsufficientSpaceStopsUnattendedWork() {
        #expect(AutomaticStudioPolicy.blockedReason(with { $0.thermalStatus = 2 }, .lyrics) != nil)
        #expect(AutomaticStudioPolicy.blockedReason(with { $0.thermalStatus = 1 }, .lyrics) == nil)
        #expect(AutomaticStudioPolicy.blockedReason(with { $0.freeBytes = AutomaticStudioPolicy.minFreeBytes - 1 },
                                                    .instrumental) != nil)
        #expect(AutomaticStudioPolicy.blockedReason(with { $0.freeBytes = AutomaticStudioPolicy.minFreeBytes },
                                                    .instrumental) == nil)
    }

    @Test func unknownDurationAndLongRecordingsRequireManualProcessing() {
        #expect(!AutomaticStudioPolicy.canProcessDuration(0))
        #expect(!AutomaticStudioPolicy.canProcessDuration(-1))
        #expect(AutomaticStudioPolicy.canProcessDuration(180_000))
        #expect(AutomaticStudioPolicy.canProcessDuration(AutomaticStudioPolicy.maxSongDurationMs))
        #expect(!AutomaticStudioPolicy.canProcessDuration(AutomaticStudioPolicy.maxSongDurationMs + 1))
        #expect(AutomaticStudioPolicy.maxWorkDurationMs < 10 * 60_000)
    }

    @Test func offlineCatalogsDeferWithoutBlockingAlreadyLocalInstrumentalProcessing() {
        let offline = with { $0.validatedNetwork = false }
        #expect(AutomaticStudioPolicy.blockedReason(offline, .lyrics) != nil)
        #expect(AutomaticStudioPolicy.blockedReason(offline, .instrumental) == nil)
    }

    @Test func currentAndRecentSongsWinAndDuplicateFavoritesCannotFillTheCandidateList() {
        #expect(AutomaticStudioPolicy.orderedIds(current: "current", recent: ["recent", "current"],
                                                 favorites: ["favorite", "recent"], local: ["local", "favorite", ""])
                == ["current", "recent", "favorite", "local"])
        #expect(AutomaticStudioPolicy.orderedIds(current: nil, recent: (1...100).map(String.init), favorites: [],
                                                 local: []).count == 40)
    }

    @Test func instrumentalsNeedLocalAudioWhileCatalogLyricsCanPrepareStreamingSongs() {
        #expect(!AutomaticStudioPolicy.canSchedule(.instrumental, hasLocalAudio: false, alreadyComplete: false,
                                                   cooldownUntil: 0, now: 1))
        #expect(AutomaticStudioPolicy.canSchedule(.instrumental, hasLocalAudio: true, alreadyComplete: false,
                                                  cooldownUntil: 0, now: 1))
        #expect(AutomaticStudioPolicy.canSchedule(.lyrics, hasLocalAudio: false, alreadyComplete: false,
                                                  cooldownUntil: 0, now: 1))
        #expect(!AutomaticStudioPolicy.canSchedule(.lyrics, hasLocalAudio: true, alreadyComplete: true,
                                                   cooldownUntil: 0, now: 1))
        #expect(!AutomaticStudioPolicy.canSchedule(.instrumental, hasLocalAudio: true, alreadyComplete: true,
                                                   cooldownUntil: 0, now: 1))
    }

    @Test func persistentCooldownsPreventRepeatedFailedOrMissingLookupsUntilTheirDeadline() {
        var firstProcess = AutomaticStudioCooldowns()
        firstProcess.record("LYRICS:song", 500)
        let restarted = AutomaticStudioCooldowns(firstProcess.snapshot())
        #expect(!AutomaticStudioPolicy.canSchedule(.lyrics, hasLocalAudio: true, alreadyComplete: false,
                                                   cooldownUntil: restarted.until("LYRICS:song"), now: 499))
        #expect(AutomaticStudioPolicy.canSchedule(.lyrics, hasLocalAudio: true, alreadyComplete: false,
                                                  cooldownUntil: restarted.until("LYRICS:song"), now: 500))
        #expect(restarted.until("INSTRUMENTAL:song") == 0)
        #expect(AutomaticStudioPolicy.ledgerKey(.lyrics, songId: "song") == "LYRICS:song")
    }

    @Test func ledgerKeepsItsBoundOnLoadAndUpdateWithoutEvictingTheLatestAttempt() {
        var ledger = AutomaticStudioCooldowns(["old": 1, "middle": 2, "new": 3], capacity: 2)
        #expect(Set(ledger.snapshot().keys) == ["middle", "new"])
        ledger.record("middle", 4)
        ledger.record("latest", 5)
        #expect(Set(ledger.snapshot().keys) == ["middle", "latest"])
    }
}
