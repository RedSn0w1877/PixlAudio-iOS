import Foundation
import Testing
import PixlFoundation
import PixlModel
@testable import PixlNet

/// Spatial audio's library jobs (cloud audio spec of 2026-11-10, sections 3, 4, 6.1, 6.2 and 6.4): the `/run` body
/// against the worker's own examples, the result and render manifests, the local store's rules, the money, the status
/// of a rendition and the retry ladder.
@Suite struct CloudLibraryTests {
    static let jobKey = "3d9f0c52-7a41-4e8b-b6f3-91c2d5e7a804"
    static let videoId = "J7p4bzqLvCw"
    static let studio = RenditionKey(videoId: videoId, profile: .studio)

    /// The record the worker's `job.input.spatial.json` was built from: one render (studio) of J7p4bzqLvCw, the stream
    /// itag 251 (Opus), uploaded as FLAC.
    static func exampleRecord() -> CloudJobRecord {
        var record = CloudJobRecord(jobKey: jobKey, songId: "sp:track", title: "Song", artist: "Artist", batchId: "b",
                                    tasks: [.spatial], lyricsMode: nil, quality: .standard, createdAtMs: 0,
                                    isStreamed: true, videoId: videoId)
        record.origin = .library
        var info = CloudLibraryJobInfo(videoId: videoId, profiles: [.studio])
        info.sourceItag = 251
        info.sourceCodec = "opus"
        record.library = info
        record.inputExt = "flac"
        record.sha256 = "F2218379956AB8D0D22BFD05D9C0B60A7F461AADA888AA86F614E0DB77724372"
        record.bytes = 27_418_112
        record.durationMs = 202_000
        return record
    }

