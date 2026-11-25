import PixlLibrary
import PixlModel
import SwiftUI

/// Endless Listening's station screen, redesign batch 3 (Android `EndlessStationScreen`, mockup AndroidEndlessStation; 390 × 844, 1 dp =
/// 1 pt). Opened from the Home entry once the intro was seen, and right after the intro's "Start listening". A full-screen cover (no tab
/// bar, no mini player, like Android). Everything on it is the real queue: the song playing, its place in the station, the host's notes
/// for the songs coming up (`SetNoteLines`, the same notes the player and the queue show). Material fills become Liquid Glass.
///
///   header    safe area + 20 pt, 16 pt gutter, 48 pt: Minimise (neutral glass circle, chevron down), the centre column (16 dp infinity +
///             "ENDLESS LISTENING" 12/16 semibold 0.4 tertiary, 6 pt gap; under it the current song's taste island 16/22 semibold when the
///             host knows it), Station options (glass circle, ⋯: host notes on/off, how it works, open the player).
///   artwork   16 pt under, 212 pt, 32 pt corners: the song's art; "ON AIR" pill (28 pt, glass over the art, error dot) at 14/14; "Track N
///             of ∞" at right / bottom 14.
///   title     16 pt under: 34/40 heavy expanded, fitted (2 lines), artist 16/22; Like 48 pt glass circle (filled heart in primary).
///   progress  18 pt under: 20 pt touch row, 6 pt track surfaceContainerHighest, primary fill, 4 × 20 pt handle; times 12/16 6 pt under.
///   controls  10 pt under, 72 pt, space between: Less like this (56 pt glass circle), Previous (bare, 28 dp), Play / Pause (104 × 72, 28 pt
///             corners, primary glass), Next, Up next (56 pt glass circle: the next 20 songs, read only).
///   notes     22 pt under: "Host notes" 20/26 (expanded + compressed accent in tertiary), the count 13/18; 10 pt; the top note
///             (tertiaryContainer glass, 24 pt corners, 16 pt padding, 40 pt host badge) with the next one peeking 14 pt in, 12 pt lower
///             (secondaryContainer). Swipe a note away past a third. Hidden while host notes are off.
///   asks      18 pt under: outlined 36 pt chips, 12 pt corners, 8 pt apart: open the host with that chip.
///   ask pill  12 pt from the sides, 16 pt from the bottom: 68 pt, 34 pt corners, tertiaryContainer glass: sparkle, "Ask the host", a 52 pt
///             onTertiaryContainer circle with the mic (starts speech right away).
///
/// Performance: the position is read only by the progress row, on a `TimelineView` at most four times a second while playing; the notes
/// are made again only when the queue's window, the current song or the history change (`SetNoteMemo`, read off the main thread).
struct EndlessStationView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var memo = SetNoteMemo()
    @State private var heard: Set<String>?
    @State private var hostFacts: SetNoteLines.HostFacts?
    @State private var hostStamp = 0
    @State private var dismissed: Set<StationNote> = []
    @State private var showsUpNext = false
    @State private var showsHost = false

    var body: some View {
        let song = playback.current
        let queue = playback.queue
        let index = playback.currentIndex ?? -1
        let hostActive = env.endless.wantsHostNotes
        let notesOff = env.endless.hostNotesOff
        let result = memo.notes(queue: queue, currentIndex: index, heard: heard, host: hostFacts, stamp: hostStamp, notesOff: notesOff)
        let notes = result.byIndex.filter { $0.key >= index }.sorted { $0.key < $1.key }
            .map { StationNote(index: $0.key, text: $0.value) }
            .filter { !dismissed.contains($0) }
        let island = song.flatMap { hostFacts?.islandOf[$0.id] }.flatMap { $0.isEmpty ? nil : $0 }
        ZStack(alignment: .bottom) {
            theme.surface.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(island: island)
                    Spacer().frame(height: 16)
                    artwork(song: song, index: index)
                    Spacer().frame(height: 16)
                    titleRow(song: song)
                    Spacer().frame(height: 18)
                    StationProgress()
                    Spacer().frame(height: 10)
                    controls(song: song)
                    if !notesOff {
                        Spacer().frame(height: 22)
                        HStack(alignment: .center) {
                            TwoToneTitle(wide: HomeRedesignStrings.hostNotesA, accent: HomeRedesignStrings.hostNotesB, size: 20,
                                         tracking: -0.2, accentColor: theme.tertiary, lines: 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !notes.isEmpty {
                                Text(verbatim: HomeRedesignStrings.notesCount(notes.count))
                                    .pixlFont(.redesignRowSubtitle)
                                    .foregroundStyle(theme.onSurfaceVariant)
                            }
                        }
                        Spacer().frame(height: 10)
                        HostNotesStack(notes: notes, onDismiss: { dismissed.insert($0) })
                    }
                    Spacer().frame(height: 18)
                    QuickAsks(onChip: { openHost(chip: $0, voice: false) })
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
            askHostPill
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
        }
        .accessibilityIdentifier("screen.endlessStation")
        .accessibilityAction(.escape) { router.dismissCover() }
        // The history of plays and the host's facts are read when the window of the queue changes, off the main thread.
        .task(id: memo.key(queue: queue, currentIndex: index, host: hostActive, notesOff: notesOff)) {
            let window = SetNoteLines.window(queue, currentIndex: index)
            heard = await SetNoteHistoryLoader.heard(window, repository: env.brain.repository, engine: env.brain.engine)
            hostFacts = hostActive ? await env.endless.hostFacts(window: window) : nil
            hostStamp &+= 1
        }
        .sheet(isPresented: $showsUpNext) {
            UpNextSheet(upcoming: index < 0 ? [] : Array(queue.dropFirst(index + 1).prefix(20)))
                .pixlSheet(detents: [.medium, .large])
        }
        .sheet(isPresented: $showsHost) {
            TaisChatSheet(hostMode: true).pixlSheet(detents: [.tallGlass])
        }
    }

    /// Opens the host sheet (Android `EndlessStateHolder.openHostSheet`): the chip is sent, or speech starts, once the sheet is up.
    private func openHost(chip: HostChip?, voice: Bool) {
        env.endless.setPendingHostRequest(chip: chip, voice: voice)
        showsHost = true
    }

    // MARK: Header

    private func header(island: String?) -> some View {
        let tint = theme.surfaceContainerHigh.opacity(GlassTint.surface)
        return HStack(spacing: 8) {
            GlassCircleButton(systemImage: "chevron.down", accessibilityLabel: LocalizedStringKey(HomeRedesignStrings.stationMinimise),
                              size: 48, iconSize: 20, tint: tint) { router.dismissCover() }
                .accessibilityIdentifier("endless.station.minimise")
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "infinity")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 16, height: 16)
                    Text(verbatim: HomeRedesignStrings.endlessEyebrow)
                        .pixlFont(.custom(size: 12, weight: .semibold, lineHeight: 16, tracking: 0.4))
                }
                .foregroundStyle(theme.tertiary)
                if let island {
                    Text(verbatim: island)
                        .pixlFont(.custom(size: 16, weight: .semibold, lineHeight: 22))
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Menu {
                Button(env.endless.hostNotesEnabled ? HomeRedesignStrings.notesOn : HomeRedesignStrings.notesOff) {
                    env.endless.hostNotesEnabled.toggle()
                }
                Button(EndlessStrings.howItWorks) {
                    env.endless.introReturnsToStation = true
                    router.present(AppCover.endlessIntro)
                }
                Button(HomeRedesignStrings.openPlayer) {
                    router.present(AppCover.nowPlaying)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(theme.onSurface)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .pixlGlass(in: Circle(), tint: tint, interactive: true)
            .accessibilityLabel(Text(verbatim: HomeRedesignStrings.stationOptions))
            .accessibilityIdentifier("endless.station.options")
        }
        .frame(height: 48)
    }

    // MARK: Artwork

    private func artwork(song: Song?, index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        let pill = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return GeometryReader { proxy in
            ZStack {
                theme.surfaceContainerHigh
                if let song {
                    ArtworkView(song: song, size: proxy.size.width, cornerRadius: 0)
                        .frame(width: proxy.size.width, height: 212)
                        .clipped()
                }
            }
            .frame(width: proxy.size.width, height: 212)
            .clipShape(shape)
            .overlay(alignment: .topLeading) {
                OnAirLabel(color: theme.onSurface)
                    .padding(.leading, 10)
                    .padding(.trailing, 12)
                    .frame(height: 28)
                    .pixlGlass(in: pill, tint: theme.surface.opacity(GlassTint.container))
                    .padding(14)
            }
            .overlay(alignment: .bottomTrailing) {
                if index >= 0 {
                    Text(verbatim: HomeRedesignStrings.trackOf(index + 1))
                        .pixlFont(.custom(size: 12, weight: .semibold, lineHeight: 16))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .pixlGlass(in: pill, tint: theme.surface.opacity(GlassTint.container))
                        .padding(14)
                }
            }
        }
        .frame(height: 212)
        .accessibilityElement(children: .combine)
    }

    // MARK: Title

    private func titleRow(song: Song?) -> some View {
        let liked = song.map { library.song(id: $0.id)?.isFavorite ?? $0.isFavorite } ?? false
        let title = song?.title ?? ""
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                FitWidthTitle(text: title, face: ExpressiveFace(size: 34, weight: .heavy, width: .expanded, tracking: -0.6),
                              narrowest: .compressed, lines: 2)
                    .foregroundStyle(theme.onSurface)
                Text(verbatim: song?.displayArtist ?? "")
                    .pixlFont(.custom(size: 16, lineHeight: 22))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            GlassCircleButton(systemImage: liked ? "heart.fill" : "heart",
                              accessibilityLabel: LocalizedStringKey(liked ? HomeRedesignStrings.unlike(title)
                                                                     : HomeRedesignStrings.like(title)),
                              size: 48, iconSize: 20, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface),
                              foreground: liked ? theme.primary : theme.onSurface) {
                if let song { env.libraryEditor.toggleFavorite(song.id) }
            }
            .disabled(song == nil)
            .accessibilityIdentifier("endless.station.like")
        }
    }

    // MARK: Controls

    private func controls(song: Song?) -> some View {
        let tint = theme.surfaceContainerHigh.opacity(GlassTint.surface)
        let playShape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return GlassEffectContainer(spacing: 4) {
            HStack(spacing: 0) {
                GlassCircleButton(systemImage: "hand.thumbsdown", accessibilityLabel: LocalizedStringKey(HomeRedesignStrings.lessLikeThis),
                                  size: 56, iconSize: 19, tint: tint) {
                    if let song { env.brainActions.notForMe(song) }
                }
                .disabled(song == nil)
                .accessibilityIdentifier("endless.station.less")
                Spacer(minLength: 0)
                bareButton("backward.end.fill", HomeRedesignStrings.previous) { playback.skipToPrevious() }
                Spacer(minLength: 0)
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(theme.onPrimary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 104, height: 72)
                        .contentShape(playShape)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: playShape, tint: theme.primary.opacity(GlassTint.prominent), interactive: true)
                .accessibilityLabel(Text(verbatim: playback.isPlaying ? HomeRedesignStrings.pause : HomeRedesignStrings.play))
                .accessibilityIdentifier("endless.station.playPause")
                Spacer(minLength: 0)
                bareButton("forward.end.fill", HomeRedesignStrings.next) { playback.skipToNext() }
                Spacer(minLength: 0)
                GlassCircleButton(systemImage: "list.bullet", accessibilityLabel: LocalizedStringKey(HomeRedesignStrings.upNext),
                                  size: 56, iconSize: 19, tint: tint) { showsUpNext = true }
                    .accessibilityIdentifier("endless.station.upNext")
            }
        }
        .frame(height: 72)
    }

    /// Previous / Next: no container, a 28 dp icon in a 56 pt target (Android's transparent circles).
    private func bareButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.onSurface)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.88))
        .accessibilityLabel(Text(verbatim: label))
    }

    // MARK: Ask the host

    private var askHostPill: some View {
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
        return HStack(spacing: 10) {
            Button { openHost(chip: nil, voice: false) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 22, height: 22)
                    Text(verbatim: EndlessStrings.askHost)
                        .pixlFont(.custom(size: 16, weight: .medium, lineHeight: 22))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(theme.onTertiaryContainer)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("endless.askHost")
            Button { openHost(chip: nil, voice: true) } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(theme.tertiaryContainer)
                    .frame(width: 52, height: 52)
                    .background(theme.onTertiaryContainer, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.9))
            .accessibilityLabel(Text(verbatim: HomeRedesignStrings.voice))
            .accessibilityIdentifier("endless.askHost.voice")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 68)
        .pixlGlass(in: shape, tint: theme.tertiaryContainer.opacity(GlassTint.prominent), interactive: true)
    }
}

