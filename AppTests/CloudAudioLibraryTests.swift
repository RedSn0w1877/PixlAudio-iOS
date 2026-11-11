import Foundation
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// Spatial audio's cloud side (cloud audio spec of 2026-11-10, sections 6.1, 6.2 and 6.4): library jobs through Cloud
/// Studio with the harness's fakes (RunPod, the bucket, the transfers, the preparer, the clock), and the library with
/// its store on a temporary folder. Nothing touches the network or the person's files.
@MainActor
final class CloudAudioLibraryTests: XCTestCase {
    static let videoId = "J7p4bzqLvCw"
    static let studio = RenditionKey(videoId: videoId, profile: .studio)
    /// A render's bytes (what the fake bucket "serves").
    static let renderBytes = Data(repeating: 9, count: 8_192)

    /// The manifest the worker writes for a render of `bytes`: 44.1 kHz, the harness's frame count (four minutes).
    static func renderManifest(_ key: RenditionKey = studio, bytes: Data = renderBytes,
                               samples: Int64 = CloudTestValues.sourceFrames, durationMs: Int64 = 240_000) -> CloudLibraryManifest {
        CloudLibraryManifest(
            videoId: key.videoId, profile: key.profile.rawValue,
            audio: CloudLibraryManifest.Audio(key: CloudLibrary.audioKey(key) ?? "", bytes: Int64(bytes.count),
                                              sha256: CloudPlatform.sha256Hex(bytes), sampleRate: 44_100, samples: samples,
                                              durationMs: durationMs),
            loudness: CloudLibraryManifest.Loudness(integratedLufs: -13.8, sourceLufs: -9.8, headroomDb: 4.0),
            source: CloudLibraryManifest.Source(itag: 140, codec: "aac", sampleRate: 44_100, decodedSamples: samples),
            render: CloudLibraryManifest.Render(engine: CloudLibrary.engineId, stems: "open-cascade-6", stemMode: "stems6"))
    }

    /// Cloud Studio holds its render store weakly: the test keeps what it hands over alive.
    private var keepAlive: [AnyObject] = []

    func makeHarness() -> (h: CloudHarness, store: FakeRenderStore, song: Song) {
        let h = CloudHarness()
        let store = FakeRenderStore()
        keepAlive.append(store)
        h.studio.renderInstaller = store
        let song = h.addSong("sp:track1", contentUri: "pixlstream://\(Self.videoId)")
        return (h, store, song)
    }

    func putInLibrary(_ h: CloudHarness, _ manifest: CloudLibraryManifest) throws {
        let key = try XCTUnwrap(manifest.profile.flatMap(SpatialProfile.init(rawValue:)).map {
            RenditionKey(videoId: manifest.videoId, profile: $0)
        })
        h.objects.set(try XCTUnwrap(CloudLibrary.manifestKey(key)), try manifest.encoded())
    }

    // MARK: Jobs

