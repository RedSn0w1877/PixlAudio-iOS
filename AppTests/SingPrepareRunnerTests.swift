import Foundation
import PixlLibrary
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// "Prepare songs ahead in the cloud" (Settings › Sing): the runner that picks songs and has Cloud Studio send them, with
/// the studio's usual fakes. The ranking itself is tested in PixlLibraryTests (`SingPrepareRankerTests`) and the money
/// rules in PixlNetTests (`CloudAutoBudgetTests`); this is what the runner does with them.
@MainActor
final class SingPrepareRunnerTests: XCTestCase {
    /// A favourite song (3 points on its own) with no album, so nothing else lifts it.
    private func favorite(_ h: CloudHarness, _ name: String) -> Song {
        var song = h.addSong("f:root/\(name).m4a")
        song.isFavorite = true
        song.albumId = -1
        return song
    }

    private func makeRunner(_ h: CloudHarness, songs: [Song]) -> SingPrepareRunner {
        let runner = SingPrepareRunner(cloud: h.studio, sources: SingPrepareRunner.Sources(
            songs: { songs }, playlists: { [] }, events: { [] }, signals: { [:] }, blocked: { .empty },
            isAppActive: { true }))
        h.studio.autoPrepare = runner
        return runner
    }

    private func fiveFavorites(_ h: CloudHarness) -> [Song] {
        ["a", "b", "c", "d", "e"].map { favorite(h, $0) }
    }

    // MARK: Picking and sending

    func testItSendsTheBestSongsAsOneAutoBatchOfThree() async throws {
        let h = CloudHarness()
        h.settings.autoPrepareEnabled = true
        let songs = fiveFavorites(h)
        let runner = makeRunner(h, songs: songs)
        await runner.evaluate()
        XCTAssertEqual(h.studio.jobs.map(\.songId), songs.prefix(3).map(\.id), "best first, ties by id")
        XCTAssertEqual(h.studio.jobs.map(\.origin), [.auto, .auto, .auto])
        XCTAssertEqual(Set(h.studio.jobs.map(\.batchId)).count, 1, "one batch, so one burst with one last")
        XCTAssertEqual(runner.todayCount, 3)
        XCTAssertGreaterThan(runner.monthSpentMicroUSD, 0)
        XCTAssertTrue(runner.statusLine.hasPrefix("3 songs today · "), runner.statusLine)
        XCTAssertEqual(runner.whyLines.count, 5, "every song it could prepare, best first")
        XCTAssertTrue(runner.whyLines[0].contains("a favorite"), runner.whyLines[0])
    }

    func testASongThatAlreadyHasAnInstrumentalIsSkipped() async throws {
        let h = CloudHarness()
        h.settings.autoPrepareEnabled = true
        let songs = fiveFavorites(h)
        h.host.instrumentals.insert(songs[0].id)
        let runner = makeRunner(h, songs: songs)
        await runner.evaluate()
        XCTAssertEqual(h.studio.jobs.map(\.songId), [songs[1].id, songs[2].id, songs[3].id])
    }

    func testNothingStartsWhileThePhoneIsNotReady() async throws {
        let h = CloudHarness()
        h.settings.autoPrepareEnabled = true
        let runner = makeRunner(h, songs: fiveFavorites(h))
        h.phone.goOffWiFi()
        await runner.evaluate()
        XCTAssertTrue(h.studio.jobs.isEmpty)
        XCTAssertEqual(runner.statusLine, "Waiting for Wi-Fi")

        h.phone.goOnWiFi()
        h.phone.auto.batteryPercent = 20
        await runner.evaluate()
        XCTAssertTrue(h.studio.jobs.isEmpty)
        XCTAssertEqual(runner.statusLine, "Waiting for the phone to charge")

        h.phone.auto.isCharging = true
        await runner.evaluate()
        XCTAssertEqual(h.studio.jobs.count, 3)
    }

