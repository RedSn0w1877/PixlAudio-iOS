import PixlFoundation
import PixlModel
import SwiftUI

/// Android `CarouselStyle` (`carousel_style`): how much of the neighbouring covers peeks in.
nonisolated enum PlayerCarouselStyle: String, Sendable {
    case noPeek = "no_peek"
    case onePeek = "one_peek"
    case twoPeek = "two_peek"

    init(storageKey: String) { self = PlayerCarouselStyle(rawValue: storageKey) ?? .noPeek }

    /// Android `FullPlayerAlbumCoverSection`: the carousel is as tall as the width (no peek), 80 % (one peek) or
    /// 60 % (two peeks); the focused cover is square at that height.
    func itemSize(width: CGFloat) -> CGFloat {
        switch self {
        case .noPeek: width
        case .onePeek: width * 0.8
        case .twoPeek: width * 0.6
        }
    }

    /// Content margins that put the focused cover at the start (no / one peek) or in the middle (two peeks).
    func margins(width: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        let item = itemSize(width: width)
        switch self {
        case .noPeek: return (0, 0)
        case .onePeek: return (0, width - item)
        case .twoPeek: return ((width - item) / 2, (width - item) / 2)
        }
    }
}

/// The album-art carousel (Android `AlbumCarouselSection` over `RoundedHorizontalMultiBrowseCarousel`): the queue's
/// covers (18 pt corners, 8 pt apart), one page per swipe. A settled swipe plays that queue entry (with a haptic);
/// a skip from the buttons scrolls the carousel with a no-bounce spring; tapping the focused cover opens its album.
/// While paused the covers shrink to 95 % (260 ms).
///
/// Material's keyline carousel (neighbours masked to smaller slices) is approximated by plain square pages whose
/// neighbours are cut by the carousel edge.
///
/// `fullBleed` (new UI, 2026-11-16): the full player's hero. The covers fill the width edge to edge without corners or
/// gaps, and stay full size while paused, each page sized by `ProgressiveHero.playerLayout` (the cover scaled to fill
/// `width × sharpHeight`, so it reaches about halfway down the screen). Each page is as tall as the whole hero: the
/// sharp cover at its top and, on pages near the focused one, its own blurred copy (`HeroBlurredCopy`) down to the
/// hero's bottom, so a swipe moves one melting picture (pages further away carry the copy's page-colour fallback, so
/// no page ever shows the sharp cover's cut); the veil and the top scrim (`HeroVeil`) are one static layer
/// over the whole carousel. Nothing is drawn outside a page or the scroll view: a copy that overflowed a page only as
/// tall as the sharp part was cut at its bottom edge (a hard line right above the title, 2026-11-16), whatever
/// `scrollClipDisabled` said. Only the sharp cover takes the page's taps (album, double-tap to like); the copy takes
/// none. The copies are bounded: the focused page and its two neighbours while the player is shown (a swipe can only
/// bring those in), the focused page alone while it is hidden (it is what the expand opens on), so prefetched pages
/// and a collapsed player run no extra blur jobs or flattened layers. Peeking neighbours can't show in a full-bleed
/// hero, so the carousel style doesn't apply there.
struct AlbumCarousel: View {
    let queue: [Song]
    let currentIndex: Int?
    let style: PlayerCarouselStyle
    let isPlaying: Bool
    let onSelect: (Int) -> Void
    let onAlbumTap: (Song) -> Void
    /// Gestures (Settings › Gestures & haptics): swiping the covers and double-tap to like (the long-press quick actions
    /// are a context menu the full player puts around the whole carousel).
    var allowsSwipe = true
    var onDoubleTap: (() -> Void)?
    var fullBleed: CarouselHero?

    /// Starts at the width the player lays it out at (when known), so the covers are there on the first pass instead
    /// of after a measuring pass; measuring still follows later changes.
    @State private var width: CGFloat

