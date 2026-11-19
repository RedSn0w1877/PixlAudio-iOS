// The one door every open-data request goes through (docs/brain-spec.md, 3.7): the host's off switch (local and remote),
// its daily budget and request ledger, its polite spacing, and its back-off. A source client never talks to the network
// any other way, so none of these rules can be bypassed. A port of Android's `KnowledgeHttp.kt` and `KnowledgeLedger.kt`.
//
// A reply of `nil` means "not asked": the source is switched off, its budget for the day is spent, it is in back-off, or
// there is no network. The caller treats that as "try later" and records nothing.

import Foundation
import PixlModel

public struct KnowledgeReply: Sendable, Equatable {
    public var code: Int
    public var body: String?
    public var retryAfterSec: Int
    public init(code: Int, body: String?, retryAfterSec: Int = 0) {
        self.code = code
        self.body = body
        self.retryAfterSec = retryAfterSec
    }
    public var ok: Bool { code >= 200 && code <= 299 }
}

public struct KnowledgeRequest: Sendable, Equatable {
    public var method: String
    public var url: String
    public var body: String?
    public var contentType: String?
    public var accept: String
    public init(method: String, url: String, body: String? = nil, contentType: String? = nil, accept: String = "application/json") {
        self.method = method
        self.url = url
        self.body = body
        self.contentType = contentType
        self.accept = accept
    }
}

/// The network, supplied by the app (`URLSession` with the app's User-Agent). Throws when there was no answer at all.
public protocol KnowledgeTransport: Sendable {
    func send(_ request: KnowledgeRequest) async throws -> KnowledgeReply
}

public protocol KnowledgeHttp: Sendable {
    func get(_ host: KnowledgeHost, url: String, accept: String) async -> KnowledgeReply?
    func post(_ host: KnowledgeHost, url: String, body: String, contentType: String, accept: String) async -> KnowledgeReply?
    /// A source says it was told to slow down (Deezer's quota error arrives as HTTP 200): no request for `forMs`.
    func backOff(_ host: KnowledgeHost, forMs: Int64) async
}

public extension KnowledgeHttp {
    func get(_ host: KnowledgeHost, url: String) async -> KnowledgeReply? { await get(host, url: url, accept: "application/json") }
}

/// Whether an open-data source may be asked right now: its local switch is on and the remote config does not switch it off.
public protocol KnowledgeSwitch: Sendable {
    func sourceAllowed(_ host: KnowledgeHost) async -> Bool
}

/// Small named text values the ledger keeps (the brain's `brain_state`).
public protocol KnowledgeValueStore: Sendable {
    func value(_ key: String) async -> String?
    func setValue(_ key: String, _ value: String?) async
}

/// The requests of the last 24 hours to each open-data host, one timestamp each, so a restart cannot give a host's day
/// a new ceiling (3.7). Nothing is read until a request is about to go out or the Developer screen asks.
public actor KnowledgeLedger {
    public static let dayMs: Int64 = 24 * 60 * 60 * 1000
    static let maxKept = 700

    private let store: any KnowledgeValueStore
    private let clock: @Sendable () -> Int64
    private var loaded: Set<KnowledgeHost> = []
    private var stamps: [KnowledgeHost: [Int64]] = [:]

    public init(store: any KnowledgeValueStore, clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.store = store
        self.clock = clock
    }

    private func key(_ host: KnowledgeHost) -> String { "request_ledger_\(host.key)" }

    private func load(_ host: KnowledgeHost) async {
        if !loaded.insert(host).inserted { return }
        let text = await store.value(key(host)) ?? ""
        var list = stamps[host] ?? []
        list.append(contentsOf: text.split(separator: ",").compactMap { Int64($0) })
        list.sort()
        stamps[host] = list
    }

    /// One request to `host` is about to go out.
    public func record(_ host: KnowledgeHost, nowMs: Int64? = nil) async {
        let now = nowMs ?? clock()
        await load(host)
        var list = stamps[host] ?? []
        list.append(now)
        let keepAfter = now - Self.dayMs
        list.removeAll { $0 < keepAfter }
        if list.count > Self.maxKept { list.removeFirst(list.count - Self.maxKept) }
        stamps[host] = list
        await store.setValue(key(host), list.map(String.init).joined(separator: ","))
    }

    public func countSince(_ host: KnowledgeHost, sinceMs: Int64) async -> Int {
        await load(host)
        return (stamps[host] ?? []).filter { $0 >= sinceMs }.count
    }

    /// The day's requests per host, newest 24 hours, for the Developer screen.
    public func today() async -> [KnowledgeHost: Int] {
        let since = clock() - Self.dayMs
        var out: [KnowledgeHost: Int] = [:]
        for host in KnowledgeHost.allCases { out[host] = await countSince(host, sinceMs: since) }
        return out
    }

    public func hasRoom(_ host: KnowledgeHost) async -> Bool {
        await countSince(host, sinceMs: clock() - Self.dayMs) < host.dailyCeiling
    }

    /// When the host was last asked, or 0.
    public func lastRequestMs(_ host: KnowledgeHost) async -> Int64 {
        await load(host)
        return stamps[host]?.max() ?? 0
    }
}

