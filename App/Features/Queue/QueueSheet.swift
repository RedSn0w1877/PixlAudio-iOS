import PixlModel
import SwiftUI

/// The queue (Android `QueueBottomSheet`), presented over the player with the system sheet:
/// - header: "Next up" (`headlineLarge` semibold; tap = locate the current song) over "N tracks lined up.", and the
///   queue-source capsule;
/// - the songs (from the current one on, or the whole queue with `show_queue_history`), 8 pt apart: glass rows with
///   22 pt corners — the current one a capsule with circular art, bold `primary` title and the playing indicator.
///   Songs after the current one have a drag handle (reorder) and swipe left to remove (60 pt of tension, then free;
///   past 40 % of the width it goes), with an undo bar;
/// - the bottom toolbar: shuffle / repeat / sleep timer circles and the ⋯ circle, which opens Locate current song ·
///   Clear queue · Save as playlist over a scrim.
/// Every row's ⋮ opens the song sheet; the timer opens `SleepTimerSheet`; Save as playlist opens
/// `SaveQueueAsPlaylistSheet`.
///
/// Liquid (Hoa, 2026-10-07, "more Liquid Glass"; docs/design.md › Glass expansion): the sheet is see-through glass at
/// 92 % (`PresentationDetent.tallGlass`); the toolbar's circles are each their own interactive glass (Android puts
/// glass circles on a glass capsule, which iOS can't stack, so the capsule went, as in `PlayerToggleRow`); and the
/// toolbar and the open menu share one `GlassEffectContainer`, so the ⋯ circle liquid-morphs into the
/// "Save as playlist" pill (one `glassEffectID`) while Locate and Clear materialise.
struct QueueSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback
    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme

    @State private var isMenuExpanded = false
    @State private var showsTimer = false
    @State private var confirmsClear = false
    @State private var showsSaveAsPlaylist = false
    @State private var songInfo: QueueSongRef?
    /// The drag's state lives in its own observable model: a drag event re-runs the visible rows' offset modifiers,
    /// not this sheet's body.
    @State private var reorder = QueueReorderState()
    @State private var rowPitch: CGFloat = 84
    @State private var undo: QueueUndo?
    @State private var locateRequest = 0
    @State private var didApplyLaunchState = false
    @Namespace private var glassNamespace

    /// The glass shapes of the toolbar and the menu that morph (`glassEffectID`): the ⋯ circle and "Save as playlist"
    /// share `.menu`, so the circle flows into the pill and back. `nonisolated`: the id must be `Sendable` under the
    /// app's default MainActor isolation (as `GlassPillRow.GlassID`).
    nonisolated private enum QueueGlassID: Hashable, Sendable {
        case menu, locate, clear
    }

    var body: some View {
        let queue = playback.queue
        let current = playback.currentIndex ?? -1
        let offset = settings.playback.showQueueHistory || current < 0 ? 0 : current
        // The shown rows are the queue from `offset` on, addressed by index (no copy of the queue per pass).
        let displayCount = max(queue.count - offset, 0)
        let currentDisplay = current - offset
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header(count: displayCount)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                if displayCount == 0 {
                    Text("Queue is empty.")
                        .pixlFont(.bodyLarge)
                        .foregroundStyle(theme.onSurface)
                        .frame(maxWidth: .infinity)
                        .padding(32)
                    Spacer(minLength: 0)
                } else {
                    list(queue: queue, count: displayCount, offset: offset, currentDisplay: currentDisplay)
                }
            }
            .accessibilityHidden(isMenuExpanded)
            if isMenuExpanded {
                menuScrim
            }
            // The toolbar and the open menu in ONE container, so the ⋯ circle can morph into the menu's pills. The
            // container always stays in the tree and only its content switches (an `if` around it would change its
            // identity and drop the morph). The toolbar leaves while the menu is open: the Save pill overlaps its
            // area, and overlapping shapes in one container would blend.
            GlassEffectContainer(spacing: 8) {
                ZStack(alignment: .bottom) {
                    if isMenuExpanded {
                        menuPills(canLocate: currentDisplay >= 0 && currentDisplay < displayCount)
                            .padding(.bottom, 36)
                    } else {
                        toolbar
                            .padding(.bottom, 16)
                    }
                }
            }
            if let undo {
                // Outside the container: the undo bar overlaps the open menu.
                undoBar(undo)
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // No implicit animation on `isMenuExpanded`: it would override the morph's spring (`withAnimation` in
        // `toggleMenu` / `closeMenu`) for the whole subtree.
        .animation(PixlMotion.bars, value: undo?.id)
        .pixlHaptic(.selection, trigger: isMenuExpanded)
        .sheet(item: $songInfo) { ref in
            SongInfoSheet(songId: ref.id).pixlSheet(detents: [.tallGlass])
        }
        .sheet(isPresented: $showsTimer) {
            SleepTimerSheet().sleepTimerPresentation()
        }
        .fullScreenCover(isPresented: $showsSaveAsPlaylist) {
            SaveQueueAsPlaylistSheet(songs: queue, defaultName: String(localized: "Current queue"))
        }
        .alert("Clear queue", isPresented: $confirmsClear) {
            Button("Clear", role: .destructive) { clearQueue() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to clear all songs from the queue except the current one?")
        }
        // The store bumps the revision whenever it replaces the queue (comparing every id per pass cost O(queue)).
        .onChange(of: playback.queueRevision) { _, _ in
            reorder.queueDidChange()
            completeUndoIfNeeded(playback.queue.map(\.id))
        }
        .task {
            // UI tests open Save as playlist straight away (`-screen queue.saveAsPlaylist`), once the sheet is up.
            guard env.launch.screen == .queueSaveAsPlaylist, !didApplyLaunchState else { return }
            didApplyLaunchState = true
            try? await Task.sleep(for: .milliseconds(700))
            showsSaveAsPlaylist = true
        }
        .accessibilityIdentifier("screen.queue")
    }

    // MARK: Header

    private func header(count: Int) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Next up")
                    .pixlFont(.headlineLarge, weight: .semibold)
                    .foregroundStyle(theme.onSurface)
                    .onTapGesture { locateRequest += 1 }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Scrolls to the current song")
                Text(Self.countLabel(count))
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 15, weight: .semibold))
                Text("Queue")
                    .pixlFont(.labelLarge)
                    .lineLimit(1)
            }
            .foregroundStyle(theme.onSurfaceVariant)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 190)
            .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHighest.opacity(0.88 * GlassTint.container))
            .padding(.top, 6)
        }
    }

    /// Android `queue_tracks_empty` / `queue_tracks_lined_up`.
    static func countLabel(_ count: Int) -> String {
        if count <= 0 { return String(localized: "Queue is empty for now.") }
        if count == 1 { return String(localized: "1 track lined up.") }
        return String(localized: "\(count) tracks lined up.")
    }

    // MARK: List

    private func list(queue: [Song], count: Int, offset: Int, currentDisplay: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    Spacer().frame(height: 6)
                    // Display positions as ids, as before (a row's slot is reused when the queue shifts).
                    ForEach(0..<count, id: \.self) { index in
                        let song = queue[index + offset]
                        let canReorder = index > currentDisplay
                        let isCurrent = index == currentDisplay
                        QueueSongRow(song: song, isCurrent: isCurrent,
                                     isPlaying: isCurrent && playback.isPlaying, canReorder: canReorder,
                                     isDragging: reorder.draggingIndex == index,
                                     onTap: { playback.skipToQueueItem(at: index + offset) },
                                     onMore: { songInfo = QueueSongRef(id: song.id) },
                                     onDismiss: { remove(song, at: index + offset) },
                                     canMoveUp: index - 1 > currentDisplay,
                                     canMoveDown: canReorder && index + 1 < count,
                                     onMove: { delta in
                                         playback.moveQueueItem(from: index + offset, to: index + delta + offset)
                                     },
                                     handle: handleGesture(index: index, minIndex: currentDisplay + 1,
                                                           maxIndex: count - 1, offset: offset))
                            .modifier(QueueRowReorderOffset(reorder: reorder, index: index, pitch: rowPitch))
                            .zIndex(reorder.draggingIndex == index ? 1 : 0)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                if index == 0 { rowPitch = height + 8 }
                            }
                            .id(index)
                    }
                }
                .padding(.bottom, 120)
            }
            .scrollDisabled(reorder.draggingIndex != nil)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous))
            .onChange(of: locateRequest) { _, _ in
                guard currentDisplay >= 0 else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                    proxy.scrollTo(currentDisplay, anchor: .top)
                }
            }
        }
    }

    /// The drag handle's gesture (Android `ReorderableItem` + `draggableHandle`): only songs after the current one
    /// move, and only among themselves.
    private func handleGesture(index: Int, minIndex: Int, maxIndex: Int, offset: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if reorder.draggingIndex == nil {
                    reorder.begin(index: index, minIndex: minIndex, maxIndex: maxIndex)
                }
                reorder.translation = value.translation.height
            }
            .onEnded { _ in
                guard let move = reorder.end(pitch: rowPitch) else { return }
                if move.from != move.to {
                    playback.moveQueueItem(from: move.from + offset, to: move.to + offset)
                    // Engines without native moves never answer: drop the preview after a moment.
                    Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { reorder.reset() }
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { reorder.reset() }
                }
            }
    }

    // MARK: Toolbar

    /// Shuffle · repeat · sleep timer as separate glass circles, then the ⋯ circle (Android `QueueControlsToolbar`).
    /// The gaps are 12 pt between the circles and 16 pt to the ⋯ circle, above the container's 8 pt: they render
    /// together but never blend at rest.
    private var toolbar: some View {
        let timerActive = env.sleepTimer.state.display != nil || env.sleepTimer.state.countedPlay != nil
        return HStack(spacing: 4) {
            HStack(spacing: 12) {
                toolbarButton("shuffle", label: "Toggle shuffle", active: playback.isShuffleEnabled) {
                    playback.setShuffleEnabled(!playback.isShuffleEnabled)
                }
                toolbarButton(playback.repeatMode == .one ? "repeat.1" : "repeat", label: "Toggle repeat",
                              active: playback.repeatMode != .off) {
                    playback.setRepeatMode(NowPlayingView.nextRepeatMode(after: playback.repeatMode))
                }
                toolbarButton("timer", label: "Sleep timer", active: timerActive) {
                    showsTimer = true
                }
                .accessibilityIdentifier("queue.timer")
            }
            // Android's capsule padding, kept so nothing moves now that the capsule's glass is gone.
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxHeight: .infinity)
            Button(action: toggleMenu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.onTertiaryContainer)
                    .frame(width: 70, height: 70)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .pixlGlass(in: Circle(), tint: theme.tertiaryContainer.opacity(GlassTint.prominent), interactive: true)
            .glassEffectID(QueueGlassID.menu, in: glassNamespace)
            // UI tests find it by identifier OR label: inside a glass container it may keep only its label.
            .accessibilityLabel("More actions")
            .accessibilityIdentifier("queue.more")
        }
        .frame(height: 70)
    }

    /// One toolbar circle: its own interactive glass (`primary` when on, a hint of `surfaceContainer` when off), the
    /// `PlayerToggleRow` recipe with `.regular` glass (the queue isn't over media). It materialises in and out when
    /// the menu opens instead of being pulled into the Save pill.
    private func toolbarButton(_ systemImage: String, label: LocalizedStringKey, active: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(active ? theme.onPrimary : theme.onSurfaceVariant)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 48)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Circle(),
                   tint: active ? theme.primary.opacity(GlassTint.prominent)
                                : theme.surfaceContainer.opacity(GlassTint.surface),
                   interactive: true)
        .glassEffectTransition(.materialize)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: active)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: Menu (the ⋯ circle)

    private func toggleMenu() {
        withAnimation(PixlMotion.selection) { isMenuExpanded.toggle() }
    }

    private func closeMenu() {
        withAnimation(PixlMotion.selection) { isMenuExpanded = false }
    }

    /// Android's 0.55 scrim plus the gradient into `surfaceContainerLowest` (kt:1038-1080); a tap closes the menu.
    private var menuScrim: some View {
        ZStack {
            theme.scrim.opacity(0.55)
            LinearGradient(colors: [.clear, theme.surfaceContainerLowest], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .onTapGesture { closeMenu() }
        .accessibilityHidden(true)
        .transition(.opacity.animation(.easeOut(duration: 0.2)))
    }

    /// Locate current song · Clear queue · Save as playlist. "Save as playlist" (nearest the toolbar) carries the ⋯
    /// circle's glass id, so the circle morphs into it; Locate and Clear materialise.
    private func menuPills(canLocate: Bool) -> some View {
        VStack(spacing: 10) {
            if canLocate {
                menuButton("Locate current song", systemImage: "location.fill", tint: theme.tertiaryContainer,
                           foreground: theme.onTertiaryContainer, id: .locate) {
                    closeMenu()
                    locateRequest += 1
                }
                .glassEffectTransition(.materialize)
            }
            menuButton("Clear queue", systemImage: "clear.fill", tint: theme.errorContainer,
                       foreground: theme.onErrorContainer, id: .clear) {
                closeMenu()
                confirmsClear = true
            }
            .glassEffectTransition(.materialize)
            menuButton("Save as playlist", systemImage: "text.badge.plus", tint: theme.primaryContainer,
                       foreground: theme.onPrimaryContainer, id: .menu) {
                closeMenu()
                showsSaveAsPlaylist = true
            }
        }
        // Modal for VoiceOver: the queue under the scrim is out of reach, and the escape gesture closes the menu
        // (instead of bubbling up and dismissing the whole queue). On the pills themselves, which exist only while
        // the menu is open: on a wrapper around the container they would also trap VoiceOver in the closed toolbar
        // and swallow the escape that dismisses the sheet.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { closeMenu() }
        .accessibilityIdentifier("queue.menu")
    }

    private func menuButton(_ title: LocalizedStringKey, systemImage: String, tint: Color, foreground: Color,
                            id: QueueGlassID, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage).font(.system(size: 18, weight: .semibold))
                Text(title).pixlFont(.titleMedium, weight: .semibold)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minWidth: 184, maxWidth: 260, minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: tint.opacity(GlassTint.prominent),
                   interactive: true)
        .glassEffectID(id, in: glassNamespace)
    }

    // MARK: Removing, undo, clearing

    private func remove(_ song: Song, at queueIndex: Int) {
        playback.removeQueueItem(at: queueIndex)
        let entry = QueueUndo(song: song, index: queueIndex)
        undo = entry
        Task {
            try? await Task.sleep(for: .seconds(4))
            if undo?.id == entry.id { undo = nil }
        }
    }

    private func undoBar(_ entry: QueueUndo) -> some View {
        HStack(spacing: 4) {
            Text(entry.song.title)
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.inverseOnSurface)
                .lineLimit(1)
            Text("removed")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.inverseOnSurface.opacity(0.7))
            Button {
                undo?.isRestoring = true
                playback.addToQueue([entry.song])
            } label: {
                Text("Undo")
                    .pixlFont(.labelLarge, weight: .bold)
                    .foregroundStyle(theme.inversePrimary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                   tint: theme.inverseSurface.opacity(GlassTint.prominent))
        .padding(.horizontal, 24)
        .accessibilityIdentifier("queue.undo")
    }

    /// "Undo" re-appends the song, then moves it back to where it was once the engine reports the new queue.
    private func completeUndoIfNeeded(_ ids: [String]) {
        guard let entry = undo, entry.isRestoring, ids.last == entry.song.id else { return }
        let from = ids.count - 1
        undo = nil
        if from != entry.index, entry.index < ids.count {
            playback.moveQueueItem(from: from, to: entry.index)
        }
    }

    /// Android `clearQueueExceptCurrent`: removes every other entry, last first so the indices stay valid.
    private func clearQueue() {
        let current = playback.currentIndex
        for index in stride(from: playback.queue.count - 1, through: 0, by: -1) where index != current {
            playback.removeQueueItem(at: index)
        }
    }
}

