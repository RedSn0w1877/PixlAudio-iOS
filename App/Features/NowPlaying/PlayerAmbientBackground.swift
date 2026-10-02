import CoreImage
import PixlModel
import SwiftUI

/// Android `PlayerAmbientStyle` (`player_ambient_style`, `BLENDED_COVER` by default).
nonisolated enum PlayerAmbientStyle: String, Sendable {
    case off = "OFF"
    case blendedCover = "BLENDED_COVER"
    case flowingGradient = "FLOWING_GRADIENT"
    case lowPolyMesh = "LOW_POLY_MESH"
    case audioWaveform = "AUDIO_WAVEFORM"

    init(storageKey: String) { self = PlayerAmbientStyle(rawValue: storageKey) ?? .blendedCover }
}

/// The full player's ambient background (Android `PlayerAmbientBackground`), one exclusive style behind the content:
/// - blended cover: the art blurred (72 dp) at 50 % — blurred once off the main thread with Core Image, then a static
///   image, so the sheet's motion never re-runs a blur;
/// - flowing gradient: three radial blobs of `primary` / `tertiary` / `secondary` drifting on Android's 50 s Lissajous
///   paths;
/// - low-poly mesh: eleven drifting points (seeded like Android) joined when close, over 60 s;
/// - audio waveform: Android draws live bars from the `Visualizer`; iOS gives apps no such capture of their own output
///   outside the processing tap, so this style shows the idle, decayed bars.
/// The animated styles draw at most 30 times a second, only while playing and visible, and stop with Reduce Motion.
struct PlayerAmbientBackground: View {
    let song: Song
    let style: PlayerAmbientStyle
    let isPlaying: Bool
    var isVisible = true

    @Environment(\.playerTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch style {
        case .off:
            Color.clear
        case .blendedCover:
            BlendedCoverBackground(song: song)
        case .flowingGradient:
            animatedCanvas { context, size, time in
                PlayerAmbientDrawing.flowingGradient(context: &context, size: size, time: time, theme: theme)
            }
        case .lowPolyMesh:
            animatedCanvas { context, size, time in
                PlayerAmbientDrawing.lowPolyMesh(context: &context, size: size, time: time, theme: theme)
            }
        case .audioWaveform:
            Canvas { context, size in
                PlayerAmbientDrawing.idleWaveform(context: &context, size: size, theme: theme)
            }
        }
    }

    private func animatedCanvas(_ draw: @escaping (inout GraphicsContext, CGSize, Double) -> Void) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying || !isVisible || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(&context, size, time)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The blurred cover, at half opacity, filling the player.
private struct BlendedCoverBackground: View {
    let song: Song

    @State private var image: ArtworkImage?

