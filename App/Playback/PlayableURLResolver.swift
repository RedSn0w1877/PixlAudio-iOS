import AVFoundation
import Foundation
import PixlModel

/// Turns a `Song` into the URL an `AVURLAsset` plays. Stage 6 injects a resolver that opens folder bookmarks
/// (security scope) and maps `mp:` ids to `ipod-library://` asset URLs; stage 11 maps `yt:` ids to its streaming scheme.
nonisolated protocol PlayableURLResolving: Sendable {
    /// The URL to play, or nil when the song can't be played (missing file, no stream yet).
    func playableURL(for song: Song) async -> URL?
}

/// The default resolver: `contentUriString` when it parses as a URL with a scheme (file, ipod-library, http(s) or a
/// registered streaming scheme), else `path` as an absolute file path.
nonisolated struct DefaultPlayableURLResolver: PlayableURLResolving {
    func playableURL(for song: Song) async -> URL? {
        Self.url(for: song)
    }

    static func url(for song: Song) -> URL? {
        let uri = song.contentUriString
        if !uri.isEmpty, let url = URL(string: uri), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }
        if uri.hasPrefix("/") { return URL(fileURLWithPath: uri) }
        if song.path.hasPrefix("/") { return URL(fileURLWithPath: song.path) }
        return nil
    }
}

/// Hook for stage 11's streaming resource loader: a URL scheme (e.g. `pixlstream`) whose assets get a resource-loader
/// delegate. The playback stage contains no YouTube code; it only attaches whatever delegate is registered here.
@MainActor
final class StreamingResourceLoaderRegistry {
    /// A factory for one asset's delegate (a fresh delegate per asset keeps per-request state separate).
    typealias Factory = @Sendable (URL) -> (any AVAssetResourceLoaderDelegate)?

    static let shared = StreamingResourceLoaderRegistry()

    private var factories: [String: Factory] = [:]
    /// Delegates are held weakly by AVFoundation; keep them alive with their asset.
    private var live: [ObjectIdentifier: any AVAssetResourceLoaderDelegate] = [:]
    /// The queue resource-loader callbacks run on (one serial queue for all streams).
    let delegateQueue = DispatchQueue(label: "io.github.redsn0w1877.pixlaudio.resource-loader", qos: .userInitiated)

    /// Registers `factory` for `scheme` (lower-cased). Replaces an earlier registration.
    func register(scheme: String, factory: @escaping Factory) {
        factories[scheme.lowercased()] = factory
    }

    func unregister(scheme: String) {
        factories[scheme.lowercased()] = nil
    }

    func handles(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return factories[scheme] != nil
    }

    /// Attaches the registered delegate to `asset` when its scheme is registered.
    func attach(to asset: AVURLAsset) {
        guard let scheme = asset.url.scheme?.lowercased(), let factory = factories[scheme],
              let delegate = factory(asset.url) else { return }
        live[ObjectIdentifier(asset)] = delegate
        asset.resourceLoader.setDelegate(delegate, queue: delegateQueue)
    }

    /// Drops the delegate kept for `asset` (the item was discarded).
    func detach(from asset: AVURLAsset) {
        live[ObjectIdentifier(asset)] = nil
    }
}