/// A queue row's song, for the song sheet presented from the queue.
private struct QueueSongRef: Identifiable {
    let id: String
}

/// A removed song kept for "Undo".
private struct QueueUndo {
    let id = UUID()
    let song: Song
    let index: Int
    var isRestoring = false
}

/// A row's drag-reorder offset, read here — in this modifier only — so a drag event re-evaluates the visible rows'
/// offsets and nothing else.
private struct QueueRowReorderOffset: ViewModifier {
    let reorder: QueueReorderState
    let index: Int
    let pitch: CGFloat

    func body(content: Content) -> some View {
        content.offset(y: reorder.offset(for: index, pitch: pitch))
    }
}

/// Drag-reorder state: the dragged row follows the finger, the rows it passes slide one pitch the other way.
@Observable
final class QueueReorderState {
    struct Move: Equatable {
        var from: Int
        var to: Int
    }

    private(set) var draggingIndex: Int?
    var translation: CGFloat = 0
    @ObservationIgnored private var minIndex = 0
    @ObservationIgnored private var maxIndex = 0
    /// After a drop, the rows keep their preview offsets until the engine reports the reordered queue.
    private var pending: Move?

    func begin(index: Int, minIndex: Int, maxIndex: Int) {
        draggingIndex = index
        translation = 0
        self.minIndex = minIndex
        self.maxIndex = maxIndex
        pending = nil
    }

