import PixlLibrary
import PixlModel
import SwiftUI

/// Daily Mix (Android `DailyMixScreen`): today's picks on the mix page (redesign batch 3, tertiary): Remix draws a new Daily Mix, More
/// opens the AI playlist prompt.
struct DailyMixView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let details = env.home.brainMixDetails
        MixScreen(tone: .tertiary, tag: HomeRedesignStrings.mixTagDaily, title: BrainStrings.mixDaily,
                  songs: env.home.content.dailyMix, playsFromLibrary: false, screenID: "dailyMix",
                  remix: { await env.home.regenerateDailyMix(snapshot: library.snapshot, libraryRevision: library.songsRevision) },
                  showsMore: true, brain: details.ownsMixes ? BrainMixRows(details.daily) : nil)
    }
}

/// Your Mix (Android `YourMixScreen`): the full list the Home hero opens, with the same curated → daily → newest-songs fallback, on the
/// mix page (primary); Remix regenerates it.
struct YourMixView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let content = env.home.content
        let details = env.home.brainMixDetails
        MixScreen(tone: .primary, tag: HomeRedesignStrings.mixTagYour, title: HomeRedesignStrings.yourMixName,
                  songs: content.yourMix, playsFromLibrary: content.usesFallbackYourMix, screenID: "yourMix",
                  remix: { await env.home.regenerateYourMix(snapshot: library.snapshot) },
                  brain: details.ownsMixes && !content.usesFallbackYourMix ? BrainMixRows(details.your) : nil)
    }
}

/// What the brain says about the rows of a mix it built (docs/brain-spec.md, 8.2): the reason under a row, which rows
/// are music the listener does not have yet (they get Save), and what a play of the mix carries into the queue.
struct BrainMixRows {
    var reasons: [String: MixReason]
    var novelIds: Set<String>
    var tags: [String: BrainItemTag]

    init(_ part: BrainMixDetails.Part) {
        reasons = part.reasons
        novelIds = part.novelIds
        tags = part.tags
    }
}

/// The mix page (redesign batch 3, `MixPage.swift`) that Daily Mix, Your Mix and the other made-for-you lists share: the cover and its
/// block as the list's first item, the songs as glass cards with the brain's reason under each, Back / Save / More floating over the
/// page. The nav bar and the mini player stay (Android: Daily Mix left the hidden-nav list).
struct MixScreen: View {
    let tone: MixPageTone
    let tag: String
    let title: String
    let songs: [Song]
    /// The fallback mix plays from the whole library (Android `showAndPlaySongFromLibrary`).
    let playsFromLibrary: Bool
    let screenID: String
    /// Remix (Daily: a new Daily Mix, Your: regenerate); nil for the lists the brain plans (no reroll, no button).
    var remix: (() async -> Void)?
    /// Daily Mix only: the on-device AI prompt sheet.
    var showsMore = false
    /// Nil while the legacy mixes are showing.
    var brain: BrainMixRows?
    /// The weekly note of First Listen: two or three sentences from the list itself (docs/brain-spec.md, 9.3). Nil for every other list.
    var note: String? = nil

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var isRemixing = false
    @State private var safeTop: CGFloat = 0
    @State private var savingIds: IdentifiedIds?

