import Foundation

/// A folder the scanner walks: a user-picked folder (security-scoped bookmark) or the app's Documents folder.
nonisolated struct FolderRoot: Sendable, Equatable, Identifiable {
    /// `documents` for the Documents folder, else the `FolderSourceRecord` id.
    var id: String
    /// Unique among the roots; the first component of every library path under this root.
    var displayName: String
    /// The resolved folder URL (its security scope is held open by `FolderAccessRegistry`).
    var url: URL

    static let documentsID = "documents"
    /// The Documents folder appears as "PixlAudio" in the Files app (On My iPhone › PixlAudio).
    static let documentsDisplayName = "PixlAudio"

    /// `/<display name>` — the library path of the root (Android: a storage root such as `/storage/emulated/0`).
    var libraryPath: String { "/" + displayName }
}

/// Song ids, library paths and stable album ids of scanned items.
nonisolated enum LibraryIdentity {
    static let filePrefix = "f:"
    static let mediaLibraryPrefix = "mp:"

    /// `f:<root id>/<relative path>` (architecture §2).
    static func fileSongID(rootID: String, relativePath: String) -> String { "\(filePrefix)\(rootID)/\(relativePath)" }

    /// `mp:<persistentID>`.
    static func mediaLibrarySongID(persistentID: UInt64) -> String { "\(mediaLibraryPrefix)\(persistentID)" }

    /// Songs the importer owns (and may delete when their file disappears). Spotify / YouTube songs are never touched.
    static func isManaged(_ songID: String) -> Bool {
        songID.hasPrefix(filePrefix) || songID.hasPrefix(mediaLibraryPrefix)
    }

    static func rootID(ofFileSongID id: String) -> String? {
        guard id.hasPrefix(filePrefix) else { return nil }
        let rest = id.dropFirst(filePrefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return String(rest[..<slash])
    }

    /// The library path of a file: `/<root display name>/<relative path>`. Its parent is the song's
    /// `parentDirectory` (the folder tree, album grouping by folder and the allow/block directory rules use it).
    static func libraryPath(root: FolderRoot, relativePath: String) -> String {
        root.libraryPath + "/" + relativePath
    }

    static func parentDirectory(ofLibraryPath path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash > path.startIndex else { return "" }
        return String(path[..<slash])
    }

    /// A positive id in `1 ... 10¹²` from a key (FNV-1a 64), for albums of scanned files: the album grouping key, so
    /// the same album gets the same id on every scan even before an album row exists.
    static func stableID(_ key: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int64(hash % 1_000_000_000_000) + 1
    }
}

/// The audio file types the scanner imports (what AVFoundation plays on iOS), with the MIME type Android's
/// MediaStore reports for them.
nonisolated enum AudioFileTypes {
    static let mimeTypes: [String: String] = [
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "m4b": "audio/mp4", "aac": "audio/aac", "adts": "audio/aac",
        "wav": "audio/x-wav", "wave": "audio/x-wav", "aif": "audio/x-aiff", "aiff": "audio/x-aiff",
        "aifc": "audio/x-aiff", "caf": "audio/x-caf", "flac": "audio/flac",
    ]

    static func isAudio(_ fileExtension: String) -> Bool { mimeTypes[fileExtension.lowercased()] != nil }
    static func mimeType(_ fileExtension: String) -> String? { mimeTypes[fileExtension.lowercased()] }

    /// Sidecar cover images, checked when a file has no embedded artwork (lower-cased base names).
    static let coverBaseNames: Set<String> = ["cover", "folder", "album", "front", "albumart", "artwork"]
    static let coverExtensions: Set<String> = ["jpg", "jpeg", "png"]
}

/// One audio file found under a root.
nonisolated struct ScannedFileEntry: Sendable, Equatable {
    /// Path below the root, `/`-separated, no leading slash.
    var relativePath: String
    var url: URL
    /// Modification time in ms since 1970 (Android `DATE_MODIFIED`).
    var modifiedMs: Int64
    var size: Int64
    /// An iCloud file that is not on the device yet (download requested; imported on a later scan).
    var isPlaceholder: Bool

    var stamp: FileStamp { FileStamp(modifiedMs: modifiedMs, size: size) }
}

/// Result of walking one root.
nonisolated struct FolderListing: Sendable {
    var files: [ScannedFileEntry]
    /// Sidecar cover image per relative directory ("" = the root itself).
    var coverImages: [String: URL]
}

/// Walks a root with `FileManager`'s directory enumerator (synchronous; call it off the main actor).
///
/// Rules ported from Android's MediaStore scan: hidden files and folders are skipped, a folder containing a
/// `.nomedia` file is skipped with everything below it, and only audio types are listed. iCloud placeholders
/// (`.name.icloud` files, or entries whose download status isn't current) are listed as placeholders and their
/// download is started.
nonisolated enum AudioFileEnumerator {
    static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    static func list(root: URL, startDownloads: Bool = true) -> FolderListing {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: resourceKeys,
                                                      options: [.skipsPackageDescendants],
                                                      errorHandler: { _, _ in true }) else {
            return FolderListing(files: [], coverImages: [:])
        }
        var files: [ScannedFileEntry] = []
        var noMediaDirectories: [String] = []
        var covers: [String: URL] = [:]
        while let next = enumerator.nextObject() {
            guard let url = next as? URL else { continue }
            let level = enumerator.level
            let components = url.pathComponents.suffix(level)
            guard let name = components.last else { continue }
            let directory = components.dropLast().joined(separator: "/")
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))

            if values?.isDirectory == true {
                if name.hasPrefix(".") { enumerator.skipDescendants() }
                continue
            }
            if name == ".nomedia" {
                noMediaDirectories.append(directory)
                continue
            }
            // iCloud placeholder of a file that was evicted: `.Song.mp3.icloud`.
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let original = String(name.dropFirst().dropLast(".icloud".count))
                guard AudioFileTypes.isAudio((original as NSString).pathExtension) else { continue }
                let originalURL = url.deletingLastPathComponent().appendingPathComponent(original)
                if startDownloads { try? fileManager.startDownloadingUbiquitousItem(at: originalURL) }
                let relative = directory.isEmpty ? original : directory + "/" + original
                files.append(ScannedFileEntry(relativePath: relative, url: originalURL, modifiedMs: 0, size: 0,
                                              isPlaceholder: true))
                continue
            }
            if name.hasPrefix(".") { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            if AudioFileTypes.coverExtensions.contains(ext),
               AudioFileTypes.coverBaseNames.contains((name as NSString).deletingPathExtension.lowercased()),
               covers[directory] == nil {
                covers[directory] = url
                continue
            }
            guard AudioFileTypes.isAudio(ext), values?.isRegularFile != false else { continue }
            var isPlaceholder = false
            if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus,
               status != .current {
                isPlaceholder = true
                if startDownloads { try? fileManager.startDownloadingUbiquitousItem(at: url) }
            }
            let modified = values?.contentModificationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
            let relative = components.joined(separator: "/")
            files.append(ScannedFileEntry(relativePath: relative, url: url, modifiedMs: modified,
                                          size: Int64(values?.fileSize ?? 0), isPlaceholder: isPlaceholder))
        }
        if !noMediaDirectories.isEmpty {
            files.removeAll { entry in
                let directory = (entry.relativePath as NSString).deletingLastPathComponent
                return noMediaDirectories.contains { isAtOrUnder(directory, $0) }
            }
        }
        return FolderListing(files: files, coverImages: covers)
    }

    /// Whether `path` is `root` or below it (relative paths; "" is the top).
    static func isAtOrUnder(_ path: String, _ root: String) -> Bool {
        if root.isEmpty || path == root { return true }
        return path.hasPrefix(root + "/")
    }
}
