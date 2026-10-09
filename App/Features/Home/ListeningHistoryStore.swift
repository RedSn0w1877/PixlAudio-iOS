import Foundation
import Observation
import PixlLibrary
import PixlModel

/// Playback history (Android `PlaybackStatsRepository`): the listening events behind Recently Played, Stats, the
/// greeting and the recommendation inputs, stored as `playback_history.json` in Application Support with Android's
/// schema (`PlaybackHistoryCodec`), so an Android backup's history imports unchanged.
///
/// Observation: only `revision` is observable (bumped on every change); screens re-derive their data off the main
/// thread when it changes. The events themselves are never read in `body`.
///
/// Stage 5 (playback) reports finished listening spans with `record(songId:durationMs:endTimestampMs:)`.
@Observable
final class ListeningHistoryStore {
    private(set) var revision = 0
    @ObservationIgnored private(set) var events: [PlaybackEvent] = []
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The history file is rewritten in full (a few MB at two years of listening): changes within a few seconds share
    /// one write, and `flush()` writes at once (backgrounding, an import, clearing).
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var hasPendingWrite = false
    static let writeDelay: Duration = .seconds(3)

    let clock: HomeClock
    private let file: ListeningHistoryFile?

    /// `file == nil` keeps history in memory only (UI tests, previews).
    init(clock: HomeClock, file: ListeningHistoryFile?, seed: [PlaybackEvent] = []) {
        self.clock = clock
        self.file = file
        if !seed.isEmpty {
            events = seed
            isLoaded = true
            revision = 1
        } else if file == nil {
            isLoaded = true
        }
    }

    /// Reads the history file once, off the main thread.
    func ensureLoaded() async {
        if isLoaded { return }
        if let loadTask { return await loadTask.value }
        let file = self.file
        let task = Task { [weak self] in
            let loaded = await file?.read() ?? []
            guard let self, !self.isLoaded else { return }
            // Events recorded while the file was loading are kept.
            self.events = loaded + self.events
            self.isLoaded = true
            self.revision += 1
        }
        loadTask = task
        await task.value
    }

    /// `recordPlayback`: appends one listening span (events older than two years before it are pruned).
    func record(songId: String, durationMs: Int64, endTimestampMs: Int64? = nil) {
        let end = endTimestampMs ?? clock.nowMs()
        // Never write before the file was read: the write would replace the stored history with this one event.
        guard isLoaded else {
            Task { [weak self] in
                await self?.ensureLoaded()
                self?.record(songId: songId, durationMs: durationMs, endTimestampMs: end)
            }
            return
        }
        guard let updated = PlaybackStats.recordingPlayback(songId: songId, durationMs: durationMs, timestamp: end,
                                                            into: events) else { return }
        replace(with: updated)
    }

    /// `importEventsFromBackup`.
    func importEvents(_ imported: [PlaybackEvent], clearExisting: Bool = true) {
        replace(with: PlaybackStats.importingEvents(imported, into: events, clearExisting: clearExisting))
        flush()
    }

    func clear() {
        replace(with: [])
        flush()
    }

    private func replace(with newEvents: [PlaybackEvent]) {
        events = newEvents
        revision += 1
        guard file != nil else { return }
        hasPendingWrite = true
        guard writeTask == nil else { return }
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.writeDelay)
            if Task.isCancelled { return }
            self?.flush()
        }
    }

    /// Writes the history now if a change is waiting for its write.
    func flush() {
        writeTask?.cancel()
        writeTask = nil
        guard hasPendingWrite, let file else { return }
        hasPendingWrite = false
        let snapshot = events
        Task { await file.write(snapshot) }
    }
}

/// The history file, read and written off the main thread.
actor ListeningHistoryFile {
    private let url: URL

    init(url: URL) { self.url = url }

    static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(PlaybackHistoryCodec.fileName)
    }

    func read() -> [PlaybackEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return PlaybackHistoryCodec.decode(utf8: [UInt8](data))
    }

    func write(_ events: [PlaybackEvent]) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(PlaybackHistoryCodec.encodeUTF8(events)).write(to: url, options: .atomic)
    }
}

/// Deterministic listening history for UI tests and screenshots, relative to `HomeClock.uiTest`: plays across
/// the last eight weeks with a heavier Monday this week (like the Android reference), so every Home shelf,
/// the stats card and each Stats range have data.
nonisolated enum DemoListeningHistory {
    static func events(songs: [Song], nowMs: Int64) -> [PlaybackEvent] {
        guard !songs.isEmpty else { return [] }
        let day: Int64 = 86_400_000
        let hour: Int64 = 3_600_000
        // Today is Thursday (HomeClock.uiTest); offsets in days before today.
        var plays: [(daysAgo: Int64, hourOfDay: Int64, song: Int)] = []
        // This week: Monday heavy, Wednesday medium, Tuesday and today light.
        for (i, song) in [0, 3, 18, 0, 5, 2, 0, 3, 10].enumerated() { plays.append((3, 9 + Int64(i), song)) }
        for (i, song) in [7, 1].enumerated() { plays.append((2, 20 + Int64(i), song)) }
        for (i, song) in [0, 18, 12, 6].enumerated() { plays.append((1, 13 + Int64(i), song)) }
        for (i, song) in [2, 8, 3, 0].enumerated() { plays.append((0, 8 + Int64(i) * 2, song)) }
        // Earlier: a steady pattern over seven weeks so month/year/all ranges have shape.
        var seed: UInt64 = 0x5EED_1234
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed >> 33
        }
        for daysAgo in Int64(5)...Int64(56) where next() % 3 != 0 {
            let count = Int(next() % 4) + 1
            for k in 0..<count {
                let song = Int(next() % UInt64(min(songs.count, 20)))
                plays.append((daysAgo, 7 + Int64(k) * 3 + Int64(next() % 3), song))
            }
        }
        let startOfToday = nowMs - nowMs % day
        return plays.compactMap { play -> PlaybackEvent? in
            let song = songs[play.song % songs.count]
            let end = startOfToday - play.daysAgo * day + play.hourOfDay * hour + 12 * 60_000
            guard end < nowMs else { return nil }
            let duration = min(song.duration, 240_000)
            return PlaybackEvent(songId: song.id, timestamp: end, durationMs: duration,
                                 startTimestamp: end - duration, endTimestamp: end)
        }
        .sorted { $0.timestamp < $1.timestamp }
    }
}