    func testARenderIsMadeFetchedCheckedAndStored() async throws {
        let (h, store, song) = makeHarness()
        let enqueued = await h.studio.enqueueLibraryRender(song: song, videoId: Self.videoId, profile: .studio, ahead: false)
        let key = try XCTUnwrap(enqueued)
        await h.studio.pump()
        await h.studio.settle()
        // Nothing in the shared library: the song's audio is prepared like every streamed song's and uploaded.
        XCTAssertEqual(h.studio.job(key)?.state, .uploading)
        XCTAssertEqual(h.preparer.forcedDecode, [true], "decoded to FLAC like every streamed song")
        XCTAssertEqual(h.transfers.uploads.count, 1)

        await h.studio.handle(.uploaded(jobKey: key))
        await h.studio.pump()
        let runs = await h.runpod.runs
        let request = try XCTUnwrap(runs.first)
        XCTAssertEqual(request.input.typedTasks, [.spatial])
        XCTAssertEqual(request.policy?.executionTimeout, CloudTiming.libraryExecutionTimeoutMs)
        XCTAssertEqual(request.input.library?.videoId, Self.videoId)
        XCTAssertEqual(request.input.library?.renders.map(\.profile), ["studio"])
        XCTAssertEqual(request.input.library?.renders.first?.audioPut.contains("/lib/v1/\(Self.videoId)/sp-studio.flac?m=PUT"), true)
        XCTAssertNil(request.input.output?.codec, "library renders have no codec of the job's")
        XCTAssertEqual(request.input.output?.put?.keys.sorted(), ["manifest"])
        XCTAssertGreaterThan(h.settings.libraryLedger.spentMicroUSD, 0, "its estimate is reserved in the library's ledger")
        XCTAssertEqual(h.studio.committedThisMonthMicroUSD, 0, "and never in Sing's sum")

        // The worker made it: the render manifest is read from its library key, the audio comes down as sp-studio.
        let manifest = Self.renderManifest()
        try putInLibrary(h, manifest)
        let audio = try XCTUnwrap(manifest.audio)
        let result = CloudJobResult(
            jobKey: key, status: .ok,
            worker: CloudWorkerInfo(version: "1.1.0", gitSha: "abc", gpu: "NVIDIA RTX A4500", vramGB: 20, cuda: "12.8"),
            outputs: ["sp-studio": CloudOutputFile(render: audio)],
            timings: CloudTimings(coldStartMs: 0, totalMs: 70_000),
            library: CloudLibraryResult(videoId: Self.videoId, libV: 1, renders: ["studio": "ok"], stemMode: "stems6"))
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "COMPLETED", result: result))
        h.clock.advance(16_000)
        await h.studio.pump()
        XCTAssertEqual(h.studio.job(key)?.state, .downloading)
        XCTAssertEqual(h.transfers.downloads.map { $0.slot }, ["sp-studio"])

        // Checked (size, SHA-256, its frame count against this phone's decode) and stored; the job's own objects go,
        // the library's never.
        await h.studio.handle(.downloaded(jobKey: key, slot: "sp-studio", stagedFile: try h.stagedInstrumental(Self.renderBytes)))
        XCTAssertEqual(h.studio.job(key)?.state, .imported)
        XCTAssertEqual(store.stored[Self.studio], manifest)
        XCTAssertTrue(h.objects.deleted.contains("in/\(key).flac"))
        XCTAssertTrue(h.objects.deleted.contains("out/\(key)/manifest.json"))
        XCTAssertFalse(h.objects.deleted.contains { $0.hasPrefix("lib/") }, "lib/ objects are never deleted")
        // The real cost replaced the estimate (an A4500 at its price), in the library's ledger only.
        XCTAssertEqual(h.settings.libraryLedger.spentMicroUSD,
                       (70_000 * CloudCost.ampere16PricePerSecondMicroUSD + 999) / 1000)
        XCTAssertEqual(h.settings.libraryLedger.dayCount, 0, "the playing song's render doesn't count for the day")
        XCTAssertEqual(h.studio.committedThisMonthMicroUSD, 0)
    }

    func testARenderInTheSharedLibraryIsOnlyFetched() async throws {
        let (h, store, song) = makeHarness()
        let manifest = Self.renderManifest(durationMs: 238_000)
        try putInLibrary(h, manifest)
        let enqueued = await h.studio.enqueueLibraryRender(song: song, videoId: Self.videoId, profile: .studio, ahead: false)
        let key = try XCTUnwrap(enqueued)
        await h.studio.pump()
        await h.studio.settle()
        // No upload, no GPU: the render is fetched from the library.
        XCTAssertEqual(h.studio.job(key)?.state, .downloading)
        XCTAssertEqual(h.studio.job(key)?.library?.foundInLibrary, true)
        XCTAssertTrue(h.transfers.uploads.isEmpty)
        XCTAssertTrue(h.preparer.prepared.isEmpty)
        let runs = await h.runpod.runs
        XCTAssertTrue(runs.isEmpty)

        // Another phone made it, maybe at another rate: lined up by media time (238 s for a 240 s song is fine).
        await h.studio.handle(.downloaded(jobKey: key, slot: "sp-studio", stagedFile: try h.stagedInstrumental(Self.renderBytes)))
        XCTAssertEqual(h.studio.job(key)?.state, .imported)
        XCTAssertEqual(store.stored[Self.studio], manifest)
        XCTAssertTrue(h.objects.deleted.isEmpty, "nothing of its own in the bucket, and lib/ is never deleted")
        XCTAssertEqual(h.settings.libraryLedger.spentMicroUSD, 0, "a download costs nothing on the GPU")
    }

    func testACutOffSharedRenderIsNotStored() async throws {
        let (h, store, song) = makeHarness()
        // Made from an upload that stopped after 50 s (a stream cut short).
        try putInLibrary(h, Self.renderManifest(durationMs: 50_000))
        let enqueued = await h.studio.enqueueLibraryRender(song: song, videoId: Self.videoId, profile: .studio, ahead: false)
        let key = try XCTUnwrap(enqueued)
        await h.studio.pump()
        await h.studio.settle()
        await h.studio.handle(.downloaded(jobKey: key, slot: "sp-studio", stagedFile: try h.stagedInstrumental(Self.renderBytes)))
        let job = try XCTUnwrap(h.studio.job(key))
        XCTAssertEqual(job.state, .failed)
        XCTAssertTrue(job.library?.isRejected(.studio) == true)
        XCTAssertTrue(store.stored.isEmpty)
        XCTAssertEqual(CloudLibraryStatus.status(for: Self.studio, isLocal: false, job: job, networkAllowed: true, retry: nil,
                                                 nowMs: h.clock.ms), .failed)
    }

    func testADamagedDownloadIsFetchedAgain() async throws {
        let (h, store, song) = makeHarness()
        try putInLibrary(h, Self.renderManifest())
        let enqueued = await h.studio.enqueueLibraryRender(song: song, videoId: Self.videoId, profile: .studio, ahead: false)
        let key = try XCTUnwrap(enqueued)
        await h.studio.pump()
        await h.studio.settle()
        await h.studio.handle(.downloaded(jobKey: key, slot: "sp-studio",
                                          stagedFile: try h.stagedInstrumental(Data(repeating: 1, count: 8_192))))
        XCTAssertEqual(h.studio.job(key)?.state, .resultsReady)
        XCTAssertNotNil(h.studio.job(key)?.nextAttemptAtMs, "tried again after a wait")
        XCTAssertNil(h.studio.job(key)?.library?.downloading)
        XCTAssertTrue(store.stored.isEmpty)
    }

    func testARenderAlreadyOnThePhoneNeedsNothing() async throws {
        let (h, store, song) = makeHarness()
        store.stored[Self.studio] = Self.renderManifest()
        let enqueued = await h.studio.enqueueLibraryRender(song: song, videoId: Self.videoId, profile: .studio, ahead: false)
        let key = try XCTUnwrap(enqueued)
        await h.studio.pump()
        await h.studio.settle()
        XCTAssertEqual(h.studio.job(key)?.state, .imported)
        XCTAssertTrue(h.transfers.downloads.isEmpty && h.transfers.uploads.isEmpty)
    }

    func testOneJobPerRendition() async throws {
        let (h, store, song) = makeHarness()
        _ = store
        let first = await h.studio.enqueueLibraryRender(song: song, videoId: Self.videoId, profile: .studio, ahead: true)
        let again = await h.studio.enqueueLibraryRender(song: song, videoId: Self.videoId, profile: .studio, ahead: false)
        XCTAssertEqual(first, again)
        XCTAssertEqual(h.studio.jobs.count, 1)
        // The playing song took over the background queue's job.
        XCTAssertEqual(h.studio.jobs.first?.isPreparedAhead, false)
        let other = await h.studio.enqueueLibraryRender(song: song, videoId: Self.videoId, profile: .night, ahead: false)
        XCTAssertNotEqual(other, first)
        XCTAssertEqual(h.studio.jobs.count, 2)
    }

    // MARK: Money

    func testLibraryJobsHaveTheirOwnCap() async throws {
        let (h, store, song) = makeHarness()
        _ = store
        h.studio.libraryMonthlyCapMicroUSD = 1_000
        let enqueued = await h.studio.enqueueLibraryRender(song: song, videoId: Self.videoId, profile: .studio, ahead: false)
        let key = try XCTUnwrap(enqueued)
        await h.studio.pump()
        await h.studio.settle()
        // Over the library's cap: nothing is prepared or uploaded, and it says why.
        XCTAssertEqual(h.studio.job(key)?.state, .queued)
        XCTAssertEqual(h.studio.job(key)?.library?.heldByCap, true)
        XCTAssertTrue(h.preparer.prepared.isEmpty)
        XCTAssertEqual(CloudLibraryStatus.status(for: Self.studio, isLocal: false, job: h.studio.job(key),
                                                 networkAllowed: true, retry: nil, nowMs: h.clock.ms), .capReached)
        XCTAssertNotEqual(h.studio.notice, .capReached, "Sing's cap notice is Sing's")
        // No limit: it goes.
        h.studio.libraryMonthlyCapMicroUSD = nil
        await h.studio.pump()
        await h.studio.settle()
        XCTAssertEqual(h.studio.job(key)?.state, .uploading)
        XCTAssertNil(h.studio.job(key)?.library?.heldByCap)
    }

    func testSingsCapNeverHoldsALibraryJob() async throws {
        let (h, store, song) = makeHarness()
        _ = store
        h.settings.monthlyCapMicroUSD = 0
        let enqueued = await h.studio.enqueueLibraryRender(song: song, videoId: Self.videoId, profile: .studio, ahead: false)
        let key = try XCTUnwrap(enqueued)
        await h.studio.pump()
        await h.studio.settle()
        await h.studio.handle(.uploaded(jobKey: key))
        await h.studio.pump()
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.count, 1, "Sing's cap (here zero) is not the library's")
        XCTAssertEqual(h.studio.job(key)?.state, .submitted)
    }

    func testSingIsNotBlockedByALibraryJob() async throws {
        let (h, store, song) = makeHarness()
        _ = store
        _ = await h.studio.enqueueLibraryRender(song: song, videoId: Self.videoId, profile: .studio, ahead: false)
        XCTAssertFalse(h.studio.hasPendingJob(songId: song.id))
        XCTAssertNil(h.studio.job(forSong: song.id))
        let outcome = await h.studio.startSing(song: song)
        XCTAssertEqual(outcome, .started(1))
        XCTAssertEqual(h.studio.jobs.filter { !$0.isLibraryJob }.count, 1)
        XCTAssertEqual(h.studio.job(forSong: song.id)?.effectiveOrigin, .sing)
    }

    // MARK: Network

    func testTheSongThatPlaysWaitsForANetworkItMayUse() async throws {
        let (h, store, song) = makeHarness()
        _ = store
        h.phone.goOffWiFi()
        let enqueued = await h.studio.enqueueLibraryRender(song: song, videoId: Self.videoId, profile: .studio, ahead: false)
        let key = try XCTUnwrap(enqueued)
        await h.studio.pump()
        await h.studio.settle()
        XCTAssertEqual(h.studio.job(key)?.state, .queued, "mobile data is off for cloud work")
        XCTAssertEqual(CloudLibraryStatus.status(for: Self.studio, isLocal: false, job: h.studio.job(key),
                                                 networkAllowed: h.studio.libraryMayUseNetwork(ahead: false), retry: nil,
                                                 nowMs: h.clock.ms), .waitingForNetwork)
        h.phone.goOnWiFi()
        await h.studio.pump()
        await h.studio.settle()
        XCTAssertEqual(h.studio.job(key)?.state, .uploading)
    }

    func testTheBackgroundQueueUsesWiFiOnly() async throws {
        let (h, store, song) = makeHarness()
        _ = store
        h.settings.useCellular = true
        h.phone.goOffWiFi()
        let enqueued = await h.studio.enqueueLibraryRender(song: song, videoId: Self.videoId, profile: .studio, ahead: true)
        let key = try XCTUnwrap(enqueued)
        XCTAssertTrue(h.studio.libraryMayUseNetwork(ahead: false), "the playing song could use mobile data")
        XCTAssertFalse(h.studio.libraryMayUseNetwork(ahead: true), "the background queue never does")
        await h.studio.pump()
        await h.studio.settle()
        XCTAssertEqual(h.studio.job(key)?.state, .queued)
        h.phone.goOnWiFi()
        await h.studio.pump()
        await h.studio.settle()
        XCTAssertEqual(h.studio.job(key)?.state, .uploading)
        XCTAssertEqual(h.transfers.uploadAllowedCellular[key], false)
    }

    // MARK: The library

    func makeLibrary(_ h: CloudHarness, settings: CloudAudioSettings) -> (SpatialCloudLibrary, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudAudioTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(CloudAudioLocalLayout.directoryName, isDirectory: true)
        let defaults = UserDefaults(suiteName: "cloud-audio-\(UUID().uuidString)") ?? .standard
        let library = SpatialCloudLibrary(cloud: h.studio, store: CloudAudioStore(directory: directory), defaults: defaults,
                                          settings: settings)
        keepAlive.append(library)
        h.studio.renderInstaller = library
        library.start()
        return (library, directory)
    }

    static func spatialSettings(cloud: Bool = true) -> CloudAudioSettings {
        var settings = CloudAudioSettings(builtInCloudKeys: false)
        settings.cloud = cloud
        settings.profile = .profile(.studio)
        return settings
    }

    func testTheLibraryFetchesStoresReportsAndRemoves() async throws {
        let h = CloudHarness()
        var settings = Self.spatialSettings(cloud: false)
        let (library, directory) = makeLibrary(h, settings: settings)
        let log = SpatialEventLog(await library.events())
        let song = h.addSong("sp:track1", contentUri: "pixlstream://\(Self.videoId)")
        let request = RenditionRequest(song: song, videoId: Self.videoId, profile: .studio)
        let nothing = await library.status(Self.studio)
        XCTAssertEqual(nothing, .none)

        // Spatial audio's cloud switch off: nothing is asked of the cloud.
        let off = await library.request(request)
        XCTAssertEqual(off, .none)
        XCTAssertTrue(h.studio.jobs.isEmpty)

        settings.cloud = true
        await library.apply(settings)
        let manifest = Self.renderManifest()
        try putInLibrary(h, manifest)
        let first = await library.request(request)
        XCTAssertEqual(first, .queued)
        await h.studio.pump()
        await h.studio.settle()
        let jobKey = try XCTUnwrap(h.studio.jobs.last?.jobKey)
        let coming = await library.status(Self.studio)
        XCTAssertEqual(coming, .downloading)

        await h.studio.handle(.downloaded(jobKey: jobKey, slot: "sp-studio", stagedFile: try h.stagedInstrumental(Self.renderBytes)))
        let local = await library.localRendition(Self.studio)
        XCTAssertEqual(local?.manifest, manifest)
        XCTAssertEqual(local?.fileURL.lastPathComponent, "sp-studio.flac")
        XCTAssertEqual(local?.headroomDb, 4.0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(Self.videoId)/sp-studio.json").path))
        let ready = await library.status(Self.studio)
        XCTAssertEqual(ready, .ready)
        let again = await library.request(request)
        XCTAssertEqual(again, .ready)
        XCTAssertEqual(h.studio.jobs.count, 1, "a render on the phone needs no job")
        let all = await library.localRenditions(videoId: Self.videoId)
        XCTAssertEqual(all.map(\.key), [Self.studio])
        let usage = await library.usage()
        XCTAssertEqual(usage.songsReady, 1)
        XCTAssertEqual(usage.bytes, Int64(Self.renderBytes.count))

        // The files are the index: a store opened on the same folder finds the render.
        let reopened = await CloudAudioStore(directory: directory).load()
        XCTAssertEqual(reopened.map(\.rendition.key), [Self.studio])

        // "Remove downloaded renders": gone from the phone, never from the shared library.
        let after = await library.removeAll()
        XCTAssertEqual(after.songsReady, 0)
        XCTAssertEqual(after.bytes, 0)
        let gone = await library.localRendition(Self.studio)
        XCTAssertNil(gone)
        XCTAssertFalse(h.objects.deleted.contains { $0.hasPrefix("lib/") })

        // What the model heard.
        await h.waitUntil { log.events.contains(.renditionRemoved(Self.studio)) }
        XCTAssertTrue(log.events.contains { event in
            if case .renditionReady(let rendition) = event { return rendition.key == Self.studio }
            return false
        })
        XCTAssertTrue(log.events.contains(.statusChanged(Self.studio, .ready)))
        XCTAssertTrue(log.events.contains(.renditionRemoved(Self.studio)))
        log.stop()
    }

    func testAFailedRenditionWaitsOutItsBackoff() async throws {
        let h = CloudHarness()
        let (library, _) = makeLibrary(h, settings: Self.spatialSettings())
        let song = h.addSong("sp:track1", contentUri: "pixlstream://\(Self.videoId)")
        let request = RenditionRequest(song: song, videoId: Self.videoId, profile: .studio)
        // The shared library holds a render cut short: it is fetched, refused, and the job fails.
        try putInLibrary(h, Self.renderManifest(durationMs: 50_000))
        _ = await library.request(request)
        await h.studio.pump()
        await h.studio.settle()
        let jobKey = try XCTUnwrap(h.studio.jobs.last?.jobKey)
        await h.studio.handle(.downloaded(jobKey: jobKey, slot: "sp-studio", stagedFile: try h.stagedInstrumental(Self.renderBytes)))
        XCTAssertEqual(h.studio.job(jobKey)?.state, .failed)
        let failed = await library.status(Self.studio)
        XCTAssertEqual(failed, .failed)

        // Asked again within ten minutes: nothing changes.
        h.clock.advance(60_000)
        let during = await library.request(request)
        XCTAssertEqual(during, .failed)
        XCTAssertEqual(h.studio.jobs.count, 1)

        // After it: a new attempt (which looks in the shared library again).
        h.clock.advance(RenditionRetry.backoffMs[0])
        let later = await library.request(request)
        XCTAssertEqual(later, .queued)
        XCTAssertEqual(h.studio.jobs.count, 2)
    }

    func testCloudRendersNeedTheMasterSwitchToo() async throws {
        let h = CloudHarness()
        let (library, _) = makeLibrary(h, settings: Self.spatialSettings())
        let song = h.addSong("sp:track1", contentUri: "pixlstream://\(Self.videoId)")
        h.settings.isEnabled = false
        XCTAssertFalse(library.cloudRendersOn)
        let answer = await library.request(RenditionRequest(song: song, videoId: Self.videoId, profile: .studio))
        XCTAssertEqual(answer, .none)
        XCTAssertTrue(h.studio.jobs.isEmpty)
    }

    func testSwitchingCloudRendersOffStopsTheirJobs() async throws {
        let h = CloudHarness()
        var settings = Self.spatialSettings()
        let (library, _) = makeLibrary(h, settings: settings)
        let song = h.addSong("sp:track1", contentUri: "pixlstream://\(Self.videoId)")
        _ = await library.request(RenditionRequest(song: song, videoId: Self.videoId, profile: .studio))
        XCTAssertEqual(h.studio.jobs.first?.state.isPending, true)
        settings.cloud = false
        await library.apply(settings)
        XCTAssertEqual(h.studio.jobs.first?.state, .cancelled)
        let status = await library.status(Self.studio)
        XCTAssertEqual(status, .none)
    }

    // MARK: The store

    func stage(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("render-\(UUID().uuidString).flac")
        try data.write(to: url)
        return url
    }

    func testTheStoreKeepsWhatItCanVouchForAndEvictsTheLeastRecentlyPlayed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudAudioStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CloudAudioStore(directory: directory)
        _ = await store.load()
        let a = RenditionKey(videoId: "AAAAAAAAAAA", profile: .studio)
        let b = RenditionKey(videoId: "BBBBBBBBBBB", profile: .wide)
        _ = try await store.install(staged: try stage(Self.renderBytes), manifest: Self.renderManifest(a), nowMs: 1_000_000)
        _ = try await store.install(staged: try stage(Self.renderBytes), manifest: Self.renderManifest(b), nowMs: 2_000_000)
        await store.markPlayed(a, nowMs: 3_000_000)
        let evicted = await store.evict(budgetBytes: 10_000, keeping: [])
        XCTAssertEqual(evicted, [b], "the least recently played goes first")

        // A file whose manifest was never written (a crash between the two), and a manifest that no longer describes
        // its file, are not in the index and are deleted.
        let stray = directory.appendingPathComponent("CCCCCCCCCCC", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Self.renderBytes.write(to: stray.appendingPathComponent("sp-night.flac"))
        let short = directory.appendingPathComponent("DDDDDDDDDDD", isDirectory: true)
        try FileManager.default.createDirectory(at: short, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 100).write(to: short.appendingPathComponent("sp-hall.flac"))
        try Self.renderManifest(RenditionKey(videoId: "DDDDDDDDDDD", profile: .hall)).encoded()
            .write(to: short.appendingPathComponent("sp-hall.json"))
        let items = await CloudAudioStore(directory: directory).load()
        XCTAssertEqual(items.map(\.rendition.key), [a])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: short.path))
        // The one that stayed keeps when it was last played (the manifest's date).
        XCTAssertEqual(items.first.map { abs($0.lastPlayedMs - 3_000_000) <= 1_000 }, true)

        // A manifest for another render than the one it is filed as is refused at the door.
        var wrong = Self.renderManifest(a)
        wrong.libV = 2
        do {
            _ = try await store.install(staged: try stage(Self.renderBytes), manifest: wrong, nowMs: 4_000_000)
            XCTFail("a manifest of another library version must not be stored")
        } catch {}
    }
}

/// Spatial audio's store as Cloud Studio sees it, in memory.
@MainActor
final class FakeRenderStore: CloudRenderInstalling {
    var stored: [RenditionKey: CloudLibraryManifest] = [:]

    func hasRender(_ key: RenditionKey) -> Bool { stored[key] != nil }

    func installRender(staged: URL, manifest: CloudLibraryManifest) async throws {
        guard let profile = manifest.profile.flatMap(SpatialProfile.init(rawValue:)) else {
            throw CloudStudio.Failure("No profile")
        }
        stored[RenditionKey(videoId: manifest.videoId, profile: profile)] = manifest
        try? FileManager.default.removeItem(at: staged)
    }
}

/// Every event a library sent, in order.
@MainActor
final class SpatialEventLog {
    private(set) var events: [SpatialLibraryEvent] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<SpatialLibraryEvent>) {
        task = Task { [weak self] in
            for await event in stream { self?.events.append(event) }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