    /// A presign that answers with the example's own URLs (the signatures are the only part that is not the
    /// builder's), keyed by method and object key, and remembers the lifetimes it was asked for.
    final class ExamplePresign: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String: String] = [:]
        private var seconds: Set<Int> = []

        init(_ input: CloudJobInput) {
            func add(_ method: HTTPMethod, _ url: String?) {
                guard let url, let start = url.range(of: "/pixl-cloud-studio/"), let query = url.firstIndex(of: "?") else { return }
                urls["\(method.rawValue) \(url[start.upperBound..<query])"] = url
            }
            add(.get, input.audio?.get)
            add(.delete, input.audio?.delete)
            add(.put, input.output?.put?["manifest"])
            add(.get, input.guard?.manifestGet)
            add(.get, input.guard?.attemptGet)
            add(.put, input.guard?.attemptPut)
            for render in input.library?.renders ?? [] {
                add(.put, render.audioPut)
                add(.put, render.manifestPut)
                add(.get, render.manifestGet)
            }
        }

        var presign: CloudPresign {
            { method, key, seconds in
                self.lock.withLock {
                    self.seconds.insert(seconds)
                    return self.urls["\(method.rawValue) \(key)"]
                }
            }
        }

        var lifetimes: Set<Int> { lock.withLock { seconds } }
    }

    // MARK: The /run body

    @Test func builtBodyIsTheWorkersExample() throws {
        let example = try CloudJSON.decode(CloudJobInput.self, from: CloudFixtures.worker("job.input.spatial"))
        let presign = ExamplePresign(example)
        let request = try #require(CloudJobBuilder.request(for: Self.exampleRecord(), build: "1.1.0 (431)", lyrics: nil,
                                                           lastInBatch: true, presign: presign.presign))
        // Field for field and value for value, URLs included (they are the example's own signatures).
        #expect(try CloudFixtures.canonical(try CloudJSON.encode(request.input))
            == CloudFixtures.canonical(try CloudFixtures.worker("job.input.spatial")))
        #expect(try CloudFixtures.canonical(try CloudJSON.encode(request))
            == CloudFixtures.canonical(try CloudFixtures.worker("run.request.spatial")))
        // The library job runs under the longer timeout, and every URL outlives it.
        #expect(request.policy == CloudJobPolicy(ttl: 259_200_000, executionTimeout: 1_800_000))
        #expect(presign.lifetimes == [CloudTiming.workerPresignSeconds(executionTimeoutMs: 1_800_000)])
        #expect(CloudTiming.workerPresignSeconds(executionTimeoutMs: 1_800_000) == 259_200 + 1_800 + 3_600)
    }

    @Test func libraryBlockUsesTheCanonicalKeys() throws {
        var record = Self.exampleRecord()
        record.library?.profiles = ["night", "hall"]
        let fake: CloudPresign = { method, key, seconds in "https://r2.test/\(key)?m=\(method.rawValue)&s=\(seconds)" }
        let request = try #require(CloudJobBuilder.request(for: record, build: "1", lyrics: nil, presign: fake))
        let library = try #require(request.input.library)
        #expect(library.v == CloudLibrary.version && library.videoId == Self.videoId)
        #expect(library.source == CloudLibrarySource(itag: 251, codec: "opus"))
        #expect(library.renders.map(\.profile) == ["night", "hall"])
        let s = CloudTiming.workerPresignSeconds(executionTimeoutMs: CloudTiming.libraryExecutionTimeoutMs)
        #expect(library.renders[1].audioPut == "https://r2.test/lib/v1/\(Self.videoId)/sp-hall.flac?m=PUT&s=\(s)")
        #expect(library.renders[1].manifestPut == "https://r2.test/lib/v1/\(Self.videoId)/sp-hall.json?m=PUT&s=\(s)")
        #expect(library.renders[1].manifestGet == "https://r2.test/lib/v1/\(Self.videoId)/sp-hall.json?m=GET&s=\(s)")
        // Library renders never go into the job's own folder: `output.put` is the manifest alone, with no codec.
        #expect(request.input.output?.put?.keys.sorted() == ["manifest"])
        #expect(request.input.output?.codec == nil && request.input.output?.kbps == nil)
        #expect(request.input.typedTasks == [.spatial])
        // Nothing to sign without a library block, a known profile or a valid video id.
        var noBlock = Self.exampleRecord()
        noBlock.library = nil
        #expect(CloudJobBuilder.request(for: noBlock, build: "1", lyrics: nil, presign: fake) == nil)
        var unknown = Self.exampleRecord()
        unknown.library?.profiles = ["studio", "cathedral"]
        #expect(CloudJobBuilder.request(for: unknown, build: "1", lyrics: nil, presign: fake) == nil)
        var badVideo = Self.exampleRecord()
        badVideo.library?.videoId = "../escape/x"
        #expect(CloudJobBuilder.request(for: badVideo, build: "1", lyrics: nil, presign: fake) == nil)
        // The objects a cleanup may delete stay inside the job's own folder: never a `lib/` key.
        record.outputs = ["sp-night": CloudOutputFile(key: "lib/v1/\(Self.videoId)/sp-night.flac", bytes: 1, sha256: "a",
                                                      codec: "flac", kbps: nil, samples: 1)]
        #expect(CloudJobBuilder.objectKeys(for: record) == ["in/\(Self.jobKey).flac", "out/\(Self.jobKey)/manifest.json",
                                                            "out/\(Self.jobKey)/attempt.json"])
    }

    @Test func oldJobsKeepTheirBodies() throws {
        // An instrumental job is exactly what it was: codec, the short timeout, no library block.
        var record = Self.exampleRecord()
        record.tasks = [.instrumental]
        record.library = nil
        record.origin = nil
        let fake: CloudPresign = { method, key, _ in "https://r2.test/\(key)?m=\(method.rawValue)" }
        let request = try #require(CloudJobBuilder.request(for: record, build: "1", lyrics: nil, presign: fake))
        #expect(request.input.library == nil)
        #expect(request.input.output?.codec == "aac" && request.input.output?.kbps == 256)
        #expect(request.policy?.executionTimeout == 900_000)
        #expect(CloudTiming.executionTimeoutMs(for: [.instrumental]) == 900_000)
        #expect(CloudTiming.executionTimeoutMs(for: [.instrumental, .spatial]) == 1_800_000)
        #expect(CloudTask.spatial.outputSlots.isEmpty)
    }

    @Test func combinedExampleDecodes() throws {
        let input = try CloudJSON.decode(CloudJobInput.self, from: CloudFixtures.worker("job.input.spatial.combined"))
        #expect(input.typedTasks == [.instrumental, .spatial])
        #expect(input.library?.renders.map(\.profile) == ["night", "hall"])
        // `manifestGet` is optional.
        #expect(input.library?.renders[1].manifestGet == nil)
        #expect(input.output?.codec == "aac")
        let request = try CloudJSON.decode(CloudJobRequest.self, from: CloudFixtures.worker("run.request.spatial"))
        #expect(request.policy?.executionTimeout == CloudTiming.libraryExecutionTimeoutMs)
    }

    // MARK: Results

    @Test func okResultNamesTheRenderToFetch() throws {
        let result = try CloudJSON.decode(CloudJobResult.self, from: CloudFixtures.worker("job.result.spatial"))
        #expect(result.typedStatus == .ok)
        #expect(result.library?.state(of: .studio) == .ok)
        #expect(result.library?.stemMode == "stems6")
        #expect(result.models?.stems6 == "open-cascade-6")
        #expect(result.timings?.stems6Ms == 41_800 && result.timings?.renderMs == 23_600)
        var record = Self.exampleRecord()
        record.state = .running
        record.takeResult(result, fallbackPricePerSecondMicroUSD: 192, nowMs: 5)
        let info = try #require(record.library)
        #expect(info.state(of: .studio) == .ok)
        #expect(info.nextToFetch == .studio)
        #expect(!info.isSettled && !record.isFullyImported)
        let output = try #require(record.outputs?["sp-studio"])
        let manifest = try CloudLibraryManifest.decode(CloudFixtures.worker("library.render.spatial"))
        let audio = try #require(try? manifest.check(for: Self.studio).get())
        #expect(CloudLibraryImportCheck.outputAgrees(output, with: audio, key: Self.studio))
        // A job manifest that names another key, or another file, does not agree.
        var moved = output
        moved.key = "out/\(Self.jobKey)/sp-studio.flac"
        #expect(!CloudLibraryImportCheck.outputAgrees(moved, with: audio, key: Self.studio))
        var other = output
        other.sha256 = String(repeating: "0", count: 64)
        #expect(!CloudLibraryImportCheck.outputAgrees(other, with: audio, key: Self.studio))
        // Stored on the phone: the job is done.
        record.library?.markImported(.studio)
        #expect(record.library?.isSettled == true && record.isFullyImported)
        #expect((record.costMicroUSD ?? 0) > 0)
    }

    @Test func existsAndPartialResults() throws {
        let exists = try CloudJSON.decode(CloudJobResult.self, from: CloudFixtures.worker("job.result.spatial.exists"))
        #expect(exists.library?.state(of: .studio) == .exists)
        #expect(exists.library?.stemMode == nil)
        #expect(CloudLibraryRenderState.exists.hasRender)

        let partial = try CloudJSON.decode(CloudJobResult.self, from: CloudFixtures.worker("job.result.spatial.partial"))
        #expect(partial.typedStatus == .partial && partial.hasResults)
        var record = CloudJobRecord(jobKey: "a81c7e30-5f2d-4b96-8e14-c07d3a9b62f5", songId: "s", title: "T", artist: "A",
                                    batchId: "b", tasks: [.spatial], lyricsMode: nil, quality: .standard, createdAtMs: 0)
        record.library = CloudLibraryJobInfo(videoId: "ZD6rXLXZOEI", profiles: [.night, .hall])
        record.state = .running
        record.takeResult(partial, fallbackPricePerSecondMicroUSD: 192, nowMs: 1)
        let info = try #require(record.library)
        #expect(info.state(of: .night) == .ok && info.state(of: .hall) == .failed)
        #expect(info.didFail(.hall) && !info.didFail(.night))
        #expect(info.nextToFetch == .night)
        var done = info
        done.markImported(.night)
        #expect(done.isSettled && done.nextToFetch == nil)
        // A result for another video or library version names nothing of this job.
        var mine = CloudLibraryJobInfo(videoId: Self.videoId, profiles: [.studio])
        mine.take(CloudLibraryResult(videoId: "ZD6rXLXZOEI", libV: 1, renders: ["studio": "ok"], stemMode: "stems6"))
        #expect(mine.renders == nil)
        mine.take(CloudLibraryResult(videoId: Self.videoId, libV: 2, renders: ["studio": "ok"], stemMode: "stems6"))
        #expect(mine.renders == nil)
        // A worker that named nothing: every profile counts as not made, and the job is settled.
        mine.settleUnanswered()
        #expect(mine.isSettled && mine.didFail(.studio))
        // An unknown state from a newer worker is never imported.
        let odd = CloudLibraryResult(videoId: Self.videoId, libV: 1, renders: ["studio": "queued-later"], stemMode: nil)
        #expect(odd.state(of: .studio) == .failed)
    }

    // MARK: The render manifest

    @Test func renderManifestIsAcceptedOnlyForWhatWasAsked() throws {
        let data = try CloudFixtures.worker("library.render.spatial")
        let manifest = try CloudLibraryManifest.decode(data)
        #expect(manifest.isAccepted(for: Self.studio))
        #expect(manifest.headroomDb == 4.0)
        #expect(manifest.stemMode == .stems6)
        #expect(manifest.audioMatches(bytes: 27_100_200, sha256: "FB8CABCCE83EA77EA9FA485FC745368FE10ABA1F241CD77CD39AC394C602F333"))
        #expect(!manifest.audioMatches(bytes: 27_100_201, sha256: manifest.audio?.sha256 ?? ""))
        #expect(!manifest.isAccepted(for: RenditionKey(videoId: Self.videoId, profile: .hall)))
        #expect(!manifest.isAccepted(for: RenditionKey(videoId: "ZD6rXLXZOEI", profile: .studio)))
        var wrong = manifest
        wrong.libV = 2
        #expect(!wrong.isAccepted(for: Self.studio))
        wrong = manifest
        wrong.kind = "stereo"
        #expect(!wrong.isAccepted(for: Self.studio))
        wrong = manifest
        wrong.schema = "pixl.cloudstudio.result"
        #expect(!wrong.isAccepted(for: Self.studio))
        wrong = manifest
        wrong.v = 2
        #expect(!wrong.isAccepted(for: Self.studio))
        wrong = manifest
        wrong.audio?.key = "out/\(Self.jobKey)/sp-studio.flac"
        #expect(!wrong.isAccepted(for: Self.studio))
        // The phone's copy of a manifest keeps what the worker wrote.
        #expect(try CloudFixtures.canonical(try manifest.encoded()) == CloudFixtures.canonical(data))
        // A shared render may come from another phone at another rate: the timeline check is by media time only.
        #expect(CloudLibraryImportCheck.sharedRenderCoversSong(renderDurationMs: 202_000, songDurationMs: 205_000))
        #expect(!CloudLibraryImportCheck.sharedRenderCoversSong(renderDurationMs: 50_000, songDurationMs: 205_000))
        #expect(!CloudLibraryImportCheck.sharedRenderCoversSong(renderDurationMs: nil, songDurationMs: 205_000))
        #expect(CloudLibraryImportCheck.sharedRenderCoversSong(renderDurationMs: 50_000, songDurationMs: nil))
        // This phone's own render keeps its upload's timeline: frame counts agree at 44.1 kHz (here 48 kHz both sides).
        #expect(CloudLibraryImportCheck.ownRenderLinesUp(decodedFrames: 9_696_000, decodedSampleRate: 48_000, manifest: manifest))
        #expect(CloudLibraryImportCheck.ownRenderLinesUp(decodedFrames: 8_908_200, decodedSampleRate: 44_100, manifest: manifest))
        #expect(!CloudLibraryImportCheck.ownRenderLinesUp(decodedFrames: 8_800_000, decodedSampleRate: 44_100, manifest: manifest))
    }

    // MARK: The local store

    @Test func storeAcceptsAPairOnlyWhenTheFileIsWhole() throws {
        let manifest = try CloudLibraryManifest.decode(CloudFixtures.worker("library.render.spatial"))
        #expect(CloudAudioStorePolicy.accepts(manifest, key: Self.studio, fileBytes: 27_100_200))
        #expect(!CloudAudioStorePolicy.accepts(manifest, key: Self.studio, fileBytes: 1_000))
        #expect(!CloudAudioStorePolicy.accepts(manifest, key: Self.studio, fileBytes: nil))
        #expect(!CloudAudioStorePolicy.accepts(manifest, key: RenditionKey(videoId: Self.videoId, profile: .wide),
                                               fileBytes: 27_100_200))
    }

    @Test func storeEvictsTheLeastRecentlyPlayedFirst() {
        let a = RenditionKey(videoId: "AAAAAAAAAAA", profile: .studio)
        let b = RenditionKey(videoId: "BBBBBBBBBBB", profile: .studio)
        let c = RenditionKey(videoId: "BBBBBBBBBBB", profile: .night)
        let entries = [CloudAudioStoreEntry(key: a, bytes: 40, lastPlayedMs: 300),
                       CloudAudioStoreEntry(key: b, bytes: 40, lastPlayedMs: 100),
                       CloudAudioStoreEntry(key: c, bytes: 40, lastPlayedMs: 200)]
        #expect(CloudAudioStorePolicy.evictions(entries, budgetBytes: 120).isEmpty)
        #expect(CloudAudioStorePolicy.evictions(entries, budgetBytes: 100) == [b])
        #expect(CloudAudioStorePolicy.evictions(entries, budgetBytes: 50) == [b, c])
        // The one that was just stored (or plays) stays even when it is the oldest.
        #expect(CloudAudioStorePolicy.evictions(entries, budgetBytes: 50, keeping: [b]) == [c, a])
        let usage = CloudAudioStorePolicy.usage(entries)
        #expect(usage.songs == 2 && usage.bytes == 120)
    }

    // MARK: Money

    @Test func libraryMoneyIsItsOwn() {
        // Sing's sums leave library jobs out, whatever they cost.
        var sing = CloudJobRecord(jobKey: CloudTestKeys.key(1), songId: "s1", title: "A", artist: "B", batchId: "b",
                                  tasks: [.instrumental], lyricsMode: nil, quality: .standard, createdAtMs: 0)
        sing.completedAtMs = 10
        sing.costMicroUSD = 5_000
        var library = Self.exampleRecord()
        library.completedAtMs = 10
        library.costMicroUSD = 70_000
        var running = Self.exampleRecord()
        running.state = .running
        running.submittedAtMs = 5
        #expect(library.isLibraryJob && !sing.isLibraryJob)
        #expect(CloudBudget.spentMicroUSD([sing, library], monthStartMs: 0) == 5_000)
        #expect(CloudBudget.committedMicroUSD([sing, library, running], monthStartMs: 0, pricePerSecondMicroUSD: 192) == 5_000)
        // The library's cap: nil is no limit; otherwise the ledger plus this pass's jobs must leave room.
        let ledger = CloudAutoLedger(monthStartMs: 0, spentMicroUSD: 29_990_000, dayStartMs: 0, dayCount: 24)
        #expect(CloudLibraryBudget.capAllows(estimateMicroUSD: 10_000, spentMicroUSD: ledger.spentMicroUSD, capMicroUSD: 30_000_000))
        #expect(!CloudLibraryBudget.capAllows(estimateMicroUSD: 10_001, spentMicroUSD: ledger.spentMicroUSD, capMicroUSD: 30_000_000))
        #expect(CloudLibraryBudget.capAllows(estimateMicroUSD: 1_000_000_000, spentMicroUSD: ledger.spentMicroUSD, capMicroUSD: nil))
        #expect(CloudLibraryBudget.allows(estimateMicroUSD: 5_000, ledger: ledger, capMicroUSD: 30_000_000, ahead: true, dailyAhead: 25))
        #expect(!CloudLibraryBudget.allows(estimateMicroUSD: 5_000, ledger: ledger, pendingAhead: 1, capMicroUSD: 30_000_000,
                                           ahead: true, dailyAhead: 25))
        // The song that plays is not the background queue's: the day's count does not hold it back.
        #expect(CloudLibraryBudget.allows(estimateMicroUSD: 5_000, ledger: ledger, pendingAhead: 1, capMicroUSD: 30_000_000,
                                          ahead: false, dailyAhead: 25))
        #expect(!CloudLibraryBudget.allows(estimateMicroUSD: 5_000, ledger: ledger, pendingMicroUSD: 6_000,
                                           capMicroUSD: 30_000_000, ahead: false, dailyAhead: 25))
        // Only the background queue's jobs count for the day.
        var counted = CloudAutoLedger()
        counted.reserve(1_000, countsForToday: false)
        #expect(counted.dayCount == 0 && counted.spentMicroUSD == 1_000)
        counted.reserve(1_000, countsForToday: true)
        #expect(counted.dayCount == 1 && counted.spentMicroUSD == 2_000)
        // Sing's $3 rule with built-in keys never clamps the library's cap (the settings' 30 dollars stand).
        var settings = CloudAudioSettings(builtInCloudKeys: true)
        #expect(settings.monthlyCapMicroUSD == 30_000_000)
        settings.monthlyCapUSD = nil
        #expect(settings.monthlyCapMicroUSD == nil)
    }

    @Test func libraryEstimateFollowsTheSongAndTheRenders() {
        let one = CloudLibraryBudget.estimateMicroUSD(durationMs: 240_000, profiles: 1, pricePerSecondMicroUSD: 192)
        let two = CloudLibraryBudget.estimateMicroUSD(durationMs: 240_000, profiles: 2, pricePerSecondMicroUSD: 192)
        #expect(one == (CloudCost.spatialBaseSeconds + CloudCost.spatialRenderSeconds) * 192)
        #expect(two - one == CloudCost.spatialRenderSeconds * 192)
        let long = CloudLibraryBudget.estimateMicroUSD(durationMs: 480_000, profiles: 1, pricePerSecondMicroUSD: 192)
        #expect(long == 2 * one)
        // A record's plan carries its profiles.
        var record = Self.exampleRecord()
        record.library?.profiles = ["studio", "night"]
        #expect(record.plan.renders == 2)
        #expect(CloudCost.estimatedSeconds(record.plan, quality: .standard)
            > CloudCost.estimatedSeconds(CloudSongPlan(songId: "s", tasks: [.instrumental], lyricsMode: nil,
                                                       isStreamed: true, durationMs: 202_000), quality: .standard))
    }

    // MARK: Status

    static func job(_ state: CloudJobState, ahead: Bool = false, change: (inout CloudLibraryJobInfo) -> Void = { _ in }) -> CloudJobRecord {
        var record = exampleRecord()
        record.state = state
        var info = CloudLibraryJobInfo(videoId: videoId, profiles: [.studio], ahead: ahead)
        change(&info)
        record.library = info
        return record
    }

    @Test func statusFollowsTheJob() {
        func status(_ job: CloudJobRecord?, local: Bool = false, network: Bool = true,
                    retry: CloudLibraryRetryBook.Entry? = nil, now: Int64 = 0) -> RenditionStatus {
            CloudLibraryStatus.status(for: Self.studio, isLocal: local, job: job, networkAllowed: network, retry: retry,
                                      nowMs: now)
        }
        #expect(status(nil) == .none)
        #expect(status(Self.job(.running), local: true) == .ready)
        #expect(status(Self.job(.queued)) == .queued)
        #expect(status(Self.job(.preparing)) == .queued)
        #expect(status(Self.job(.uploading), network: false) == .waitingForNetwork)
        #expect(status(Self.job(.queued) { $0.heldByCap = true }) == .capReached)
        #expect(status(Self.job(.uploaded)) == .queued)
        #expect(status(Self.job(.submitted)) == .processing)
        #expect(status(Self.job(.running)) == .processing)
        #expect(status(Self.job(.resultsReady) { $0.renders = ["studio": "exists"] }) == .downloading)
        #expect(status(Self.job(.downloading) { $0.renders = ["studio": "ok"] }) == .downloading)
        #expect(status(Self.job(.downloading, ahead: true) { $0.renders = ["studio": "ok"] }, network: false) == .waitingForNetwork)
        #expect(status(Self.job(.resultsReady) { $0.renders = ["studio": "failed"] }) == .failed)
        #expect(status(Self.job(.imported) { $0.renders = ["studio": "ok"]; $0.markRejected(.studio) }) == .failed)
        #expect(status(Self.job(.imported) { $0.renders = ["studio": "ok"]; $0.markImported(.studio) }) == .none)
        #expect(status(Self.job(.failed)) == .failed)
        #expect(status(Self.job(.expired)) == .failed)
        #expect(status(Self.job(.cancelled)) == .none)
        // A job about another rendition says nothing about this one.
        #expect(status(Self.job(.running) { $0.profiles = ["night"] }) == .none)
        // A failure waits out its backoff: 10 minutes after the first one.
        let failure = CloudLibraryRetryBook.Entry(failures: 1, lastFailureAtMs: 1_000)
        #expect(status(nil, retry: failure, now: 1_000 + 599_999) == .failed)
        #expect(status(nil, retry: failure, now: 1_000 + 600_000) == .none)
    }

    @Test func latestJobAndPendingJob() {
        let old = Self.job(.failed)
        var newer = Self.job(.queued)
        newer.jobKey = CloudTestKeys.key(9)
        let cancelled = Self.job(.cancelled)
        #expect(CloudLibraryStatus.latestJob(for: Self.studio, in: [old, newer, cancelled])?.jobKey == CloudTestKeys.key(9))
        #expect(CloudLibraryStatus.pendingJob(for: Self.studio, in: [old, cancelled]) == nil)
        #expect(CloudLibraryStatus.pendingJob(for: Self.studio, in: [old, newer])?.state == .queued)
    }

    @Test func retryLadderCountsEachJobOnce() {
        var book = CloudLibraryRetryBook()
        #expect(book.mayTry(Self.studio, nowMs: 0))
        let counted = book.recordFailure(Self.studio, jobKey: "j1", nowMs: 0)
        let countedTwice = book.recordFailure(Self.studio, jobKey: "j1", nowMs: 5)
        #expect(counted && !countedTwice)
        let failures = book.entry(for: Self.studio)?.failures ?? -1
        #expect(failures == 1)
        #expect(!book.mayTry(Self.studio, nowMs: 599_999) && book.mayTry(Self.studio, nowMs: 600_000))
        book.recordFailure(Self.studio, jobKey: "j2", nowMs: 600_000)
        let secondDue: Int64 = book.entry(for: Self.studio)?.dueAtMs ?? -1
        #expect(secondDue == 4_200_000)
        book.recordFailure(Self.studio, jobKey: "j3", nowMs: 5_000_000)
        book.recordFailure(Self.studio, jobKey: "j4", nowMs: 6_000_000)
        let laterDue: Int64 = book.entry(for: Self.studio)?.dueAtMs ?? -1
        #expect(laterDue == 92_400_000)
        // It survives a relaunch (it is stored as JSON) and forgets a render that arrived.
        let decoded = try? JSONDecoder().decode(CloudLibraryRetryBook.self, from: JSONEncoder().encode(book))
        #expect(decoded == book)
        book.clear(Self.studio)
        #expect(book.mayTry(Self.studio, nowMs: 6_000_001))
        // Old failures that are due are forgotten.
        book.recordFailure(Self.studio, jobKey: "j5", nowMs: 0)
        book.prune(nowMs: CloudLibraryRetryBook.forgetAfterMs + 1)
        #expect(book.entry(for: Self.studio) == nil)
    }

    // MARK: The queue's manners

    @Test func libraryJobsNeverGoFirst() {
        var playing = Self.exampleRecord()
        playing.state = .queued
        var ahead = playing
        ahead.jobKey = CloudTestKeys.key(2)
        ahead.library?.ahead = true
        var sing = CloudJobRecord(jobKey: CloudTestKeys.key(3), songId: "s", title: "S", artist: "A", batchId: "solo",
                                  tasks: [.instrumental], lyricsMode: nil, quality: .standard, createdAtMs: 0)
        sing.origin = .sing
        let jobs = [ahead, playing, sing]
        let priority = CloudPriorityLane.priorityJobKeys(jobs)
        #expect(priority == [sing.jobKey])
        #expect(CloudPriorityLane.ordered(jobs, priorityKeys: priority).map(\.jobKey) == [sing.jobKey, playing.jobKey, ahead.jobKey])
        #expect(CloudPriorityLane.transferPriority(for: playing, priorityKeys: priority) == 0.4)
        #expect(CloudPriorityLane.transferPriority(for: ahead, priorityKeys: priority) == 0.3)
        #expect(ahead.isPreparedAhead && !playing.isPreparedAhead)
        // While a Sing job gets ready, library jobs wait with the songs prepared ahead.
        var uploadedPlaying = playing
        uploadedPlaying.state = .uploaded
        let held = CloudPriorityLane.heldBack(ready: [uploadedPlaying.jobKey], jobs: [uploadedPlaying, sing], nowMs: 0)
        #expect(held == [uploadedPlaying.jobKey])
    }

    @Test func libraryJobsAreQuietAndHaveTheirOwnRow() {
        var record = Self.exampleRecord()
        record.state = .imported
        record.batchId = "spatial-1"
        #expect(CloudBatchNotifier.completions(previouslyIncomplete: ["spatial-1"], jobs: [record], alreadyNotified: []).isEmpty)
        var running = Self.exampleRecord()
        running.state = .running
        running.progressStage = "render"
        running.progressPercent = 40
        let rows = CloudActiveJobMapper.rows([running], transfer: [:])
        #expect(rows.count == 1 && rows.first?.kind == .spatial)
        #expect(rows.first?.id == "cloud.b")
        #expect(rows.first?.subtitle == "Song · Rendering Spatial audio 40%")
        #expect(CloudProgress(stage: "stems6", percent: nil).label == "Separating the instruments")
        #expect(ActiveJob.Kind.spatial.label == "Spatial audio")
        // A plan for the background requests may wait for the charger when only library work is outstanding.
        let plan = CloudBackgroundPlanner.plan(jobs: [running], nowMs: 0, isEnabled: true)
        #expect(plan.processingRequiresPower)
    }

    @Test func aheadRoomFollowsTheDayAndTheCap() {
        let ledger = CloudAutoLedger(monthStartMs: 0, spentMicroUSD: 1_000, dayStartMs: 0, dayCount: 23)
        #expect(CloudLibraryAhead.room(outstanding: 0, ledger: ledger, dailyAhead: 25, capMicroUSD: nil, estimateMicroUSD: 10) == 2)
        #expect(CloudLibraryAhead.room(outstanding: 2, ledger: ledger, dailyAhead: 25, capMicroUSD: nil, estimateMicroUSD: 10) == 1)
        #expect(CloudLibraryAhead.room(outstanding: 3, ledger: ledger, dailyAhead: 25, capMicroUSD: nil, estimateMicroUSD: 10) == 0)
        #expect(CloudLibraryAhead.room(outstanding: 0, ledger: ledger, dailyAhead: 23, capMicroUSD: nil, estimateMicroUSD: 10) == 0)
        #expect(CloudLibraryAhead.room(outstanding: 0, ledger: ledger, dailyAhead: 25, capMicroUSD: 1_005, estimateMicroUSD: 10) == 0)
    }

    // MARK: The stream the audio came from

    @Test func sourceNamesTheStream() {
        #expect(CloudLibrarySourceFormat.itag("251") == 251)
        #expect(CloudLibrarySourceFormat.itag("x") == nil && CloudLibrarySourceFormat.itag(nil) == nil)
        #expect(CloudLibrarySourceFormat.codec(itag: 251, contentType: nil) == "opus")
        #expect(CloudLibrarySourceFormat.codec(itag: 140, contentType: "audio/webm") == "aac")
        #expect(CloudLibrarySourceFormat.codec(itag: nil, contentType: "audio/mp4; codecs=\"mp4a.40.2\"") == "aac")
        #expect(CloudLibrarySourceFormat.codec(itag: nil, contentType: "audio/webm; codecs=\"opus\"") == "opus")
        #expect(CloudLibrarySourceFormat.codec(itag: nil, contentType: nil) == nil)
        #expect(CloudLibrarySource.known(itag: nil, codec: nil) == nil)
        #expect(CloudLibrarySource.known(itag: 140, codec: "aac") == CloudLibrarySource(itag: 140, codec: "aac"))
        #expect(CloudLibrarySource.known(itag: nil, codec: String(repeating: "x", count: 40))?.codec?.count == 16)
    }

    @Test func libraryRecordsStaySmallAndShortLived() throws {
        var info = CloudLibraryJobInfo(videoId: Self.videoId, profiles: [.studio])
        info.manifests = ["studio": try CloudLibraryManifest.decode(CloudFixtures.worker("library.render.spatial"))]
        info.downloading = "studio"
        info.markImported(.studio)
        #expect(info.manifests == nil && info.downloading == nil)
        var record = Self.exampleRecord()
        record.state = .imported
        record.importedAtMs = 0
        #expect(!CloudRetention.shouldPrune(record, nowMs: 86_400_000))
        #expect(CloudRetention.shouldPrune(record, nowMs: 86_400_001))
        record.state = .failed
        record.updatedAtMs = 0
        #expect(!CloudRetention.shouldPrune(record, nowMs: 3 * 86_400_000))
        #expect(CloudRetention.shouldPrune(record, nowMs: 3 * 86_400_000 + 1))
        // Sing's jobs keep their 30 days.
        var sing = CloudBuilderTests.uploadedRecord()
        sing.state = .imported
        sing.importedAtMs = 0
        #expect(!CloudRetention.shouldPrune(sing, nowMs: 86_400_001))
    }

    @Test func aCappedLibraryJobIsNotMoreToCome() {
        // While the library's cap holds a render back, a burst's last jobs still tell their workers to stop.
        let held = Self.job(.queued) { $0.heldByCap = true }
        #expect(!CloudBurstEnd.moreComing([held], nowMs: 0, autoBlocked: false))
        #expect(CloudBurstEnd.moreComing([Self.job(.queued)], nowMs: 0, autoBlocked: false))
        // The background queue's jobs wait with Sing's songs prepared ahead while the phone isn't ready.
        #expect(!CloudBurstEnd.moreComing([Self.job(.queued, ahead: true)], nowMs: 0, autoBlocked: true))
    }

    @Test func lookupHitSkipsTheUpload() {
        // A library job found in the shared library goes from preparing straight to its results.
        #expect(CloudJobMachine.next(.preparing, on: .resultsReady) == .resultsReady)
        #expect(CloudJobMachine.next(.queued, on: .resultsReady) == nil)
    }

    @Test func recordsWithLibraryFieldsRoundTrip() throws {
        var record = Self.exampleRecord()
        record.libraryReservedMicroUSD = 15_360
        record.library?.renders = ["studio": "ok"]
        record.library?.manifests = ["studio": try CloudLibraryManifest.decode(CloudFixtures.worker("library.render.spatial"))]
        record.library?.downloading = "studio"
        let data = try JSONEncoder().encode([record])
        let decoded = try JSONDecoder().decode([CloudJobRecord].self, from: data)
        #expect(decoded == [record])
        #expect(decoded[0].effectiveOrigin == .library)
        // A record stored before these fields existed still reads (and is no library job).
        let old = try JSONDecoder().decode([CloudJobRecord].self, from: JSONEncoder().encode([CloudBuilderTests.uploadedRecord()]))
        #expect(old[0].library == nil && !old[0].isLibraryJob)
    }
}

/// Job keys for these tests (`CloudKeys.isValidJobKey`).
enum CloudTestKeys {
    static func key(_ n: Int) -> String {
        let digits = String(n)
        return "6f1c2a9e-3b7d-4c11-9a0e-" + String(repeating: "0", count: max(12 - digits.count, 0)) + digits
    }
}
