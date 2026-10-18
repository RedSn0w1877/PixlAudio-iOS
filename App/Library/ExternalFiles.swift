import Foundation

/// Files opened in PixlAudio from the Files app or the share sheet (the document types declared in project.yml;
/// Android's external intents): backups, M3U playlists and LRC / TTML lyrics. (Audio files are not accepted: the app is Spotify-only.)
nonisolated enum ExternalFiles {
    enum Kind: Equatable, Sendable {
        case backup, playlist, lyrics, unsupported
    }

    static func kind(of url: URL) -> Kind {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".pxpl") || name.hasSuffix(".gz") { return .backup }
        switch url.pathExtension.lowercased() {
        case "m3u", "m3u8": return .playlist
        case "lrc", "ttml": return .lyrics
        default: return .unsupported
        }
    }

    /// The bytes of a small file handed to the app (a playlist), read under its security scope.
    static func read(_ url: URL, maxBytes: Int = 8 * 1024 * 1024) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes else { return nil }
        return try? Data(contentsOf: url)
    }
}