    func testSongsSomebodyAskedForComeFirst() async throws {
        let h = CloudHarness()
        h.settings.autoPrepareEnabled = true
        let runner = makeRunner(h, songs: fiveFavorites(h))
        let asked = h.addSong("f:root/asked.m4a")
        let started = await h.studio.startNow(songs: [asked], title: "Test")
        XCTAssertEqual(started, .started(1))
        await runner.evaluate()
        XCTAssertEqual(h.studio.jobs.count, 1, "no auto job while a song somebody asked for is on its way")
        XCTAssertEqual(runner.statusLine, "Getting your songs ready first")
    }

    func testAtMostThreeAreOnTheirWayAtOnce() async throws {
        let h = CloudHarness()
        h.settings.autoPrepareEnabled = true
        let runner = makeRunner(h, songs: fiveFavorites(h))
        await runner.evaluate()
        await runner.evaluate()
        XCTAssertEqual(h.studio.jobs.count, 3)
        XCTAssertEqual(h.studio.outstandingAutoJobs.count, 3)
    }

    func testTheDailyCapBoundsTheBatch() async throws {
        let h = CloudHarness()
        h.settings.autoPrepareEnabled = true
        h.settings.autoPrepareDailyCap = 2
        let runner = makeRunner(h, songs: fiveFavorites(h))
        await runner.evaluate()
        XCTAssertEqual(h.studio.jobs.count, 2)
        XCTAssertTrue(runner.statusLine.hasPrefix("2 songs today"), runner.statusLine)
    }

    func testAMonthlyBudgetTooSmallForASongSendsNothing() async throws {
        let h = CloudHarness()
        h.settings.autoPrepareEnabled = true
        h.settings.autoPrepareBudgetMicroUSD = 1_000
        let runner = makeRunner(h, songs: fiveFavorites(h))
        await runner.evaluate()
        XCTAssertTrue(h.studio.jobs.isEmpty)
        XCTAssertEqual(runner.todayCount, 0)
    }

    func testItDoesNothingWhileTheSwitchIsOff() async throws {
        let h = CloudHarness()
        let runner = makeRunner(h, songs: fiveFavorites(h))
        XCTAssertFalse(h.settings.autoPrepareEnabled, "off until the person turns it on")
        await runner.evaluate()
        XCTAssertTrue(h.studio.jobs.isEmpty)
        XCTAssertEqual(runner.statusLine, "")
        XCTAssertTrue(runner.whyLines.isEmpty)
    }

    func testWhenTheCloudIsNotReadyTheStatusLineSaysWhy() async throws {
        let h = CloudHarness()
        h.settings.autoPrepareEnabled = true
        let runner = makeRunner(h, songs: fiveFavorites(h))
        h.settings.isEnabled = false
        await runner.evaluate()
        XCTAssertEqual(runner.statusLine, "Turn on Cloud processing to prepare songs ahead")
        XCTAssertTrue(h.studio.jobs.isEmpty)
        XCTAssertFalse(runner.owns(songId: "f:root/a.m4a"), "the phone's own studio keeps its songs")
    }

    func testTheRunnerOwnsItsPicksAndTheSongsItHasOnTheWay() async throws {
        let h = CloudHarness()
        h.settings.autoPrepareEnabled = true
        let songs = fiveFavorites(h)
        let runner = makeRunner(h, songs: songs)
        XCTAssertFalse(runner.owns(songId: songs[0].id), "it has not looked yet")
        await runner.evaluate()
        XCTAssertTrue(runner.owns(songId: songs[0].id))
        XCTAssertTrue(runner.owns(songId: songs[4].id), "a pick, even before it is sent")
        XCTAssertFalse(runner.owns(songId: "f:root/other.m4a"))
        h.settings.autoPrepareEnabled = false
        XCTAssertFalse(runner.owns(songId: songs[0].id))
    }

    // MARK: Following the settings on its own

    func testSwitchingItOffCancelsTheAutoJobsStillWaiting() async throws {
        let h = CloudHarness()
        h.settings.autoPrepareEnabled = true
        let runner = makeRunner(h, songs: fiveFavorites(h))
        runner.start()
        await runner.evaluate()
        XCTAssertEqual(h.studio.outstandingAutoJobs.count, 3)

        h.settings.autoPrepareEnabled = false
        await h.waitUntil { h.studio.jobs.allSatisfy { $0.state == .cancelled } }
        XCTAssertTrue(h.studio.jobs.allSatisfy { $0.state == .cancelled }, "\(h.studio.jobs.map(\.state))")
        XCTAssertEqual(runner.statusLine, "")
        XCTAssertTrue(runner.whyLines.isEmpty)
    }

