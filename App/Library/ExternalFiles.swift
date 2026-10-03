import Foundation

/// Files opened in PixlAudio from the Files app or the share sheet (the document types declared in project.yml;
/// Android's external intents): backups, M3U playlists, LRC / TTML lyrics and audio files.
nonisolated enum ExternalFiles {
    enum Kind: Equatable, Sendable {
        case backup, playlist, lyrics, audio, unsupported
    }

    static func kind(of url: URL) -> Kind {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".pxpl") || name.hasSuffix(".gz") { return .backup }
        switch url.pathExtension.lowercased() {
        case "m3u", "m3u8": return .playlist
        case "lrc", "ttml": return .lyrics
        default: return AudioFileTypes.isAudio(url.pathExtension) ? .audio : .unsupported
        }
    }

    /// The bytes of a small file handed to the app (a playlist), read under its security scope.
    static func read(_ url: URL, maxBytes: Int = 8 * 1024 * 1024) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Puts an audio file where the library scan finds it and returns its path below Documents (the scan's
    /// `documents` root): a file already inside the app's Documents folder (Files › On My iPhone › PixlAudio, opened
    /// in place) stays where it is; any other is copied into `Documents/Imported` — the same file opened again is
    /// reused, a different one with the same name gets a numbered name.
    @concurrent
    static func importAudio(_ url: URL) async -> String? {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let documentsPath = documents.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        if filePath.hasPrefix(documentsPath + "/") {
            return String(filePath.dropFirst(documentsPath.count + 1))
        }

        let folder = documents.appendingPathComponent("Imported", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let baseName = (url.lastPathComponent as NSString).deletingPathExtension
        let fileExtension = url.pathExtension
        let sourceSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        var counter = 1
        while fileManager.fileExists(atPath: destination.path) {
            let existingSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
            if existingSize == sourceSize { return "Imported/" + destination.lastPathComponent }
            destination = folder.appendingPathComponent("\(baseName) (\(counter)).\(fileExtension)")
            counter += 1
        }

        var coordinationError: NSError?
        var copied = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            copied = (try? fileManager.copyItem(at: source, to: destination)) != nil
        }
        return copied ? "Imported/" + destination.lastPathComponent : nil
    }
}
