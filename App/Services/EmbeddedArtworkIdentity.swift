import CryptoKit
import Foundation
import Synchronization

/// Which picture an audio file's embedded artwork is: a short digest of the picture's bytes, per file.
///
/// Embedded art used to be cached per audio file (`e:<file url>`): every track of an album decoded, stored and
/// colour-extracted its own copy of the same cover. With the digest the memory cache, the disk thumbnails, the
/// in-flight decodes, the colour mirror and the stored album themes are keyed by the picture (`c:<digest>`), so an
/// album's N tracks share one entry. Byte-identical pictures decode to identical pixels: nothing on screen changes.
///
/// The index is learned where the bytes are already in hand: by the library scan (it reads the file's tags anyway) and
/// by the first decode of a file (`ArtworkPipeline`), so a library scanned before this existed fills in as its covers
/// are shown. A file that isn't in the index keeps its old per-file key. The index is a cache in `Caches/` (a purged
/// one is learned again); it is read once, written a few seconds after the last change, and a rescan that reads a
/// changed file records its new picture.
nonisolated final class EmbeddedArtworkIdentity: Sendable {
    static let shared = EmbeddedArtworkIdentity(storeURL: defaultStoreURL())

    private struct State {
        var digests: [String: String] = [:]
        var loaded = false
        var saveScheduled = false
    }

    private let state = Mutex(State())
    private let storeURL: URL?

    init(storeURL: URL?) { self.storeURL = storeURL }

    static func defaultStoreURL() -> URL? {
        // Next to the thumbnail folder, not in it: `ArtworkPipeline.trimDiskCache` trims that folder by age.
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("embedded-artwork-identity.plist")
    }

    /// A short digest of a picture: 16 bytes of its SHA-256, as hex. (Not a security boundary: a cache key.)
    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The digest of the picture embedded in the file at `url`, if it has been learned.
    func digest(for url: URL) -> String? {
        let key = url.absoluteString
        return state.withLock { state in
            loadIfNeeded(&state)
            return state.digests[key]
        }
    }

    /// Learns (or replaces) the picture of the file at `url`.
    func record(_ digest: String, for url: URL) {
        let key = url.absoluteString
        let schedule: Bool = state.withLock { state in
            loadIfNeeded(&state)
            guard state.digests[key] != digest else { return false }
            state.digests[key] = digest
            guard !state.saveScheduled, storeURL != nil else { return false }
            state.saveScheduled = true
            return true
        }
        if schedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [self] in flushNow() }
        }
    }

    /// Reads the stored index now (launch calls it off the main thread so the first frame finds it loaded).
    func preload() {
        state.withLock { loadIfNeeded(&$0) }
    }

    /// Writes the index (atomically) when it changed since the last write.
    func flushNow() {
        guard let storeURL else { return }
        let snapshot: [String: String] = state.withLock { state in
            state.saveScheduled = false
            return state.digests
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    private func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let stored = try? PropertyListDecoder().decode([String: String].self, from: data) else { return }
        // Anything recorded before the read finished is newer than the file.
        state.digests.merge(stored) { current, _ in current }
    }
}