/// The real door: switch, ledger, token bucket, spacing, back-off, then the transport.
public actor GatedKnowledgeHttp: KnowledgeHttp {
    static let backoffFirstMs: Int64 = 5_000
    static let backoffCapMs: Int64 = 10 * 60_000

    private let transport: any KnowledgeTransport
    private let allowed: any KnowledgeSwitch
    private let ledger: KnowledgeLedger
    private let clock: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async -> Void
    private var buckets: [KnowledgeHost: HostBudget] = [:]
    private var busy: Set<KnowledgeHost> = []
    private var waiters: [KnowledgeHost: [CheckedContinuation<Void, Never>]] = [:]
    private var nextAtMs: [KnowledgeHost: Int64] = [:]
    private var blockedUntilMs: [KnowledgeHost: Int64] = [:]
    private var failures: [KnowledgeHost: Int] = [:]

    public init(transport: any KnowledgeTransport, allowed: any KnowledgeSwitch, ledger: KnowledgeLedger,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() },
                sleep: @escaping @Sendable (Int64) async -> Void = { ms in try? await Task.sleep(for: .milliseconds(ms)) }) {
        self.transport = transport
        self.allowed = allowed
        self.ledger = ledger
        self.clock = clock
        self.sleep = sleep
    }

    public func get(_ host: KnowledgeHost, url: String, accept: String) async -> KnowledgeReply? {
        await run(host, KnowledgeRequest(method: "GET", url: url, accept: accept))
    }

    public func post(_ host: KnowledgeHost, url: String, body: String, contentType: String, accept: String) async -> KnowledgeReply? {
        await run(host, KnowledgeRequest(method: "POST", url: url, body: body, contentType: contentType, accept: accept))
    }

    public func backOff(_ host: KnowledgeHost, forMs: Int64) {
        blockedUntilMs[host] = max(blockedUntilMs[host] ?? 0, clock() + forMs)
    }

    /// Milliseconds until `host` may be asked again after a back-off (0 when it may), for the Developer screen.
    public func blockedForMs(_ host: KnowledgeHost) -> Int64 { max(0, (blockedUntilMs[host] ?? 0) - clock()) }

    private func bucket(_ host: KnowledgeHost) -> HostBudget {
        if let b = buckets[host] { return b }
        let b = HostBudget(capacity: host.dailyCeiling, refillIntervalMs: KnowledgeLedger.dayMs / Int64(host.dailyCeiling),
                           maxParallel: 1, clock: clock)
        buckets[host] = b
        return b
    }

    private func lock(_ host: KnowledgeHost) async {
        if busy.contains(host) {
            await withCheckedContinuation { waiters[host, default: []].append($0) }
        } else {
            busy.insert(host)
        }
    }

    private func unlock(_ host: KnowledgeHost) {
        if var queue = waiters[host], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[host] = queue
            next.resume()
        } else {
            busy.remove(host)
        }
    }

    private func run(_ host: KnowledgeHost, _ request: KnowledgeRequest) async -> KnowledgeReply? {
        if await !allowed.sourceAllowed(host) { return nil }
        if clock() < (blockedUntilMs[host] ?? 0) { return nil }
        if await !ledger.hasRoom(host) { return nil }
        if await !bucket(host).tryAcquire() { return nil }
        await ledger.record(host, nowMs: clock())
        await lock(host)
        defer { unlock(host) }
        // Spacing: the polite rate of the host, measured from the start of the last request.
        let wait = (nextAtMs[host] ?? 0) - clock()
        if wait > 0 { await sleep(wait) }
        if Task.isCancelled { return nil }
        nextAtMs[host] = clock() + host.minIntervalMs
        // The switch is asked again after the wait: flipping it stops the very next request.
        if await !allowed.sourceAllowed(host) { return nil }
        do {
            let reply = try await transport.send(request)
            noteOutcome(host, code: reply.code, retryAfterSec: reply.retryAfterSec)
            return reply
        } catch {
            noteOutcome(host, code: -1, retryAfterSec: 0)
            return nil
        }
    }

    /// 429, 502, 503, 504 (and iTunes' 403) back the host off, exponentially with jitter, honouring Retry-After.
    private func noteOutcome(_ host: KnowledgeHost, code: Int, retryAfterSec: Int) {
        let throttled = code == 429 || code == 502 || code == 503 || code == 504 || (host == .itunes && code == 403)
        if !throttled && code != -1 {
            failures[host] = 0
            return
        }
        let n = (failures[host] ?? 0) + 1
        failures[host] = n
        let base = min(Self.backoffCapMs, Self.backoffFirstMs << Int64(min(n - 1, 8)))
        let jitter = clock() % 1000
        let wait = max(base + jitter, Int64(retryAfterSec) * 1000)
        blockedUntilMs[host] = clock() + wait
    }
}

/// What the app calls itself to the open-data hosts. The URL is the public project page MusicBrainz and Wikimedia ask a
/// client to give: this app's own repository (public, checked with `gh repo view`). It names the app and never the listener.
public enum KnowledgeUserAgent {
    public static let projectUrl = "https://github.com/RedSn0w1877/PixlAudio-iOS"

    public static func value(version: String) -> String { "PixlAudio/\(version) ( \(projectUrl) )" }
}
