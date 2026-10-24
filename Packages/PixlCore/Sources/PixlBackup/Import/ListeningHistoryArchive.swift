// Settings › Library & storage › Listening history › Import from a file: what the picker hands over — the ZIP Spotify or
// Google Takeout sends, or the JSON files taken out of it — into plays. ZIPs are read with PixlBackup's own reader and
// inflater (no new dependency); only the history files inside are expanded, one at a time.

import Foundation
import PixlLibrary
import PixlModel

public enum ListeningHistoryArchive {
    /// One history file expands to at most this much (a decade of Spotify extended history is ~15 MB per file).
    public static let maxEntryBytes = 256 * 1024 * 1024

    /// What one picked file held.
    public struct Result: Sendable {
        public var plays: [ImportedPlay] = []
        /// History files read (inside a ZIP, or the file itself).
        public var filesRead = 0
        public var skippedEntries = 0
        /// Takeout sent HTML instead of JSON ("choose JSON in Takeout").
        public var foundHTMLHistory = false
        /// Kinds of history found.
        public var kinds: Set<ListeningHistoryFileKind> = []

        public init() {}
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case notHistory
        case unreadableZip(String)

        public var description: String {
            switch self {
            case .notHistory: "This file has no listening history in it."
            case .unreadableZip(let why): "The ZIP couldn't be opened (\(why))."
            }
        }
    }

    public static func isZip(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && (bytes[2] == 0x03 || bytes[2] == 0x05)
    }

    /// Reads a picked file (ZIP or JSON). `progress` gets 0…1 across the history files.
    public static func read(fileName: String, bytes: [UInt8],
                            progress: ((Double) -> Void)? = nil) throws(Failure) -> Result {
        var result = Result()
        if isZip(bytes) {
            let archive: ZipArchive
            do { archive = try ZipArchive(bytes: bytes) } catch { throw .unreadableZip(error.description) }
            let wanted = archive.entries.filter { entry in
                guard !entry.name.hasSuffix("/"), !entry.name.contains("__MACOSX") else { return false }
                let kind = ListeningHistoryFileKind.fromName(entry.name)
                if kind == .ignored, entry.name.lowercased().hasSuffix("watch-history.html") { result.foundHTMLHistory = true }
                return kind == .spotifyExtended || kind == .spotifyBasic || kind == .takeoutWatchHistory
            }
            for (index, entry) in wanted.enumerated() {
                guard let data = try? archive.data(for: entry, maxSize: maxEntryBytes) else {
                    result.skippedEntries += 1
                    continue
                }
                let base = Double(index) / Double(wanted.count)
                let parsed = ListeningHistoryParsers.parse(fileName: entry.name, bytes: data) { fraction in
                    progress?(base + fraction / Double(wanted.count))
                }
                add(parsed, to: &result)
            }
        } else {
            if fileName.lowercased().hasSuffix(".html") { result.foundHTMLHistory = true }
            let parsed = ListeningHistoryParsers.parse(fileName: fileName, bytes: bytes, progress: progress)
            add(parsed, to: &result)
        }
        progress?(1)
        if result.plays.isEmpty && result.filesRead == 0 && !result.foundHTMLHistory { throw .notHistory }
        return result
    }

    private static func add(_ parsed: ListeningHistoryFileParse, to result: inout Result) {
        switch parsed.kind {
        case .spotifyExtended, .spotifyBasic, .takeoutWatchHistory:
            result.filesRead += 1
            result.kinds.insert(parsed.kind)
            result.plays += parsed.plays
            result.skippedEntries += parsed.skipped
        case .ignored, .unknown:
            break
        }
    }
}
