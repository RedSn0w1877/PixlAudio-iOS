import AVFoundation
import CoreMedia
import Darwin
import XCTest
@testable import PixlAudio

/// Where an item join loses time, measured on the player clock (A's end and B's start extrapolated from
/// (host time, timebase position) samples). Raw players, no engine: AVQueuePlayer with and without the processing tap
/// and the spectral pitch algorithm, and two players handing over with `setRate(_:time:atHostTime:)`.
/// Diagnostics: results are printed (`gap-diagnostic:` lines); only the scheduled hand-over is asserted.
@MainActor
final class GaplessDiagnosticsTests: XCTestCase {
    private static let seconds = 1.5

    private func hostSeconds() -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_absolute_time()) * Double(info.numer) / Double(info.denom) / 1e9
    }

    private func position(_ item: AVPlayerItem) -> Double {
        if let timebase = item.timebase {
            let t = CMTimebaseGetTime(timebase)
            if t.isValid && t.isNumeric { return t.seconds }
        }
        let t = item.currentTime()
        return t.isValid && t.isNumeric ? t.seconds : 0
    }

    private func makeItem(_ url: URL, tap: Bool, spectral: Bool) async throws -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        if spectral { item.audioTimePitchAlgorithm = .spectral }
        if tap {
            let track = try XCTUnwrap(try await asset.loadTracks(withMediaType: .audio).first)
            item.audioMix = ProcessingTap.makeAudioMix(for: track, effects: AudioEffectsParameters(),
                                                       item: TapItemParameters())
        }
        return item
    }

    private func waitReady(_ item: AVPlayerItem) async -> Bool {
        await waitUntil(timeout: 5) { item.status == .readyToPlay }
    }

    /// Samples until B has played `until` seconds (or a timeout), returning the gap B start − A end, or nil.
    private func sampleGap(a: AVPlayerItem, b: AVPlayerItem, aIsActive: () -> Bool, bIsActive: () -> Bool,
                           until: Double = 0.6) async -> Double? {
        var aEnds: [Double] = [], bStarts: [Double] = []
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let host = hostSeconds()
            if aIsActive() {
                let p = position(a)
                if p > 0.2 && p < Self.seconds - 0.1 { aEnds.append(host + (Self.seconds - p)) }
            }
            if bIsActive() {
                let p = position(b)
                if p > 0.1 && p < until { bStarts.append(host - p) }
                if p >= until { break }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !aEnds.isEmpty, !bStarts.isEmpty else { return nil }
        return bStarts.sorted()[bStarts.count / 2] - aEnds.sorted()[aEnds.count / 2]
    }

    private func queueGap(tap: Bool, spectral: Bool) async throws -> Double? {
        let a = try await makeItem(try TestAudio.sine(frequency: 440, seconds: Self.seconds), tap: tap, spectral: spectral)
        let b = try await makeItem(try TestAudio.sine(frequency: 660, seconds: Self.seconds), tap: tap, spectral: spectral)
        let player = AVQueuePlayer(items: [a, b])
        defer { player.pause(); player.removeAllItems() }
        player.play()
        return await sampleGap(a: a, b: b, aIsActive: { player.currentItem === a },
                               bIsActive: { player.currentItem === b })
    }

    func testQueuePlayerJoins() async throws {
        let session = AudioSessionController()
        session.configure()
        _ = session.activate()
        var results: [String] = []
        for (tap, spectral) in [(false, false), (false, true), (true, false), (true, true)] {
            let gap = try await queueGap(tap: tap, spectral: spectral)
            results.append("queue tap=\(tap) spectral=\(spectral): \(gap.map { String(format: "%.3f s", $0) } ?? "n/a")")
        }
        for line in results { print("gap-diagnostic: \(line)") }
        // Temporary (diagnostic round): surface the numbers in the CI error summary.
        XCTFail("gap-diagnostic: " + results.joined(separator: " | "))
    }

    /// Two players with taps: B prerolls, then starts at A's end on the host clock.
    func testScheduledHandOverBetweenTwoPlayersIsGapless() async throws {
        let session = AudioSessionController()
        session.configure()
        _ = session.activate()
        let a = try await makeItem(try TestAudio.sine(frequency: 440, seconds: Self.seconds), tap: true, spectral: true)
        let b = try await makeItem(try TestAudio.sine(frequency: 660, seconds: Self.seconds), tap: true, spectral: true)
        let first = AVPlayer(playerItem: a), second = AVPlayer(playerItem: b)
        second.automaticallyWaitsToMinimizeStalling = false
        defer { first.pause(); second.pause() }
        first.play()
        guard await waitReady(a), await waitReady(b),
              await waitUntil(timeout: 5, { self.position(a) > 0.3 }) else {
            throw XCTSkip("the simulator rendered no audio")
        }
        let prerolled = await second.preroll(atRate: 1)
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let remaining = Self.seconds - position(a)
        let start = CMTimeAdd(now, CMTime(seconds: remaining, preferredTimescale: 1_000_000_000))
        second.setRate(1, time: .zero, atHostTime: start)
        let gap = await sampleGap(a: a, b: b, aIsActive: { true }, bIsActive: { true })
        print("gap-diagnostic: scheduled hand-over prerolled=\(prerolled) gap=\(gap.map { String(format: "%.3f s", $0) } ?? "n/a")")
        let measured = try XCTUnwrap(gap)
        XCTAssertEqual(measured, 0, accuracy: 0.03, "scheduled hand-over gap \(measured) s")
    }
}
