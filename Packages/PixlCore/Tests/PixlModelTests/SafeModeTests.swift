import Foundation
import Testing
@testable import PixlModel

@Suite struct SafeModeTests {
    private let now: Int64 = 1_000_000

    @Test func aFirstLaunchChangesNothing() {
        let state = SafeModePolicy.launch(previous: SafeModeState(), end: .firstLaunch, nowMs: now)
        #expect(state == SafeModeState())
        #expect(!state.blocksAutomaticHeavyWork)
        #expect(!state.showsBanner)
    }

    @Test func anAbnormalEndTurnsSafeModeOnWithTheBanner() {
        let state = SafeModePolicy.launch(previous: SafeModeState(), end: .abnormal(.missingCleanMarker), nowMs: now)
        #expect(state.isActive)
        #expect(state.consecutiveAbnormal == 1)
        #expect(state.showsBanner)
        #expect(state.blocksAutomaticHeavyWork)
        #expect(state.lastAbnormalAtMs == now)
        #expect(!state.isSticky)
    }

    @Test func oneAbnormalEndThenACleanSessionIsNormalAgain() {
        let crashed = SafeModePolicy.launch(previous: SafeModeState(), end: .abnormal(.missingCleanMarker), nowMs: now)
        // The run after the crash ended cleanly; this launch sees that.
        let next = SafeModePolicy.launch(previous: crashed, end: .clean, nowMs: now + 10)
        #expect(next == SafeModeState())
    }

    @Test func twoAbnormalEndsInARowStayOnThroughCleanSessions() {
        var state = SafeModePolicy.launch(previous: SafeModeState(), end: .abnormal(.missingCleanMarker), nowMs: now)
        state = SafeModePolicy.launch(previous: state, end: .abnormal(.missingCleanMarker), nowMs: now + 1)
        #expect(state.consecutiveAbnormal == 2)
        #expect(state.isSticky)
        for step in 0..<5 {
            state = SafeModePolicy.launch(previous: state, end: .clean, nowMs: now + 10 + Int64(step))
            #expect(state.isActive)
            #expect(state.isSticky)
        }
    }

    @Test func theSwitchInSettingsClearsAStickySafeMode() {
        var state = SafeModeState(consecutiveAbnormal: 3, isActive: true, bannerPending: true)
        state = SafeModePolicy.setByUser(state, on: false)
        #expect(state == SafeModeState())
        let on = SafeModePolicy.setByUser(SafeModeState(), on: true)
        #expect(on.isActive)
        #expect(on.isSticky)
        // And it survives clean launches until it is turned off.
        #expect(SafeModePolicy.launch(previous: on, end: .clean, nowMs: now).isActive)
    }

    @Test func retryLiftsSafeModeForTheRunButAnotherCrashCounts() {
        let crashed = SafeModePolicy.launch(previous: SafeModeState(), end: .abnormal(.missingCleanMarker), nowMs: now)
        let lifted = SafeModePolicy.userRetried(crashed)
        #expect(!lifted.isActive)
        #expect(!lifted.showsBanner)
        #expect(lifted.liftedByUser)
        #expect(lifted.consecutiveAbnormal == 1)
        // The retried work killed the app again: that is the second abnormal end, so safe mode is sticky.
        let again = SafeModePolicy.launch(previous: lifted, end: .abnormal(.missingCleanMarker), nowMs: now + 5)
        #expect(again.isActive)
        #expect(again.isSticky)
        #expect(!again.liftedByUser)
    }

    @Test func aRetriedRunThatEndsCleanlyClearsEvenAStickyRecord() {
        var state = SafeModeState(consecutiveAbnormal: 4, isActive: true, bannerPending: true)
        state = SafeModePolicy.userRetried(state)
        #expect(!state.blocksAutomaticHeavyWork)
        let next = SafeModePolicy.launch(previous: state, end: .clean, nowMs: now)
        #expect(next == SafeModeState())
    }

    @Test func retryWithSafeModeOffChangesNothing() {
        let state = SafeModeState()
        #expect(SafeModePolicy.userRetried(state) == state)
    }

    @Test func dismissingTheBannerKeepsSafeModeOn() {
        let crashed = SafeModePolicy.launch(previous: SafeModeState(), end: .abnormal(.missingCleanMarker), nowMs: now)
        let dismissed = SafeModePolicy.bannerDismissed(crashed)
        #expect(!dismissed.showsBanner)
        #expect(dismissed.isActive)
    }