    var body: some View {
        ZStack(alignment: .top) {
            theme.surface.ignoresSafeArea()
            if songs.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .tint(theme.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            MixPageTopButtons(screenID: screenID, onBack: { router.pop() },
                              onSave: songs.isEmpty ? nil : { savingIds = IdentifiedIds(ids: songs.map(\.id)) },
                              onMore: showsMore ? { router.present(AppSheet.aiPlaylist) } : nil)
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { safeTop = $0 }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("screen.\(screenID)")
        .sheet(item: $savingIds) { item in
            AddToPlaylistSheet(songIds: item.ids)
                .pixlSheet(detents: [.large])
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                MixPageHero(tone: tone, tag: tag, title: title, meta: MixPageText.meta(songs),
                            why: MixPageText.why(note: note, songCount: songs.count,
                                                 novelCount: brain.map { rows in songs.count(where: { rows.novelIds.contains($0.id) }) } ?? 0),
                            safeTop: safeTop,
                            onShuffle: shuffle, onPlay: playFromStart,
                            onRemix: remix.map { remix in { runRemix(remix) } }, remixBusy: isRemixing, screenID: screenID)
                    .padding(.bottom, 12)
                ForEach(songs) { song in
                    VStack(spacing: 0) {
                        PlaybackRowState(songId: song.id) { isCurrent, isPlaying in
                            SongCard(song: song, isCurrent: isCurrent, isPlaying: isPlaying,
                                     onTap: { play(from: song) },
                                     onMore: { router.present(AppSheet.songInfo(songId: song.id)) })
                        }
                        .padding(.horizontal, 16)
                        if let brain {
                            MixRowNote(song: song, reason: brain.reasons[song.id], isNew: brain.novelIds.contains(song.id))
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
    }

    private func runRemix(_ remix: @escaping () async -> Void) {
        guard !isRemixing else { return }
        isRemixing = true
        Task {
            await remix()
            isRemixing = false
        }
    }

    /// Android: play from the first song, shuffle off.
    private func playFromStart() {
        guard let first = songs.first else { return }
        play(from: first)
        if playback.isShuffleEnabled { playback.setShuffleEnabled(false) }
    }

    private func shuffle() {
        guard !songs.isEmpty else { return }
        if playsFromLibrary {
            playback.play(library.songs.shuffled())
        } else {
            playback.play(songs.shuffled(), source: mixSource, tags: brain?.tags ?? [:])
        }
    }

    private func play(from song: Song) {
        if playsFromLibrary {
            playback.play(song, in: library.songs)
        } else {
            // Every row of a mix the brain built carries its list, its arm and its reason into the queue and the event
            // log; the legacy mixes carry the surface alone.
            playback.play(song, in: songs, source: mixSource, tags: brain?.tags ?? [:])
        }
    }

    /// Where these plays come from, for the event log (docs/brain-spec.md, 4.1 `surface`).
    private var mixSource: BrainItemTag {
        switch screenID {
        case "dailyMix": .dailyMix
        case "yourMix": .yourMix
        default: .namedMix
        }
    }
}

/// Play / Shuffle (Android `Button` + `FilledTonalButton`, mirrored asymmetric corners, 18 pt icons): the primary
/// one is the strongest glass tint (`primary`), the other `secondaryContainer`.
struct MixPlayShuffleRow: View {
    let playTitle: LocalizedStringKey
    let height: CGFloat
    let verticalPadding: CGFloat
    let horizontalPadding: CGFloat
    let outerRadius: CGFloat
    let onPlay: () -> Void
    let onShuffle: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let inner: CGFloat = 14
        let buttonHeight = height - 2 * verticalPadding
        let outer = min(outerRadius, buttonHeight / 2)
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 8) {
                button(playTitle, "play.fill", foreground: theme.onPrimary,
                       tint: theme.primary.opacity(GlassTint.prominent),
                       shape: UnevenRoundedRectangle(topLeadingRadius: outer, bottomLeadingRadius: outer,
                                                     bottomTrailingRadius: inner, topTrailingRadius: inner,
                                                     style: .continuous),
                       height: buttonHeight, action: onPlay)
                button("Shuffle", "shuffle", foreground: theme.onSecondaryContainer,
                       tint: theme.secondaryContainer.opacity(GlassTint.container),
                       shape: UnevenRoundedRectangle(topLeadingRadius: inner, bottomLeadingRadius: inner,
                                                     bottomTrailingRadius: outer, topTrailingRadius: outer,
                                                     style: .continuous),
                       height: buttonHeight, action: onShuffle)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(height: height)
    }

    private func button(_ title: LocalizedStringKey, _ symbol: String, foreground: Color, tint: Color,
                        shape: UnevenRoundedRectangle, height: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(title)
                    .pixlFont(.labelLarge)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassEffect(Glass.regular.tint(tint).interactive(), in: shape)
    }
}
