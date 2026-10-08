import Foundation
import PixlModel
import PixlNet

/// Cloud Studio for UI tests (`-screen cloud.*`): demo settings, keys in memory, and a queue in every state. No
/// network, no transfer session, no Keychain; `CloudStudio(isDemo: true)` never runs a pass.
enum CloudDemo {
    static let endpointId = "pixl7demo2cloud"
    static let accountId = "0123456789abcdef0123456789abcdef"
    static let secrets = CloudSecrets(runpodKey: "rpa_DEMO0000000000000000000000000000", accessKeyId: "DEMOACCESSKEY0000000",
                                      secretAccessKey: "demo-secret-0000000000000000000000000000")

    static func make(launch: LaunchConfiguration, defaults: UserDefaults) -> CloudStudio {
        let screen = launch.screen
        let isCloudScreen = screen == .cloudSettings || screen == .cloudQueue || screen == .cloudConfirm
        let settings = CloudSettings(defaults: defaults, secrets: CloudMemorySecrets(isCloudScreen ? secrets : .empty))
        if isCloudScreen {
            settings.isEnabled = true
            settings.endpointId = endpointId
            settings.r2Endpoint = CloudConfig.r2Endpoint(accountId: accountId)
            settings.bucket = CloudConfig.defaultBucket
        }
        let dependencies = CloudStudio.Dependencies(
            store: CloudJobStore(file: nil), host: DemoCloudHost(), makeTransfers: { DemoCloudTransfers() },
            preparer: DemoCloudPreparer(), inspector: DemoCloudInspector(), makeRunPod: { _ in nil },
            makeObjects: { _ in nil }, nowMs: { now }, monthStartMs: { _ in now - 6 * 86_400_000 },
            newJobKey: { UUID().uuidString.lowercased() }, build: "demo", removeStaged: { _ in }, background: nil)
        let studio = CloudStudio(settings: settings, dependencies: dependencies, isDemo: true)
        guard isCloudScreen else { return studio }
        Task { await settings.loadSecrets() }
        let report = CloudConnectionReport(
            runpod: CloudCheck(ok: true, message: "RunPod works: the endpoint answered and accepted the key.",
                               detail: "0 songs waiting · no worker awake (normal when idle)"),
            storage: CloudCheck(ok: true, message: "Storage works: a test file was written, found and deleted."))
        studio.loadDemo(jobs: screen == .cloudSettings ? Array(jobs().prefix(2)) : jobs(),
                        report: screen == .cloudSettings ? report : nil,
                        progress: [jobKey(1): 0.42],
                        batch: screen == .cloudConfirm ? batch() : nil)
        return studio
    }

    /// 2026-10-07 18:00 UTC, so ages and the month read the same in every screenshot.
    static let now: Int64 = 1_791_396_000_000

    static func jobKey(_ n: Int) -> String { String(format: "6f1c2a9e-3b7d-4c11-9a0e-%012ld", n) }

    /// One job in each state the queue shows.
    static func jobs() -> [CloudJobRecord] {
        let songs = DemoLibrary.songs
        func record(_ n: Int, _ state: CloudJobState) -> CloudJobRecord {
            let song = songs[n % songs.count]
            var r = CloudJobRecord(jobKey: jobKey(n), songId: song.id, title: song.title, artist: song.displayArtist,
                                   batchId: "demo-batch", tasks: [.instrumental, .lyrics], lyricsMode: .align,
                                   quality: .standard, createdAtMs: now - Int64(n) * 60_000)
            r.songDurationMs = song.duration
            r.durationMs = song.duration
            r.state = state
            return r
        }
        var running = record(0, .running)
        running.progressStage = "separate"
        running.progressPercent = 40
        running.submittedAtMs = now - 90_000
        let uploading = record(1, .uploading)
        var waiting = record(2, .submitted)
        waiting.submittedAtMs = now - 60_000
        var transcribe = record(3, .queued)
        transcribe.lyricsMode = .transcribe
        var lowQuality = record(4, .uploaded)
        lowQuality.isStreamed = true
        lowQuality.lowQualitySource = true
        lowQuality.uploadedAtMs = now - 20_000
        var failed = record(5, .failed)
        failed.lastError = CloudErrorCode.poisoned.message
        failed.lastErrorCode = CloudErrorCode.poisoned.rawValue
        failed.attempts = 1
        var done = record(6, .imported)
        done.completedAtMs = now - 3_600_000
        done.importedAtMs = now - 3_500_000
        done.importedInstrumental = true
        done.importedLyrics = true
        done.costMicroUSD = 7_258
        done.gpu = "NVIDIA L4"
        var aiLyrics = record(7, .imported)
        aiLyrics.lyricsMode = .transcribe
        aiLyrics.lyricsTranscribed = true
        aiLyrics.completedAtMs = now - 7_200_000
        aiLyrics.importedAtMs = now - 7_100_000
        aiLyrics.importedInstrumental = true
        aiLyrics.importedLyrics = true
        aiLyrics.costMicroUSD = 9_120
        aiLyrics.gpu = "NVIDIA RTX A4000"
        return [running, uploading, waiting, transcribe, lowQuality, failed, done, aiLyrics]
    }

