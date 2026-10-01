import Foundation
import Observation
import PixlLibrary
import PixlModel
import SwiftUI

/// An ordered multi-selection (Android `MultiSelectionStateHolder` / `PlaylistSelectionStateHolder` and the album
/// selection list): selection order is kept because "play" and "queue" follow it, and each row shows its 1-based
/// position. Lookups are O(1).
@Observable
final class OrderedSelection<ID: Hashable> {
    private(set) var ids: [ID] = []
    @ObservationIgnored private var positions: [ID: Int] = [:]

    var isActive: Bool { !ids.isEmpty }
    var count: Int { ids.count }

    func contains(_ id: ID) -> Bool { positions[id] != nil }

    /// 1-based position, nil when not selected.
    func index(of id: ID) -> Int? { positions[id].map { $0 + 1 } }

    func toggle(_ id: ID) {
        if positions[id] != nil {
            ids.removeAll { $0 == id }
        } else {
            ids.append(id)
        }
        reindex()
    }

    /// Adds the ids that are not selected yet, keeping the current order first (Android `selectAll`).
    func selectAll(_ newIds: [ID]) {
        var next = ids
        for id in newIds where positions[id] == nil && !next.contains(id) { next.append(id) }
        ids = next
        reindex()
    }

    func clear() {
        guard !ids.isEmpty else { return }
        ids = []
        positions = [:]
    }

    private func reindex() {
        positions = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Android `MAX_ALBUM_MULTI_SELECTION`.
let maxAlbumMultiSelection = 6

// MARK: - Queue actions the Library offers (Android `addSongToQueue`, `addSongNextToQueue`, `playSongsShuffled`)

extension PlaybackStore {
    /// Space the shell's floating mini player takes over a pushed screen (Android pads lists and floating buttons
    /// by `MiniPlayerHeight` while a song is loaded).
    var miniPlayerClearance: CGFloat {
        hasItem ? Tokens.Shell.miniPlayerHeight + Tokens.Shell.miniPlayerSpacing : 0
    }

    /// Plays a shuffled copy (Android `playSongsShuffled(startAtZero = true)`).
    func playShuffled(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        play(QueueUtils.fisherYatesCopy(songs))
    }

    /// Appends to the queue (starts playback when nothing is loaded).
    /// The `PlaybackEngine` seam has no insert command yet, so the queue is re-set at the current position;
    /// stage 5 can replace this with a native insert.
    func addToQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        guard let index = currentIndex, hasItem else { play(songs); return }
        play(queue + songs, startIndex: index, startPositionMs: positionMs(), playWhenReady: isPlaying)
    }

    /// Inserts right after the current song (Android "Play next").
    func playNext(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        guard let index = currentIndex, hasItem else { play(songs); return }
        var next = queue
        next.insert(contentsOf: songs, at: min(index + 1, next.count))
        play(next, startIndex: index, startPositionMs: positionMs(), playWhenReady: isPlaying)
    }
}

// MARK: - Toast (Android `Toast` / `sendToast`)

/// A short message shown as a glass capsule near the bottom (Android toasts such as "Added to queue").
@Observable
final class LibraryToast {
    private(set) var message: String?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func show(_ text: String) {
        hideTask?.cancel()
        withAnimation(PixlMotion.bars) { message = text }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(PixlMotion.bars) { self?.message = nil }
        }
    }

    static let shared = LibraryToast()
}

/// Shows `LibraryToast.shared` over the content.
struct LibraryToastOverlay: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message = LibraryToast.shared.message {
                Text(message)
                    .pixlFont(.labelLarge)
                    .foregroundStyle(theme.inverseOnSurface)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .pixlGlass(in: Capsule(), tint: theme.inverseSurface.opacity(GlassTint.prominent))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("toast")
            }
        }
    }
}

extension View {
    func libraryToast() -> some View { modifier(LibraryToastOverlay()) }
}
