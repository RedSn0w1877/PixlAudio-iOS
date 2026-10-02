import PixlLyrics
import SwiftUI

/// The motion / crossfade clock of the background, advanced from the `TimelineView` date (a reference, never
/// observed: the timeline drives the redraws).
final class LyricsBackgroundClock {
    var motion: LyricsBackgroundMotion<String>
    private var lastDate: Date?

    init(reducedMotion: Bool) {
        motion = LyricsBackgroundMotion(initial: nil, reducedMotion: reducedMotion)
    }

    func advance(to date: Date, motion moving: Bool) {
        if let lastDate {
            let dt = Float(min(max(date.timeIntervalSince(lastDate), 0), 0.25))
            motion.step(dtSeconds: dt, motion: moving)
        }
        lastDate = date
    }
}

/// The animated artwork behind the lyrics (spec §2, Android `LyricsArtworkBackground`): four twisted, blurred,
/// over-saturated copies of the art drawn by one full-screen SwiftUI Metal shader at 30 fps, crossfading over 1.7 s
/// on a track change, paused when hidden or in Low Power Mode. Blur and colour work happen once per track in
/// `ArtworkSpriteBaker`.
struct LyricsArtworkBackground: View {
    let artSource: ArtworkSource?
    /// UI tests: a specific image instead of the song's art (the pale bright-art case).
    var overrideImage: CGImage?
    let fallbackTheme: ThemeColors
    let paused: Bool
    var deterministic = false
    let onBrightArtChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sets: [String: LyricsSpriteSet] = [:]
    @State private var clock: LyricsBackgroundClock?
    @State private var size: CGSize = .zero

    private var loadKey: String {
        "\(artSource?.cacheKey ?? "none")|\(overrideImage == nil ? 0 : 1)|\(Int(size.width))x\(Int(size.height))"
    }

    var body: some View {
        ZStack {
            Color.black
            if let clock, size.width > 0 {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { timeline in
                    let _ = clock.advance(to: timeline.date, motion: !paused)
                    frame(clock: clock)
                }
            }
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onAppear {
            if clock == nil { clock = LyricsBackgroundClock(reducedMotion: reduceMotion) }
        }
        .task(id: loadKey) { await load() }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func frame(clock: LyricsBackgroundClock) -> some View {
        let motion = clock.motion
        let alphas = motion.setAlphas
        ZStack {
            if motion.current == nil && motion.resolved {
                flowingGradient(elapsed: motion.elapsedSeconds)
                    .opacity(Double(motion.previous == nil ? 1 : motion.fade))
            }
            if let previousID = motion.previous, let previous = sets[previousID], alphas.previous > 0 {
                Rectangle().fill(shader(previous, motion: motion, alpha: alphas.previous))
            }
            if let currentID = motion.current, let current = sets[currentID], alphas.current > 0 {
                Rectangle().fill(shader(current, motion: motion, alpha: alphas.current))
            }
        }
    }

    private func shader(_ set: LyricsSpriteSet, motion: LyricsBackgroundMotion<String>, alpha: Float) -> Shader {
        let w = Float(size.width), h = Float(size.height)
        let xf = motion.shaderUniforms(initialAngles: set.initialAngles, width: w, height: h)
        let sizes = set.spriteSizes
        let scrim: Float = set.isBright ? LyricsBackgroundGrade.brightArtScrim : 0
        return ShaderLibrary.lyricsScene(
            .image(Image(decorative: set.atlas, scale: 1)),
            .float2(w, h),
            .float4(xf[0].x, xf[0].y, xf[0].z, xf[0].w),
            .float4(xf[1].x, xf[1].y, xf[1].z, xf[1].w),
            .float4(xf[2].x, xf[2].y, xf[2].z, xf[2].w),
            .float4(xf[3].x, xf[3].y, xf[3].z, xf[3].w),
            .float4(sizes[0], sizes[1], sizes[2], sizes[3]),
            .float(set.cell),
            .float(LyricsBackgroundShaderParams.twistAngle),
            .float(LyricsBackgroundShaderParams.twistRadius(width: w, height: h)),
            .float(alpha),
            .float(scrim)
        )
    }

    /// No art: the album colours flowing slowly (Android `PlayerFlowingGradient`), graded down like the art.
    private func flowingGradient(elapsed: Float) -> some View {
        let phase = Double(elapsed) / Double(LyricsBackgroundMotion<String>.flowingGradientPeriodSeconds) * 2 * .pi
        let start = UnitPoint(x: 0.5 + 0.5 * cos(phase), y: 0.5 + 0.5 * sin(phase))
        let end = UnitPoint(x: 1 - start.x, y: 1 - start.y)
        return LinearGradient(colors: [fallbackTheme.primaryContainer, fallbackTheme.tertiaryContainer,
                                       fallbackTheme.secondaryContainer],
                              startPoint: start, endPoint: end)
            .overlay(Color.black.opacity(0.5))
    }

    private func load() async {
        guard size.width > 0, size.height > 0 else { return }
        let image: ArtworkImage?
        let key: String
        if let overrideImage {
            image = ArtworkImage(cgImage: overrideImage)
            key = "override"
        } else if let artSource {
            image = await ArtworkPipeline.shared.image(artSource, pixelSize: ArtworkSprites.artTexels)
            key = artSource.cacheKey
        } else {
            image = nil
            key = "none"
        }
        guard !Task.isCancelled else { return }
        var set: LyricsSpriteSet?
        if let image {
            set = await ArtworkSpriteBaker.shared.spriteSet(key: key, image: image, width: Int(size.width),
                                                           height: Int(size.height), deterministic: deterministic)
        }
        guard !Task.isCancelled else { return }
        if clock == nil { clock = LyricsBackgroundClock(reducedMotion: reduceMotion) }
        if let set { sets[set.id] = set }
        // Keep only the sets on screen (the baker has its own LRU).
        clock?.motion.show(set?.id)
        if let motion = clock?.motion {
            let keep = Set([motion.current, motion.previous].compactMap { $0 })
            sets = sets.filter { keep.contains($0.key) }
        }
        if paused { clock?.motion.finishFade() }
        onBrightArtChange(set?.isBright ?? false)
    }
}

/// Compiles the lyrics background shader ahead of the first lyrics open (Apple: a shader compiled on first use may
/// delay that frame — here, a frame of the lyrics cover's slide-up). Started when the full player is first built
/// (lyrics open only from it); runs once per launch, at utility priority, in a detached task: the shader is built and
/// compiled off the main actor (a `Task {}` started from a view would inherit it), so no part of the compile shares
/// the main thread with the player's own first frames. The arguments match `lyricsScene`'s real call: an image, a
/// float2, five float4 and five floats.
enum LyricsShaderWarmup {
    private static var started = false

    static func prepare() {
        guard !started else { return }
        started = true
        Task.detached(priority: .utility) {
            guard let pixel = onePixel() else { return }
            let shader = ShaderLibrary.lyricsScene(
                .image(Image(decorative: pixel, scale: 1)),
                .float2(1, 1),
                .float4(0, 0, 0, 0), .float4(0, 0, 0, 0), .float4(0, 0, 0, 0), .float4(0, 0, 0, 0),
                .float4(0, 0, 0, 0),
                .float(0), .float(0), .float(0), .float(0), .float(0)
            )
            try? await shader.compile(as: .shapeStyle)
        }
    }

    nonisolated private static func onePixel() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return context.makeImage()
    }
}
