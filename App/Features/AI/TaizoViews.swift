import PixlLibrary
import PixlModel
import PixlNet
import SwiftUI

// The pieces of Taizo's chat (`TaisChatSheet`): the orb, the suggestion chips, the message rows and the queue card.

// MARK: - Orb

/// Taizo's mark: a sphere of the theme's accent palette drifting in a mesh gradient, with a specular highlight, a rim
/// and white sparkles. Not a Material surface and not glass — an emblem, like Android's gradient avatar.
///
/// Fills whatever square it is given (so `matchedGeometryEffect` can grow and shrink it). It drifts only while
/// `animated` (≤ 24 fps from a `TimelineView`); otherwise — and always with Reduce Motion or in UI tests — it is one
/// still frame. `energy` (0 rest … 1 thinking) is animatable: a stronger swirl, a breathing scale and a brighter glow.
struct TaizoOrb: View {
    var energy: Double = 0
    var animated: Bool = false
    var glow: Bool = false
    /// The sparkles' size as a fraction of the orb's diameter.
    var sparkleSize: CGFloat = 0.4

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = TaizoOrbPalette(theme: theme)
        let still = reduceMotion || LaunchConfiguration.current.isUITest
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animated || still)) { context in
            let time = still ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            TaizoOrbFace(energy: energy, time: time, palette: palette, glow: glow)
        }
        .overlay {
            GeometryReader { proxy in
                Image(systemName: "sparkles")
                    .font(.system(size: proxy.size.width * sparkleSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: proxy.size.width * 0.03, y: proxy.size.width * 0.015)
                    .symbolEffect(.pulse, isActive: energy > 0.5 && !reduceMotion)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(.easeInOut(duration: 0.6), value: energy)
        .accessibilityHidden(true)
    }
}

/// The orb's colours. Fixed roles, which are the same in the light and dark schemes, so the orb reads alike on
/// both sheets: pale accents top-left, the deep variants bottom-right.
nonisolated struct TaizoOrbPalette: Sendable {
    let mesh: [Color]
    let glow: Color

    init(theme: ThemeColors) {
        mesh = [theme.primaryFixed, theme.tertiaryFixed, theme.primaryFixedDim,
                theme.tertiaryFixedDim, theme.primaryFixedDim, theme.onPrimaryFixedVariant,
                theme.secondaryFixedDim, theme.onTertiaryFixedVariant, theme.onPrimaryFixedVariant]
        glow = theme.primaryFixedDim
    }
}

/// One frame of the orb at `time`; `energy` is interpolated by SwiftUI (`Animatable`).
private struct TaizoOrbFace: View, Animatable {
    nonisolated var animatableData: Double
    let time: Double
    let palette: TaizoOrbPalette
    let glow: Bool

    init(energy: Double, time: Double, palette: TaizoOrbPalette, glow: Bool) {
        animatableData = energy
        self.time = time
        self.palette = palette
        self.glow = glow
    }

    var body: some View {
        let energy = min(max(animatableData, 0), 1)
        let t = time
        let swirl = 0.14 + 0.1 * energy
        let breathe = 1 + 0.045 * energy * sin(t * 3.4)
        ZStack {
            MeshGradient(width: 3, height: 3, points: Self.points(t: t, swirl: swirl), colors: palette.mesh)
            // Specular highlight (top-leading) and a soft shade toward the far edge: a sphere, not a disc.
            EllipticalGradient(colors: [.white.opacity(0.55), .white.opacity(0)], center: UnitPoint(x: 0.32, y: 0.22),
                               startRadiusFraction: 0, endRadiusFraction: 0.42)
            EllipticalGradient(colors: [.black.opacity(0), .black.opacity(0.22)], center: UnitPoint(x: 0.42, y: 0.36),
                               startRadiusFraction: 0.42, endRadiusFraction: 0.78)
        }
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.05), .white.opacity(0.3)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .background {
            if glow {
                Circle()
                    .fill(EllipticalGradient(colors: [palette.glow.opacity(0.55 + 0.25 * energy), palette.glow.opacity(0)],
                                             center: .center, startRadiusFraction: 0.2, endRadiusFraction: 0.5))
                    .scaleEffect(2.1 + 0.12 * energy * sin(t * 3.4))
            }
        }
        .scaleEffect(breathe)
    }

    /// A 3×3 mesh: the corners stay put, the edge midpoints slide along their edges and the centre wanders.
    private static func points(t: Double, swirl: Double) -> [SIMD2<Float>] {
        func f(_ value: Double) -> Float { Float(value) }
        return [
            [0, 0], [f(0.5 + 0.2 * sin(t * 0.50)), 0], [1, 0],
            [0, f(0.5 + 0.2 * sin(t * 0.43 + 1.3))],
            [f(0.5 + swirl * sin(t * 0.61)), f(0.5 + swirl * cos(t * 0.53))],
            [1, f(0.5 + 0.2 * cos(t * 0.47 + 0.4))],
            [0, 1], [f(0.5 + 0.2 * cos(t * 0.57 + 2.1)), 1], [1, 1],
        ]
    }
}

