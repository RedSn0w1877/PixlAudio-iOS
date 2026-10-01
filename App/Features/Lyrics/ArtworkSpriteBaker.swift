import CoreGraphics
import Foundation
import PixlLyrics

/// One baked sprite set (spec §2.1): the four pre-blurred art sprites packed into a 2×2 atlas, plus everything the
/// shader needs to sample them and the bright-art verdict.
nonisolated final class LyricsSpriteSet: @unchecked Sendable, Identifiable {
    let id: String
    /// 2×2 atlas: sprite k sits at the top-left of cell (k % 2, k / 2).
    let atlas: CGImage
    /// Cell size in texels.
    let cell: Float
    /// Texture size of each sprite (96 + 2·pad).
    let spriteSizes: [Float]
    /// Mean graded luma of the base sprite > 0.6 (§1.2).
    let isBright: Bool
    /// Random initial rotation per sprite (radians).
    let initialAngles: [Float]

    init(id: String, atlas: CGImage, cell: Float, spriteSizes: [Float], isBright: Bool, initialAngles: [Float]) {
        self.id = id
        self.atlas = atlas
        self.cell = cell
        self.spriteSizes = spriteSizes
        self.isBright = isBright
        self.initialAngles = initialAngles
    }
}

/// Bakes the lyrics background sprites once per track, off the main thread (Android `ArtworkSpriteBaker`): the art
/// decoded at 96 px, each of the four sprites centred on transparent padding and Gaussian-blurred (3-pass box blur,
/// premultiplied — PixlLyrics' `SpriteBlur`), packed into one atlas. No blur ever runs per frame. LRU of 4.
actor ArtworkSpriteBaker {
    static let shared = ArtworkSpriteBaker()

    private var cache: [String: LyricsSpriteSet] = [:]
    private var order: [String] = []

    /// The sprite set for `image` (any size; it is drawn into 96×96, aspect-filled) at the view's aspect ratio.
    /// `deterministic` fixes the initial angles (UI tests).
    func spriteSet(key: String, image artwork: ArtworkImage, width: Int, height: Int, deterministic: Bool) -> LyricsSpriteSet? {
        let image = artwork.cgImage
        let bucket = ArtworkSprites.aspectBucket(width: width, height: height)
        let cacheKey = "\(key)#\(bucket)"
        if let hit = cache[cacheKey] { return hit }
        guard let art = Self.decode96(image) else { return nil }
        let n = ArtworkSprites.artTexels
        var sprites: [[UInt32]] = []
        var sizes: [Int] = []
        for k in 0..<4 {
            let pad = ArtworkSprites.padTexels(k, aspectBucket: bucket)
            let sigma = ArtworkSprites.sigmaTexels(k, aspectBucket: bucket)
            sprites.append(SpriteBlur.bakeSprite(art: art, artSize: n, pad: pad, sigma: sigma, opaque: k == 0))
            sizes.append(n + 2 * pad)
        }
        let luma = LyricsBackgroundGrade.meanGradedLuma(argb: sprites[0])
        let cell = sizes.max() ?? n
        guard let atlas = Self.makeAtlas(sprites: sprites, sizes: sizes, cell: cell) else { return nil }
        var generator = SplitMix64(seed: deterministic ? 0x5EED : UInt64.random(in: 1...UInt64.max))
        let angles = (0..<4).map { _ in Float(Double(generator.next() % 10_000) / 10_000 * 2 * Double.pi) }
        let set = LyricsSpriteSet(id: cacheKey, atlas: atlas, cell: Float(cell), spriteSizes: sizes.map(Float.init),
                                  isBright: LyricsBackgroundGrade.isBright(meanLuma: luma), initialAngles: angles)
        cache[cacheKey] = set
        order.append(cacheKey)
        if order.count > 4 { cache[order.removeFirst()] = nil }
        return set
    }

    /// ARGB (`0xAARRGGBB`) pixels of the art drawn into 96×96, aspect-filled.
    private static func decode96(_ image: CGImage) -> [UInt32]? {
        let n = ArtworkSprites.artTexels
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = max(CGFloat(n) / max(w, 1), CGFloat(n) / max(h, 1))
        let dw = w * scale, dh = h * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (CGFloat(n) - dw) / 2, y: (CGFloat(n) - dh) / 2, width: dw, height: dh))
        guard let data = ctx.data else { return nil }
        // BGRA little-endian premultiplied-first = 0xAARRGGBB as UInt32; the art is opaque so no un-premultiply.
        let pointer = data.bindMemory(to: UInt32.self, capacity: n * n)
        return Array(UnsafeBufferPointer(start: pointer, count: n * n))
    }

    /// Packs the sprites (unpremultiplied ARGB) into a premultiplied 2×2 atlas image.
    private static func makeAtlas(sprites: [[UInt32]], sizes: [Int], cell: Int) -> CGImage? {
        let side = cell * 2
        var pixels = [UInt32](repeating: 0, count: side * side)
        for k in 0..<4 {
            let size = sizes[k]
            let ox = (k % 2) * cell
            let oy = (k / 2) * cell
            let sprite = sprites[k]
            for y in 0..<size {
                for x in 0..<size {
                    let c = sprite[y * size + x]
                    let a = (c >> 24) & 0xFF
                    if a == 0 { continue }
                    // Premultiply for the bitmap (premultipliedFirst).
                    let r = ((c >> 16) & 0xFF) * a / 255
                    let g = ((c >> 8) & 0xFF) * a / 255
                    let b = (c & 0xFF) * a / 255
                    pixels[(oy + y) * side + ox + x] = (a << 24) | (r << 16) | (g << 8) | b
                }
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A tiny deterministic generator (random initial sprite angles; fixed seed in UI tests).
nonisolated struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
