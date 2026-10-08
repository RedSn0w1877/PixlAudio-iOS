import Foundation
import PixlNet

/// Cloud Studio's job history (design §7.1 `CloudJobStore`): every `CloudJobRecord` in one JSON file,
/// `Application Support/CloudStudio/jobs.json`, written atomically after each change and excluded from backups.
/// The design suggested a second SwiftData container; a few hundred small Codable records in one file need no
/// schema migrations and keep the main store untouched, which was the point. `file` nil keeps them in memory
/// (tests, UI tests).
actor CloudJobStore {
    private let file: URL?
    private var records: [CloudJobRecord] = []
    private var loaded = false

    init(file: URL?) {
        self.file = file
    }

    /// `Application Support/CloudStudio/` (uploads and downloads use sub-folders of it).
    nonisolated static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CloudStudio", isDirectory: true)
    }

    nonisolated static func defaultFile() -> URL? { directory?.appendingPathComponent("jobs.json") }

    /// The stored records, pruned of finished jobs older than 30 days.
    func load(nowMs: Int64) -> [CloudJobRecord] {
        if !loaded {
            loaded = true
            if let file, let data = try? Data(contentsOf: file),
               let decoded = try? JSONDecoder().decode([CloudJobRecord].self, from: data) {
                records = decoded
            }
        }
        let before = records.count
        records.removeAll { CloudRetention.shouldPrune($0, nowMs: nowMs) }
        if records.count != before { write() }
        return records
    }

    /// Replaces the whole list (the orchestrator owns the order).
    func save(_ new: [CloudJobRecord]) {
        loaded = true
        records = new
        write()
    }

    private func write() {
        guard let file else { return }
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = directory
            try? excluded.setResourceValues(values)
            let data = try JSONEncoder().encode(records)
            try data.write(to: file, options: [.atomic])
        } catch {
            // The next change writes again; nothing else to do without a disk.
        }
    }
}
