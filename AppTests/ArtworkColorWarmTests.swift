import Foundation
import PixlLibrary
import PixlModel
import XCTest
@testable import PixlAudio

/// Album colours at launch (docs/performance.md): the synchronous scheme mirror is filled from the stored themes in
/// one batched read, so cards and pills start with their colours instead of the brand tint followed by a re-theme;
/// the restored song is themed before it appears.
final class ArtworkColorWarmTests: XCTestCase {
    private let style = ArtworkPaletteStyle.default
    private let accuracy = ArtworkColorAccuracy.default
    private var paletteKey: String { ArtworkTheme.paletteCacheKey(style: style, accuracyLevel: accuracy) }

    private func makePersistence() throws -> PersistenceActor {
        PersistenceActor(modelContainer: try PersistenceActor.makeContainer(inMemory: true))
    }

    private func store(_ persistence: PersistenceActor, seeds: Range<Int>, pair: ColorRolesPair,
                       paletteKey: String? = nil) async throws -> [ArtworkSource] {
        var sources: [ArtworkSource] = []
        for seed in seeds {
            let source = ArtworkSource.generated(seed: seed)
            sources.append(source)
            let palette = paletteKey ?? self.paletteKey
            try await persistence.saveArtworkTheme(key: source.cacheKey + "|" + palette, artworkKey: source.cacheKey,
                                                   paletteKey: palette, pair: pair)
        }
        return sources
    }

    func testWarmFillsTheMirrorFromTheStoreInOneRead() async throws {
        let persistence = try makePersistence()
        let pair = ArtworkTheme.brandPair
        let sources = try await store(persistence, seeds: 0..<1_500, pair: pair)
        let extractor = ColorExtractor(pipeline: ArtworkPipeline(diskDirectory: nil), persistence: persistence)
        XCTAssertNil(extractor.peek(sources[0], style: style, accuracyLevel: accuracy), "a fresh launch starts empty")

        let start = ContinuousClock.now
        await extractor.warm(style: style, accuracyLevel: accuracy)
        let elapsed = ContinuousClock.now - start
        print("measured [colorExtractor.warm.1500] \(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) s")

        for source in sources {
            XCTAssertEqual(extractor.peek(source, style: style, accuracyLevel: accuracy), pair)
        }
    }

    func testWarmOnlyLoadsThePalettesThemes() async throws {
        let persistence = try makePersistence()
        let pair = ArtworkTheme.brandPair
        let other = try await store(persistence, seeds: 0..<5, pair: pair, paletteKey: "other-style|accuracy_7|algo_v7")
        let current = try await store(persistence, seeds: 10..<15, pair: pair)
        let extractor = ColorExtractor(pipeline: ArtworkPipeline(diskDirectory: nil), persistence: persistence)
        await extractor.warm(style: style, accuracyLevel: accuracy)
        XCTAssertNotNil(extractor.peek(current[0], style: style, accuracyLevel: accuracy))
        XCTAssertNil(extractor.peek(other[0], style: style, accuracyLevel: accuracy))
    }

    func testWarmNeverReplacesWhatTheSessionProduced() async throws {
        let persistence = try makePersistence()
        let stored = ArtworkTheme.brandPair
        let sources = try await store(persistence, seeds: 0..<1, pair: stored)
        let extractor = ColorExtractor(pipeline: ArtworkPipeline(diskDirectory: nil), persistence: persistence)
        let fresh = ArtworkTheme.accentPair(seed: 0xFFFF_453A)
        XCTAssertNotEqual(fresh, stored)
        extractor.mirror.insert(fresh, for: sources[0].cacheKey + "|" + paletteKey)
        await extractor.warm(style: style, accuracyLevel: accuracy)
        XCTAssertEqual(extractor.peek(sources[0], style: style, accuracyLevel: accuracy), fresh)
    }

    func testAThemeDroppedByInvalidateStaysDropped() async throws {
        let persistence = try makePersistence()
        let sources = try await store(persistence, seeds: 0..<3, pair: ArtworkTheme.brandPair)
        let extractor = ColorExtractor(pipeline: ArtworkPipeline(diskDirectory: nil), persistence: persistence)
        await extractor.warm(style: style, accuracyLevel: accuracy)
        await extractor.invalidate(sources[1])
        XCTAssertNil(extractor.peek(sources[1], style: style, accuracyLevel: accuracy))
        XCTAssertNotNil(extractor.peek(sources[0], style: style, accuracyLevel: accuracy))
    }

    func testSavedThemesAreReadableBeforeTheCoalescedSaveLands() async throws {
        let persistence = try makePersistence()
        let pair = ArtworkTheme.brandPair
        let sources = try await store(persistence, seeds: 0..<50, pair: pair)
        for source in sources {
            let stored = try await persistence.artworkTheme(key: source.cacheKey + "|" + paletteKey)
            XCTAssertEqual(stored, pair)
        }
    }

    @MainActor
    func testTheRestoredSongIsThemedBeforeItAppearsFromTheStore() async throws {
        let persistence = try makePersistence()
        let pair = ArtworkTheme.accentPair(seed: 0xFF00_C7BE)
        let song = try XCTUnwrap(DemoLibrary.snapshot.songs.first)
        let source = try XCTUnwrap(ArtworkSource(song: song))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pixlaudio.colorwarm.\(UUID().uuidString)"))
        let appearance = AppearanceSettings(defaults: defaults)
        let key = source.cacheKey + "|" + ArtworkTheme.paletteCacheKey(style: appearance.paletteStyle,
                                                                      accuracyLevel: appearance.colorAccuracy)
        let palette = ArtworkTheme.paletteCacheKey(style: appearance.paletteStyle, accuracyLevel: appearance.colorAccuracy)
        try await persistence.saveArtworkTheme(key: key, artworkKey: source.cacheKey, paletteKey: palette, pair: pair)

        let theme = ThemeStore(extractor: ColorExtractor(pipeline: ArtworkPipeline(diskDirectory: nil),
                                                         persistence: persistence), appearance: appearance)
        XCTAssertNil(theme.albumPair)
        await theme.seed(for: song)
        XCTAssertEqual(theme.albumPair, pair, "the first frame of the mini player has its colours")
        await theme.update(for: song)
        XCTAssertEqual(theme.albumPair, pair, "the shell's own update has nothing left to do")
    }

    @MainActor
    func testSeedingNeverExtractsAndLeavesAnUnknownSongAlone() async throws {
        let persistence = try makePersistence()
        let song = try XCTUnwrap(DemoLibrary.snapshot.songs.first)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pixlaudio.colorwarm.\(UUID().uuidString)"))
        let theme = ThemeStore(extractor: ColorExtractor(pipeline: ArtworkPipeline(diskDirectory: nil),
                                                         persistence: persistence),
                               appearance: AppearanceSettings(defaults: defaults))
        await theme.seed(for: song)
        XCTAssertNil(theme.albumPair, "nothing stored: the normal update extracts it later")
    }
}
