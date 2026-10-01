// Port of `data/repository/FolderTreeBuilder.kt` and `utils/DirectoryRuleResolver.kt`: the Folders tab tree built
// from each song's parent directory, and the allow/block rules that hide folders.

import Foundation
import PixlFoundation
import PixlModel

/// One song as the folder tree needs it (Android `FolderSongRow`).
public struct FolderSongRow: Sendable, Hashable {
    public var id: String
    public var parentDirectoryPath: String
    public var title: String
    public var albumArtUriString: String?

    public init(id: String, parentDirectoryPath: String, title: String, albumArtUriString: String? = nil) {
        self.id = id
        self.parentDirectoryPath = parentDirectoryPath
        self.title = title
        self.albumArtUriString = albumArtUriString
    }
}

/// Resolves directory allow/block rules by the nearest (longest) matching rule; an allow rule beats a block rule
/// of the same depth. Paths compare case-insensitively, trailing slashes ignored.
public struct DirectoryRuleResolver: Sendable {
    private let allowedRoots: [String]
    private let blockedRoots: [String]
    private let hasRules: Bool

    public init<A: Sequence, B: Sequence>(allowed: A, blocked: B) where A.Element == String, B.Element == String {
        allowedRoots = Self.normalizedSet(allowed)
        blockedRoots = Self.normalizedSet(blocked)
        hasRules = !allowedRoots.isEmpty || !blockedRoots.isEmpty
    }

    private static func normalizedSet<S: Sequence>(_ paths: S) -> [String] where S.Element == String {
        paths.compactMap { path -> String? in
            if path.isKotlinBlank { return nil }
            return path.utf16.last == 0x2F ? String(path.unicodeScalars.dropLast()) : path
        }.kotlinDistinct()
    }

    public func isBlocked(_ path: String) -> Bool {
        if !hasRules { return false }
        var deepestBlock = -1
        for root in blockedRoots where Self.isParentOrSame(root, path) {
            deepestBlock = max(deepestBlock, root.utf16.count)
        }
        if deepestBlock == -1 { return false }
        var deepestAllow = -1
        for root in allowedRoots where Self.isParentOrSame(root, path) {
            deepestAllow = max(deepestAllow, root.utf16.count)
        }
        return deepestBlock > deepestAllow
    }

    private static func isParentOrSame(_ root: String, _ path: String) -> Bool {
        guard KotlinText.startsWith(path, root, ignoreCase: true) else { return false }
        let p = Array(path.utf16)
        let r = root.utf16.count
        if p.count == r { return true }
        return p.count > r && p[r] == 0x2F
    }
}

public enum FolderTreeBuilder {
    /// `buildFolderTree` without the Android storage-volume lookup: filters songs through the directory rules when
    /// the folder filter is active, then builds the tree under `rootPaths` (the folder sources on iOS).
    public static func buildFolderTree(folderSongs: [FolderSongRow], allowedDirectories: Set<String>,
                                       blockedDirectories: Set<String>, isFolderFilterActive: Bool,
                                       rootPaths: [String]) -> [MusicFolder] {
        let filtered: [FolderSongRow]
        if isFolderFilterActive && !blockedDirectories.isEmpty {
            let resolver = DirectoryRuleResolver(allowed: allowedDirectories, blocked: blockedDirectories)
            filtered = folderSongs.filter { song in
                let parent = normalizePath(song.parentDirectoryPath)
                return !parent.isKotlinBlank && !resolver.isBlocked(parent)
            }
        } else {
            filtered = folderSongs
        }
        if filtered.isEmpty { return [] }
        return buildFolderTreeForRoots(folderSongs: filtered, selectedRootPaths: rootPaths)
    }