// MARK: - Suggestions

/// A suggestion chip: what it says, its symbol and mood colour, the prompt it sends and its UI-test identifier.
nonisolated struct TaizoSuggestion: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let mood: Mood
    let prompt: String

    nonisolated enum Mood: Sendable, Hashable {
        case calm, energy, blue, party, focus, sunny, personal
    }

    /// Android `TAIZO_SUGGESTIONS`, in order, each sent as "Play some <x> songs".
    static let moods: [TaizoSuggestion] = [
        mood("Chill acoustic", "guitars.fill", .calm),
        mood("Energetic rock", "bolt.fill", .energy),
        mood("Sad indie", "cloud.rain.fill", .blue),
        mood("Party anthems", "party.popper.fill", .party),
        mood("Focus beats", "headphones", .focus),
        mood("Feel-good pop", "sun.max.fill", .sunny),
    ]

    private static func mood(_ title: String, _ systemImage: String, _ mood: Mood) -> TaizoSuggestion {
        TaizoSuggestion(id: "taisChat.suggestion.\(title)", title: title, systemImage: systemImage, mood: mood,
                        prompt: "Play some \(title) songs")
    }

    /// Up to two chips from the listener's stats (Home's overview, already computed): their top artist, and their
    /// top genre when Taizo's parser knows it as a genre (otherwise it would search titles for the word).
    static func personal(from summary: PlaybackStatsSummary?) -> [TaizoSuggestion] {
        guard let summary else { return [] }
        var chips: [TaizoSuggestion] = []
        if let artist = summary.topArtists.first?.artist.trimmingCharacters(in: .whitespacesAndNewlines),
           !artist.isEmpty, artist.count <= 28 {
            chips.append(TaizoSuggestion(id: "taisChat.suggestion.personal.artist", title: artist, systemImage: "music.mic",
                                         mood: .personal, prompt: "Play some \(artist) songs"))
        }
        if let genre = HomeLogic.topGenre(summary)?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty,
           !TaisIntentParser.parse("Play some \(genre) songs").genres.isEmpty {
            chips.append(TaizoSuggestion(id: "taisChat.suggestion.personal.genre", title: "More \(genre.lowercased())",
                                         systemImage: "waveform", mood: .personal, prompt: "Play some \(genre) songs"))
        }
        return chips
    }
}

/// The chips, centred row by row across the width, in one glass container (spacing below their 8 pt gaps, so they
/// never melt together at rest). They rise in, staggered, the first time they show.
struct TaizoSuggestionCloud: View {
    let suggestions: [TaizoSuggestion]
    let onTap: (TaizoSuggestion) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            AIFlowLayout(horizontalSpacing: 8, verticalSpacing: 10, centered: true) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    TaizoSuggestionChip(suggestion: suggestion) { onTap(suggestion) }
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown || reduceMotion ? 0 : 10)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.04 * Double(index)), value: shown)
                }
            }
        }
        .onAppear { shown = true }
    }
}

/// One chip: a glass capsule with a faint mood tint, a small mood-coloured disc holding the symbol, and the title.
struct TaizoSuggestionChip: View {
    let suggestion: TaizoSuggestion
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let color = moodColor
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: suggestion.systemImage)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(color.gradient, in: Circle())
                    .accessibilityHidden(true)
                Text(suggestion.title)
                    .pixlFont(.labelLarge)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 16)
            .padding(.vertical, 6)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: color.opacity(theme.isDark ? 0.16 : 0.1), interactive: true)
        .accessibilityLabel(suggestion.title)
        .accessibilityHint("Asks Taizo for this")
        .accessibilityIdentifier(suggestion.id)
    }

    private var moodColor: Color {
        switch suggestion.mood {
        case .calm: .teal
        case .energy: .red
        case .blue: .indigo
        case .party: .pink
        case .focus: .mint
        case .sunny: .orange
        case .personal: theme.primary
        }
    }
}

