import Foundation

/// Song ids and library paths. The app is Spotify-only: nothing scans the phone for audio files any more, so this is
/// what is left of stage 6's identity helpers — the id prefixes that tell a song held in a file on this phone
/// (`f:` / the `mp:` rows an older build imported from the phone's music library) from a streamed one, and the
/// library-path helper the song table stores `parentDirectory` with.
nonisolated enum LibraryIdentity {
    static let filePrefix = "f:"
    static let mediaLibraryPrefix = "mp:"

    /// Songs that live in a file on this phone. Spotify / YouTube rows are never one.
    static func isManaged(_ songID: String) -> Bool {
        songID.hasPrefix(filePrefix) || songID.hasPrefix(mediaLibraryPrefix)
    }

    static func parentDirectory(ofLibraryPath path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash > path.startIndex else { return "" }
        return String(path[..<slash])
    }
}
