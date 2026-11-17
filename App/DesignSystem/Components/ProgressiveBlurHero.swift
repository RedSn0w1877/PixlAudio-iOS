import PixlFoundation
import SwiftUI

/// The new UI's full-bleed hero (owner decision, 2026-11-16): artwork filling the top of a screen edge to edge, sharp at
/// the top, progressively blurred from about halfway down, then melting into the page under the title and controls.
/// The artist and playlist pages use it as is (`HeroGradients.header`); the full player builds the same three layers
/// round its carousel (`AlbumCarousel` with a `CarouselHero`: each page carries its own blurred copy, so a swipe moves
/// one melting picture rather than two stitched together).
///
/// Cheap by construction — no live blur, one blurred layer, no mask over the sharp art:
/// 1. `sharp`: the caller's artwork, laid out at `size` and cut by a plain rectangular clip at `blurEnd` (where the
///    blurred copy above it is opaque);
/// 2. `HeroBlurredCopy`: ONE pre-blurred copy of the art (`BlurredArtworkCache`), its blur ramp and the melt at the
///    bottom folded into one static mask, flattened once (`drawingGroup`) so scrolling or moving it re-renders
///    nothing;
/// 3. `HeroVeil`: the page colour rising with the blur (melting with it), so text over the blurred part stays
///    legible, plus an optional dimming scrim behind the status bar and the glass chrome over the sharp top (clear
///    glass over bright art wants ~35 % dimming, docs/design.md).
/// Every layer is laid out at the hero's full size and every mask is exactly 0 at its bottom edge, so the hero melts
/// into whatever is behind it with no line: nothing of it may be drawn outside its frame, where a parent could cut it
/// (the player's blurred copies once overflowed a carousel page only as tall as the sharp part and were cut there).
/// The gradients are built once per profile (`HeroGradients`). The layers take no touches and are hidden from VoiceOver.
struct ProgressiveBlurHero<Sharp: View>: View {
    let source: ArtworkSource?
    let gradients: HeroGradients
    /// The page colour the hero melts into (the header pages: `surface`).
    let veil: Color
    /// Height of the dimming scrim at the top (0: none).
    let topScrimHeight: CGFloat
    /// The hero's size; `sharp` is laid out at it.
    let size: CGSize
    let sharp: Sharp

    init(source: ArtworkSource?, gradients: HeroGradients = .header, veil: Color, topScrimHeight: CGFloat = 0,
         size: CGSize, @ViewBuilder sharp: () -> Sharp) {
        self.source = source
        self.gradients = gradients
        self.veil = veil
        self.topScrimHeight = topScrimHeight
        self.size = size
        self.sharp = sharp()
    }

    var body: some View {
        ZStack(alignment: .top) {
            sharp
                .frame(width: size.width, height: size.height)
                .frame(width: size.width, height: (size.height * gradients.blurEnd).rounded(.up), alignment: .top)
                .clipped()
            HeroBlurredCopy(source: source, gradients: gradients, veil: veil, width: size.width,
                            sharpHeight: size.height, heroHeight: size.height)
            HeroVeil(gradients: gradients, veil: veil, topScrimHeight: topScrimHeight)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }
}

/// A hero's blurred copy: the art blurred once (`BlurredArtworkCache`, 128 px, shared with the player's blended-cover
/// background), lined up with the sharp art (`ProgressiveHero.copyLayout`: the same square, scaled to fill the sharp
/// part, and mirrored below it when the hero runs on past it), under one static mask (blur ramp × melt). Without a
/// copy — no art, not blurred yet, or the blur failed — the page colour takes its place under the same mask, so the
/// sharp art's cut edge never shows and a previous song's copy never lingers. A swap (a new source, the copy arriving
/// over the fallback or giving way to it) never dips: the incoming layer fades in over 0.3 s while the outgoing one
/// stays opaque, then the outgoing one fades (`ProgressiveHero.swapOpacities`) — a plain cross-fade left the opaque
/// band 75 % covered half way, showing the sharp art's cut as a line for 0.3 s.
///
/// Flattened (`drawingGroup`): the masked copy is drawn once into its own texture and then only moved — on the
/// player it rides a swiping carousel page and the sheet's expand / collapse, on the header pages the scroll stretch.
/// Only the copy is flattened: the page-colour fallback animates with the album colour (the player's theme fades for
/// 0.45 s per song), so it is a plain masked fill beside it, present only while there is no copy — a theme change
/// never redraws the big flattened texture.
struct HeroBlurredCopy: View {
    let source: ArtworkSource?
    let gradients: HeroGradients
    let veil: Color
    let width: CGFloat
    /// The sharp art's height (its square cover is centred on it).
    let sharpHeight: CGFloat
    let heroHeight: CGFloat