// MARK: - Messages

extension TaisChatMessage {
    /// How a row arrives: the user's bubble grows from its trailing corner, Taizo's turn from its leading one.
    var insertionTransition: AnyTransition {
        let anchor: UnitPoint
        if case .user = self { anchor = .bottomTrailing } else { anchor = .bottomLeading }
        return .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: anchor)).combined(with: .offset(y: 12)),
                           removal: .opacity)
    }
}

/// One chat row (Android `TaisChatMessageRow`).
struct TaisChatMessageRow: View {
    let message: TaisChatMessage
    let isResolvingOnlineTracks: Bool
    let onPlay: ([Song]) -> Void
    let onQueue: ([Song]) -> Void
    let onResolve: ([SearchResultItem], SearchSource, Bool) -> Void

    @Environment(\.appTheme) private var theme

    /// Taizo's bubbles: a 6 pt top-leading corner (pointing at the orb), 22 elsewhere; the user's: a 6 pt
    /// bottom-trailing corner.
    static let taizoShape = UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 22,
                                                   bottomTrailingRadius: 22, topTrailingRadius: 22, style: .continuous)
    static let userShape = UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22,
                                                  bottomTrailingRadius: 6, topTrailingRadius: 22, style: .continuous)

    var body: some View {
        switch message {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .pixlGlass(in: Self.userShape, tint: theme.primary.opacity(GlassTint.prominent))
            }
        case .thinking:
            taizoTurn {
                ThinkingDots(color: theme.primary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                    .pixlGlass(in: Self.taizoShape, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Taizo is thinking")
        case .textReply(_, let text, let isError):
            taizoTurn {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if isError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.onErrorContainer)
                            .accessibilityHidden(true)
                    }
                    Text(text)
                        .pixlFont(.bodyLarge)
                        .foregroundStyle(isError ? theme.onErrorContainer : theme.onSurface)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .pixlGlass(in: Self.taizoShape,
                           tint: isError ? theme.errorContainer.opacity(GlassTint.container)
                                         : theme.surfaceContainerHigh.opacity(GlassTint.surface))
            }
        case .djReply(_, let prompt, let result, let intro):
            taizoTurn {
                TaizoQueueCard(prompt: prompt, result: result, intro: intro, isResolving: isResolvingOnlineTracks,
                               onPlay: onPlay, onQueue: onQueue, onResolve: onResolve)
            }
        }
    }

    /// Taizo's side: a small still orb, then the content, leaving room on the trailing side.
    private func taizoTurn<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            TaizoOrb(sparkleSize: 0.44)
                .frame(width: 28, height: 28)
            content()
            Spacer(minLength: 24)
        }
    }
}

// MARK: - Queue card

/// Taizo's answer to a play / queue / find prompt: the intro line, then a card with the artwork mosaic, the mix's name
/// and size, Play and Add to Queue, and the songs (tap one to play it). One glass shape; everything on it is a fill.
struct TaizoQueueCard: View {
    let prompt: String
    let result: DjRouteResult
    let intro: String?
    let isResolving: Bool
    let onPlay: ([Song]) -> Void
    let onQueue: ([Song]) -> Void
    let onResolve: ([SearchResultItem], SearchSource, Bool) -> Void

    @Environment(\.appTheme) private var theme
    @State private var expanded = false

