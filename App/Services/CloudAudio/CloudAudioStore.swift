import Foundation
import PixlModel
import PixlNet

/// Spatial audio's local store (cloud audio spec 6.2 "Local store", 6.1 `cloudAudio.storageMB`):
/// `Application Support/CloudAudio/<videoId>/sp-<profile>.flac`, with its manifest `sp-<profile>.json` beside it, the
/// folder excluded from backups. There is no database: a file plus a valid manifest beside it is the index, read once
/// (`load`). When a render last started playing is its manifest file's modification date, so the least recently played
/// go first when the store is over its budget, across launches.
///
/// An actor: every file operation runs off the main actor, one after another.
actor CloudAudioStore {
    nonisolated struct Item: Sendable, Hashable {
        var rendition: LocalRendition
        /// When it last started playing (when it was stored, until then).
        var lastPlayedMs: Int64

        var entry: CloudAudioStoreEntry {
            CloudAudioStoreEntry(key: rendition.key, bytes: rendition.bytes, lastPlayedMs: lastPlayedMs)
        }
    }

    nonisolated struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated let directory: URL
    private var items: [RenditionKey: Item] = [:]
    private var isLoaded = false

    init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/CloudAudio`.
    nonisolated static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(CloudAudioLocalLayout.directoryName, isDirectory: true)
    }

    // MARK: The index

    /// Reads the folder once: every pair that passes `CloudAudioStorePolicy.accepts` (the manifest is the render its
    /// path names, the file has the manifest's size) is in the index. Anything else in a render's folder — a file whose
    /// manifest was never written (a crash between the two), a pair of another library version, a manifest that no
    /// longer describes its file — is deleted.
    func load() -> [Item] {
        guard !isLoaded else { return Array(items.values) }
        isLoaded = true
        prepareDirectory()
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) else { return [] }
        for folder in folders {
            let videoId = folder.lastPathComponent
            guard CloudLibrary.isValidVideoId(videoId) else { continue }
            let names = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
            var kept = Set<String>()
            for name in names {
                guard let file = CloudAudioLocalLayout.parse(fileName: name), file.isManifest else { continue }
                let key = RenditionKey(videoId: videoId, profile: file.profile)
                let manifestURL = folder.appendingPathComponent(name)
                let audioName = CloudAudioLocalLayout.audioFileName(file.profile)
                let audioURL = folder.appendingPathComponent(audioName)
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? CloudLibraryManifest.decode(data),
                      CloudAudioStorePolicy.accepts(manifest, key: key, fileBytes: Self.size(of: audioURL)) else { continue }
                items[key] = Item(rendition: LocalRendition(key: key, fileURL: audioURL, manifest: manifest),
                                  lastPlayedMs: Self.modificationMs(of: manifestURL))
                kept.insert(name)
                kept.insert(audioName)
            }
            for name in names where !kept.contains(name) {
                try? manager.removeItem(at: folder.appendingPathComponent(name))
            }
            if kept.isEmpty { try? manager.removeItem(at: folder) }
        }
        return Array(items.values)
    }

    func allItems() -> [Item] { Array(items.values) }

    // MARK: Changes

    /// Moves a downloaded render into the store. The caller checked its bytes and SHA-256 against `manifest`; here the
    /// manifest must pass the acceptance rule for the render it names, and the file must have its size. The audio goes
    /// first and the manifest last, so a crash in between leaves a file without a manifest, which `load` deletes.
    func install(staged: URL, manifest: CloudLibraryManifest, nowMs: Int64) throws -> Item {
        guard let profileId = manifest.profile, let profile = SpatialProfile(rawValue: profileId) else {
            throw Failure(message: "The render names no profile this app knows.")
        }
        let key = RenditionKey(videoId: manifest.videoId, profile: profile)
        guard case .success(let audio) = manifest.check(for: key),
              let audioPath = CloudAudioLocalLayout.relativePath(key),
              let manifestPath = CloudAudioLocalLayout.relativePath(key, manifest: true) else {
            throw Failure(message: "The render's manifest doesn't describe it.")
        }
        guard Self.size(of: staged) == audio.bytes else { throw Failure(message: "The render file isn't whole.") }
        prepareDirectory()
        let manager = FileManager.default
        try manager.createDirectory(at: directory.appendingPathComponent(key.videoId, isDirectory: true),
                                    withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent(audioPath)
        let manifestURL = directory.appendingPathComponent(manifestPath)
        // A render of the same key that was here stops being advertised before its file is replaced.
        try? manager.removeItem(at: manifestURL)
        try CloudStudio.moveAtomically(staged, to: audioURL)
        try manifest.encoded().write(to: manifestURL, options: .atomic)
        Self.setModification(nowMs, of: manifestURL)
        let item = Item(rendition: LocalRendition(key: key, fileURL: audioURL, manifest: manifest), lastPlayedMs: nowMs)
        items[key] = item
        return item
    }

    /// The render started playing now.
    func markPlayed(_ key: RenditionKey, nowMs: Int64) {
        guard var item = items[key], let path = CloudAudioLocalLayout.relativePath(key, manifest: true) else { return }
        item.lastPlayedMs = nowMs
        items[key] = item
        Self.setModification(nowMs, of: directory.appendingPathComponent(path))
    }

    /// The least recently played renders go until the rest fit in `budgetBytes` (never one of `keeping`).
    func evict(budgetBytes: Int64, keeping: Set<RenditionKey>) -> [RenditionKey] {
        let keys = CloudAudioStorePolicy.evictions(items.values.map(\.entry), budgetBytes: budgetBytes, keeping: keeping)
        for key in keys { remove(key) }
        return keys
    }

    /// Deletes one render: its manifest first (it is never advertised without its file), then the file.
    func remove(_ key: RenditionKey) {
        items[key] = nil
        let manager = FileManager.default
        if let path = CloudAudioLocalLayout.relativePath(key, manifest: true) {
            try? manager.removeItem(at: directory.appendingPathComponent(path))
        }
        if let path = CloudAudioLocalLayout.relativePath(key) {
            try? manager.removeItem(at: directory.appendingPathComponent(path))
        }
        let folder = directory.appendingPathComponent(key.videoId, isDirectory: true)
        if (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? manager.removeItem(at: folder) }
    }

    /// "Remove downloaded renders": everything in the folder goes (never anything in the shared library). Returns the
    /// renders the index held.
    func removeAll() -> [RenditionKey] {
        let keys = Array(items.keys)
        items.removeAll()
        let manager = FileManager.default
        for url in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? manager.removeItem(at: url)
        }
        return keys
    }

    // MARK: Files

    /// The folder, created, and excluded from backups (renders come back from the shared library or the cloud).
    private func prepareDirectory() {
        var folder = directory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    private static func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    private static func modificationMs(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date else { return 0 }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func setModification(_ ms: Int64, of url: URL) {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
