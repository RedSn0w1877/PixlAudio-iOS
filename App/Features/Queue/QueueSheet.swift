import PixlLibrary
import PixlModel
import SwiftUI
import UIKit

/// The queue (Android `QueueBottomSheet`, redesign 2 2026-11-25, mockup AndroidQueue), presented over the player with
/// the system sheet:
/// - header: "Queue" 28/34 bold (tap = locate the current song) over "Drag to reorder, swipe to remove", the Save as
///   playlist | Clear connected group, then "Up next" with the count of songs to come;
/// - the songs (from the current one on, or the whole queue with `show_queue_history`), 2 pt apart in the 16 pt gutter:
///   the current one is the now playing card (`tertiaryContainer`), the played songs one grouped block above it and the
///   upcoming ones another below (20 / 4 pt corners). Upcoming songs have a drag handle (reorder) and swipe left to
///   remove (60 pt of tension, then free; past 40 % of the width it goes), with an undo bar;
/// - the bottom toolbar as the nav's split pills: a big pill with shuffle / repeat / sleep timer and the round ⋯ pill,
///   which opens Locate current song · Clear queue · Save as playlist over a scrim.
/// Every row's ⋮ opens the song sheet; the timer opens `SleepTimerSheet`; Save as playlist opens
/// `SaveQueueAsPlaylistSheet`.
///
/// Liquid: the sheet is see-through glass (`PresentationDetent.tallGlass`); the toolbar's big pill is one glass shape
/// with fills on it (no glass on glass); the toolbar and the open menu share one `GlassEffectContainer`, so the ⋯ pill
/// liquid-morphs into the "Save as playlist" pill (one `glassEffectID`) while Locate and Clear materialise.
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
    /// "Why this song" for the row whose reason line was tapped (docs/brain-spec.md, 8.8).
    @State private var whyRef: QueueWhyRef?
    /// The notes of the queue (docs/brain-spec.md, 9.3): made again only when the queue, the current song or the library change.
    @State private var setNoteMemo = SetNoteMemo()
    /// The songs of the next few rows that the listener has a recorded play of; nil until read (a note is true or absent).
    @State private var heardIds: Set<String>?
    /// What the host of Endless Listening may say about the next rows (nil for any other queue or with the host's notes off).
    @State private var hostFacts: SetNoteLines.HostFacts?
    @State private var hostStamp = 0
    /// "Ask the host": Ask Taizo in host mode over the queue (Endless Listening only).
    @State private var showsAskHost = false
    @State private var showsHowPicksWork = false
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
        // The Autoplay line sits above the first song Autoplay added that is still to come (its display position),
        // or closes the queue while there is none.
        let autoplayLine = env.brain.autoplay.lineIndex.flatMap { line -> Int? in
            let display = line - offset
            return display > currentDisplay && display < displayCount ? display : nil
        }
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if displayCount == 0 {
                    header(count: displayCount, upcoming: 0)
                        .padding(.horizontal, Redesign.gutter)
                        .padding(.top, 22)
                        .padding(.bottom, 12)
                    Text("Queue is empty.")
                        .pixlFont(.bodyLarge)
                        .foregroundStyle(theme.onSurface)
                        .frame(maxWidth: .infinity)
                        .padding(32)
                    Spacer(minLength: 0)
                } else {
                    list(queue: queue, count: displayCount, offset: offset, currentDisplay: currentDisplay,
                         autoplayLine: autoplayLine)
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
        .sheet(item: $whyRef) { ref in
            WhyThisSongSheet(song: ref.song, why: ref.why).pixlSheet()
        }
        .sheet(isPresented: $showsHowPicksWork) {
            HowPicksWorkSheet().pixlSheet()
        }
        .sheet(isPresented: $showsAskHost) {
            TaisChatSheet(hostMode: true).pixlSheet(detents: [.tallGlass])
        }
        // "Not for me" from a row's song sheet or from "Why this song": the bar with Undo shows over the queue.
        .brainNoticeBar(bottomPadding: 96)
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

    /// Redesign 2 (Android `QueueHeader`, mockup AndroidQueue): 54 pt min in the 16 pt gutter — "Queue" 28/34 bold
    /// (−0.2) over "Drag to reorder, swipe to remove" 13/18 (tap the title: locate the current song), the Endless host
    /// chip under it; on the right a connected group, 44 pt, `surfaceContainerHighest` glass: Save as playlist (48 pt
    /// wide, 22 / 6 corners) | "Clear" (6 / 22). Then 12 pt and "Up next" (from the station when there is one) 16/22
    /// medium with "N songs" 13/18 on the right.
    private func header(count: Int, upcoming: Int) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Queue")
                        .pixlFont(.custom(size: 28, weight: .bold, lineHeight: 34, tracking: -0.2))
                        .foregroundStyle(theme.onSurface)
                        .onTapGesture { locateRequest += 1 }
                        .accessibilityAddTraits([.isHeader, .isButton])
                        .accessibilityHint("Scrolls to the current song")
                    Text(count <= 0 ? Self.countLabel(0) : String(localized: "Drag to reorder, swipe to remove"))
                        .pixlFont(.redesignRowSubtitle)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                    // Endless Listening: the host is one tap away from the queue (only while that station is the queue).
                    if env.brain.autoplay.isEndless {
                        AskHostButton { showsAskHost = true }
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                GlassEffectContainer(spacing: 1) {
                    HStack(spacing: Redesign.groupGap) {
                        RedesignGroupButton(position: .first, isSelected: false, height: 44, horizontalPadding: 0,
                                            container: theme.surfaceContainerHighest,
                                            action: { showsSaveAsPlaylist = true }) { _ in
                            Image(systemName: "text.badge.plus")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(theme.onSurface)
                        }
                        .frame(width: 48)
                        .accessibilityLabel("Save as playlist")
                        .accessibilityIdentifier("queue.save")
                        RedesignGroupButton(position: .last, isSelected: false, height: 44, horizontalPadding: 0,
                                            container: theme.surfaceContainerHighest,
                                            action: { confirmsClear = true }) { _ in
                            Text("Clear")
                                .pixlFont(.redesignLabel)
                                .foregroundStyle(theme.onSurface)
                                .padding(.leading, 14)
                                .padding(.trailing, 16)
                        }
                        .fixedSize()
                        .accessibilityIdentifier("queue.clear")
                    }
                }
            }
            .frame(minHeight: 54)
            if count > 0 {
                HStack(spacing: 12) {
                    Text(upNextTitle)
                        .pixlFont(.redesignRowTitle)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Self.songCount(upcoming))
                        .pixlFont(.redesignRowSubtitle)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
                .padding(.top, 12)
            }
        }
    }

    /// "Up next from <source>" (Android `queue_up_next_from`): iOS knows the source only for a station.
    private var upNextTitle: String {
        if let station = env.brain.autoplay.stationTitle, !station.isEmpty {
            return String(localized: "Up next from \(station)")
        }
        return String(localized: "Up next")
    }

    /// Android `queue_song_count`.
    static func songCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs")
    }

    /// Android `queue_tracks_empty` / `queue_tracks_lined_up`.
    static func countLabel(_ count: Int) -> String {
        if count <= 0 { return String(localized: "Queue is empty for now.") }
        if count == 1 { return String(localized: "1 track lined up.") }
        return String(localized: "\(count) tracks lined up.")
    }

    // MARK: List

    /// The queue's Autoplay line (docs/brain-spec.md, 8.3, 8.4): what follows it was picked by the engine; its switch
    /// turns the picking off. When the queue is a station it names the station instead. Under it, Familiar / Blend /
    /// Discover; beside it, the way to "How picks work".
    private var autoplayLineView: some View {
        let state = env.brain.autoplay
        let ai = settings.ai
        let autoplayController = env.autoplayController
        let actions = env.brainActions
        return AutoplayLine(isOn: ai.musicDiscoveryEnabled, finding: state.finding, fromLibrary: state.fromLibrary, onConnect: state.onConnect,
                            changedDirection: state.changedDirection, stationTitle: state.stationTitle,
                            stationIsArtist: state.stationIsArtist, stationSource: state.stationSource, novelty: state.novelty,
                            onToggle: { isOn in
                                ai.musicDiscoveryEnabled = isOn
                                autoplayController?.settingChanged()
                            },
                            onNovelty: { level in actions.setNovelty(level) },
                            onRefresh: { actions.refreshPicks() },
                            onHowPicksWork: { showsHowPicksWork = true })
    }

    private func list(queue: [Song], count: Int, offset: Int, currentDisplay: Int, autoplayLine: Int?) -> some View {
        // The reason line of every pick that has one, by song id (kept in step with the queue by Autoplay).
        let whyLines = env.brain.autoplay.why
        let currentIndex = playback.currentIndex ?? -1
        // By the position of the row in the queue: a song queued twice has its note on one row only.
        let hostActive = env.endless.wantsHostNotes
        let notesOff = env.endless.hostNotesOff
        let setNotes = setNoteMemo.notes(queue: queue, currentIndex: currentIndex, heard: heardIds, host: hostFacts, stamp: hostStamp,
                                         notesOff: notesOff).byIndex
        return ScrollViewReader { proxy in
            ScrollView {
                // Redesign 2: grouped rows 2 pt apart in the 16 pt gutter; the played songs are one group above the
                // now playing card, the upcoming ones another below it.
                LazyVStack(spacing: Redesign.rowGap) {
                    Spacer().frame(height: 4)
                    // Display positions as ids, as before (a row's slot is reused when the queue shifts).
                    ForEach(0..<count, id: \.self) { index in
                        if index == autoplayLine { autoplayLineView }
                        let song = queue[index + offset]
                        let canReorder = index > currentDisplay
                        let isCurrent = index == currentDisplay
                        let note = canReorder || isCurrent ? setNotes[index + offset] : nil
                        let why = whyLines.isEmpty ? nil : whyLines[song.id]
                        // The note is part of its row: it moves with the row when it is dragged, and the row's own height is what sets the
                        // drag's pitch (measured on the row, below, not on the note).
                        let shape = isCurrent ? groupedRowShape(index: 0, count: 1)
                            : (index < currentDisplay ? groupedRowShape(index: index, count: max(currentDisplay, 1))
                               : groupedRowShape(index: index - (currentDisplay + 1),
                                                 count: count - (currentDisplay + 1)))
                        VStack(spacing: 8) {
                            if let note {
                                // Endless Listening: the host's note is a small card; every other queue keeps the quiet line.
                                if hostActive { HostNoteCard(text: note) } else { SetNoteRowLabel(text: note) }
                            }
                            if isCurrent {
                                QueueNowPlayingCard(song: song, isPlaying: playback.isPlaying,
                                                    onPlayPause: { playback.togglePlayPause() },
                                                    onTap: { playback.skipToQueueItem(at: index + offset) },
                                                    onLongPress: { songInfo = QueueSongRef(id: song.id) })
                                    .padding(.vertical, 6)
                            } else {
                            QueueSongRow(song: song, isCurrent: isCurrent, shape: shape,
                                     isPlaying: isCurrent && playback.isPlaying, canReorder: canReorder,
                                     isDragging: reorder.draggingIndex == index,
                                     why: why?.line.map(BrainStrings.whyLine),
                                     onWhy: { if let why { whyRef = QueueWhyRef(song: song, why: why) } },
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
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                if index == currentDisplay + 1 { rowPitch = height + Redesign.rowGap }
                            }
                            }
                        }
                        .modifier(QueueRowReorderOffset(reorder: reorder, index: index, pitch: rowPitch))
                        .zIndex(reorder.draggingIndex == index ? 1 : 0)
                        .id(index)
                    }
                    // No pick of Autoplay's is waiting: the line closes the queue, so its switch is always in reach.
                    if autoplayLine == nil { autoplayLineView }
                }
                .padding(.horizontal, Redesign.gutter)
                .padding(.bottom, 120)
            }
            .scrollDisabled(reorder.draggingIndex != nil)
            // The header is the list's top inset, so rows scroll up under it (the cut-off sits at the top of the sheet,
            // not right below the title) and the system blurs the edge softly; the same soft edge at the bottom.
            .safeAreaInset(edge: .top, spacing: 0) {
                header(count: count, upcoming: max(count - currentDisplay - 1, 0))
                    .padding(.horizontal, Redesign.gutter)
                    .padding(.top, 22)
                    .padding(.bottom, 8)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            // The plays behind the notes are read when the window of the queue changes, on the brain's own actors (never on the main thread).
            .task(id: setNoteMemo.key(queue: queue, currentIndex: currentIndex, host: hostActive, notesOff: notesOff)) {
                let window = SetNoteLines.window(queue, currentIndex: currentIndex)
                heardIds = await SetNoteHistoryLoader.heard(window, repository: env.brain.repository, engine: env.brain.engine)
                hostFacts = hostActive ? await env.endless.hostFacts(window: window) : nil
                hostStamp &+= 1
            }
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

    /// Redesign 2 (Android: the nav's split pills, mockup AndroidQueue): 12 pt from the sides, 68 pt tall, 10 pt
    /// apart. The big pill is `surfaceContainerHigh` glass, 34 pt corners, 8 pt in, with shuffle / repeat / timer as
    /// equal 52 pt buttons (26 pt corners, 4 pt apart; on = a `tertiaryContainer` fill on the pill's glass); the round
    /// 68 pt ⋯ pill is `tertiaryContainer` glass and keeps the menu (it morphs into "Save as playlist").
    private var toolbar: some View {
        let timerActive = env.sleepTimer.state.display != nil || env.sleepTimer.state.countedPlay != nil
        return HStack(spacing: 10) {
            HStack(spacing: 4) {
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
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 34, style: .continuous),
                       tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
            .glassEffectTransition(.materialize)
            Button(action: toggleMenu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.onTertiaryContainer)
                    .frame(width: 68, height: 68)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .pixlGlass(in: Circle(), tint: theme.tertiaryContainer.opacity(GlassTint.prominent), interactive: true)
            .glassEffectID(QueueGlassID.menu, in: glassNamespace)
            // UI tests find it by identifier OR label: inside a glass container it may keep only its label.
            .accessibilityLabel("More actions")
            .accessibilityIdentifier("queue.more")
        }
        .frame(height: 68)
        .padding(.horizontal, 12)
    }

    /// One toolbar button: a 52 pt fill on the big pill's glass (no glass on glass), 26 pt corners, `tertiaryContainer`
    /// when on, clear when off.
    private func toolbarButton(_ systemImage: String, label: LocalizedStringKey, active: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(active ? theme.onTertiaryContainer : theme.onSurface)
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(active ? theme.tertiaryContainer : .clear))
                .contentShape(.rect(cornerRadius: 26))
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.94))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: active)
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
        // A pick the engine queued, swiped away unheard, is a weak negative for the session (8.4).
        env.autoplayController?.engineRowRemoved(songId: song.id)
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

