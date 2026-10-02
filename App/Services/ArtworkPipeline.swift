import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PixlLibrary
import PixlModel
import Synchronization
import UIKit
import UniformTypeIdentifiers

/// Where a piece of artwork comes from. Parsed from a song's / album's `albumArtUriString`.
nonisolated enum ArtworkSource: Hashable, Sendable {
    /// A local image file (sidecar cover, imported image, cached download).
    case file(URL)
    /// An http(s) image (Spotify / YouTube art).
    case remote(URL)
    /// Embedded artwork of an audio file, read by `ArtworkPipeline.embeddedArtworkLoader` (stage 6 installs it).
    case embedded(URL)
    /// Generated gradient artwork (demo library, UI tests). `seed` picks the colours.
    case generated(seed: Int)

    /// `demo-art://<seed>`, `embedded://<file url>`, `file://…`, `http(s)://…`; nil for empty / unknown strings.
    init?(uriString: String?) {
        guard let s = uriString, !s.isEmpty else { return nil }
        if s.hasPrefix("demo-art://"), let seed = Int(s.dropFirst("demo-art://".count)) {
            self = .generated(seed: seed)
        } else if s.hasPrefix("embedded://"), let url = URL(string: String(s.dropFirst("embedded://".count))) {
            self = .embedded(url)
        } else if let url = URL(string: s), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https": self = .remote(url)
            case "file": self = .file(url)
            default: return nil
            }
        } else if s.hasPrefix("/") {
            self = .file(URL(fileURLWithPath: s))
        } else {
            return nil
        }
    }

    init?(song: Song) { self.init(uriString: song.albumArtUriString) }

    /// Stable key for caches.
    var cacheKey: String {
        switch self {
        case .file(let url): "f:" + url.absoluteString
        case .remote(let url): "r:" + url.absoluteString
        case .embedded(let url): "e:" + url.absoluteString
        case .generated(let seed): "g:\(seed)"
        }
    }
}

/// A decoded, display-sized image. `CGImage` is immutable, so sharing it across actors is safe.
nonisolated final class ArtworkImage: @unchecked Sendable {
    let cgImage: CGImage
    var pixelSize: Int { max(cgImage.width, cgImage.height) }

    init(cgImage: CGImage) { self.cgImage = cgImage }
}

