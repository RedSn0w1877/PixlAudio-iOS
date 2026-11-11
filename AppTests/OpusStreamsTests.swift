import AVFoundation
import Foundation
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// The iOS Opus upgrade on the simulator: the system decoder reads the repackaged file (format, duration, a full
/// decode to the valid samples, AVPlayer plays it), and the store and resolver around it (order, recovery, memory).
/// Nothing here touches the network.
@MainActor
final class OpusStreamsTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        try await super.tearDown()
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("opus-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func remuxedFixture() throws -> (url: URL, summary: OpusRemuxer.Summary) {
        let webm = try XCTUnwrap(OpusTestFixture.webm)
        let output = try OpusRemuxer.remux(webm: webm)
        XCTAssertEqual(output.summary.validSamples, 48_000)
        XCTAssertEqual(output.summary.preSkip, 312)
        let url = temporaryDirectory().appendingPathComponent("dQw4w9WgXcQ.check.mp4")
        try output.mp4.write(to: url)
        return (url, output.summary)
    }

    // MARK: The system decoder

    func testTheSystemDecoderReadsTheRepackagedFileExactly() async throws {
        let (url, summary) = try remuxedFixture()
        let report: OpusPlaybackCheck.Report
        do {
            report = try await OpusPlaybackCheck.verify(fileURL: url, summary: summary)
        } catch {
            XCTFail("The check refused the file: \(error.localizedDescription)")
            return
        }
        // AVAssetReader cuts the pre-skip and may decode the last packet whole (648 padded frames).
        XCTAssertTrue([48_000, 48_648].contains(report.decodedFrames), "decoded \(report.decodedFrames) frames")
        XCTAssertEqual(report.durationSeconds, 1.0, accuracy: 0.0005)
        XCTAssertGreaterThan(report.peak, 1_000)
    }

    /// Positions line up sample for sample: the system decoder's output matches ffmpeg's decode of the WebM (which
    /// cuts the pre-skip from CodecDelay) at the reference frames; an uncut pre-skip would be 312 frames late.
    func testTheDecodeStartsOnTheSameSampleAsTheWebM() async throws {
        let (url, _) = try remuxedFixture()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var left: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Int16](repeating: 0, count: length / 2)
            _ = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            left += stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
        }
        XCTAssertEqual(reader.status, .completed)
        for (frame, value) in OpusTestFixture.referenceLeft {
            XCTAssertLessThan(frame, left.count)
            guard frame < left.count else { continue }
            XCTAssertEqual(Int(left[frame]), value, accuracy: 64, "frame \(frame)")
        }
    }

    func testThePlayerOpensAndPlaysTheFile() async throws {
        let (url, _) = try remuxedFixture()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        let ready = Date().addingTimeInterval(10)
        while item.status == .unknown, Date() < ready { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(item.status, .readyToPlay, "item error: \(String(describing: item.error))")
        XCTAssertEqual(item.duration.seconds, 1.0, accuracy: 0.0005)
        player.play()
        let playing = Date().addingTimeInterval(5)
        while player.currentTime().seconds < 0.2, Date() < playing { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 0.2, "playback did not advance")
        XCTAssertNil(item.error)
        player.pause()
        // Seeking lands where asked (the roll groups give the decoder its 80 ms pre-roll).
        let target = CMTime(value: 24_000, timescale: 48_000)
        _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertEqual(player.currentTime().seconds, 0.5, accuracy: 0.001)
    }

    func testAFileThatIsNotOpusIsRefused() async throws {
        let (url, summary) = try remuxedFixture()
        var wrong = summary
        wrong.validSamples = 96_000   // claims 2 s
        do {
            _ = try await OpusPlaybackCheck.verify(fileURL: url, summary: wrong)
            XCTFail("a wrong length must be refused")
        } catch let failure as OpusPlaybackCheck.Failure {
            guard case .wrongDuration = failure else { return XCTFail("unexpected \(failure)") }
        }
        let garbage = temporaryDirectory().appendingPathComponent("x.mp4")
        try Data(repeating: 7, count: 4096).write(to: garbage)
        do {
            _ = try await OpusPlaybackCheck.verify(fileURL: garbage, summary: summary)
            XCTFail("garbage must be refused")
        } catch {}
    }

    // MARK: Store and resolver

    private func song(_ videoId: String) -> Song {
        var song = DemoLibrary.songs[0]
        song.id = "yt:\(videoId)"
        song.contentUriString = "pixlstream://\(videoId)"
        return song
    }

    func testResolverOrderPutsTheOpusFileBeforeTheAACCache() async throws {
        let id = "Zz9_-Zz9_-Z"
        let cache = StreamCache(directory: temporaryDirectory())
        let store = OpusStreamStore(directory: temporaryDirectory())
        let resolver = StreamingPlayableURLResolver(base: DefaultPlayableURLResolver(), cache: cache, opus: store)
        let streamed = await resolver.playableURL(for: song(id))
        XCTAssertEqual(streamed?.absoluteString, "pixlstream://\(id)")
        await cache.setInfo(id, contentLength: 2, contentType: "audio/mp4", itag: "140")
        await cache.write(id, offset: 0, data: Data([1, 2]))
        let cached = await resolver.playableURL(for: song(id))
        XCTAssertEqual(cached?.lastPathComponent, "\(id).m4a")
        try Data([0]).write(to: store.fileURL(videoId: id))
        let opus = await resolver.playableURL(for: song(id))
        XCTAssertEqual(opus, store.fileURL(videoId: id))
        XCTAssertEqual(store.videoId(ofFile: try XCTUnwrap(opus)), id)
        XCTAssertNil(store.videoId(ofFile: try XCTUnwrap(cached)))
        XCTAssertNil(store.videoId(ofFile: try XCTUnwrap(streamed)))
    }

    func testARefusedOpusFileGoesBackToAACForThatVideo() async throws {
        let id = "Zz9_-Zz9_-Z"
        let cache = StreamCache(directory: temporaryDirectory())
        let store = OpusStreamStore(directory: temporaryDirectory())
        let resolver = StreamingPlayableURLResolver(base: DefaultPlayableURLResolver(), cache: cache, opus: store)
        let file = store.fileURL(videoId: id)
        try Data([0]).write(to: file)
        let recovered = await resolver.recoverPlayableURL(for: song(id), afterFailedURL: file)
        XCTAssertEqual(recovered?.absoluteString, "pixlstream://\(id)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let claimed = await store.begin(videoId: id)
        XCTAssertFalse(claimed, "a refused video is not prepared again")
        let status = await store.statusLine(videoId: id, playingURL: nil, cache: cache)
        XCTAssertTrue(status.contains("the player could not open the file"), status)
        // Any other failed URL is the base resolver's business.
        let other = await resolver.recoverPlayableURL(for: song(id), afterFailedURL: URL(string: "pixlstream://\(id)")!)
        XCTAssertNil(other)
    }

    func testTheStoreRemembersFailuresButNotCancellations() async throws {
        let store = OpusStreamStore(directory: temporaryDirectory())
        let first = await store.begin(videoId: "aaaaaaaaaaa")
        XCTAssertTrue(first)
        let again = await store.begin(videoId: "aaaaaaaaaaa")
        XCTAssertFalse(again, "already running")
        await store.finish(videoId: "aaaaaaaaaaa", outcome: .skipped("cancelled"))
        let afterSkip = await store.begin(videoId: "aaaaaaaaaaa")
        XCTAssertTrue(afterSkip)
        await store.finish(videoId: "aaaaaaaaaaa", outcome: .failed(.remux, "odd file"))
        let afterFailure = await store.begin(videoId: "aaaaaaaaaaa")
        XCTAssertFalse(afterFailure)
        // The ledger survives a new store on the same folder (a relaunch).
        let reopened = OpusStreamStore(directory: store.directory)
        let afterRelaunch = await reopened.begin(videoId: "aaaaaaaaaaa")
        XCTAssertFalse(afterRelaunch)
        let status = await reopened.statusLine(videoId: "aaaaaaaaaaa", playingURL: nil, cache: nil)
        XCTAssertTrue(status.hasPrefix("AAC for this song: the WebM file could not be repackaged (odd file)"), status)
    }

    func testTheStatusLineNamesWhatPlays() async throws {
        let id = "Zz9_-Zz9_-Z"
        let cache = StreamCache(directory: temporaryDirectory())
        let store = OpusStreamStore(directory: temporaryDirectory())
        let claimed = await store.begin(videoId: id)
        XCTAssertTrue(claimed)
        try Data([0]).write(to: store.fileURL(videoId: id))
        await store.finish(videoId: id, outcome: .ready(.init(itag: 251, durationMs: 1000, bytes: 4_100_000, preparedAt: 0)))
        let line = await store.statusLine(videoId: id, playingURL: store.fileURL(videoId: id), cache: cache)
        XCTAssertEqual(line, "Playing now: Opus 48 kHz (itag 251), prepared file\n"
                       + "Opus file ready (itag 251, 4.1 MB): this song plays Opus from its next start.")
        await cache.setInfo(id, contentLength: 10, contentType: "audio/mp4", itag: "140")
        let streaming = await OpusStreamStore.describe(itemURL: URL(string: "pixlstream://\(id)")!, store: store, cache: cache)
        XCTAssertEqual(streaming, "AAC (itag 140), streaming")
    }
}
