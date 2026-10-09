import PixlLibrary
import UIKit
import XCTest
@testable import PixlAudio

/// Embedded art is cached per picture, not per audio file (docs/performance.md): an album's tracks share one cache
/// entry, one decode, one disk thumbnail and one stored colour theme.
final class EmbeddedArtworkIdentityTests: XCTestCase {
    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private func png(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }
    }

    /// Files nobody has seen: each test uses its own, so the shared index never carries one test into another.
    private func trackURLs(_ count: Int) -> [URL] {
        let folder = UUID().uuidString
        return (0..<count).map { URL(string: "file:///identity-tests/\(folder)/\($0).mp3")! }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testTheDigestIsPerPictureAndStable() {
        let red = png(.systemRed), blue = png(.systemBlue)
        XCTAssertEqual(EmbeddedArtworkIdentity.digest(of: red), EmbeddedArtworkIdentity.digest(of: red))
        XCTAssertNotEqual(EmbeddedArtworkIdentity.digest(of: red), EmbeddedArtworkIdentity.digest(of: blue))
        XCTAssertEqual(EmbeddedArtworkIdentity.digest(of: red).count, 32)
    }

    func testTheTracksOfAnAlbumShareOneCacheKey() {
        let urls = trackURLs(12)
        let digest = EmbeddedArtworkIdentity.digest(of: png(.systemRed))
        XCTAssertEqual(ArtworkSource.embedded(urls[0]).cacheKey, "e:" + urls[0].absoluteString, "unknown files keep their key")
        for url in urls { EmbeddedArtworkIdentity.shared.record(digest, for: url) }
        XCTAssertEqual(Set(urls.map { ArtworkSource.embedded($0).cacheKey }), ["c:" + digest])
        let other = trackURLs(1)[0]
        EmbeddedArtworkIdentity.shared.record(EmbeddedArtworkIdentity.digest(of: png(.systemBlue)), for: other)
        XCTAssertNotEqual(ArtworkSource.embedded(other).cacheKey, "c:" + digest, "another picture, another key")
    }

    func testTheIndexSurvivesARelaunch() throws {
        let store = try temporaryDirectory().appendingPathComponent("identity.plist")
        let url = trackURLs(1)[0]
        let first = EmbeddedArtworkIdentity(storeURL: store)
        first.record("abc123", for: url)
        first.flushNow()
        let second = EmbeddedArtworkIdentity(storeURL: store)
        XCTAssertEqual(second.digest(for: url), "abc123")
        XCTAssertNil(second.digest(for: trackURLs(1)[0]))
    }

    /// 12 tracks of one album, the scan has told us they share a picture: one read of the picture, one decode, one file.
    func testAKnownAlbumIsDecodedOnce() async throws {
        let urls = trackURLs(12)
        let data = png(.systemTeal)
        let digest = EmbeddedArtworkIdentity.digest(of: data)
        for url in urls { EmbeddedArtworkIdentity.shared.record(digest, for: url) }
        let reads = Counter()
        let saved = ArtworkPipeline.embeddedArtworkLoader
        ArtworkPipeline.embeddedArtworkLoader = { _ in
            await reads.increment()
            return data
        }
        defer { ArtworkPipeline.embeddedArtworkLoader = saved }
        let cache = try temporaryDirectory()
        let pipeline = ArtworkPipeline(diskDirectory: cache)

        let start = ContinuousClock.now
        let images = await withTaskGroup(of: ArtworkImage?.self) { group in
            for url in urls { group.addTask { await pipeline.image(.embedded(url), pixelSize: 180) } }
            var result: [ArtworkImage?] = []
            for await image in group { result.append(image) }
            return result
        }
        let elapsed = ContinuousClock.now - start
        print("measured [artwork.album12.sharedCover] \(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) s")
        XCTAssertEqual(images.compactMap { $0 }.count, 12)
        let readCount = await reads.value
        XCTAssertEqual(readCount, 1, "one read of the picture for the whole album (12 before)")
        let decodes = await pipeline.decodesRun
        XCTAssertEqual(decodes, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".jpg") }
        XCTAssertEqual(files.count, 1, "one thumbnail on disk (12 before)")
    }

    /// An album scanned before the index existed: each track's bytes are read once to learn the picture, but only the
    /// first is decoded and written; the rest find the picture's thumbnail.
    func testAnUnindexedAlbumLearnsItsPictureAndWritesOneThumbnail() async throws {
        let urls = trackURLs(6)
        let data = png(.systemPurple)
        let reads = Counter()
        let saved = ArtworkPipeline.embeddedArtworkLoader
        ArtworkPipeline.embeddedArtworkLoader = { _ in
            await reads.increment()
            return data
        }
        defer { ArtworkPipeline.embeddedArtworkLoader = saved }
        let cache = try temporaryDirectory()
        let pipeline = ArtworkPipeline(diskDirectory: cache)
        for url in urls {
            let image = await pipeline.image(.embedded(url), pixelSize: 180)
            XCTAssertNotNil(image)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".jpg") }
        XCTAssertEqual(files.count, 1, "one thumbnail for six tracks")
        let digest = EmbeddedArtworkIdentity.digest(of: data)
        XCTAssertEqual(Set(urls.map { ArtworkSource.embedded($0).cacheKey }), ["c:" + digest], "every track learned its picture")
        // A second pass is all memory hits: nothing is read again.
        let readsBefore = await reads.value
        for url in urls { _ = await pipeline.image(.embedded(url), pixelSize: 180) }
        let readsAfter = await reads.value
        XCTAssertEqual(readsAfter, readsBefore)
    }

    /// A theme stored under the per-file key by an earlier build answers for the picture's key, and is promoted.
    func testAThemeStoredUnderThePerFileKeyIsFoundUnderThePictureKey() async throws {
        let persistence = PersistenceActor(modelContainer: try PersistenceActor.makeContainer(inMemory: true))
        let url = trackURLs(1)[0]
        let style = ArtworkPaletteStyle.default, accuracy = ArtworkColorAccuracy.default
        let palette = ArtworkTheme.paletteCacheKey(style: style, accuracyLevel: accuracy)
        let pair = ArtworkTheme.accentPair(seed: 0xFF00_C7BE)
        let legacy = ArtworkSource.embedded(url)
        try await persistence.saveArtworkTheme(key: legacy.cacheKey + "|" + palette, artworkKey: legacy.cacheKey,
                                               paletteKey: palette, pair: pair)
        let digest = EmbeddedArtworkIdentity.digest(of: png(.systemYellow))
        EmbeddedArtworkIdentity.shared.record(digest, for: url)
        let source = ArtworkSource.embedded(url)
        XCTAssertEqual(source.cacheKey, "c:" + digest)

        // No loader is installed: finding the theme proves nothing was extracted.
        let extractor = ColorExtractor(pipeline: ArtworkPipeline(diskDirectory: nil), persistence: persistence)
        let found = await extractor.schemePair(for: source, style: style, accuracyLevel: accuracy)
        XCTAssertEqual(found, pair)
        let promoted = try await persistence.artworkTheme(key: "c:" + digest + "|" + palette)
        XCTAssertEqual(promoted, pair)
    }

    /// The launch warm-up gives a card of a file with a known picture its colours from the per-file rows too.
    func testWarmAnswersForThePictureKeyFromPerFileRows() async throws {
        let persistence = PersistenceActor(modelContainer: try PersistenceActor.makeContainer(inMemory: true))
        let url = trackURLs(1)[0]
        let style = ArtworkPaletteStyle.default, accuracy = ArtworkColorAccuracy.default
        let palette = ArtworkTheme.paletteCacheKey(style: style, accuracyLevel: accuracy)
        let pair = ArtworkTheme.accentPair(seed: 0xFFFF_453A)
        let legacyKey = "e:" + url.absoluteString
        try await persistence.saveArtworkTheme(key: legacyKey + "|" + palette, artworkKey: legacyKey, paletteKey: palette,
                                               pair: pair)
        let digest = EmbeddedArtworkIdentity.digest(of: png(.systemGreen))
        EmbeddedArtworkIdentity.shared.record(digest, for: url)
        let extractor = ColorExtractor(pipeline: ArtworkPipeline(diskDirectory: nil), persistence: persistence)
        XCTAssertNil(extractor.peek(.embedded(url), style: style, accuracyLevel: accuracy))
        await extractor.warm(style: style, accuracyLevel: accuracy)
        XCTAssertEqual(extractor.peek(.embedded(url), style: style, accuracyLevel: accuracy), pair)
    }
}
