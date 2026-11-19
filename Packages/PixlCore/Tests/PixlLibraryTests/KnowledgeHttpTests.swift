import Foundation
import Testing
@testable import PixlLibrary

/// The one door every open-data request goes through (docs/brain-spec.md, 3.7): switches, budget, ledger, spacing,
/// back-off. A port of Android's `KnowledgeHttpTest`, with a clock the test moves and a transport that counts.
@Suite("Knowledge http")
struct KnowledgeHttpTests {
    final class Transport: KnowledgeTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _code = 200
        private var _retryAfter = 0
        private var _fail = false
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        var code: Int {
            get { lock.lock(); defer { lock.unlock() }; return _code }
            set { lock.lock(); defer { lock.unlock() }; _code = newValue }
        }
        var retryAfter: Int {
            get { lock.lock(); defer { lock.unlock() }; return _retryAfter }
            set { lock.lock(); defer { lock.unlock() }; _retryAfter = newValue }
        }
        var fail: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _fail }
            set { lock.lock(); defer { lock.unlock() }; _fail = newValue }
        }
        private func take() -> (code: Int, retryAfter: Int, fail: Bool) {
            lock.lock(); defer { lock.unlock() }
            _calls += 1
            return (_code, _retryAfter, _fail)
        }
        func send(_ request: KnowledgeRequest) async throws -> KnowledgeReply {
            let t = take()
            if t.fail { throw URLError(.notConnectedToInternet) }
            return KnowledgeReply(code: t.code, body: #"{"ok":true}"#, retryAfterSec: t.retryAfter)
        }
    }

    final class Switch: KnowledgeSwitch, @unchecked Sendable {
        private let lock = NSLock()
        private var allowed = Set(KnowledgeHost.allCases)
        func remove(_ host: KnowledgeHost) { lock.lock(); allowed.remove(host); lock.unlock() }
        private func has(_ host: KnowledgeHost) -> Bool { lock.lock(); defer { lock.unlock() }; return allowed.contains(host) }
        func sourceAllowed(_ host: KnowledgeHost) async -> Bool { has(host) }
    }

    let clock = KnowledgeClock()
    let transport = Transport()
    let allowed = Switch()
    let store = MemoryValueStore()

    func http(store: MemoryValueStore? = nil) -> GatedKnowledgeHttp {
        GatedKnowledgeHttp(transport: transport, allowed: allowed, ledger: KnowledgeLedger(store: store ?? self.store, clock: clock.read),
                           clock: clock.read, sleep: clock.sleep)
    }

    @Test func aSwitchedOffSourceIsNeverAskedAndFlippingItStopsTheVeryNextRequest() async {
        let h = http()
        #expect(await h.get(.itunes, url: "https://itunes.apple.com/search?term=a") != nil)
        #expect(transport.calls == 1)
        allowed.remove(.itunes)
        #expect(await h.get(.itunes, url: "https://itunes.apple.com/search?term=b") == nil)
        #expect(transport.calls == 1, "nothing went out")
        #expect(await h.get(.deezer, url: "https://api.deezer.com/track/1") != nil, "the other sources are not affected")
    }

    @Test func everyRequestIsCountedInTheLedgerAndTheCeilingOfTheDayIsAHardStop() async {
        let h = http()
        let url = "https://query.wikidata.org/sparql"
        for _ in 0..<KnowledgeHost.wikidata.dailyCeiling {
            #expect(await h.post(.wikidata, url: url, body: "query=x", contentType: "text/plain", accept: "application/json") != nil)
        }
        #expect(await h.post(.wikidata, url: url, body: "query=x", contentType: "text/plain", accept: "application/json") == nil,
                "the fourth query of the day is refused")
        #expect(transport.calls == 3)
        let ledger = KnowledgeLedger(store: store, clock: clock.read)
        #expect(await ledger.countSince(.wikidata, sinceMs: clock.now - 86_400_000) == 3)
        // A new process: the ledger remembers, so the budget of a fresh object still refuses.
        let restarted = http()
        #expect(await restarted.post(.wikidata, url: url, body: "query=x", contentType: "text/plain", accept: "application/json") == nil)
        // A day later there is room again.
        clock.advance(86_400_000 + 1)
        #expect(await restarted.post(.wikidata, url: url, body: "query=x", contentType: "text/plain", accept: "application/json") != nil)
    }

    @Test func requestsToOneHostAreSpacedByItsPoliteInterval() async {
        let h = http()
        let start = clock.now
        _ = await h.get(.musicbrainz, url: "https://musicbrainz.org/ws/2/a")
        _ = await h.get(.musicbrainz, url: "https://musicbrainz.org/ws/2/b")
        #expect(clock.now - start >= KnowledgeHost.musicbrainz.minIntervalMs, "waited \(clock.now - start) ms")
    }

    @Test func a503BacksTheHostOffAndTheNextRequestIsNotAskedUntilItPasses() async {
        let h = http()
        transport.code = 503
        let reply = await h.get(.musicbrainz, url: "https://musicbrainz.org/ws/2/a")
        #expect(reply?.code == 503)
        #expect(await h.get(.musicbrainz, url: "https://musicbrainz.org/ws/2/b") == nil, "in back-off")
        #expect(transport.calls == 1)
        #expect(await h.get(.deezer, url: "https://api.deezer.com/track/1") != nil, "another host is not held")
        transport.code = 200
        clock.advance(11 * 60 * 1000)
        #expect(await h.get(.musicbrainz, url: "https://musicbrainz.org/ws/2/c") != nil)
    }

    @Test func aRetryAfterLongerThanTheBackOffIsHonoured() async {
        let h = http()
        transport.code = 429
        transport.retryAfter = 900
        _ = await h.get(.listenbrainz, url: "https://api.listenbrainz.org/1/x")
        clock.advance(11 * 60 * 1000)
        #expect(await h.get(.listenbrainz, url: "https://api.listenbrainz.org/1/y") == nil, "900 s have not passed")
        clock.advance(5 * 60 * 1000)
        #expect(await h.get(.listenbrainz, url: "https://api.listenbrainz.org/1/y") != nil)
    }

    @Test func itunesTreatsA403AsSlowDownAndOtherHostsDoNot() async {
        let h = http()
        transport.code = 403
        _ = await h.get(.itunes, url: "https://itunes.apple.com/search?term=a")
        #expect(await h.get(.itunes, url: "https://itunes.apple.com/search?term=b") == nil)
        _ = await h.get(.deezer, url: "https://api.deezer.com/track/1")
        #expect(await h.get(.deezer, url: "https://api.deezer.com/track/2") != nil, "a 403 from Deezer is not a throttle")
    }

    @Test func aTransportThatFailsIsNoAnswerAndBacksOff() async {
        let h = http()
        transport.fail = true
        #expect(await h.get(.deezer, url: "https://api.deezer.com/track/1") == nil)
        #expect(await h.get(.deezer, url: "https://api.deezer.com/track/2") == nil, "in back-off")
        #expect(transport.calls == 1)
    }

    @Test func aSourceCanAskForABackOffByItselfAsDeezerDoesOnItsQuotaError() async {
        let h = http()
        await h.backOff(.deezer, forMs: 60_000)
        #expect(await h.get(.deezer, url: "https://api.deezer.com/track/1") == nil)
        clock.advance(61_000)
        #expect(await h.get(.deezer, url: "https://api.deezer.com/track/1") != nil)
    }

    @Test func theLedgerKeepsOnlyTheLastDayAndSurvivesARestart() async {
        let ledger = KnowledgeLedger(store: store, clock: clock.read)
        await ledger.record(.deezer, nowMs: clock.now - 2 * 86_400_000)
        await ledger.record(.deezer, nowMs: clock.now - 1000)
        await ledger.record(.deezer, nowMs: clock.now)
        let again = KnowledgeLedger(store: store, clock: clock.read)
        #expect(await again.countSince(.deezer, sinceMs: clock.now - 86_400_000) == 2)
        #expect(await again.lastRequestMs(.deezer) == clock.now)
        #expect(await again.today()[.deezer] == 2)
        #expect(await again.today()[.itunes] == 0)
        #expect(await again.hasRoom(.deezer))
    }
}
