import Foundation
import Testing
@testable import PixlLibrary

/// Endless Listening, milestone E2: the log of the spoken host (Android `HostVoiceLogTest`) and the choice of the voice.
@Suite("Endless Listening spoken host support")
struct HostVoiceSupportTests {
    private func entry(_ i: Int, spoke: Bool = false, cancelled: Bool = false, reason: String? = nil, text: String = "") -> HostVoiceLogEntry {
        HostVoiceLogEntry(atMs: Int64(i), spoke: spoke, cancelled: cancelled, reason: reason ?? "r\(i)", text: text)
    }

    @Test func theLogKeepsTheLastTwentyDecisionsNewestFirst() {
        var log: [HostVoiceLogEntry] = []
        for i in 1...35 { log = HostVoiceLog.add(log, entry(i)) }
        #expect(log.count == HostVoice.logSize)
        #expect(HostVoice.logSize == 20)
        #expect(log.first?.atMs == 35)
        #expect(log.last?.atMs == 16)
    }

    @Test func addingNeverChangesTheListItWasGiven() {
        let one = HostVoiceLog.add([], entry(1))
        let two = HostVoiceLog.add(one, entry(2))
        #expect(one.count == 1)
        #expect(two.count == 2)
    }

    @Test func anEntryReadsAsSaidStoppedOrSkippedWithItsReasonAndLine() {
        #expect(HostVoiceLog.describe(entry(1, spoke: true, reason: "speak", text: "From your Bedroom pop side."))
                == "spoke, \"From your Bedroom pop side.\"")
        #expect(HostVoiceLog.describe(entry(1, cancelled: true, reason: "skip", text: "Released in 2019."))
                == "stopped: skip, \"Released in 2019.\"")
        #expect(HostVoiceLog.describe(entry(1, reason: "transition")) == "skipped: transition")
    }

    // MARK: The voice

    private func voice(_ id: String, _ language: String, _ quality: Int = 0, novelty: Bool = false, personal: Bool = false) -> HostVoiceChoice.Candidate {
        HostVoiceChoice.Candidate(identifier: id, language: language, quality: quality, isNovelty: novelty, isPersonal: personal)
    }

    @Test func theListenersOwnEnglishComesFirstThenUsEnglishThenAnyOtherEnglish() {
        let voices = [voice("fr", "fr-FR", 2), voice("us", "en-US"), voice("gb", "en-GB"), voice("au", "en-AU", 2)]
        #expect(HostVoiceChoice.pick(voices, preferredLanguages: ["de-DE", "en-GB", "en-US"]) == "gb")
        #expect(HostVoiceChoice.pick(voices, preferredLanguages: ["en_AU"]) == "au")
        #expect(HostVoiceChoice.pick(voices, preferredLanguages: ["fr-FR"]) == "us")
        #expect(HostVoiceChoice.pick(voices, preferredLanguages: []) == "us")
        #expect(HostVoiceChoice.pick([voice("au", "en-AU"), voice("gb", "en-GB")], preferredLanguages: ["fr-FR"]) == "au")
    }

    @Test func aBetterQualityWinsInsideAGroupAndTheIdentifierBreaksTies() {
        let voices = [voice("b", "en-US", 0), voice("a", "en-US", 1), voice("c", "en-US", 1), voice("d", "en-US", 2)]
        #expect(HostVoiceChoice.pick(voices, preferredLanguages: ["en-US"]) == "d")
        #expect(HostVoiceChoice.pick(Array(voices.prefix(3)), preferredLanguages: []) == "a")
    }

    @Test func noveltyAndPersonalVoicesAndOtherLanguagesAreNeverUsed() {
        #expect(HostVoiceChoice.pick([voice("fun", "en-US", 2, novelty: true), voice("me", "en-US", 2, personal: true)], preferredLanguages: []) == nil)
        #expect(HostVoiceChoice.pick([voice("fr", "fr-FR"), voice("de", "de-DE")], preferredLanguages: ["en-US"]) == nil)
        #expect(HostVoiceChoice.pick([], preferredLanguages: ["en-US"]) == nil)
        // A tag that only starts with the letters is not English.
        #expect(HostVoiceChoice.pick([voice("x", "enm-GB")], preferredLanguages: []) == nil)
    }
}