    init(queue: [Song], currentIndex: Int?, style: PlayerCarouselStyle, isPlaying: Bool, initialWidth: CGFloat = 0,
         allowsSwipe: Bool = true, onDoubleTap: (() -> Void)? = nil, fullBleed: CarouselHero? = nil,
         onSelect: @escaping (Int) -> Void, onAlbumTap: @escaping (Song) -> Void) {
        self.allowsSwipe = allowsSwipe
        self.fullBleed = fullBleed
        self.onDoubleTap = onDoubleTap
        self.queue = queue
        self.currentIndex = currentIndex
        self.style = style
        self.isPlaying = isPlaying
        self.onSelect = onSelect
        self.onAlbumTap = onAlbumTap
        _width = State(initialValue: initialWidth)
    }
    @State private var position: Int?
    @State private var userDragged = false
    @State private var settleHaptic = 0
    /// The "Next" / "Previous" hint after a swipe changed the song.
    @State private var hint: SwipeDirection?
    @State private var hintToken = 0

    var body: some View {
        let hero = fullBleed.map { config in
            ProgressiveHero.playerLayout(width: Double(width), screenHeight: Double(config.screenHeight),
                                         titleClearance: Double(config.titleClearance))
        }
        let isFullBleed = fullBleed != nil
        let item = hero.map { CGFloat($0.sharpHeight) } ?? style.itemSize(width: width)
        // Full bleed: the pages and the scroll view are as tall as the whole hero, so its melting bottom is inside them.
        let carouselHeight = hero.map { max(CGFloat($0.heroHeight), item) } ?? item
        let margins = style.margins(width: width)
        let singleStyle = queue.count <= 1 || isFullBleed ? PlayerCarouselStyle.noPeek : style
        ScrollView(.horizontal) {
            LazyHStack(spacing: isFullBleed ? 0 : 8) {
                // Covers decode at their display size, so they wait for the measured width.
                ForEach(width > 0 ? queue.indices : 0..<0, id: \.self) { index in
                    let song = queue[index]
                    page(song, index: index, size: max(singleStyle == .noPeek ? width : item, 1), hero: hero)
                        .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled(isFullBleed)
        .scrollDisabled(!allowsSwipe)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.leading, singleStyle == .noPeek ? 0 : margins.leading, for: .scrollContent)
        .contentMargins(.trailing, singleStyle == .noPeek ? 0 : margins.trailing, for: .scrollContent)
        .scrollPosition(id: $position, anchor: singleStyle == .twoPeek ? .center : .leading)
        .onScrollPhaseChange { oldPhase, newPhase in
            if newPhase == .interacting { userDragged = true }
            if newPhase == .idle, oldPhase != .idle, userDragged {
                userDragged = false
                if let settled = position, settled != currentIndex, queue.indices.contains(settled) {
                    settleHaptic += 1
                    hint = (currentIndex ?? settled) < settled ? .left : .right
                    hintToken += 1
                    onSelect(settled)
                }
            }
        }
        .frame(height: max(carouselHeight, 1))
        // The hero's veil and top scrim: one static layer over every page, down to the hero's bottom.
        .overlay(alignment: .top) {
            if let fullBleed, let hero {
                HeroVeil(gradients: .player, veil: fullBleed.veil, topScrimHeight: fullBleed.topScrimHeight)
                    .frame(width: width, height: max(CGFloat(hero.heroHeight), 1))
            }
        }
        // Full bleed stays full size: a shrink would open gaps at the screen edges.
        .scaleEffect(isPlaying || isFullBleed ? 1 : 0.95)
        .animation(.easeOut(duration: 0.26), value: isPlaying)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { position = currentIndex }
        .onChange(of: width) { _, _ in position = currentIndex }
        .onChange(of: currentIndex) { _, index in
            guard !userDragged, let index, position != index else { return }
            // Android: a no-bounce, medium-low stiffness spring for programmatic skips.
            withAnimation(.interpolatingSpring(mass: 1, stiffness: 400, damping: 40)) { position = index }
        }
        .onChange(of: queue.count) { _, _ in
            if position != currentIndex { position = currentIndex }
        }
        .pixlHaptic(.impact(weight: .medium), trigger: settleHaptic)
        // Full bleed: in the middle of the sharp cover (not of the taller hero), clear of the player's top bar over it.
        .overlay(alignment: .top) {
            if let hint {
                SwipeHint(direction: hint)
                    .padding(.top, isFullBleed ? 0 : 10)
                    .frame(height: isFullBleed ? max(item, 1) : nil)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .task(id: hintToken) {
            guard hintToken > 0 else { return }
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { hint = nil }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hint)
    }

    /// One page: a rounded square cover, or (full bleed) the whole hero's height — the cover filling
    /// `width × sharpHeight` at the top and, near the focused page, its blurred copy over it down to the hero's
    /// bottom. Only the cover takes the page's taps.
    @ViewBuilder
    private func page(_ song: Song, index: Int, size: CGFloat, hero: ProgressiveHero.Layout?) -> some View {
        if let fullBleed, let hero {
            let sharp = max(CGFloat(hero.sharpHeight), 1)
            let heroHeight = max(CGFloat(hero.heroHeight), sharp)
            let distance = abs(index - (position ?? currentIndex ?? 0))
            ZStack(alignment: .top) {
                coverTaps(ArtworkView(song: song, size: max(width, sharp), cornerRadius: 0)
                              .frame(width: width, height: sharp)
                              .clipped(),
                          song: song, index: index)
                // Every page has the layer, so the sharp cover's cut is always under something opaque; only pages near
                // the focused one get the blurred copy, the others its page-colour fallback (a source of nil: no blur
                // job, no flattened layer). A jump of several songs scrolls past those, and the page it leaves loses
                // its copy as the scroll starts: with no layer at all, each showed the cut as a hard line.
                HeroBlurredCopy(source: distance <= (fullBleed.isVisible ? 1 : 0) ? ArtworkSource(song: song) : nil,
                                gradients: .player, veil: fullBleed.veil,
                                width: width, sharpHeight: sharp, heroHeight: heroHeight)
            }
            .frame(width: width, height: heroHeight, alignment: .top)
        } else {
            coverTaps(ArtworkView(song: song, size: size, cornerRadius: 18), song: song, index: index)
        }
    }

    /// A cover's touches and its VoiceOver element: tap for the album, double-tap to like.
    private func coverTaps(_ cover: some View, song: Song, index: Int) -> some View {
        cover
            .contentShape(.rect)
            // Double-tap goes first, so the single tap (open the album) waits for it to fail.
            .modifier(CarouselDoubleTap(action: index == (position ?? currentIndex) ? onDoubleTap : nil))
            .onTapGesture {
                if index == (position ?? currentIndex), song.albumId != -1 { onAlbumTap(song) }
            }
            .accessibilityElement()
            .accessibilityLabel(song.album)
            .accessibilityHint(index == currentIndex ? "Opens the album" : "")
    }
}

/// The full player's hero round the carousel (`AlbumCarousel.fullBleed`).
struct CarouselHero {
    /// The screen height the player is laid out at (0: unknown).
    var screenHeight: CGFloat
    /// From the title's top to the screen's bottom edge: the blurred copy is fully in by the title.
    var titleClearance: CGFloat
    /// The colour the hero melts into (the album's `primaryContainer`).
    var veil: Color
    /// The dimming scrim behind the status bar and the top bar.
    var topScrimHeight: CGFloat
    /// Whether the player is on screen (not collapsed): only then do the focused page's neighbours carry blurred copies.
    var isVisible = true
}

/// Double-tap on a cover (like / unlike) when the gesture is on; no gesture at all otherwise, so the single tap that
/// opens the album does not wait for a second tap that can never come.
private struct CarouselDoubleTap: ViewModifier {
    let action: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture(count: 2, perform: action)
        } else {
            content
        }
    }
}
