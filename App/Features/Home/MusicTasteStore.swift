import Foundation
import Observation
import PixlLibrary

/// Settings › AI › Music intelligence (Android `MusicTasteRepository`): what each finished listening session says
/// about a song — completed, skipped early, chosen by hand — kept per song on this device and fed to the
/// recommendation engine (Daily Mix, Your Mix, Home's mixes and shelves) while "Learn from listening" is on.
/// Stored as `music_taste.json` in Application Support, written off the main thread; capped at the 5,000 most
/// recently played songs, as on Android.
@Observable
final class MusicTasteStore {
    private(set) var learnedSongs = 0
    private(set) var completions = 0
    private(set) var skips = 0
    /// The last preview / refresh report (Android `last_report`).
    private(set) var lastReport = MusicTasteStore.noReport
    /// Bumped when the learned signals change (Home re-plans with them).
    private(set) var revision = 0

    static let noReport = "No recommendation refresh yet."
    private static let maxSongs = 5_000

    @ObservationIgnored private var signals: [String: MusicRecommendationEngine.Signal] = [:]
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let settings: AISettings

    /// `file == nil` keeps everything in memory (UI tests).
    init(settings: AISettings, file: URL?) {
        self.settings = settings
        self.file = file
        if file == nil { isLoaded = true }
    }

    static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("music_taste.json")
    }

    private nonisolated struct Stored: Codable, Sendable {
        var signals: [String: MusicRecommendationEngine.Signal]
        var report: String
    }

    /// Reads the file once, off the main thread.
    func ensureLoaded() async {
        if isLoaded { return }
        if let loadTask { return await loadTask.value }
        let file = self.file
        let task = Task { [weak self] in
            let stored = await Self.read(file)
            guard let self, !self.isLoaded else { return }
            if let stored {
                // Sessions recorded while the file was loading win over the stored ones.
                self.signals = stored.signals.merging(self.signals) { _, recent in recent }
                self.lastReport = stored.report
            }
            self.isLoaded = true
            self.updateCounts()
        }
        loadTask = task
        await task.value
    }

    @concurrent
    private nonisolated static func read(_ file: URL?) async -> Stored? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    /// The signals the recommendations use (`signals()`): none while learning is off.
    var learnedSignals: [String: MusicRecommendationEngine.Signal] {
        settings.musicLearningEnabled ? signals : [:]
    }

    /// `record`: one finished listening session (at least 5 s; nothing is learned while learning is off).
    func record(songId: String, listenedMs: Int64, durationMs: Int64, voluntary: Bool, changedTrack: Bool,
                timestamp: Int64) {
        guard !songId.isEmpty, listenedMs >= 5_000, settings.musicLearningEnabled else { return }
        guard isLoaded else {
            Task { [weak self] in
                await self?.ensureLoaded()
                self?.record(songId: songId, listenedMs: listenedMs, durationMs: durationMs, voluntary: voluntary,
                             changedTrack: changedTrack, timestamp: timestamp)
            }
            return
        }
        signals[songId] = MusicRecommendationEngine.record(signals[songId] ?? MusicRecommendationEngine.Signal(),
                                                           listenedMs: listenedMs, durationMs: durationMs,
                                                           voluntary: voluntary, changedTrack: changedTrack,
                                                           nowMs: timestamp)
        if signals.count > Self.maxSongs {
            let kept = signals.sorted { $0.value.lastPlayedMs > $1.value.lastPlayedMs }.prefix(Self.maxSongs)
            signals = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        changed()
    }

    /// `resetLearning`: the learned signals go; the library and play history stay.
    func reset() {
        signals = [:]
        lastReport = "Learning reset. Your library and play history are unchanged."
        changed()
    }

    /// `saveReport` (12,000 characters at most).
    func saveReport(_ report: String) {
        lastReport = String(report.prefix(12_000))
        save()
    }

    private func changed() {
        updateCounts()
        revision &+= 1
        save()
    }

    private func updateCounts() {
        learnedSongs = signals.count
        completions = signals.values.reduce(0) { $0 + $1.completions }
        skips = signals.values.reduce(0) { $0 + $1.earlySkips }
    }

    private func save() {
        guard let file, isLoaded else { return }
        let stored = Stored(signals: signals, report: lastReport)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
