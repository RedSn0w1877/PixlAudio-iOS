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
struct AlbumCarousel: View {
    let queue: [Song]
    let currentIndex: Int?
    let style: PlayerCarouselStyle
    let isPlaying: Bool
    let onSelect: (Int) -> Void
    let onAlbumTap: (Song) -> Void

    /// Starts at the width the player lays it out at (when known), so the covers are there on the first pass instead
    /// of after a measuring pass; measuring still follows later changes.
    @State private var width: CGFloat

    init(queue: [Song], currentIndex: Int?, style: PlayerCarouselStyle, isPlaying: Bool, initialWidth: CGFloat = 0,
         onSelect: @escaping (Int) -> Void, onAlbumTap: @escaping (Song) -> Void) {
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

    var body: some View {
        let item = style.itemSize(width: width)
        let margins = style.margins(width: width)
        let singleStyle = queue.count <= 1 ? PlayerCarouselStyle.noPeek : style
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                // Covers decode at their display size, so they wait for the measured width.
                ForEach(width > 0 ? queue.indices : 0..<0, id: \.self) { index in
                    let song = queue[index]
                    ArtworkView(song: song, size: max(singleStyle == .noPeek ? width : item, 1), cornerRadius: 18)
                        .contentShape(.rect)
                        .onTapGesture {
                            if index == (position ?? currentIndex), song.albumId != -1 { onAlbumTap(song) }
                        }
                        .accessibilityElement()
                        .accessibilityLabel(song.album)
                        .accessibilityHint(index == currentIndex ? "Opens the album" : "")
                        .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
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
                    onSelect(settled)
                }
            }
        }
        .frame(height: max(item, 1))
        .scaleEffect(isPlaying ? 1 : 0.95)
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
    }
}
