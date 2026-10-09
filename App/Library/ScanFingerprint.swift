import Foundation

/// The "nothing changed" test of an incremental rescan (`LocalLibraryImporter`). A scan's result depends on the files
/// (their stamps), on every scan option, on the roots and where they live, on hidden songs, on tag overrides, on the
/// device music library and on the code that builds the rows. The first is compared per file; the rest is folded into
/// one fingerprint saved with the scan state. A rescan that finds the same fingerprint, the same row count in the song
/// table and every file as the last scan left it has nothing to do, and does nothing: no snapshot read, no build, no
/// write. Anything that differs falls back to the full pass.
nonisolated enum ScanFingerprint {
    /// Bump when a scan would produce different rows for the same inputs (a builder or grouping fix).
    static let algorithmVersion = 1

    /// The code that builds the rows: a different build rescans fully once, so a builder fix reaches an existing
    /// library. The bundle version is constant on CI builds, hence the executable's size.
    static let buildStamp: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "").\(info["CFBundleVersion"] as? String ?? "")"
        var size: Int64 = 0
        if let path = Bundle.main.executablePath,
           let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let bytes = attributes[.size] as? NSNumber {
            size = bytes.int64Value
        }
        return "\(algorithmVersion)|\(version)|\(size)"
    }()

    /// FNV-1a 64 of the parts (a process-independent hash: `Hasher` is seeded per launch), as hex.
    static func hash(_ parts: [String]) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for part in parts {
            for byte in part.utf8 {
                value ^= UInt64(byte)
                value = value &* 0x0000_0100_0000_01b3
            }
            value ^= 0x1f // part separator
            value = value &* 0x0000_0100_0000_01b3
        }
        return String(value, radix: 16)
    }

    /// - Parameters:
    ///   - roots / unresolved: where the scan looks, and which folders could not be opened this time (their songs stay).
    ///   - hidden: `HiddenSongs.ids()`.
    ///   - overrides: `PersistenceActor.tagOverridesSignature()`.
    ///   - media: `mediaLibrarySignature(takesPart:lastModified:)`.
    static func make(options: LibraryScanOptions, roots: [FolderRoot], unresolved: Set<String>, hidden: Set<String>,
                     overrides: String, media: String, build: String = buildStamp) -> String {
        let separator = "\u{1}"
        return hash([
            build,
            options.artistDelimiters.joined(separator: separator),
            options.artistWordDelimiters.joined(separator: separator),
            "\(options.extractArtistsFromTitle)|\(options.groupByAlbumArtist)|\(options.minSongDurationMs)",
            options.allowedDirectories.sorted().joined(separator: separator),
            options.blockedDirectories.sorted().joined(separator: separator),
            "\(options.includeMediaLibrary)",
            roots.map { "\($0.id)|\($0.displayName)|\($0.url.standardizedFileURL.absoluteString)" }
                .joined(separator: separator),
            unresolved.sorted().joined(separator: separator),
            hidden.sorted().joined(separator: separator),
            overrides,
            media,
        ])
    }

    /// Whether the device music library takes part in the scan, and its last change when it does. A changed date means
    /// "read the items again".
    static func mediaLibrarySignature(takesPart: Bool, lastModified: Date?) -> String {
        guard takesPart, let lastModified else { return "off" }
        return "on|\(lastModified.timeIntervalSince1970)"
    }

    /// Whether one root's listing is exactly what the last scan left behind: every imported file at its recorded stamp,
    /// every other file known as rejected at its stamp, iCloud placeholders only where a song is kept, and no imported
    /// or rejected file gone. Reading the root again would then change nothing. (`files` has the directory rules
    /// applied, like the scan's own loop.)
    static func rootIsUnchanged(rootID: String, files: [ScannedFileEntry], state: ScanState,
                                stampedIDs: Set<String>, rejectedIDs: Set<String>) -> Bool {
        var stampedSeen = 0
        var rejectedSeen = 0
        for file in files {
            let id = LibraryIdentity.fileSongID(rootID: rootID, relativePath: file.relativePath)
            if file.isPlaceholder {
                // Kept as it is when a song exists; nothing to import otherwise.
                if stampedIDs.contains(id) { stampedSeen += 1 }
            } else if let stamp = state.stamps[id] {
                guard stamp == file.stamp else { return false }
                stampedSeen += 1
            } else if let stamp = state.rejected[id], stamp == file.stamp {
                rejectedSeen += 1
            } else {
                return false // a new or changed file to read
            }
        }
        return stampedSeen == stampedIDs.count && rejectedSeen == rejectedIDs.count
    }

    /// The ids grouped by the root they belong to (`f:<root>/…`).
    static func idsByRoot<S: Sequence<String>>(_ ids: S) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for id in ids {
            if let root = LibraryIdentity.rootID(ofFileSongID: id) { result[root, default: []].insert(id) }
        }
        return result
    }
}