    /// `buildFolderTreeForRoots`: one tree per root (roots nested in another root are dropped), keeping only
    /// folders with songs, sorted by lower-cased name.
    public static func buildFolderTreeForRoots(folderSongs: [FolderSongRow], selectedRootPaths: [String]) -> [MusicFolder] {
        let roots = normalizeRootPaths(selectedRootPaths)
        if roots.isEmpty { return [] }
        return roots.flatMap { buildFolderTreeForRoot(folderSongs: folderSongs, selectedRootPath: $0) }
            .filter { $0.totalSongCount > 0 }
            .kotlinSorted { KotlinText.compare(KotlinText.lowercase($0.name), KotlinText.lowercase($1.name)) }
    }

    /// `inferRemovableStorageRoots`: storage roots of songs outside internal storage (Android paths).
    public static func inferRemovableStorageRoots(folderSongs: [FolderSongRow], internalStorageRoot: String,
                                                  knownRemovableRoots: [String]) -> [String] {
        let internalRoot = normalizePath(internalStorageRoot)
        let known = normalizeRootPaths(knownRemovableRoots)
        var result: [String] = []
        var seen = Set<KotlinKey>()
        for song in folderSongs {
            let parent = normalizePath(song.parentDirectoryPath)
            if parent.isKotlinBlank || isPathAtOrUnder(parent, internalRoot) { continue }
            guard let root = known.first(where: { isPathAtOrUnder(parent, $0) }) ?? inferStorageRoot(parent) else { continue }
            if seen.insert(KotlinKey(root)).inserted { result.append(root) }
        }
        return result
    }

