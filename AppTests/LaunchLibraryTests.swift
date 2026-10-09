import Foundation
import PixlModel
import XCTest
@testable import PixlAudio

/// Launch order (docs/performance.md): the cached snapshot is installed first, so the restored queue and the library
/// do not wait for the store's full read, which then only reconciles.
final class LaunchLibraryTests: XCTestCase {
    private var workDirectory: URL!
    private var persistence: PersistenceActor!
    private var cacheURL: URL!

    override func setUp() async throws {
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        cacheURL = workDirectory.appendingPathComponent("cache.plist")
        persistence = PersistenceActor(modelContainer: try PersistenceActor.makeContainer(inMemory: true))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private var loader: SnapshotLoader { SnapshotLoader(persistence: persistence, cacheURL: cacheURL) }

    /// The demo library in the store, and the snapshot the store reads back from it (what a previous launch cached).
    private func seed() async throws -> LibrarySnapshot {
        try await persistence.replaceLibrary(with: DemoLibrary.snapshot)
        return try await persistence.loadLibrarySnapshot()
    }

    @MainActor
    func testTheCachedLibraryIsInstalledBeforeTheStoreIsRead() async throws {
        let demo = try await seed()
        loader.writeCache(demo)
        let readsBefore = await persistence.fullLibraryReads

        let store = LibraryStore(loader: loader, importer: nil)
        let hadCache = await store.installCached()
        XCTAssertTrue(hadCache)
        XCTAssertEqual(store.songs.count, demo.songs.count)
        let first = try XCTUnwrap(demo.songs.first)
        XCTAssertEqual(store.song(id: first.id)?.title, first.title, "the queue restore looks songs up right away")
        XCTAssertTrue(store.isLoading, "loading ends with the reconcile")
        let readsAfterInstall = await persistence.fullLibraryReads
        XCTAssertEqual(readsAfterInstall, readsBefore, "the store has not been read yet")
        let revision = store.revision

        await store.reconcileWithStore()
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.revision, revision, "a store equal to the cache applies nothing")
        let readsAfterReconcile = await persistence.fullLibraryReads
        XCTAssertEqual(readsAfterReconcile, readsBefore + 1)
    }

    @MainActor
    func testWithoutACacheTheReconcileInstallsTheLibrary() async throws {
        let demo = try await seed()
        let store = LibraryStore(loader: loader, importer: nil)
        let hadCache = await store.installCached()
        XCTAssertFalse(hadCache)
        XCTAssertTrue(store.songs.isEmpty)
        await store.reconcileWithStore()
        XCTAssertEqual(store.songs.count, demo.songs.count)
        XCTAssertFalse(store.isLoading)
        XCTAssertNotNil(loader.loadCached(), "the cache is written for the next launch")
    }

    @MainActor
    func testADifferingStoreReplacesTheCachedLibraryAtTheReconcile() async throws {
        let demo = try await seed()
        var stale = demo
        stale.songs.removeLast()
        loader.writeCache(stale)

        let store = LibraryStore(loader: loader, importer: nil)
        let hadCache = await store.installCached()
        XCTAssertTrue(hadCache)
        XCTAssertEqual(store.songs.count, demo.songs.count - 1)
        await store.reconcileWithStore()
        XCTAssertEqual(store.songs.count, demo.songs.count)
        let last = try XCTUnwrap(demo.songs.last)
        XCTAssertNotNil(store.song(id: last.id), "the lookups follow the store")
    }

    @MainActor
    func testLoadStillDoesBothHalves() async throws {
        let demo = try await seed()
        loader.writeCache(demo)
        let store = LibraryStore(loader: loader, importer: nil)
        store.beginCachedLoad()
        await store.load()
        XCTAssertEqual(store.songs.count, demo.songs.count)
        XCTAssertFalse(store.isLoading)
    }
}