    func target(pitch: CGFloat) -> Int? {
        guard let draggingIndex else { return pending?.to }
        let steps = Int((translation / max(pitch, 1)).rounded())
        return min(max(draggingIndex + steps, minIndex), maxIndex)
    }

    func offset(for index: Int, pitch: CGFloat) -> CGFloat {
        let move: Move
        if let draggingIndex, let target = target(pitch: pitch) {
            if index == draggingIndex { return translation }
            move = Move(from: draggingIndex, to: target)
        } else if let pending {
            if index == pending.from { return CGFloat(pending.to - pending.from) * pitch }
            move = pending
        } else {
            return 0
        }
        if move.from < move.to, index > move.from, index <= move.to { return -pitch }
        if move.to < move.from, index >= move.to, index < move.from { return pitch }
        return 0
    }

    /// Ends the drag; returns the move (display indices).
    func end(pitch: CGFloat) -> Move? {
        guard let draggingIndex, let target = target(pitch: pitch) else { return nil }
        let move = Move(from: draggingIndex, to: target)
        pending = move
        self.draggingIndex = nil
        translation = 0
        return move
    }

    func queueDidChange() { reset() }

    func reset() {
        if draggingIndex != nil { draggingIndex = nil }
        if translation != 0 { translation = 0 }
        if pending != nil { pending = nil }
    }
}