/// One host note and the queue row it belongs to (so the same text on two rows stays two notes).
private struct StationNote: Hashable {
    let index: Int
    let text: String
}

// MARK: - Progress

/// The 6 pt progress bar and its times (Android `StationProgress`). Tap or drag to seek. The position is read only here, on a
/// `TimelineView` at most four times a second while playing; a drag draws its own fraction until it ends.
private struct StationProgress: View {
    @Environment(PlaybackStore.self) private var playback
    @Environment(\.appTheme) private var theme
    @State private var dragFraction: Double?

    var body: some View {
        let _ = playback.seekRevision
        let playing = playback.isPlaying
        TimelineView(.animation(minimumInterval: 0.25, paused: !playing || dragFraction != nil)) { context in
            let _ = context.date
            let duration = playback.durationMs()
            let position = playback.positionMs()
            let live = duration > 0 ? min(max(Double(position) / Double(duration), 0), 1) : 0
            let fraction = dragFraction ?? live
            let shown = dragFraction.map { Int64($0 * Double(duration)) } ?? position
            VStack(spacing: 6) {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.surfaceContainerHighest).frame(height: 6)
                        Capsule().fill(theme.primary).frame(width: max(width * fraction, 0), height: 6)
                        Capsule().fill(theme.primary)
                            .frame(width: 4, height: 20)
                            .offset(x: min(max(width * fraction - 2, 0), max(width - 4, 0)))
                    }
                    .frame(width: width, height: 20)
                    .contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0, width > 0 else { return }
                            dragFraction = min(max(value.location.x / width, 0), 1)
                        }
                        .onEnded { value in
                            defer { dragFraction = nil }
                            guard duration > 0, width > 0 else { return }
                            let f = min(max(value.location.x / width, 0), 1)
                            playback.seek(toMs: Int64(f * Double(duration)))
                        })
                }
                .frame(height: 20)
                HStack {
                    Text(verbatim: PlayerFormat.duration(shown))
                    Spacer()
                    Text(verbatim: PlayerFormat.duration(duration))
                }
                .pixlTimeFont(.custom(size: 12, lineHeight: 16))
                .foregroundStyle(theme.onSurfaceVariant)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: HomeRedesignStrings.seek(PlayerFormat.duration(position), PlayerFormat.duration(duration))))
        }
    }
}