    func testSwitchingItOffWhileTheSongsAreBeingSentStopsThemToo() async throws {
        let h = CloudHarness()
        h.settings.autoPrepareEnabled = true
        let runner = makeRunner(h, songs: fiveFavorites(h))
        // The person turns the switch off just as the batch is being put together: the switch's own cancel would find no
        // job yet, so the runner stops what it just sent.
        h.host.whileSongsAreChecked = { h.settings.autoPrepareEnabled = false }
        await runner.evaluate()
        XCTAssertTrue(h.studio.outstandingAutoJobs.isEmpty, "nothing keeps going behind the person's back")
        XCTAssertEqual(runner.statusLine, "")
    }

    func testAChangedBudgetShowsInTheStatusLineAtOnce() async throws {
        let h = CloudHarness()
        h.settings.autoPrepareEnabled = true
        let runner = makeRunner(h, songs: [])
        runner.start()
        XCTAssertEqual(runner.statusLine, "No songs yet today · $0.00 of $1.00 this month")
        h.settings.autoPrepareBudgetMicroUSD = 2_000_000
        await h.waitUntil { runner.statusLine.contains("$2.00") }
        XCTAssertEqual(runner.statusLine, "No songs yet today · $0.00 of $2.00 this month")
    }

    // MARK: Words

    func testTheStatusLineWords() {
        func line(_ today: Int, _ spent: Int64, waiting: String? = nil) -> String {
            SingPrepareRunner.statusText(todayCount: today, monthSpentMicroUSD: spent, budgetMicroUSD: 1_000_000,
                                         waitingFor: waiting)
        }
        XCTAssertEqual(line(0, 0), "No songs yet today · $0.00 of $1.00 this month")
        XCTAssertEqual(line(1, 120_000), "1 song today · $0.12 of $1.00 this month")
        XCTAssertEqual(line(3, 120_000), "3 songs today · $0.12 of $1.00 this month")
        XCTAssertEqual(line(3, 120_000, waiting: "Waiting for Wi-Fi"), "Waiting for Wi-Fi")
        XCTAssertEqual(line(3, 120_000, waiting: ""), "3 songs today · $0.12 of $1.00 this month")
    }

    func testTheWhyLineNamesTheSongAndWhatLiftedIt() {
        let song = Song(id: "s", title: "Title", artist: "Artist", artistId: 1, album: "Album", albumId: 1, path: "s.m4a",
                        contentUriString: "file:///s.m4a", albumArtUriString: nil, duration: 200_000, mimeType: nil,
                        bitrate: nil, sampleRate: nil)
        let candidate = SingPrepareRanker.Candidate(song: song, score: 4.0, reasons: [.favorite, .nextInPlaylist])
        XCTAssertEqual(SingPrepareRunner.whyLine(candidate),
                       "Title · Artist — a favorite, follows a song you played in a playlist (4.0)")
        let plain = SingPrepareRanker.Candidate(song: song, score: 0.5, reasons: [])
        XCTAssertEqual(SingPrepareRunner.whyLine(plain), "Title · Artist — ranked by your listening (0.5)")
        for reason in [SingPrepareRanker.Reason.favorite, .playedOften, .playedRecently, .addedRecently, .nextInPlaylist,
                       .sameAlbum] {
            XCTAssertFalse(SingPrepareRunner.reasonText(reason).isEmpty)
        }
    }

    func testNoTextHereSaysTheWordsThatAreNeverShown() {
        let lines = [
            SingPrepareRunner.notReadyLine(.off), SingPrepareRunner.notReadyLine(.notConfigured),
            SingPrepareRunner.notReadyLine(.keysMissing), SingPrepareRunner.notReadyLine(.usable),
        ]
        for line in lines { XCTAssertFalse(line.contains("Apple"), line) }
        XCTAssertEqual(SingPrepareRunner.notReadyLine(.notConfigured), "Finish setting up Cloud processing first")
    }
}