/// Decodes artwork off the main thread with ImageIO thumbnails at the size it is displayed, with a memory cache
/// (synchronous hits for list cells) and a disk cache of the decoded thumbnails (Caches/Artwork).
///
/// Views ask for a display size bucket (`displayPixelSize(forPoints:)`), not their exact size, so the same cover
/// shown at nearby sizes (a grid card, a list row, the mini player; the album header and the player's carousel) is
/// one cache entry instead of a miss per size; a bucket is never more than 1.6× the request, and the image is drawn
/// downscaled. The memory cache is a real LRU bounded by bytes and emptied on memory warnings; a view whose exact
/// size is missing starts from the largest decoded size of the same cover instead of the placeholder.
actor ArtworkPipeline {
    static let shared = ArtworkPipeline()

    /// Reads embedded artwork bytes of an audio file. Stage 6 (library import) installs the AVAsset-based loader.
    nonisolated(unsafe) static var embeddedArtworkLoader: (@Sendable (URL) async -> Data?)?

    /// 80 MB of decoded bitmaps (a 540 px cover is 1.1 MB; the previous 400-entry limit could reach several hundred).
    private let memory = MemoryCache(budgetBytes: 80 * 1024 * 1024)
    private var inFlight: [String: Task<ArtworkImage?, Never>] = [:]
    private let diskDirectory: URL?

    init(diskDirectory: URL? = ArtworkPipeline.defaultDiskDirectory()) {
        self.diskDirectory = diskDirectory
        if let diskDirectory {
            try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        }
        let memory = self.memory
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                   object: nil, queue: nil) { @Sendable _ in
            memory.removeAll()
        }
    }

    nonisolated static func defaultDiskDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Artwork", isDirectory: true)
    }

    /// Pixel size to request for a view `points` wide (3× covers every current iPhone).
    nonisolated static func pixelSize(forPoints points: CGFloat) -> Int { Int((points * 3).rounded(.up)) }

    /// The display buckets: every size views ask for (rows, mini player, Home cards, grid cards, mixes) rounds up to
    /// one of these; 1320 px is the widest iPhone, shared by the album header and the full player's cover.
    nonisolated static let displayBuckets = [180, 270, 408, 540, 720, 1320]

    /// The pixel size a view `points` wide decodes at: its bucket, or its exact size when the bucket would be more
    /// than 1.6× larger (tiny icons) or it is larger than every bucket.
    nonisolated static func displayPixelSize(forPoints points: CGFloat) -> Int {
        bucket(forPixels: pixelSize(forPoints: points))
    }

    nonisolated static func bucket(forPixels pixels: Int) -> Int {
        guard let bucket = displayBuckets.first(where: { $0 >= pixels }),
              Double(bucket) <= Double(pixels) * 1.6 else { return pixels }
        return bucket
    }

    /// A memory-cache hit, synchronously (for the first frame of a cell).
    nonisolated func cachedImage(_ source: ArtworkSource, pixelSize: Int) -> ArtworkImage? {
        memory.value(source: source.cacheKey, pixelSize: pixelSize)
    }

    /// The exact size if cached, else the largest decoded size of the same cover (a view's first frame shows the
    /// art, slightly softer for a moment, rather than the placeholder).
    nonisolated func cachedImageOrVariant(_ source: ArtworkSource, pixelSize: Int) -> ArtworkImage? {
        memory.value(source: source.cacheKey, pixelSize: pixelSize) ?? memory.largest(source: source.cacheKey)
    }

    /// The image at `pixelSize` (longest side), decoded off the main thread; nil if the source has no image.
    /// `priority`: `.userInitiated` for what is on screen, `.utility` for prefetches.
    func image(_ source: ArtworkSource, pixelSize: Int, priority: TaskPriority = .userInitiated) async -> ArtworkImage? {
        let key = Self.key(source, pixelSize)
        if let hit = memory.value(source: source.cacheKey, pixelSize: pixelSize) { return hit }
        if let task = inFlight[key] { return await task.value }
        let disk = diskDirectory
        let task = Task.detached(priority: priority) { () -> ArtworkImage? in
            await Self.load(source, pixelSize: pixelSize, key: key, diskDirectory: disk)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { memory.insert(result, source: source.cacheKey, pixelSize: pixelSize) }
        return result
    }

    /// Decodes a cover at the size a screen is about to show it (e.g. the album header before its push).
    nonisolated func prefetch(_ source: ArtworkSource, pixelSize: Int) {
        guard cachedImage(source, pixelSize: pixelSize) == nil else { return }
        Task(priority: .utility) { _ = await self.image(source, pixelSize: pixelSize, priority: .utility) }
    }

    /// The artwork as ARGB pixels at most `maxDimension` per side (Android decodes 128×128 for colour extraction).
    func argbPixels(_ source: ArtworkSource, maxDimension: Int = 128) async -> [UInt32]? {
        guard let image = await image(source, pixelSize: maxDimension) else { return nil }
        return Self.argbPixels(of: image.cgImage)
    }

    nonisolated func removeAll() { memory.removeAll() }

    // MARK: - Loading (off the actor)

    private nonisolated static func key(_ source: ArtworkSource, _ pixelSize: Int) -> String {
        "\(source.cacheKey)#\(pixelSize)"
    }

    private nonisolated static func load(_ source: ArtworkSource, pixelSize: Int, key: String,
                                         diskDirectory: URL?) async -> ArtworkImage? {
        if case .generated(let seed) = source {
            return GeneratedArtwork.render(seed: seed, pixelSize: pixelSize).map(ArtworkImage.init)
        }
        let diskURL = diskDirectory.map { $0.appendingPathComponent(diskName(key)) }
        if let diskURL, let cached = thumbnail(CGImageSourceCreateWithURL(diskURL as CFURL, nil), pixelSize) {
            return ArtworkImage(cgImage: cached)
        }
        var imageSource: CGImageSource?
        switch source {
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        case .remote(let url):
            guard let result = try? await URLSession.shared.data(from: url) else { return nil }
            if let http = result.1 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            imageSource = CGImageSourceCreateWithData(result.0 as CFData, nil)
        case .embedded(let url):
            guard let loader = embeddedArtworkLoader, let data = await loader(url) else { return nil }
            imageSource = CGImageSourceCreateWithData(data as CFData, nil)
        case .generated:
            return nil
        }
        guard let image = thumbnail(imageSource, pixelSize) else { return nil }
        if let diskURL { writeJPEG(image, to: diskURL) }
        return ArtworkImage(cgImage: image)
    }

    private nonisolated static func thumbnail(_ source: CGImageSource?, _ pixelSize: Int) -> CGImage? {
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    private nonisolated static func diskName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    /// Draws `image` into an RGBA8 premultiplied buffer and converts it to ARGB (Android `Bitmap.getPixels`).
    nonisolated static func argbPixels(of image: CGImage) -> [UInt32]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return ArtworkTheme.argbPixels(rgba: rgba, width: width, height: height, premultipliedAlpha: true)
    }

    // MARK: - Memory cache

    /// An LRU of decoded covers guarded by a `Mutex`, readable synchronously from any thread: per cover, its decoded
    /// sizes. Recency is a counter per entry (a hit costs a lookup, not a reorder); eviction drops the least recently
    /// used until the bitmaps fit the byte budget again.
    nonisolated final class MemoryCache: Sendable {
        private struct Entry {
            var image: ArtworkImage
            var tick: UInt64
            var cost: Int
        }

        private struct State {
            var covers: [String: [Int: Entry]] = [:]
            var tick: UInt64 = 0
            var cost = 0
        }

        private let state = Mutex(State())
        private let budget: Int

        init(budgetBytes: Int) { budget = budgetBytes }

        func value(source: String, pixelSize: Int) -> ArtworkImage? {
            state.withLock { s in
                guard var entry = s.covers[source]?[pixelSize] else { return nil }
                s.tick &+= 1
                entry.tick = s.tick
                s.covers[source]?[pixelSize] = entry
                return entry.image
            }
        }

        /// The largest decoded size of a cover (no recency change: it stands in until the exact size arrives).
        func largest(source: String) -> ArtworkImage? {
            state.withLock { s in
                s.covers[source]?.max { $0.key < $1.key }?.value.image
            }
        }

        func insert(_ image: ArtworkImage, source: String, pixelSize: Int) {
            let cost = image.cgImage.width * image.cgImage.height * 4
            state.withLock { s in
                s.tick &+= 1
                if let old = s.covers[source]?[pixelSize] { s.cost -= old.cost }
                s.covers[source, default: [:]][pixelSize] = Entry(image: image, tick: s.tick, cost: cost)
                s.cost += cost
                guard s.cost > budget else { return }
                // Evict down to 90 % of the budget in one pass, least recently used first.
                var all: [(source: String, size: Int, tick: UInt64, cost: Int)] = []
                for (key, sizes) in s.covers {
                    for (size, entry) in sizes { all.append((key, size, entry.tick, entry.cost)) }
                }
                all.sort { $0.tick < $1.tick }
                let target = budget / 10 * 9
                for victim in all where s.cost > target {
                    s.covers[victim.source]?[victim.size] = nil
                    if s.covers[victim.source]?.isEmpty == true { s.covers[victim.source] = nil }
                    s.cost -= victim.cost
                }
            }
        }

        func removeAll() {
            state.withLock { $0 = State() }
        }
    }
}