// MARK: - Notes

/// The top note with the next one peeking under it (Android `HostNotesStack`); a sideways swipe past a third sends the top one away.
private struct HostNotesStack: View {
    let notes: [StationNote]
    let onDismiss: (StationNote) -> Void

    @Environment(\.appTheme) private var theme
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        if let top = notes.first {
            ZStack(alignment: .top) {
                if notes.count > 1 {
                    shape.fill(theme.secondaryContainer)
                        .padding(.horizontal, 14)
                        .padding(.top, 18)
                        .offset(y: 12)
                        .accessibilityHidden(true)
                }
                HStack(alignment: .top, spacing: 12) {
                    HostBadge(size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: HomeRedesignStrings.noteEyebrow)
                            .pixlFont(.custom(size: 12, weight: .bold, lineHeight: 16, tracking: 0.4))
                        Text(verbatim: top.text)
                            .pixlFont(.custom(size: 15, lineHeight: 21))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(theme.onTertiaryContainer)
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                .pixlGlass(in: shape, tint: theme.tertiaryContainer.opacity(GlassTint.prominent))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
                .offset(x: offset)
                .opacity(1 - min(abs(offset) / width, 1))
                .gesture(DragGesture(minimumDistance: 12)
                    .onChanged { offset = $0.translation.width }
                    .onEnded { value in
                        if abs(value.translation.width) > width * 0.33 {
                            withAnimation(.easeOut(duration: 0.16)) { offset = value.translation.width > 0 ? width : -width }
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(160))
                                onDismiss(top)
                                offset = 0
                            }
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { offset = 0 }
                        }
                    })
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text(verbatim: HomeRedesignStrings.noteDismiss))
                .accessibilityAction(named: Text(verbatim: HomeRedesignStrings.noteDismiss)) { onDismiss(top) }
                .accessibilityIdentifier("endless.station.note")
            }
            .padding(.bottom, notes.count > 1 ? 12 : 0)
            .id(top)
        } else {
            Text(verbatim: HomeRedesignStrings.noNote)
                .pixlFont(.custom(size: 15, lineHeight: 21))
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pixlGlass(in: shape, tint: theme.surfaceContainer.opacity(GlassTint.surface))
        }
    }
}