    @Test func aMetricKitCrashIsCountedOnceNotTwice() {
        let counted = SafeModePolicy.launch(previous: SafeModeState(), end: .abnormal(.missingCleanMarker), nowMs: now)
        // The same crash arrives from MetricKit: already counted for this launch, so the count stays at one.
        #expect(SafeModePolicy.metricKitCrash(counted, alreadyCounted: true, nowMs: now + 1) == counted)
        // A crash the marker missed (the app was backgrounded idle) is counted.
        let fresh = SafeModePolicy.metricKitCrash(SafeModeState(), alreadyCounted: false, nowMs: now)
        #expect(fresh.isActive)
        #expect(fresh.consecutiveAbnormal == 1)
    }

    @Test func theStateRoundTripsThroughJson() throws {
        let state = SafeModeState(consecutiveAbnormal: 2, isActive: true, bannerPending: true, liftedByUser: false,
                                  lastAbnormalAtMs: 42)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(SafeModeState.self, from: data) == state)
    }
}

@Suite struct InFlightJournalTests {
    @Test func addingReplacesTheSameJobAndRemovingForgetsIt() {
        let a = InFlightEntry(kind: "lyricsSync", reference: "song.1", startedAtMs: 1)
        let b = InFlightEntry(kind: "modelDownload", reference: "wav2vec2", startedAtMs: 2)
        var entries = InFlightJournal.adding(a, to: [])
        entries = InFlightJournal.adding(b, to: entries)
        entries = InFlightJournal.adding(InFlightEntry(kind: "lyricsSync", reference: "song.1", startedAtMs: 9), to: entries)
        #expect(entries.count == 2)
        #expect(entries.last?.startedAtMs == 9)
        entries = InFlightJournal.removing(kind: "lyricsSync", reference: "song.1", from: entries)
        #expect(entries == [b])
    }

    @Test func rowIdsRoundTripEvenWithDotsInTheReference() {
        let entry = InFlightEntry(kind: "instrumental", reference: "file.root.a.b", startedAtMs: 0)
        let parsed = InFlightJournal.parse(rowId: InFlightJournal.rowId(entry))
        #expect(parsed?.kind == "instrumental")
        #expect(parsed?.reference == "file.root.a.b")
        #expect(InFlightJournal.parse(rowId: "download.abc") == nil)
        #expect(InFlightJournal.parse(rowId: "interrupted.lyricsSync") == nil)
    }
}

@Suite struct HeavyWorkPolicyTests {
    @Test func nothingHeavyRunsInTheBackgroundWithoutAWindow() {
        let verdict = HeavyWorkPolicy.verdict(HeavyWorkConditions(isForeground: false))
        #expect(verdict == .pause(.background))
        let granted = HeavyWorkPolicy.verdict(HeavyWorkConditions(isForeground: false, hasBackgroundWindow: true))
        #expect(granted == .run(dutyCycle: HeavyWorkPolicy.baseDutyCycle))
    }