/// The row whose reason line was tapped, for "Why this song".
private struct QueueWhyRef: Identifiable {
    let song: Song
    let why: QueueWhy

    var id: String { song.id }
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

/// One queue row (redesign 2, Android `QueuePlaylistSongItem` with a grouped shape, mockup AndroidQueue):
/// `surfaceContainerHighest` glass in its grouped shape (20 / 4 pt corners), 64 pt min, 10 pt start / 4 pt end, 44 pt
/// art with 12 pt corners, 12 pt, title 16/22 over artist 13/18, More (40 pt, 22 dp icon), then the drag handle
/// (44 × 48 pt, upcoming songs only). Swipe left removes (tension, then free; past 40 % it goes) over a 4 pt-cornered
/// `errorContainer` block.
private struct QueueSongRow<Handle: Gesture>: View {
    let song: Song
    let isCurrent: Bool
    let shape: UnevenRoundedRectangle
    let isPlaying: Bool
    let canReorder: Bool
    let isDragging: Bool
    /// Why the engine picked this song (docs/brain-spec.md, 8.8); nil for a song the listener queued and for a pick
    /// with nothing true to say. A tap on the line opens "Why this song".
    let why: String?
    let onWhy: () -> Void
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
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(theme.errorContainer.opacity(inZone ? 1 : 0.82)))
            }
            row
                .offset(x: swipe)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
        .pixlHaptic(.impact(weight: .light), trigger: inZone)
    }

    private var row: some View {
        HStack(spacing: 0) {
            ArtworkView(song: song, size: 44, cornerRadius: 12)
            Spacer().frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(song.title)
                    .pixlFont(.custom(size: 16, lineHeight: 22))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Text(song.displayArtist)
                    .pixlFont(.redesignRowSubtitle)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                if let why {
                    // One quiet line in `primary`; its own tap (the row's tap still plays the song).
                    Button(action: onWhy) {
                        Text(why)
                            .pixlFont(.labelMedium)
                            .foregroundStyle(theme.primary)
                            .lineLimit(1)
                            .padding(.vertical, 2)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(BrainStrings.whyDescription)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 40, height: 40)
                    .contentShape(.rect)
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel("More options for \(song.title)")
            if canReorder {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 44, height: 48)
                    .contentShape(.rect)
                    .gesture(handle)
                    .accessibilityLabel("Reorder song")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .contentShape(shape)
        .onTapGesture { if swipe == 0 { onTap() } }
        // Not `interactive`: interactive glass takes the touch for its press highlight and starved the scroll view of
        // pans that began on a row (only the margins around the rows scrolled).
        .pixlGlass(in: shape, tint: theme.surfaceContainerHighest.opacity(GlassTint.surface), interactive: false)
        .scaleEffect(isDragging ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: isDragging)
        .gesture(HorizontalRowSwipe(isEnabled: canReorder, onChanged: swipeChanged, onEnded: swipeEnded))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "More options") { onMore() }
        // Only the upcoming songs can be removed or moved: the current song and the history offer neither.
        .accessibilityActions {
            if why != nil {
                Button(BrainStrings.whySheetTitle, action: onWhy)
            }
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
    private func swipeChanged(_ dx: CGFloat) {
        isSwiping = true
        rawSwipe = min(dx, 0)
        let distance = -rawSwipe
        let visual = distance < 60 ? -20 * distance / 60 : rawSwipe
        withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.9)) { swipe = visual }
        let zone = distance > width * 0.4
        if zone != inZone { inZone = zone }
    }

    private func swipeEnded() {
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

/// Horizontal-only pan for the row's swipe-to-remove. A SwiftUI `DragGesture` claims a drag in any direction after
/// its minimum distance and cancels the scroll view's pan, so touches that started on a row could not scroll. This
/// UIKit recognizer refuses to begin unless the finger is moving mostly sideways, so vertical drags always scroll.
private struct HorizontalRowSwipe: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            onChanged(recognizer.translation(in: recognizer.view).x)
        case .ended, .cancelled, .failed:
            onEnded()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.2
        }
    }
}