    /// Rows shown before "Show all", and the most the card ever lists (Android lists 8).
    private static let collapsedRows = 4
    private static let maxRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch result {
            case .offline(let songs):
                Text(intro ?? "Found \(songs.count) songs in your library.")
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurface)
                summary(art: songs.prefix(4).map { ArtworkSource(song: $0) }, count: songs.count,
                        detail: Self.durationText(songs), artists: Self.artistLine(songs.map(\.displayArtist)))
                actions(enabled: true, play: { onPlay(songs) }, queue: { onQueue(songs) })
                rows(count: songs.count) { range in
                    ForEach(songs[range]) { song in
                        TaizoTrackRow(title: song.title, subtitle: song.displayArtist,
                                      artwork: ArtworkSource(song: song), enabled: true) { onPlay([song]) }
                    }
                }
            case .online(let items, let source):
                let infos = items.map(Self.trackInfo)
                let sourceName = source == .spotify ? "Spotify" : "YouTube Music"
                Text(intro ?? "Found \(items.count) tracks on \(sourceName).")
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurface)
                summary(art: infos.prefix(4).map { ArtworkSource(uriString: $0.art) }, count: items.count,
                        detail: sourceName, artists: Self.artistLine(infos.map(\.artist)))
                actions(enabled: !isResolving, play: { onResolve(items, source, true) },
                        queue: { onResolve(items, source, false) })
                rows(count: items.count) { range in
                    ForEach(range, id: \.self) { index in
                        TaizoTrackRow(title: infos[index].title, subtitle: infos[index].artist,
                                      artwork: ArtworkSource(uriString: infos[index].art),
                                      enabled: !isResolving) { onResolve([items[index]], source, true) }
                    }
                }
            case .noResults:
                Label("Couldn't find anything for that — try a different genre or mood.", systemImage: "magnifyingglass")
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurface)
            }
        }
        .padding(14)
        .pixlGlass(in: TaisChatMessageRow.taizoShape, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
    }

    // MARK: Pieces

    private func summary(art: [ArtworkSource?], count: Int, detail: String?, artists: String) -> some View {
        HStack(spacing: 14) {
            TaizoArtworkStack(sources: art, size: 76)
            VStack(alignment: .leading, spacing: 3) {
                Text(TaizoMixTitle.make(prompt))
                    .pixlFont(.titleMedium, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2)
                Text([count == 1 ? "1 song" : "\(count) songs", detail].compactMap { $0 }.joined(separator: " · "))
                    .pixlFont(.bodySmall, weight: .semibold)
                    .foregroundStyle(theme.primary)
                if !artists.isEmpty {
                    Text(artists)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Play (accent) and Add to Queue (tonal): fills on the card (Android's two `FilledTonalButton`s).
    private func actions(enabled: Bool, play: @escaping () -> Void, queue: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: play) {
                HStack(spacing: 6) {
                    if isResolving {
                        ProgressView().controlSize(.small).tint(theme.onPrimary)
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 15, weight: .bold))
                    }
                    Text("Play").pixlFont(.labelLarge, weight: .semibold).lineLimit(1)
                }
                .foregroundStyle(theme.onPrimary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(theme.primary, in: Capsule())
                .contentShape(.capsule)
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
            .accessibilityLabel("Play Queue")
            Button(action: queue) {
                HStack(spacing: 6) {
                    Image(systemName: "text.badge.plus").font(.system(size: 15, weight: .semibold))
                    Text("Add to Queue").pixlFont(.labelLarge, weight: .semibold).lineLimit(1).minimumScaleFactor(0.8)
                }
                .foregroundStyle(theme.onSecondaryContainer)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(theme.secondaryContainer, in: Capsule())
                .contentShape(.capsule)
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
            .accessibilityLabel("Add to Queue")
        }
        .disabled(!enabled)
        .opacity(enabled || isResolving ? 1 : 0.5)
    }

    /// The first rows (all of them when there are five or fewer), then "Show all" up to `maxRows`.
    @ViewBuilder
    private func rows<Rows: View>(count: Int, @ViewBuilder content: (Range<Int>) -> Rows) -> some View {
        let total = min(count, Self.maxRows)
        let collapses = total > Self.collapsedRows + 1
        let shown = collapses && !expanded ? Self.collapsedRows : total
        if total > 0 {
            VStack(spacing: 2) {
                content(0..<shown)
                if collapses {
                    Button {
                        withAnimation(PixlMotion.state) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? "Show less" : "Show all \(total)")
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                        .pixlFont(.labelLarge, weight: .semibold)
                        .foregroundStyle(theme.primary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(.rect)
                    }
                    .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
                }
            }
        }
    }

    // MARK: Text

    private static func durationText(_ songs: [Song]) -> String? {
        let totalMs = songs.reduce(Int64(0)) { $0 + max($1.duration, 0) }
        guard totalMs > 0 else { return nil }
        let minutes = Int((Double(totalMs) / 60_000).rounded())
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }

    /// "Artist A, Artist B and 3 more" from the distinct artists, in order.
    private static func artistLine(_ artists: [String]) -> String {
        var seen = Set<String>()
        let distinct = artists.filter { !$0.isEmpty && seen.insert($0).inserted }
        switch distinct.count {
        case 0: return ""
        case 1: return distinct[0]
        case 2: return "\(distinct[0]) and \(distinct[1])"
        default: return "\(distinct[0]), \(distinct[1]) and \(distinct.count - 2) more"
        }
    }

    static func trackInfo(_ item: SearchResultItem) -> (title: String, artist: String, art: String?) {
        switch item {
        case .catalog(let track): (track.title, track.artist, track.albumArtUrl)
        case .youtubeMusic(let track): (track.title, track.artist, track.thumbnailUrl)
        case .song(let song): (song.title, song.displayArtist, song.albumArtUriString)
        case .album(let album): (album.title, album.artist, album.albumArtUriString)
        case .artist(let artist): (artist.name, "", nil)
        case .playlist(let playlist): (playlist.name, "", nil)
        }
    }
}

/// The mix's name from the prompt: its moods and genres ("Chill Acoustic"), else what was searched for, else "Your
/// mix". Parsed once per prompt and cached (the parser is cheap, but `body` stays free of parsing).
@MainActor
enum TaizoMixTitle {
    private static var cache: [String: String] = [:]

    static func make(_ prompt: String) -> String {
        if let hit = cache[prompt] { return hit }
        let intent = TaisIntentParser.parse(prompt)
        let words = intent.moods + intent.genres
        let title: String
        if !words.isEmpty {
            title = words.map(\.localizedCapitalized).joined(separator: " ") + " mix"
        } else if !intent.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            title = intent.searchQuery.localizedCapitalized
        } else {
            title = "Your mix"
        }
        if cache.count > 64 { cache.removeAll() }
        cache[prompt] = title
        return title
    }
}

/// A 2×2 mosaic of the first covers (repeating when there are fewer than four) on two tinted cards fanned out
/// behind it, like a stack of records. Fills, not glass (it sits on the card's glass).
struct TaizoArtworkStack: View {
    let sources: [ArtworkSource?]
    let size: CGFloat

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            shape.fill(theme.tertiary.opacity(0.35))
                .rotationEffect(.degrees(9))
                .offset(x: 7, y: -2)
            shape.fill(theme.primary.opacity(0.45))
                .rotationEffect(.degrees(-6))
                .offset(x: -5, y: 1)
            mosaic
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        }
        .frame(width: size, height: size)
        .padding(6)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mosaic: some View {
        let tiles = sources.isEmpty ? [nil] : sources
        if tiles.count == 1 {
            ArtworkView(source: tiles[0], size: size, cornerRadius: 0)
        } else {
            let half = size / 2
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ArtworkView(source: tiles[0], size: half, cornerRadius: 0)
                    ArtworkView(source: tiles[1 % tiles.count], size: half, cornerRadius: 0)
                }
                GridRow {
                    ArtworkView(source: tiles[2 % tiles.count], size: half, cornerRadius: 0)
                    ArtworkView(source: tiles[3 % tiles.count], size: half, cornerRadius: 0)
                }
            }
        }
    }
}

