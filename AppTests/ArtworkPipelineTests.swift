import UIKit
import XCTest
@testable import PixlAudio

/// `ArtworkPipeline`'s disk tiers: a display size it has not decoded yet comes from a larger size already on disk,
/// without going back to the source; other sizes still need the source.
final class ArtworkPipelineTests: XCTestCase {
    func testASmallerDisplaySizeIsDecodedFromALargerCachedOne() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artwork-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cover = directory.appendingPathComponent("cover.png")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let side = 800.0
        let png = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        try png.write(to: cover)

        let pipeline = ArtworkPipeline(diskDirectory: directory.appendingPathComponent("cache", isDirectory: true))
        let large = await pipeline.image(.file(cover), pixelSize: 1320)
        XCTAssertEqual(large?.cgImage.width, 800, "a thumbnail never upscales")

        // The source is gone: the 540 px bucket can only come from the 1320 px file on disk.
        try FileManager.default.removeItem(at: cover)
        let derived = await pipeline.image(.file(cover), pixelSize: 540)
        XCTAssertEqual(derived?.cgImage.width, 540)

        // Sizes that are not display buckets (colour extraction's 128 px) still decode from the source only.
        let extraction = await pipeline.image(.file(cover), pixelSize: 128)
        XCTAssertNil(extraction)
    }
}

/// Cancellation and the decode limit (docs/performance.md): a cover nobody waits for any more is not decoded.
final class ArtworkPipelineCancellationTests: XCTestCase {
    private func pngData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    /// A fling: 60 covers asked for, then their views go. Only the decodes that already held a slot run.
    func testCancelledRequestsDoNotAllDecode() async throws {
        let png = pngData()
        let saved = ArtworkPipeline.embeddedArtworkLoader
        ArtworkPipeline.embeddedArtworkLoader = { _ in
            try? await Task.sleep(for: .milliseconds(80))
            return png
        }
        defer { ArtworkPipeline.embeddedArtworkLoader = saved }
        let pipeline = ArtworkPipeline(diskDirectory: nil)
        var tasks: [Task<ArtworkImage?, Never>] = []
        for index in 0..<60 {
            let source = ArtworkSource.embedded(URL(string: "file:///fling/\(index).mp3")!)
            tasks.append(Task { await pipeline.image(source, pixelSize: 180) })
        }
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        let ran = await pipeline.decodesRun
        print("measured [artwork.cancelledBurst.decodesRun] \(ran) of 60")
        XCTAssertLessThanOrEqual(ran, ArtworkPipeline.maxConcurrentDecodes + 3, "cancelled requests were decoded anyway")

        // The cancelled jobs did not poison the cover: asking again decodes it.
        let again = await pipeline.image(.embedded(URL(string: "file:///fling/0.mp3")!), pixelSize: 180)
        XCTAssertNotNil(again)
    }

    /// Two views want one cover; one goes away. The other still gets it.
    func testOneCancelledWaiterDoesNotCancelASharedDecode() async throws {
        let png = pngData()
        let saved = ArtworkPipeline.embeddedArtworkLoader
        ArtworkPipeline.embeddedArtworkLoader = { _ in
            try? await Task.sleep(for: .milliseconds(100))
            return png
        }
        defer { ArtworkPipeline.embeddedArtworkLoader = saved }
        let pipeline = ArtworkPipeline(diskDirectory: nil)
        let source = ArtworkSource.embedded(URL(string: "file:///shared/cover.mp3")!)
        let first = Task { await pipeline.image(source, pixelSize: 180) }
        let second = Task { await pipeline.image(source, pixelSize: 180) }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        let survivor = await second.value
        _ = await first.value
        XCTAssertNotNil(survivor, "the remaining view still gets its cover")
        let ran = await pipeline.decodesRun
        XCTAssertEqual(ran, 1, "one decode served both")
    }
}
