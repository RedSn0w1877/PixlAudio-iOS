// "Getting to know your music" (docs/brain-spec.md, 8.10): the first minute of a listener with a sizeable library. Eight radios,
// for the day's seeds of the listener's own music (at most two by one artist), are fetched once so the first mixes have
// something to be built from; Home shows how far it is ("3 of 8"). It is lane 1 of the refresh run in the foreground, the same
// work under the same budget and switches, and it does nothing once eight lists are cached. A port of Android's `ColdStart.kt`.
//
// Not a second background job: it runs while Home is on screen, in the process's own task, and ends by itself.

import Foundation

public actor ColdStart {
    /// Eight radios (8.10).
    public static let target = 8
    /// The spec runs 6 in parallel; the YouTube budget of stage 1 allows 2 (Android deviation 156).
    public static let parallel = 2

    /// What the strip shows; nil while there is nothing to show.
    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
    }

    private let work: any RefreshWork
    private let healthyLists: @Sendable () async -> Int
    private let allowed: @Sendable () async -> Bool
    private var running = false

    public init(work: any RefreshWork, healthyLists: @escaping @Sendable () async -> Int, allowed: @escaping @Sendable () async -> Bool) {
        self.work = work
        self.healthyLists = healthyLists
        self.allowed = allowed
    }

    /// Runs at most once at a time, and only while fewer than `target` lists are cached. Safe to call again. `progress` is
    /// told how far it is, and nil when it ends.
    public func run(progress: @escaping @Sendable (Progress?) -> Void) async {
        if running { return }
        running = true
        defer {
            // Once finished the strip goes; what was fetched stays cached.
            progress(nil)
            running = false
        }
        if !(await allowed()) { return }
        if await healthyLists() >= Self.target { return }
        if await work.requestsLeft() <= 0 { return }
        let targets = Array(await work.radioSeeds().prefix(Self.target))
        if targets.isEmpty { return }
        let total = targets.count
        progress(Progress(done: 0, total: total))
        let work = self.work
        let allowed = self.allowed
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func start() {
                guard next < targets.count else { return }
                let target = targets[next]
                next += 1
                group.addTask {
                    if await allowed(), await work.requestsLeft() > 0 { _ = await work.radio(target) }
                    progress(Progress(done: counter.increment(), total: total))
                }
            }
            for _ in 0..<Self.parallel { start() }
            for await _ in group { start() }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int { lock.withLock { value += 1; return value } }
    }
}
