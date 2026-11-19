import Foundation
import PixlBackup
import Testing
@testable import PixlLibrary

/// Fixtures cut from real responses (Android's `tools/brain/cut_knowledge_fixtures.py`, copied unchanged) and the real atlas.
enum KnowledgeFixtures {
    static func read(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures/knowledge"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("the fixture \(name) is missing")
            return ""
        }
        return text
    }

    static let atlas: GenreAtlas = {
        // The same asset the golden tests read, parsed once for the whole run.
        (try? BrainStage2bGoldenTests.atlas()) ?? { fatalError("the atlas asset did not load") }()
    }()
}

/// An atlas provider over the real asset.
struct FixtureAtlas: AtlasProvider {
    var value: GenreAtlas? = KnowledgeFixtures.atlas
    func atlas() async -> GenreAtlas? { value }
    func loadedOrNil() async -> GenreAtlas? { value }
}

/// A `KnowledgeHttp` answering from fixtures: the first route whose test matches the URL answers, no route answers 404, a
/// host in `down` is "not asked" (nil), as when a source is switched off or its budget is spent.
final class FakeKnowledgeHttp: KnowledgeHttp, @unchecked Sendable {
    struct Route {
        var host: KnowledgeHost
        var contains: String
        var body: String
        var code: Int
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var asked: [(host: KnowledgeHost, url: String)] = []
    private var downHosts: Set<KnowledgeHost> = []
    private var backed: [(host: KnowledgeHost, ms: Int64)] = []

    func route(_ host: KnowledgeHost, _ contains: String, fixture: String, code: Int = 200) {
        routeText(host, contains, KnowledgeFixtures.read(fixture), code: code)
    }

    func routeText(_ host: KnowledgeHost, _ contains: String, _ text: String, code: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        routes.append(Route(host: host, contains: contains, body: text, code: code))
    }

    func removeRoutes(of host: KnowledgeHost) {
        lock.lock(); defer { lock.unlock() }
        routes.removeAll { $0.host == host }
    }

    func setDown(_ host: KnowledgeHost) {
        lock.lock(); defer { lock.unlock() }
        downHosts.insert(host)
    }

    var requests: [(host: KnowledgeHost, url: String)] {
        lock.lock(); defer { lock.unlock() }
        return asked
    }

    var backedOff: [(host: KnowledgeHost, ms: Int64)] {
        lock.lock(); defer { lock.unlock() }
        return backed
    }

    func count(_ host: KnowledgeHost) -> Int { requests.filter { $0.host == host }.count }

    func clearRequests() {
        lock.lock(); defer { lock.unlock() }
        asked.removeAll()
    }

    private func answer(_ host: KnowledgeHost, _ url: String, _ body: String?) -> KnowledgeReply? {
        lock.lock(); defer { lock.unlock() }
        if downHosts.contains(host) { return nil }
        asked.append((host, url))
        let key = body.map { url + " " + $0 } ?? url
        guard let r = routes.first(where: { $0.host == host && key.contains($0.contains) }) else { return KnowledgeReply(code: 404, body: nil) }
        return KnowledgeReply(code: r.code, body: r.body)
    }

    func get(_ host: KnowledgeHost, url: String, accept: String) async -> KnowledgeReply? { answer(host, url, nil) }

    func post(_ host: KnowledgeHost, url: String, body: String, contentType: String, accept: String) async -> KnowledgeReply? {
        answer(host, url, body)
    }

    func backOff(_ host: KnowledgeHost, forMs: Int64) async { noteBackOff(host, forMs) }

    private func noteBackOff(_ host: KnowledgeHost, _ ms: Int64) {
        lock.lock(); defer { lock.unlock() }
        backed.append((host, ms))
    }
}

/// A clock a test moves by hand (and that `sleep` moves, so a spaced request needs no real wait).
final class KnowledgeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ start: Int64 = 1_795_000_000_000) { value = start }

    var now: Int64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(_ ms: Int64) {
        lock.lock(); defer { lock.unlock() }
        value += ms
    }

    var read: @Sendable () -> Int64 { { [self] in now } }
    var sleep: @Sendable (Int64) async -> Void { { [self] ms in advance(ms) } }
}

/// `brain_state` in memory.
actor MemoryValueStore: KnowledgeValueStore {
    private var values: [String: String] = [:]
    func value(_ key: String) -> String? { values[key] }
    func setValue(_ key: String, _ value: String?) { values[key] = value }
}

/// A fresh directory for a store under test, removed afterwards.
func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pixl-dna-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class KnowledgeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    @discardableResult func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return n
    }
}
