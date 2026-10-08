import AVFoundation
import Foundation
import XCTest
@testable import PixlAudio

/// Cloud Studio's upload preparation (design §1 step 1, §7.1, §7.6 "preparer passthrough decisions"): AAC-LC M4A is
/// uploaded unchanged, everything else is decoded on the phone and written as FLAC at 44.1 kHz stereo; the SHA-256
/// and the frame count describe exactly the uploaded bytes. Files are generated at test time.
final class CloudAudioPreparerTests: XCTestCase {
    private var temporary: URL!
    private var jobKeys: [String] = []

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CloudAudioPreparerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for key in jobKeys { CloudAudioPreparer.removeUpload(jobKey: key) }
        try? FileManager.default.removeItem(at: temporary)
    }

    private func newJobKey() -> String {
        let key = UUID().uuidString.lowercased()
        jobKeys.append(key)
        return key
    }

    func testRouteDecisions() {
        typealias P = CloudAudioPreparer
        // AAC-LC in an MP4 container with one audio track: as it is.
        XCTAssertEqual(P.route(isLibraryItem: false, fileExtension: "m4a", audioTrackCount: 1, videoTrackCount: 0,
                               formatID: kAudioFormatMPEG4AAC, sourceSampleRate: 44_100), .copy)
        XCTAssertEqual(P.route(isLibraryItem: false, fileExtension: "MP4", audioTrackCount: 1, videoTrackCount: 0,
                               formatID: kAudioFormatMPEG4AAC, sourceSampleRate: 48_000), .copy)
        // A music-library AAC item: passthrough export.
        XCTAssertEqual(P.route(isLibraryItem: true, fileExtension: "m4a", audioTrackCount: 1, videoTrackCount: 0,
                               formatID: kAudioFormatMPEG4AAC, sourceSampleRate: 44_100), .exportPassthrough)
        // HE-AAC (itag 139), muxed video (itag 18), MP3, ALAC, raw ADTS, two audio tracks, implicit-SBR rates: decode.
        XCTAssertEqual(P.route(isLibraryItem: false, fileExtension: "m4a", audioTrackCount: 1, videoTrackCount: 0,
                               formatID: kAudioFormatMPEG4AAC_HE, sourceSampleRate: 44_100), .decode)
        XCTAssertEqual(P.route(isLibraryItem: false, fileExtension: "mp4", audioTrackCount: 1, videoTrackCount: 1,
                               formatID: kAudioFormatMPEG4AAC, sourceSampleRate: 44_100), .decode)
        XCTAssertEqual(P.route(isLibraryItem: false, fileExtension: "mp3", audioTrackCount: 1, videoTrackCount: 0,
                               formatID: kAudioFormatMPEGLayer3, sourceSampleRate: 44_100), .decode)
        XCTAssertEqual(P.route(isLibraryItem: true, fileExtension: "m4a", audioTrackCount: 1, videoTrackCount: 0,
                               formatID: kAudioFormatAppleLossless, sourceSampleRate: 44_100), .decode)
        XCTAssertEqual(P.route(isLibraryItem: false, fileExtension: "aac", audioTrackCount: 1, videoTrackCount: 0,
                               formatID: kAudioFormatMPEG4AAC, sourceSampleRate: 44_100), .decode)
        XCTAssertEqual(P.route(isLibraryItem: false, fileExtension: "m4a", audioTrackCount: 2, videoTrackCount: 0,
                               formatID: kAudioFormatMPEG4AAC, sourceSampleRate: 44_100), .decode)
        XCTAssertEqual(P.route(isLibraryItem: false, fileExtension: "m4a", audioTrackCount: 1, videoTrackCount: 0,
                               formatID: kAudioFormatMPEG4AAC, sourceSampleRate: 22_050), .decode)
        XCTAssertEqual(P.route(isLibraryItem: false, fileExtension: "m4a", audioTrackCount: 1, videoTrackCount: 0,
                               formatID: nil, sourceSampleRate: nil), .decode)
    }

    func testAACM4AIsUploadedUnchanged() async throws {
        let source = temporary.appendingPathComponent("song.m4a")
        try TestAudioFiles.writeM4A(to: source, seconds: 2)
        let key = newJobKey()
        let prepared = try await CloudAudioPreparer.prepare(source: source, jobKey: key)
        XCTAssertTrue(prepared.passthrough)
        XCTAssertEqual(prepared.ext, "m4a")
        XCTAssertEqual(prepared.fileURL.lastPathComponent, "\(key).m4a")
        XCTAssertEqual(try Data(contentsOf: prepared.fileURL), try Data(contentsOf: source))
        XCTAssertEqual(prepared.sha256, try ModelManager.sha256Hex(of: source))
        XCTAssertEqual(prepared.sha256.count, 64)
        XCTAssertEqual(prepared.bytes, Int64(try Data(contentsOf: source).count))
        XCTAssertEqual(prepared.sampleRate, 44_100)
        // About 2 s of frames (whether or not the encoder's priming is trimmed is not the point here).
        XCTAssertEqual(Double(prepared.frames), 88_200, accuracy: 4_096)
        XCTAssertEqual(Double(prepared.durationMs), 2_000, accuracy: 100)
    }

    func testWAVIsDecodedToFLACAtTheWorkersRate() async throws {
        let source = temporary.appendingPathComponent("tone.wav")
        try TestToneWriter.makeWAV(seconds: 3).write(to: source)
        let key = newJobKey()
        let prepared = try await CloudAudioPreparer.prepare(source: source, jobKey: key)
        XCTAssertFalse(prepared.passthrough)
        XCTAssertEqual(prepared.ext, "flac", "this iOS couldn't encode FLAC; the preparer fell back to \(prepared.ext)")
        XCTAssertEqual(prepared.fileURL.lastPathComponent, "\(key).\(prepared.ext)")
        let file = try AVAudioFile(forReading: prepared.fileURL)
        let framesPerPacket = file.fileFormat.streamDescription.pointee.mFramesPerPacket
        let note = "frames \(prepared.frames), FLAC frames per packet \(framesPerPacket)"
        // PCM in, lossless out: the source's frames (44.1 kHz mono, upmixed to stereo), then less than one FLAC
        // packet of silence so the file ends on a whole packet (CI once read this 3-second tone back as
        // 133,632 = 29 × 4,608 frames while 132,300 were written: the encoder had padded the short last packet).
        XCTAssertGreaterThanOrEqual(prepared.frames, 3 * 44_100, note)
        XCTAssertLessThan(prepared.frames, 3 * 44_100 + 8_192, note)
        XCTAssertEqual(Double(prepared.durationMs), 3_000, accuracy: 200, note)
        XCTAssertEqual(prepared.sha256, try ModelManager.sha256Hex(of: prepared.fileURL))
        // The written file decodes back to exactly the recorded length: what the import's sample check compares.
        let counted = try await CloudAudioPreparer.countFrames(of: prepared.fileURL)
        XCTAssertEqual(counted, prepared.frames, note)
        // Stereo at 44.1 kHz.
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        // Lossless and 16-bit: well under the 32-bit float size.
        XCTAssertLessThan(prepared.bytes, Int64(3 * 44_100 * 2 * 4))
    }

    func testPreparingAgainReplacesTheEarlierFile() async throws {
        let source = temporary.appendingPathComponent("tone.wav")
        try TestToneWriter.makeWAV(seconds: 1).write(to: source)
        let key = newJobKey()
        let first = try await CloudAudioPreparer.prepare(source: source, jobKey: key)
        let second = try await CloudAudioPreparer.prepare(source: source, jobKey: key)
        XCTAssertEqual(first.fileURL, second.fileURL)
        XCTAssertEqual(first.sha256, second.sha256)
        let directory = try CloudAudioPreparer.uploadsDirectory()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(key) }
        XCTAssertEqual(files, [second.fileURL.lastPathComponent])
        CloudAudioPreparer.removeUpload(jobKey: key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.fileURL.path))
    }

    func testBadInputsAreRefused() async throws {
        let source = temporary.appendingPathComponent("tone.wav")
        try TestToneWriter.makeWAV(seconds: 1).write(to: source)
        do {
            _ = try await CloudAudioPreparer.prepare(source: source, jobKey: "../not-a-job-key")
            XCTFail("a malformed job key must be refused")
        } catch {}
        XCTAssertNil(try CloudAudioPreparer.uploadURL(jobKey: "../x", ext: "flac"))
        XCTAssertNil(try CloudAudioPreparer.uploadURL(jobKey: newJobKey(), ext: "exe"))
        let notAudio = temporary.appendingPathComponent("notes.m4a")
        try Data("not audio".utf8).write(to: notAudio)
        do {
            _ = try await CloudAudioPreparer.prepare(source: notAudio, jobKey: newJobKey())
            XCTFail("a file without audio must be refused")
        } catch {}
    }

    func testTransferTaskDescriptions() {
        let key = UUID().uuidString.lowercased()
        let description = CloudTransfers.taskDescription(jobKey: key, slot: "instrumental")
        XCTAssertEqual(description, "\(key)|instrumental")
        XCTAssertEqual(CloudTransfers.parse(description)?.jobKey, key)
        XCTAssertEqual(CloudTransfers.parse(description)?.slot, "instrumental")
        XCTAssertNil(CloudTransfers.parse("\(key)|../x"))
        XCTAssertNil(CloudTransfers.parse("NOT-A-KEY|input"))
        XCTAssertNil(CloudTransfers.parse(nil))
        XCTAssertEqual(try CloudTransfers.stagedURL(jobKey: key, slot: "instrumental",
                                                    sourceURL: URL(string: "https://h/b/out/\(key)/instrumental.m4a?X-Amz-Signature=a"))?
                           .lastPathComponent, "\(key)-instrumental.m4a")
        XCTAssertNil(try CloudTransfers.stagedURL(jobKey: "bad", slot: "instrumental", sourceURL: nil))
    }
}
