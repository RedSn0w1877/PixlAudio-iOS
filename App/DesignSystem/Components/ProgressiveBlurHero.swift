import PixlFoundation
import SwiftUI

/// The new UI's full-bleed hero (owner decision, 2026-11-16): artwork filling the top of a screen edge to edge, sharp at
/// the top, progressively blurred from about halfway down, then melting into the page under the title and controls.
/// The full player uses it first; the artist and playlist pages take the same treatment (`HeroGradients.header`).
///
/// Cheap by construction — no live blur, one blurred layer:
/// 1. `sharp`: the caller's artwork (the player passes its full-bleed carousel, so swipes and taps still work);
/// 2. ONE pre-blurred copy of the art (`BlurredArtworkCache`: blurred once, off the main thread, at 128 px, shared
///    with the player's blended-cover background), masked by a static smoothstep gradient (`ProgressiveHero.blurMask`);
/// 3. a veil of the page colour rising with the blur, so text over the blurred part stays legible;
/// 4. an optional dimming scrim behind the status bar and the glass chrome over the sharp top (clear glass over bright
///    art wants ~35 % dimming, docs/design.md);
/// and the whole stack faded out at the bottom (`ProgressiveHero.meltMask`), so it melts into whatever is behind it —
/// the album colour and the ambient background on the player.
///
/// The gradients are built once per profile (`HeroGradients`); a new song swaps the blurred copy with a 0.3 s
/// cross-fade. The decorative layers take no touches and are hidden from VoiceOver.
struct ProgressiveBlurHero<Sharp: View>: View {
    let source: ArtworkSource?
    let gradients: HeroGradients
    /// The page colour the hero melts into (the player: the album's `primaryContainer`).
    let veil: Color
    /// Height of the dimming scrim at the top (0: none).
    let topScrimHeight: CGFloat
    /// Width ÷ height of the hero (1: a square cover).
    let aspectRatio: CGFloat
    let sharp: Sharp

    init(source: ArtworkSource?, gradients: HeroGradients = .player, veil: Color, topScrimHeight: CGFloat = 0,
         aspectRatio: CGFloat = 1, @ViewBuilder sharp: () -> Sharp) {
        self.source = source
        self.gradients = gradients
        self.veil = veil
        self.topScrimHeight = topScrimHeight
        self.aspectRatio = aspectRatio
        self.sharp = sharp()
    }

    /// The blurred copy with the source it belongs to (its identity: a new song cross-fades instead of popping).
    private struct Blurred {
        let source: ArtworkSource
        let image: ArtworkImage
    }

    @State private var blurred: Blurred?

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay { sharp }
            .overlay { blurLayer }
            .overlay { veilLayer }
            .overlay(alignment: .top) { scrim }
            .mask {
                LinearGradient(gradient: gradients.melt, startPoint: .top, endPoint: .bottom)
            }
            .task(id: source) { await loadBlur() }
    }

    @ViewBuilder
    private var blurLayer: some View {
        ZStack {
            if let blurred {
                Image(decorative: blurred.image.cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
                    // Cut to the hero's frame (a cover that isn't square overflows), so the ramp lines up with it.
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
                    .mask {
                        LinearGradient(gradient: gradients.blur, startPoint: .top, endPoint: .bottom)
                    }
                    .id(blurred.source)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var veilLayer: some View {
        let stops = gradients.veilStops.map { Gradient.Stop(color: veil.opacity($0.opacity), location: $0.location) }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var scrim: some View {
        if topScrimHeight > 0 {
            LinearGradient(gradient: HeroGradients.topScrim, startPoint: .top, endPoint: .bottom)
                .frame(height: topScrimHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func loadBlur() async {
        guard let source else {
            blurred = nil
            return
        }
        if blurred?.source == source { return }
        guard let image = await BlurredArtworkCache.shared.image(for: source), !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.3)) { blurred = Blurred(source: source, image: image) }
    }
}

/// A hero profile's gradients, built once (static) from PixlCore's stops: never a brush per frame or per body.
struct HeroGradients {
    /// The blurred copy's mask (alpha only).
    let blur: Gradient
    /// The whole hero's mask (alpha only).
    let melt: Gradient
    /// The veil's opacities; the colour is the page's, applied when drawn.
    let veilStops: [(location: CGFloat, opacity: Double)]

    init(profile: ProgressiveHero.Profile) {
        blur = Self.alphaGradient(ProgressiveHero.blurMask(profile))
        melt = Self.alphaGradient(ProgressiveHero.meltMask(profile))
        veilStops = ProgressiveHero.veilMask(profile).map { (location: CGFloat($0.location), opacity: $0.opacity) }
    }

    /// The full player.
    static let player = HeroGradients(profile: .player)
    /// Artist and playlist headers.
    static let header = HeroGradients(profile: .header)

    /// Behind the status bar and the chrome over the sharp top.
    static let topScrim = Gradient(colors: [.black.opacity(0.32), .black.opacity(0)])

    private static func alphaGradient(_ stops: [ProgressiveHero.Stop]) -> Gradient {
        Gradient(stops: stops.map { Gradient.Stop(color: .black.opacity($0.opacity), location: CGFloat($0.location)) })
    }
}