    var body: some View {
        // The filled image lives in an overlay of a flexible clear view, so it never widens its parent.
        Color.clear
            .overlay {
                if let image {
                    Image(decorative: image.cgImage, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .opacity(0.5)
                        .transition(.opacity)
                }
            }
            .clipped()
        .allowsHitTesting(false)
        .task(id: song.albumArtUriString) {
            guard let source = ArtworkSource(song: song) else { image = nil; return }
            let blurred = await BlurredArtworkCache.shared.image(for: source)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { image = blurred }
        }
    }
}

/// Blurs a cover once at a small size (Core Image Gaussian blur) and keeps the last few.
actor BlurredArtworkCache {
    static let shared = BlurredArtworkCache()

    /// Created on the actor at the first blur, not on the main thread when `shared` is first touched (setting up a
    /// Core Image context prepares Metal). One context for the cache's lifetime, as Core Image recommends.
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private var cache: [ArtworkSource: ArtworkImage] = [:]
    private var order: [ArtworkSource] = []

    func image(for source: ArtworkSource) async -> ArtworkImage? {
        if let hit = cache[source] { return hit }
        guard let art = await ArtworkPipeline.shared.image(source, pixelSize: 128) else { return nil }
        let input = CIImage(cgImage: art.cgImage)
        let extent = input.extent
        // Android blurs 72 dp on a screen-wide image; the art here is 128 px for ~400 pt.
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 14).cropped(to: extent)
        guard let output = context.createCGImage(blurred, from: extent) else { return nil }
        let result = ArtworkImage(cgImage: output)
        cache[source] = result
        order.append(source)
        if order.count > 4 { cache[order.removeFirst()] = nil }
        return result
    }
}

/// Canvas drawing of the animated ambient styles (Android `PlayerFlowingGradient`, `PlayerLowPolyMesh`,
/// `PlayerAudioWaveform`), same constants.
enum PlayerAmbientDrawing {
    static func flowingGradient(context: inout GraphicsContext, size: CGSize, time: Double, theme: ThemeColors) {
        let t = (time.truncatingRemainder(dividingBy: 50)) / 50
        let w = size.width, h = size.height
        let angleA = t * 2 * .pi
        let angleB = t * 2 * .pi * 0.63 + 1.7
        let angleC = t * 2 * .pi * 0.47 + 3.4
        let centerA = CGPoint(x: w * (0.5 + 0.32 * cos(angleA)), y: h * (0.32 + 0.22 * sin(angleA * 1.3)))
        let centerB = CGPoint(x: w * (0.5 + 0.30 * cos(angleB + .pi)), y: h * (0.68 + 0.20 * sin(angleB)))
        let centerC = CGPoint(x: w * (0.5 + 0.26 * cos(angleC + 2.1)), y: h * (0.5 + 0.26 * sin(angleC)))
        let radius = min(w, h) * 0.78
        func blob(_ color: Color, _ alpha: Double, _ center: CGPoint) {
            let gradient = Gradient(stops: [
                .init(color: color.opacity(alpha), location: 0),
                .init(color: color.opacity(alpha * 0.7), location: 0.55),
                .init(color: color.opacity(0), location: 1),
            ])
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect),
                         with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: radius))
        }
        blob(theme.secondary, 0.42, centerC)
        blob(theme.tertiary, 0.50, centerB)
        blob(theme.primary, 0.55, centerA)
    }

    /// Eleven points from Kotlin's `Random(1337)` stand-in: fixed phases so every launch draws the same mesh.
    private static let meshPoints: [(phaseX: Double, phaseY: Double, speed: Double, baseX: Double, baseY: Double)] = {
        var state: UInt64 = 1337
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        return (0..<11).map { _ in
            (next() * 6.28, next() * 6.28, 0.6 + next() * 0.8, next(), next())
        }
    }()

    static func lowPolyMesh(context: inout GraphicsContext, size: CGSize, time: Double, theme: ThemeColors) {
        let t = (time.truncatingRemainder(dividingBy: 60)) / 60 * 2 * .pi
        let w = size.width, h = size.height
        let positions = meshPoints.map { p in
            CGPoint(x: w * min(max(p.baseX + 0.06 * cos(t * p.speed + p.phaseX), 0), 1),
                    y: h * min(max(p.baseY + 0.06 * sin(t * p.speed + p.phaseY), 0), 1))
        }
        let connect = min(w, h) * 0.28
        for i in positions.indices {
            for j in (i + 1)..<positions.count {
                let a = positions[i], b = positions[j]
                let distance = hypot(a.x - b.x, a.y - b.y)
                guard distance < connect else { continue }
                var line = Path()
                line.move(to: a)
                line.addLine(to: b)
                context.stroke(line, with: .color(theme.tertiary.opacity(0.18 * (1 - distance / connect))),
                               lineWidth: 1)
            }
        }
        for p in positions {
            context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                         with: .color(theme.tertiaryContainer.opacity(0.35)))
        }
    }

    static func idleWaveform(context: inout GraphicsContext, size: CGSize, theme: ThemeColors) {
        let bars = 48
        let barWidth = size.width / CGFloat(bars)
        let baseline = size.height * 0.92
        for i in 0..<bars {
            let x = CGFloat(i) * barWidth + barWidth / 2
            var line = Path()
            line.move(to: CGPoint(x: x, y: baseline))
            line.addLine(to: CGPoint(x: x, y: baseline - 1))
            context.stroke(line, with: .color(theme.primary.opacity(0.35)),
                           style: StrokeStyle(lineWidth: max(barWidth * 0.55, 1), lineCap: .round))
        }
    }
}
