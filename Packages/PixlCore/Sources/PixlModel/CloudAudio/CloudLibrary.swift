// The shared library of finished renders (cloud audio spec of 2026-11-10, sections 2, 3 and 6.2): its ids and
// versions, the object keys in R2, and the layout of the copies a phone keeps.
//
//   lib/v1/<videoId>/sp-<profile>.flac     the binaural render
//   lib/v1/<videoId>/sp-<profile>.json     its manifest, written last: its presence means the render is complete
//
// Phones sign the URLs themselves (the same bucket and keys as Cloud Studio) and never delete `lib/` objects: other
// devices use them, and the bucket's lifecycle rule removes them 30 days after they were written.

import Foundation

public enum CloudLibrary {
    /// The library version `LIB_V`, in every key. It is bumped when the renderer or the separator changes audibly;
    /// renders of an older version are then ignored (in the bucket and on the phone) and expire on their own.
    public static let version = 1
    /// The render engine id (`render.engine` in a manifest, `engine` in the on-device table file).
    public static let engineId = "pixl-spatial-1"
    /// The worker version this contract was written against (`worker.version` in a manifest; informational).
    public static let workerVersion = "1.1.0"
    /// `lib/`: everything of the library, every version.
    public static let rootPrefix = "lib/"
    public static let audioExtension = "flac"
    public static let manifestExtension = "json"
    /// How long a render stays shared (the bucket's catch-all lifecycle rule). Phones keep their copy as long as they like.
    public static let timeToLiveDays = 30

    /// `lib/v1/`: this version's renders.
    public static var versionPrefix: String { "\(rootPrefix)v\(version)/" }

    /// A YouTube video id as the library accepts it: `^[A-Za-z0-9_-]{11}$`.
    public static func isValidVideoId(_ id: String) -> Bool {
        let bytes = id.utf8
        guard bytes.count == 11 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x5F || byte == 0x2D
        }
    }

    /// `lib/v1/<videoId>/`, or nil for a video id the library does not accept.
    public static func folder(videoId: String) -> String? {
        guard isValidVideoId(videoId) else { return nil }
        return "\(versionPrefix)\(videoId)/"
    }

    /// `lib/v1/<videoId>/sp-<profile>.flac`, or nil for a video id the library does not accept.
    public static func audioKey(_ key: RenditionKey) -> String? {
        folder(videoId: key.videoId).map { "\($0)\(key.slot).\(audioExtension)" }
    }

    /// `lib/v1/<videoId>/sp-<profile>.json`, or nil for a video id the library does not accept.
    public static func manifestKey(_ key: RenditionKey) -> String? {
        folder(videoId: key.videoId).map { "\($0)\(key.slot).\(manifestExtension)" }
    }

    /// An object key of this library version, taken apart.
    public struct ObjectKey: Sendable, Hashable {
        public var rendition: RenditionKey
        /// The manifest (`.json`), not the audio (`.flac`).
        public var isManifest: Bool
    }

    /// The reverse of `audioKey` / `manifestKey`. Nil for anything that is not exactly a key of this library version
    /// (another version, an unknown profile, a bad video id, extra path parts).
    public static func parse(objectKey: String) -> ObjectKey? {
        guard objectKey.hasPrefix(versionPrefix) else { return nil }
        let parts = objectKey.dropFirst(versionPrefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, isValidVideoId(String(parts[0])) else { return nil }
        guard let file = CloudAudioLocalLayout.parse(fileName: String(parts[1])) else { return nil }
        return ObjectKey(rendition: RenditionKey(videoId: String(parts[0]), profile: file.profile),
                         isManifest: file.isManifest)
    }
}

/// The copies a phone keeps (spec 6.2): `<app data>/CloudAudio/<videoId>/sp-<profile>.flac` and `.json` (iOS:
/// Application Support; Android: `filesDir/cloud_audio`). A file plus a valid manifest beside it is the index:
/// there is no database. The video id and the profile are in the path, so a file says what it is.
public enum CloudAudioLocalLayout {
    /// The folder's name on iOS, under Application Support.
    public static let directoryName = "CloudAudio"

    public static func audioFileName(_ profile: SpatialProfile) -> String {
        "\(RenditionKey.slot(profile)).\(CloudLibrary.audioExtension)"
    }

    public static func manifestFileName(_ profile: SpatialProfile) -> String {
        "\(RenditionKey.slot(profile)).\(CloudLibrary.manifestExtension)"
    }

    /// `<videoId>/sp-<profile>.flac` (or `.json`), relative to the store's folder; nil for a video id the library does
    /// not accept (so a path is never built from text that could leave the folder).
    public static func relativePath(_ key: RenditionKey, manifest: Bool = false) -> String? {
        guard CloudLibrary.isValidVideoId(key.videoId) else { return nil }
        return "\(key.videoId)/\(manifest ? manifestFileName(key.profile) : audioFileName(key.profile))"
    }

    /// A file name of the store taken apart: `sp-wide.flac` → (wide, audio). Nil for anything else.
    public static func parse(fileName: String) -> (profile: SpatialProfile, isManifest: Bool)? {
        guard let dot = fileName.lastIndex(of: ".") else { return nil }
        let ext = String(fileName[fileName.index(after: dot)...])
        guard ext == CloudLibrary.audioExtension || ext == CloudLibrary.manifestExtension,
              let profile = RenditionKey.profile(slot: String(fileName[..<dot])) else { return nil }
        return (profile, ext == CloudLibrary.manifestExtension)
    }

    /// Which rendition an audio file of the store is, from the last three parts of its path
    /// (`…/CloudAudio/<videoId>/sp-<profile>.flac`). Nil for a manifest and for any file that is not in the store, so
    /// the player can ask this of whatever file it is about to play: a spatial render plays with the on-device stage
    /// bypassed, everything else does not.
    public static func rendition(ofAudioFileAt pathComponents: [String]) -> RenditionKey? {
        guard pathComponents.count >= 3 else { return nil }
        let count = pathComponents.count
        let fileName = pathComponents[count - 1], videoId = pathComponents[count - 2]
        guard pathComponents[count - 3] == directoryName, CloudLibrary.isValidVideoId(videoId),
              let file = parse(fileName: fileName), !file.isManifest else { return nil }
        return RenditionKey(videoId: videoId, profile: file.profile)
    }

    /// `rendition(ofAudioFileAt:)` for a file URL.
    public static func rendition(ofAudioFile url: URL) -> RenditionKey? {
        guard url.isFileURL else { return nil }
        return rendition(ofAudioFileAt: url.pathComponents)
    }
}
