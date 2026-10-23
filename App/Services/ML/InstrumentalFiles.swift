import Foundation
import PixlAudioCore

/// Rendered instrumentals on disk (Android `TaisInstrumentalIndex`): `Application Support/Stems/`, one
/// `<song>_instrumental.wav` (on-device MDX-Net) and/or `<song>_hq_roformer_inst.wav` (cloud BS-RoFormer, preferred)
/// and/or `<song>_cloud_inst.m4a` (Cloud Studio, ranked between the two) per song, names from PixlAudioCore's
/// `StemFiles` (song ids made file-safe). Excluded from iCloud backups — they can be rendered again.
nonisolated enum InstrumentalFiles {
    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Stems", isDirectory: true)
    }

    static func instrumentalURL(songId: String) -> URL? {
        directory?.appendingPathComponent(StemFiles.safeName(songId) + StemFiles.instrumentalSuffix)
    }

    static func roformerURL(songId: String) -> URL? {
        directory?.appendingPathComponent(StemFiles.safeName(songId) + StemFiles.roformerSuffix)
    }

    /// Cloud Studio's result: `<song>_cloud_inst.m4a` (AAC), or `.flac` after a FLAC redo.
    static func cloudURL(songId: String, flac: Bool) -> URL? {
        directory?.appendingPathComponent(StemFiles.safeName(songId) + (flac ? StemFiles.cloudFlacSuffix : StemFiles.cloudSuffix))
    }

    /// The best complete render for a song (`bestAvailableFile`), or nil.
    static func bestAvailable(songId: String) -> URL? {
        guard let directory else { return nil }
        for name in StemFiles.candidates(songId: songId) {
            let url = directory.appendingPathComponent(name)
            if isComplete(url) { return url }
        }
        return nil
    }

    /// `isCompleteStem` on the file's first bytes and length.
    static func isComplete(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let length = (attributes[.size] as? NSNumber)?.int64Value,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 12)) ?? Data()
        return StemFiles.isCompleteStem(firstBytes: [UInt8](head), fileLength: length)
    }

    /// Creates the directory (excluded from backups).
    static func prepareDirectory() throws {
        guard var directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    /// Total size of the renders (Experimental › On-device models).
    static var totalBytes: Int64 {
        guard let directory else { return 0 }
        return ModelManager.directorySize(directory)
    }

    static func deleteAll() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Sing's preview pieces

    /// `Caches/SingClips/`: Sing's preview pieces (`<song>_clip_<startMs>.m4a`), a minute of a song's instrumental
    /// played until the whole one lands. Never in `Stems/`, so nothing above (`bestAvailable`, the cloud's "has an
    /// instrumental") counts them; deleted when the whole instrumental lands, when the song changes and at launch.
    static var clipsDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SingClips", isDirectory: true)
    }

    static func clipURL(songId: String, startMs: Int64, flac: Bool) -> URL? {
        clipsDirectory?.appendingPathComponent(StemFiles.clipFileName(songId: songId, startMs: startMs, flac: flac))
    }

    static func prepareClipsDirectory() throws {
        guard let clipsDirectory else { return }
        try FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
    }

    /// Deletes a song's preview pieces.
    static func removeClips(songId: String) {
        guard let clipsDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: clipsDirectory.path) else { return }
        let prefix = StemFiles.clipPrefix(songId: songId)
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: clipsDirectory.appendingPathComponent(name))
        }
    }

    /// Deletes every preview piece (launch: what they were for ended with the last process).
    static func removeAllClips() {
        guard let clipsDirectory else { return }
        try? FileManager.default.removeItem(at: clipsDirectory)
    }
}