    @Test func aHotPhonePausesAndAWarmOneSlowsDown() {
        #expect(HeavyWorkPolicy.verdict(HeavyWorkConditions(isForeground: true, thermal: .serious)) == .pause(.thermal))
        #expect(HeavyWorkPolicy.verdict(HeavyWorkConditions(isForeground: true, thermal: .critical)) == .pause(.thermal))
        #expect(HeavyWorkPolicy.verdict(HeavyWorkConditions(isForeground: true, thermal: .fair))
            == .run(dutyCycle: HeavyWorkPolicy.fairDutyCycle))
    }

    @Test func lowPowerAndMemoryPressureTakeTheSmallestShare() {
        let low = HeavyWorkPolicy.verdict(HeavyWorkConditions(isForeground: true, lowPowerMode: true))
        #expect(low == .run(dutyCycle: HeavyWorkPolicy.lowPowerDutyCycle))
        let both = HeavyWorkPolicy.verdict(HeavyWorkConditions(isForeground: true, thermal: .fair, lowPowerMode: true,
                                                               recentMemoryPressure: true))
        #expect(both == .run(dutyCycle: HeavyWorkPolicy.memoryPressureDutyCycle))
    }

    @Test func theDutyCycleKeepsAverageCpuUnderHalfOverThreeMinutes() {
        // Simulate 3 minutes of 200 ms inference windows under the normal verdict.
        guard case .run(let duty) = HeavyWorkPolicy.verdict(HeavyWorkConditions(isForeground: true)) else {
            Issue.record("expected a run verdict")
            return
        }
        var busy: Int64 = 0, wall: Int64 = 0
        while wall < 180_000 {
            let window: Int64 = 200
            let idle = HeavyWorkPolicy.idleMs(afterBusyMs: window, dutyCycle: duty)
            busy += window
            wall += window + idle
        }
        let average = Double(busy) / Double(wall)
        #expect(average <= 0.5 + 0.01)
    }

    @Test func idleTimeIsBoundedAndZeroWithoutALimit() {
        #expect(HeavyWorkPolicy.idleMs(afterBusyMs: 100, dutyCycle: 0.5) == 100)
        #expect(HeavyWorkPolicy.idleMs(afterBusyMs: 100, dutyCycle: 0.25) == 300)
        #expect(HeavyWorkPolicy.idleMs(afterBusyMs: 60_000, dutyCycle: 0.2) == HeavyWorkPolicy.maxIdleMs)
        #expect(HeavyWorkPolicy.idleMs(afterBusyMs: 100, dutyCycle: 1) == 0)
        #expect(HeavyWorkPolicy.idleMs(afterBusyMs: 0, dutyCycle: 0.5) == 0)
    }

    @Test func theNeuralEngineIsForTheForegroundOfACoolPhoneOnly() {
        #expect(HeavyWorkPolicy.prefersNeuralEngine(HeavyWorkConditions(isForeground: true)))
        #expect(!HeavyWorkPolicy.prefersNeuralEngine(HeavyWorkConditions(isForeground: false, hasBackgroundWindow: true)))
        #expect(!HeavyWorkPolicy.prefersNeuralEngine(HeavyWorkConditions(isForeground: true, thermal: .serious)))
        #expect(!HeavyWorkPolicy.prefersNeuralEngine(HeavyWorkConditions(isForeground: true, lowPowerMode: true)))
    }

    @Test func aSmallPhoneDecodesShorterSongsThanABigOne() {
        let small: UInt64 = 3_850_000_000, big: UInt64 = 8_000_000_000
        let stereoSmall = HeavyWorkPolicy.maxDecodeSeconds(channels: 2, sampleRate: 44_100, physicalMemoryBytes: small)
        let stereoBig = HeavyWorkPolicy.maxDecodeSeconds(channels: 2, sampleRate: 44_100, physicalMemoryBytes: big)
        #expect(stereoSmall > 600 && stereoSmall < 720)
        #expect(stereoBig > stereoSmall)
        #expect(stereoBig <= 20 * 60)
        #expect(HeavyWorkPolicy.maxDecodeSeconds(channels: 1, sampleRate: 16_000, physicalMemoryBytes: small) == 20 * 60)
        #expect(HeavyWorkPolicy.maxDecodeSeconds(channels: 2, sampleRate: 44_100, physicalMemoryBytes: 100_000_000) == 120)
    }

    @Test func automaticStartsNeedAQuietForegroundPhone() {
        #expect(HeavyWorkPolicy.allowsAutomaticStart(HeavyWorkConditions(isForeground: true)))
        #expect(!HeavyWorkPolicy.allowsAutomaticStart(HeavyWorkConditions(isForeground: false)))
        #expect(!HeavyWorkPolicy.allowsAutomaticStart(HeavyWorkConditions(isForeground: true, recentMemoryPressure: true)))
        #expect(!HeavyWorkPolicy.allowsAutomaticStart(HeavyWorkConditions(isForeground: true, lowPowerMode: true)))
    }
}

@Suite struct DiagnosticLoggingTests {
    @Test func urlsLoseTheirPathAndQuery() {
        let text = LogRedactor.redact("GET https://cdn.example.com/a/b/song.mp3?X-Amz-Signature=abcdef&token=1 failed")
        #expect(text == "GET https://cdn.example.com/… failed")
        #expect(!text.contains("Signature"))
    }

    @Test func pathsEmailsAndTokensAreRemoved() {
        let line = LogRedactor.redact("open /var/mobile/Containers/Data/Application/ABC/Documents/My Song.mp3 by a@b.com")
        #expect(!line.contains("Containers"))
        #expect(!line.contains("a@b.com"))
        #expect(LogRedactor.redact("file:///private/var/x/y.m4a").contains("<path>"))
        let token = String(repeating: "A1b2", count: 12)
        #expect(!LogRedactor.redact("key \(token) end").contains(token))
        #expect(LogRedactor.redact("Authorization: Bearer abc.def-123").contains("<redacted>"))
    }