    /// The confirm sheet for a 12-song playlist.
    static func batch() -> CloudBatchPreview {
        let songs = Array(DemoLibrary.songs.prefix(12))
        let plans = songs.enumerated().map { index, song in
            CloudSongPlan(songId: song.id, tasks: index % 4 == 0 ? [.instrumental] : [.instrumental, .lyrics],
                          lyricsMode: index % 4 == 0 ? nil : (index % 5 == 0 ? .transcribe : .align),
                          isStreamed: index % 6 == 0, durationMs: max(song.duration, 180_000))
        }
        let estimate = CloudBatchEstimate.make(plans: plans, uploadBytes: [:], quality: .standard,
                                               pricePerSecondMicroUSD: CloudCost.defaultPricePerSecondMicroUSD,
                                               committedMicroUSD: 16_378, capMicroUSD: CloudCost.defaultMonthlyCapMicroUSD)
        return CloudBatchPreview(id: "demo-batch-2", songs: songs, plans: plans,
                                 skipped: [CloudBatchPreview.Skip(reason: .alreadyDone, count: 3),
                                           CloudBatchPreview.Skip(reason: .tooLong, count: 1)],
                                 estimate: estimate, replaceUserSynced: false, title: "Late Night Drive")
    }
}

/// The demo's app side: nothing to look up, nothing written.
@MainActor
final class DemoCloudHost: CloudStudioHost {
    func song(id: String) -> Song? { DemoLibrary.songs.first { $0.id == id } }
    var currentSong: Song? { DemoLibrary.songs.first }
    var librarySongs: [Song] { DemoLibrary.songs }
    func audioSource(for song: Song) async throws -> URL { throw CloudStudio.Failure("Demo") }
    func streamIdentity(for song: Song) async -> String? { nil }
    func lyricsFacts(for song: Song) async -> CloudLyricsFacts { .none }
    func hasInstrumental(songId: String) async -> Bool { false }
    func installInstrumental(from staged: URL, songId: String, flac: Bool) throws {}
    func saveLyrics(_ doc: LyricsDoc, for song: Song, replaceUserSynced: Bool) async -> CloudLyricsSaveOutcome { .unusable }
    func instrumentalImported(songId: String) {}
    func lyricsImported(song: Song) {}
}

nonisolated final class DemoCloudTransfers: CloudTransferring, @unchecked Sendable {
    var onEvent: (@Sendable (CloudTransferEvent) -> Void)?
    var onProgress: (@Sendable (_ jobKey: String, _ slot: String, _ fraction: Double) -> Void)?
    var allowsCellular = false
    func upload(fileURL: URL, to url: URL, jobKey: String, contentType: String) {}
    func download(from url: URL, jobKey: String, slot: String) {}
    func cancel(jobKey: String) async {}
    func pendingTaskDescriptions() async -> [String] { [] }
}

nonisolated struct DemoCloudPreparer: CloudAudioPreparing {
    func prepare(source: URL, jobKey: String) async throws -> CloudPreparedAudio { throw CloudStudio.Failure("Demo") }
    func removeUpload(jobKey: String) {}
    func uploadFile(jobKey: String, ext: String) -> URL? { nil }
}

nonisolated struct DemoCloudInspector: CloudFileInspecting {
    func digest(_ url: URL) throws -> (sha256: String, bytes: Int64) { ("", 0) }
    func frames(_ url: URL) async throws -> Int64 { 0 }
    func sha256Hex(_ data: Data) -> String { "" }
}