    static func inferStorageRoot(_ path: String) -> String? {
        let parts = trimSlashes(path).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.isKotlinBlank }
        if parts.isEmpty { return nil }
        if parts[0] == "storage" && parts.count >= 3 && parts[1] == "emulated" { return "/storage/emulated/\(parts[2])" }
        if parts[0] == "storage" && parts.count >= 2 { return "/storage/\(parts[1])" }
        if parts.count >= 3 && parts[0] == "mnt" && parts[1] == "media_rw" { return "/mnt/media_rw/\(parts[2])" }
        if parts.count >= 2 && parts[0] == "mnt" { return "/mnt/\(parts[1])" }
        if KotlinText.startsWith(parts[0], "sdcard", ignoreCase: true) { return "/\(parts[0])" }
        return nil
    }

    private static func trimSlashes(_ s: String) -> String {
        var scalars = Substring(s).unicodeScalars[...]
        while scalars.first == "/" { scalars = scalars.dropFirst() }
        while scalars.last == "/" { scalars = scalars.dropLast() }
        return String(scalars)
    }

    static func normalizeRootPaths(_ rootPaths: [String]) -> [String] {
        let normalized = rootPaths.map(normalizePath).filter { !$0.isKotlinBlank }.kotlinDistinct()
        return normalized.filter { candidate in
            !normalized.contains { other in !KotlinText.equals(other, candidate) && isPathAtOrUnder(other, candidate) }
        }
    }

    static func isPathAtOrUnder(_ path: String, _ root: String) -> Bool {
        if KotlinText.equals(path, root) { return true }
        return path.utf8.starts(with: (root + "/").utf8)
    }

    static func normalizePath(_ path: String) -> String {
        path.utf16.last == 0x2F ? String(path.unicodeScalars.dropLast()) : path
    }

    static func parentPath(_ path: String) -> String? {
        let units = Array(path.utf16)
        guard let last = units.lastIndex(of: 0x2F), last > 0 else { return nil }
        return String(decoding: units[..<last], as: UTF16.self)
    }

    static func nameFromPath(_ path: String) -> String {
        let units = Array(path.utf16)
        guard let last = units.lastIndex(of: 0x2F) else { return path }
        return String(decoding: units[(last + 1)...], as: UTF16.self)
    }

    private final class TempFolder {
        let path: String
        let name: String
        var songs: [Song] = []
        var subFolderPaths = JavaHashSet()

        init(path: String, name: String) {
            self.path = path
            self.name = name
        }
    }

    private static func buildFolderTreeForRoot(folderSongs: [FolderSongRow], selectedRootPath: String) -> [MusicFolder] {
        let root = normalizePath(selectedRootPath)
        let toProcess = folderSongs.filter { isPathAtOrUnder(normalizePath($0.parentDirectoryPath), root) }
        if toProcess.isEmpty { return [] }
        var folders: [KotlinKey: TempFolder] = [:]
        func folder(_ path: String) -> TempFolder {
            if let existing = folders[KotlinKey(path)] { return existing }
            let created = TempFolder(path: path, name: nameFromPath(path))
            folders[KotlinKey(path)] = created
            return created
        }
        let rootFolder = folder(root)
        for song in toProcess {
            let parent = normalizePath(song.parentDirectoryPath)
            if parent.isKotlinBlank { continue }
            folder(parent).songs.append(stubSong(song))
            var current = parent
            while current.utf16.count > root.utf16.count && isPathAtOrUnder(current, root) {
                guard let up = parentPath(current) else { break }
                if !isPathAtOrUnder(up, root) { break }
                if !folder(up).subFolderPaths.add(current) { break }
                current = up
            }
        }
        func build(_ path: String) -> MusicFolder? {
            guard let temp = folders[KotlinKey(path)] else { return nil }
            let subFolders = temp.subFolderPaths.iterationOrder.compactMap(build)
                .kotlinSorted { KotlinText.compare(KotlinText.lowercase($0.name), KotlinText.lowercase($1.name)) }
            let songs = temp.songs.kotlinSorted { a, b in
                chain(cmp(a.trackNumber > 0 ? a.trackNumber : Int(Int32.max), b.trackNumber > 0 ? b.trackNumber : Int(Int32.max)),
                      KotlinText.compare(KotlinText.lowercase(a.title), KotlinText.lowercase(b.title)))
            }
            return MusicFolder(path: temp.path, name: temp.name, songs: songs, subFolders: subFolders)
        }
        return rootFolder.subFolderPaths.iterationOrder.compactMap(build)
            .filter { $0.totalSongCount > 0 }
            .kotlinSorted { KotlinText.compare(KotlinText.lowercase($0.name), KotlinText.lowercase($1.name)) }
    }

    /// `toFolderStubSong`. Android also rewrites MediaStore artwork URIs; iOS artwork URIs pass through unchanged.
    static func stubSong(_ row: FolderSongRow) -> Song {
        let parent = normalizePath(row.parentDirectoryPath)
        let path = parent.isKotlinBlank ? row.title : "\(parent)/\(row.title)"
        return Song(id: row.id, title: row.title, artist: "", artistId: -1, album: "", albumId: -1, path: path,
                    contentUriString: "", albumArtUriString: row.albumArtUriString, duration: 0, trackNumber: 0,
                    year: 0, dateAdded: 0, dateModified: 0, mimeType: nil, bitrate: nil, sampleRate: nil)
    }
}

/// A `java.util.HashSet<String>` that reproduces Java's iteration order (bucket order of the spread hash in a
/// table that doubles past a 0.75 load factor, insertion order within a bucket). The folder tree sorts by name,
/// so this only decides the order of folders whose lower-cased names tie — as on Android.
struct JavaHashSet {
    private var entries: [(key: String, hash: Int32)] = []
    private var keys = Set<KotlinKey>()

    /// `add`: false when already present.
    mutating func add(_ value: String) -> Bool {
        guard keys.insert(KotlinKey(value)).inserted else { return false }
        entries.append((value, KotlinText.hashCode(value)))
        return true
    }

    var iterationOrder: [String] {
        var capacity = 16
        while Double(entries.count) > Double(capacity) * 0.75 { capacity *= 2 }
        let mask = Int32(capacity - 1)
        return entries.enumerated().sorted { a, b in
            let ha = a.element.hash, hb = b.element.hash
            let ba = (ha ^ Int32(bitPattern: UInt32(bitPattern: ha) >> 16)) & mask
            let bb = (hb ^ Int32(bitPattern: UInt32(bitPattern: hb) >> 16)) & mask
            return ba != bb ? ba < bb : a.offset < b.offset
        }.map(\.element.key)
    }
}