/// The current song in the queue list (redesign 2, Android `QueueNowPlayingCard`): an 80 pt `tertiaryContainer` glass
/// card, 28 pt corners, 12 pt side padding; 56 pt art with 16 pt corners, 14 pt, "NOW PLAYING" 11/16 medium (0.8
/// tracking), the title 17/22 bold, the artist 14/18; a 40 pt `tertiary` play / pause square (14 pt corners, `onTertiary`
/// glyph, a fill on the card's glass) in a 56 pt touch box. A tap plays it from the start of its row's handler; a long
/// press opens the song's options.
private struct QueueNowPlayingCard: View {
    let song: Song
    let isPlaying: Bool
    let onPlayPause: () -> Void
    let onTap: () -> Void
    let onLongPress: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        HStack(spacing: 14) {
            ArtworkView(song: song, size: 56, cornerRadius: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(String(localized: "Now playing").uppercased())
                    .pixlFont(.custom(size: 11, weight: .medium, lineHeight: 16, tracking: 0.8))
                Text(song.title)
                    .pixlFont(.custom(size: 17, weight: .bold, lineHeight: 22))
                    .lineLimit(1)
                Text(song.displayArtist)
                    .pixlFont(.custom(size: 14, lineHeight: 18))
                    .lineLimit(1)
            }
            .foregroundStyle(theme.onTertiaryContainer)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.onTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.tertiary))
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("queue.nowPlaying.playPause")
        }
        .padding(.horizontal, 12)
        .frame(height: 80)
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.45, perform: onLongPress)
        .pixlGlass(in: shape, tint: theme.tertiaryContainer.opacity(GlassTint.container))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "More options", onLongPress)
        .accessibilityIdentifier("queue.nowPlaying")
    }
}
