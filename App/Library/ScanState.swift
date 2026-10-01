import Foundation

/// What a file looked like when it was last read (modification time + size). A file whose stamp is unchanged is
/// not read again on an incremental scan.
nonisolated struct FileStamp: Sendable, Codable, Hashable {
    var modifiedMs: Int64
    var size: Int64
}

/// The scanner's memory between runs (`Application Support/library-scan-state.plist`): the stamp of every file it
/// read, the files it rejected (too short / unreadable) so they aren't re-read until they change, the root paths
/// (a moved root rewrites its songs' URLs) and the filter options of the last scan.
nonisolated struct ScanState: Sendable, Codable, Equatable {
    static let currentVersion = 1

    var version = ScanState.currentVersion
    /// Song id → stamp of the imported file.
    var stamps: [String: FileStamp] = [:]
    /// Song id → stamp of a file that was read but not imported.
    var rejected: [String: FileStamp] = [:]
    /// `LibraryScanOptions.filterFingerprint` of the last scan.
    var filterFingerprint: String?

    static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("library-scan-state.plist")
    }

    static func load(from url: URL?) -> ScanState {
        guard let url, let data = try? Data(contentsOf: url),
              let state = try? PropertyListDecoder().decode(ScanState.self, from: data),
              state.version == currentVersion else { return ScanState() }
        return state
    }

    func save(to url: URL?) {
        guard let url else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Forget a file so the next scan reads it again (tag override set or cleared, write-back done).
    mutating func invalidate(_ songID: String) {
        stamps[songID] = nil
        rejected[songID] = nil
    }
}

/// The diff of one root's listing against the previous scan (Android: `isSongUnchanged` + the deletion phase).
nonisolated struct FolderScanPlan: Sendable, Equatable {
    /// Files to read (new, changed, or everything on a full scan).
    var toRead: [ScannedFileEntry] = []
    /// Files whose stamp matches an imported song: the stored song is kept.
    var unchanged: [ScannedFileEntry] = []
    /// iCloud placeholders: a stored song is kept as is, nothing new is imported.
    var placeholders: [ScannedFileEntry] = []
    /// Files skipped because they were rejected before and haven't changed.
    var stillRejected: [ScannedFileEntry] = []

    /// - Parameters:
    ///   - storedSongIDs: ids of the songs of this root currently in the library.
    ///   - fullRescan: read every file again (`LibraryImportMode.full`, or the filter options changed).
    static func make(rootID: String, files: [ScannedFileEntry], state: ScanState, storedSongIDs: Set<String>,
                     fullRescan: Bool) -> FolderScanPlan {
        var plan = FolderScanPlan()
        for file in files {
            let id = LibraryIdentity.fileSongID(rootID: rootID, relativePath: file.relativePath)
            if file.isPlaceholder {
                plan.placeholders.append(file)
            } else if fullRescan {
                plan.toRead.append(file)
            } else if storedSongIDs.contains(id), state.stamps[id] == file.stamp {
                plan.unchanged.append(file)
            } else if state.rejected[id] == file.stamp {
                plan.stillRejected.append(file)
            } else {
                plan.toRead.append(file)
            }
        }
        return plan
    }
}