/// Generated gradient artwork for the demo library and UI tests: two hues from the seed, a diagonal gradient and
/// a soft highlight, rendered with Core Graphics at the requested size.
nonisolated enum GeneratedArtwork {
    /// The two colours (RGB 0…1) of seed `n`.
    static func colors(seed: Int) -> ((Double, Double, Double), (Double, Double, Double)) {
        let hue = Double((seed * 37) % 100) / 100
        return (hsb(hue, 0.62, 0.95), hsb((hue + 0.09).truncatingRemainder(dividingBy: 1), 0.8, 0.55))
    }

    static func render(seed: Int, pixelSize: Int) -> CGImage? {
        let size = max(8, pixelSize)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let (a, b) = colors(seed: seed)
        let gradientColors = [CGColor(srgbRed: a.0, green: a.1, blue: a.2, alpha: 1),
                              CGColor(srgbRed: b.0, green: b.1, blue: b.2, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: gradientColors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let highlight = [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)]
            as CFArray
        if let glow = CGGradient(colorsSpace: space, colors: highlight, locations: [0, 1]) {
            let center = CGPoint(x: CGFloat(size) * 0.3, y: CGFloat(size) * 0.72)
            context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: CGFloat(size) * 0.55, options: [])
        }
        // A ring motif so artworks are distinguishable in screenshots.
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))
        context.setLineWidth(CGFloat(size) * 0.05)
        let inset = CGFloat(size) * (0.22 + Double(seed % 4) * 0.04)
        context.strokeEllipse(in: CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset,
                                         height: CGFloat(size) - 2 * inset))
        return context.makeImage()
    }

    private static func hsb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