/// One result row (Android `TaizoSongRow` / `TaizoOnlineTrackRow`): 44 pt art (10 pt corners), title / artist,
/// a play icon; tap anywhere to play it.
struct TaizoTrackRow: View {
    let title: String
    let subtitle: String
    let artwork: ArtworkSource?
    let enabled: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                ArtworkView(source: artwork, size: 44, cornerRadius: 10)
                Spacer().frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .pixlFont(.bodyMedium, weight: .semibold)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(subtitle)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 8)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24, weight: .regular))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(theme.onPrimary, theme.primary)
                    .accessibilityLabel("Play \(title)")
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 2)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }
}

/// Three dots rising and brightening out of phase (900 ms) — Taizo's typing indicator. Ticks at ≤ 30 fps and only
/// while a prompt is in flight (the row exists only then); still with Reduce Motion.
struct ThinkingDots: View {
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let local = (phase + 1 - Double(index) * 0.18).truncatingRemainder(dividingBy: 1)
                    let wave = reduceMotion ? 0.6 : min(max(sin(local * .pi), 0), 1)
                    Circle()
                        .fill(color.opacity(0.35 + 0.65 * wave))
                        .frame(width: 8, height: 8)
                        .offset(y: -3 * wave)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Flow layout

/// Compose `FlowRow` for chips: rows of chips wrapped at the proposed width, start-aligned or centred.
nonisolated struct AIFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat
    var centered = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = centered ? bounds.minX + max((bounds.width - row.width) / 2, 0) : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if !current.indices.isEmpty, extra > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