    /// The blurred copy with the source it belongs to (its identity: a new song cross-fades instead of popping).
    private struct Blurred {
        let source: ArtworkSource
        let image: ArtworkImage
    }

    @State private var blurred: Blurred?

    /// In over 0.3 s; out only after that, over 0.3 s (`ProgressiveHero.swapOpacities`): whichever layer is on top,
    /// the other is opaque while it is part-way, so the band where the copy is opaque stays covered throughout.
    private static var swap: AnyTransition {
        let fade = ProgressiveHero.swapFade
        return .asymmetric(insertion: .opacity.animation(.easeOut(duration: fade)),
                           removal: .opacity.animation(.easeOut(duration: fade).delay(fade)))
    }

    var body: some View {
        let copy = ProgressiveHero.copyLayout(width: Double(width), sharpHeight: Double(sharpHeight),
                                              heroHeight: Double(heroHeight))
        let side = CGFloat(copy.side)
        let top = CGFloat(copy.top)
        ZStack(alignment: .top) {
            if blurred == nil {
                veil
                    .frame(width: width, height: heroHeight)
                    .mask { LinearGradient(gradient: gradients.blur, startPoint: .top, endPoint: .bottom) }
                    .transition(Self.swap)
            }
            if let blurred {
                ZStack(alignment: .top) {
                    Image(decorative: blurred.image.cgImage, scale: 1)
                        .resizable()
                        .frame(width: side, height: side)
                        .offset(y: top)
                    if copy.mirrors {
                        Image(decorative: blurred.image.cgImage, scale: 1)
                            .resizable()
                            .scaleEffect(x: 1, y: -1)
                            .frame(width: side, height: side)
                            .offset(y: top + side)
                    }
                }
                .frame(width: width, height: heroHeight, alignment: .top)
                .clipped()
                .mask { LinearGradient(gradient: gradients.blur, startPoint: .top, endPoint: .bottom) }
                .drawingGroup()
                .id(blurred.source)
                .transition(Self.swap)
            }
        }
        .frame(width: width, height: heroHeight, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: source) { await load() }
    }

    private func load() async {
        guard let source else {
            if blurred != nil { withAnimation(.easeOut(duration: 0.3)) { blurred = nil } }
            return
        }
        if blurred?.source == source { return }
        // Assigned even when nil: a failed blur shows the page colour, never the previous song's copy.
        let image = await BlurredArtworkCache.shared.image(for: source)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.3)) { blurred = image.map { Blurred(source: source, image: $0) } }
    }
}

/// A hero's veil (the page colour rising with the blur and melting with it) and its optional top scrim. Static.
struct HeroVeil: View {
    let gradients: HeroGradients
    let veil: Color
    var topScrimHeight: CGFloat = 0

    var body: some View {
        let stops = gradients.veilStops.map { Gradient.Stop(color: veil.opacity($0.opacity), location: $0.location) }
        LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                if topScrimHeight > 0 {
                    LinearGradient(gradient: HeroGradients.topScrim, startPoint: .top, endPoint: .bottom)
                        .frame(height: topScrimHeight)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A hero profile's gradients, built once (static) from PixlCore's stops: never a brush per frame or per body.
struct HeroGradients {
    /// The blurred copy's mask (alpha only): the blur ramp times the melt.
    let blur: Gradient
    /// The veil's opacities (melt folded in); the colour is the page's, applied when drawn.
    let veilStops: [(location: CGFloat, opacity: Double)]
    /// Where the blurred copy is opaque (a fraction of the hero): the sharp art is cut there.
    let blurEnd: CGFloat

    init(profile: ProgressiveHero.Profile) {
        blur = Self.alphaGradient(ProgressiveHero.blurMeltMask(profile))
        veilStops = ProgressiveHero.veilMeltMask(profile).map { (location: CGFloat($0.location), opacity: $0.opacity) }
        blurEnd = CGFloat(profile.blurEnd)
    }

    /// The full player.
    static let player = HeroGradients(profile: .player)
    /// Artist and playlist headers.
    static let header = HeroGradients(profile: .header)

    /// Behind the status bar and the chrome over the sharp top: 32 % black eased to nothing at its bottom edge.
    static let topScrim = HeroGradients.alphaGradient(ProgressiveHero.topScrimMask(opacity: 0.32))

    private static func alphaGradient(_ stops: [ProgressiveHero.Stop]) -> Gradient {
        Gradient(stops: stops.map { Gradient.Stop(color: .black.opacity($0.opacity), location: CGFloat($0.location)) })
    }
}