// MARK: - Quick asks

/// The quick asks (Android `QuickAsks`): outlined 36 pt chips, 12 pt corners, 14 pt padding, 14 medium, 8 pt apart, in Android's order.
private struct QuickAsks: View {
    let onChip: (HostChip) -> Void
    @Environment(\.appTheme) private var theme

    private static let chips: [HostChip] = [.why, .surprise, .new, .upbeat, .slower, .familiar]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(Self.chips, id: \.rawValue) { chip in
                        Button { onChip(chip) } label: {
                            Text(verbatim: EndlessStrings.label(of: chip))
                                .pixlFont(.redesignLabel)
                                .foregroundStyle(theme.onSurface)
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .contentShape(shape)
                        }
                        .buttonStyle(.plain)
                        .overlay { shape.strokeBorder(theme.outline, lineWidth: 1).allowsHitTesting(false) }
                        .pixlGlass(in: shape, interactive: true)
                        .accessibilityIdentifier("endless.station.ask.\(chip.rawValue)")
                    }
                }
                .padding(.trailing, 16)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

// MARK: - Up next

/// "Up next": the station's next songs, read only (the queue itself is in the full player).
private struct UpNextSheet: View {
    let upcoming: [Song]
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: HomeRedesignStrings.upNext)
                .pixlFont(.custom(size: 22, weight: .bold, lineHeight: 28))
                .foregroundStyle(theme.onSurface)
                .accessibilityAddTraits(.isHeader)
            if upcoming.isEmpty {
                Text(verbatim: HomeRedesignStrings.upNextEmpty)
                    .pixlFont(.custom(size: 15, lineHeight: 21))
                    .foregroundStyle(theme.onSurfaceVariant)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(upcoming.enumerated()), id: \.offset) { _, song in
                            HStack(spacing: 12) {
                                ArtworkView(song: song, size: 44, cornerRadius: 12)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(verbatim: song.title)
                                        .pixlFont(.custom(size: 15, weight: .medium, lineHeight: 20))
                                        .foregroundStyle(theme.onSurface)
                                        .lineLimit(1)
                                    Text(verbatim: song.displayArtist)
                                        .pixlFont(.redesignRowSubtitle)
                                        .foregroundStyle(theme.onSurfaceVariant)
                                        .lineLimit(1)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("endless.station.upNextSheet")
    }
}