/// One queue row (Android `QueuePlaylistSongItem`): handle · 42 pt art · title / artist · playing indicator · ⋮,
/// 16 pt vertical padding, 12 pt side insets. Swipe left removes (tension, then free; past 40 % it goes).
private struct QueueSongRow<Handle: Gesture>: View {
    let song: Song
    let isCurrent: Bool
    let isPlaying: Bool
    let canReorder: Bool
    let isDragging: Bool
    let onTap: () -> Void
    let onMore: () -> Void
    let onDismiss: () -> Void
    /// VoiceOver's way to reorder (the drag handle's gesture can't be driven by it): one place up or down, offered
    /// only where the row can go (never above the current song, never past the end).
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (_ delta: Int) -> Void
    let handle: Handle

    @Environment(\.appTheme) private var theme

    @State private var swipe: CGFloat = 0
    @State private var rawSwipe: CGFloat = 0
    @State private var isSwiping = false
    @State private var width: CGFloat = 1
    @State private var inZone = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: isCurrent ? 40 : 22, style: .continuous)
        ZStack(alignment: .trailing) {
            if swipe < 0 {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.onErrorContainer)
                    .opacity(min(-swipe / 56, 1) * (inZone ? 1 : 0.88))
                    .scaleEffect(inZone ? 1.08 : 0.95)
                    .padding(.trailing, 16)
                    .frame(width: -swipe, alignment: .trailing)
                    .frame(maxHeight: .infinity)
                    .background(Capsule().fill(theme.errorContainer.opacity(inZone ? 1 : 0.82)))
                    .padding(.trailing, 12)
            }
            row(shape: shape)
                .offset(x: swipe)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
        .pixlHaptic(.impact(weight: .light), trigger: inZone)
    }

    private func row(shape: RoundedRectangle) -> some View {
        HStack(spacing: 0) {
            if canReorder {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 40, height: 40)
                    .contentShape(.rect)
                    .gesture(handle)
                    .accessibilityLabel("Reorder song")
            }
            Spacer().frame(width: canReorder ? 6 : 12)
            ArtworkView(song: song, size: 42, cornerRadius: isCurrent ? 21 : 8)
            Spacer().frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(song.title)
                    .pixlFont(.bodyLarge, weight: isCurrent ? .bold : .regular)
                    .foregroundStyle(isCurrent ? theme.primary : theme.onSurface)
                    .lineLimit(1)
                Text(song.displayArtist)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(isCurrent ? theme.primary.opacity(0.8) : theme.onSurfaceVariant)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isCurrent {
                PlayingIndicator(isPlaying: isPlaying, color: theme.secondary)
                    .padding(.leading, 8)
                Spacer().frame(width: 12)
            } else {
                Spacer().frame(width: 8)
            }
            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(isCurrent ? theme.onTertiaryContainer : theme.onSurface)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(isCurrent ? theme.tertiaryContainer : theme.surfaceContainerHigh))
                    .contentShape(Rectangle().inset(by: -4))
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel("More options for \(song.title)")
            Spacer().frame(width: 14)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 16)
        .contentShape(shape)
        .onTapGesture { if swipe == 0 { onTap() } }
        .pixlGlass(in: shape, tint: (isCurrent ? theme.tertiaryContainer : theme.surfaceContainerLowest)
            .opacity(isCurrent ? GlassTint.container : GlassTint.surface), interactive: true)
        .scaleEffect(isDragging ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: isDragging)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: isCurrent)
        .padding(.horizontal, 12)
        .simultaneousGesture(canReorder ? swipeGesture : nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "More options") { onMore() }
        // Only the upcoming songs can be removed or moved: the current song and the history offer neither.
        .accessibilityActions {
            if canReorder {
                Button("Remove from queue", action: onDismiss)
            }
            if canMoveUp {
                Button("Move up") { onMove(-1) }
            }
            if canMoveDown {
                Button("Move down") { onMove(1) }
            }
        }
    }

    /// Android `QueueItemDismissGestureHandler`: left only; up to 60 pt the row moves at most 20 pt (tension), then
    /// it follows the finger; released past 40 % of the width it slides out and is removed.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                if !isSwiping {
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    isSwiping = true
                }
                rawSwipe = min(value.translation.width, 0)
                let distance = -rawSwipe
                let visual = distance < 60 ? -20 * distance / 60 : rawSwipe
                withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.9)) { swipe = visual }
                let zone = distance > width * 0.4
                if zone != inZone { inZone = zone }
            }
            .onEnded { _ in
                guard isSwiping else { return }
                isSwiping = false
                if -rawSwipe > width * 0.4 {
                    withAnimation(.easeOut(duration: 0.18)) { swipe = -width }
                    Task {
                        try? await Task.sleep(for: .milliseconds(180))
                        onDismiss()
                        try? await Task.sleep(for: .seconds(1))
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { swipe = 0 }
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { swipe = 0 }
                }
                rawSwipe = 0
                inZone = false
            }
    }
}
