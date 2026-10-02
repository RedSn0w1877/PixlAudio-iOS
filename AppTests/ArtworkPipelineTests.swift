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