    @Test func redactingTwiceChangesNothingAndKeepsTheClosingBracket() {
        let once = LogRedactor.redact("fail (no source at https://x.example/p?q=1) after 2s")
        #expect(once == "fail (no source at https://x.example/…) after 2s")
        #expect(LogRedactor.redact(once) == once)
    }

    @Test func plainJobFactsSurvive() {
        let text = "job lyricsSync finished in 41s id=song.12 reason=cancelled"
        #expect(LogRedactor.redact(text) == text)
    }

    @Test func aLineIsOneLineAndBounded() {
        let line = LogRedactor.line("first\nsecond\r\nthird " + String(repeating: "word ", count: 100), limit: 60)
        #expect(!line.contains("\n"))
        #expect(line.count <= 60)
        #expect(line.hasSuffix("…"))
    }

    @Test func theRingKeepsTheNewestWholeLinesUnderTheCap() {
        var log = ""
        for index in 0..<400 {
            log = LogRing.appending("event \(index) " + String(repeating: "x", count: 40) + "\n", to: log, limitBytes: 2_000)
            #expect(log.utf8.count <= 2_000)
        }
        #expect(log.contains("event 399 "))
        #expect(!log.contains("event 0 "))
        #expect(log.hasPrefix("… earlier events dropped"))
        // No half line: every line after the marker starts with "event".
        let lines = log.split(separator: "\n").dropFirst()
        #expect(lines.allSatisfy { $0.hasPrefix("event ") })
    }

    @Test func aSmallLogIsLeftAlone() {
        #expect(LogRing.appending("b\n", to: "a\n", limitBytes: 100) == "a\nb\n")
    }

    @Test func eventLinesCarryATimeACategoryAndRedactedText() {
        let line = LogRing.format(timestamp: Date(timeIntervalSince1970: 1_760_000_000), category: "job",
                                  message: "failed https://x.example/p?q=1")
        #expect(line == "2025-10-09T08:53:20Z  job  failed https://x.example/…\n")
    }

    @Test func theReportHasIdentityStatusLogAndPayloads() {
        let report = DiagnosticReport.assemble(identity: "PixlAudio 1.0 (1) abc1234", status: [("Memory", "120 MB")],
                                               safeMode: "off", log: "line\n", metricKit: ["{\"a\":1}"])
        #expect(report.hasPrefix("PixlAudio diagnostics"))
        #expect(report.contains("PixlAudio 1.0 (1) abc1234"))
        #expect(report.contains("Memory: 120 MB"))
        #expect(report.contains("Safe mode: off"))
        #expect(report.contains("{\"a\":1}"))
        let empty = DiagnosticReport.assemble(identity: "x", status: [], safeMode: "off", log: "", metricKit: [])
        #expect(empty.contains("(empty)"))
        #expect(empty.contains("(none received yet"))
    }
}

@Suite struct LocalModelGateTests {
    private func decide(_ reason: LocalModelReason = .userRequest, foreground: Bool = true, safe: Bool = false,
                        low: Bool = false, thermal: ThermalLevel = .nominal, available: Int64 = 2_000_000_000) -> LocalModelDecision {
        LocalModelGatePolicy.decide(reason: reason, isForeground: foreground, safeModeActive: safe, lowPowerMode: low,
                                    thermal: thermal, availableBytes: available, modelBytes: 900_000_000)
    }

    @Test func aUserRequestOnAHealthyPhoneIsAllowed() {
        #expect(decide() == .allowed)
    }

    @Test func automaticFeaturesNeverLoadTheModel() {
        #expect(!decide(.automatic).isAllowed)
    }

    @Test func safeModeLowPowerHeatBackgroundAndLowMemoryDeny() {
        #expect(!decide(safe: true).isAllowed)
        #expect(!decide(low: true).isAllowed)
        #expect(!decide(thermal: .serious).isAllowed)
        #expect(!decide(foreground: false).isAllowed)
        #expect(decide(available: 1_300_000_000) == .denied("Not enough memory on this phone"))
        #expect(decide(available: 1_350_000_000) == .allowed)
    }

    @Test func aCrashWithTheModelInFlightBlamesTheModel() {
        let model = InFlightEntry(kind: "localModel", reference: "request", startedAtMs: 1)
        let other = InFlightEntry(kind: "lyricsSync", reference: "a", startedAtMs: 1)
        #expect(SafeModePolicy.blamesLocalModel([other, model]))
        #expect(!SafeModePolicy.blamesLocalModel([other]))
        #expect(!SafeModePolicy.blamesLocalModel([]))
    }
}
