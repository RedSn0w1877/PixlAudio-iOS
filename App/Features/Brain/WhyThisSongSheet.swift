import PixlLibrary
import PixlModel
import SwiftUI

/// The sheet behind a pick's reason line (docs/brain-spec.md, 8.8; Android `WhyThisSongSheet`): the song, the reason
/// in full, the feedback controls of 8.5 (Like, Not for me, Less from the artist) and the way to "How picks work".
/// Stage 1 has the arm reasons; the supporting facts of stage 2 are not shown, not guessed.
struct WhyThisSongSheet: View {
    let song: Song
    let why: QueueWhy

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var showsHowPicksWork = false
    /// Up to two true facts under the reason, read from the listener's own plays when the sheet opens (8.8).
    @State private var facts: [WhyFacts.Fact] = []
    /// What moved this pick's score the most, by fixed names, from the vector it was served with (docs/brain-spec.md, 9.3); empty when none.
    @State private var factors: [AssistantRules.Factor] = []

    var body: some View {
        let reason = why.line.map(BrainStrings.whyLine)
        let artist = BrainFeedback.artistOf(song)
        let isFavorite = library.observedSong(id: song.id)?.isFavorite ?? song.isFavorite
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    ArtworkView(song: song, size: 56, cornerRadius: 14)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(song.title)
                            .pixlFont(.titleMedium)
                            .foregroundStyle(theme.onSurface)
                            .lineLimit(1)
                        Text(song.displayArtist)
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurfaceVariant)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                Spacer().frame(height: 20)
                Text(BrainStrings.whySheetTitle)
                    .pixlFont(.labelLarge)
                    .foregroundStyle(theme.primary)
                Spacer().frame(height: 4)
                Text(reason ?? BrainStrings.whySheetBasis)
                    .pixlFont(.headlineSmall, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if reason != nil {
                    Spacer().frame(height: 6)
                    Text(BrainStrings.whySheetBasis)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !facts.isEmpty {
                    Spacer().frame(height: 10)
                    ForEach(facts, id: \.key) { fact in
                        Text(BrainStrings.whyFact(fact))
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                let helped = ServedFactorLines.helped(factors)
                let held = ServedFactorLines.held(factors)
                if !helped.isEmpty {
                    Spacer().frame(height: 4)
                    Text(BrainStrings.whyFactorsUp(helped))
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !held.isEmpty {
                    Spacer().frame(height: 4)
                    Text(BrainStrings.whyFactorsDown(held))
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer().frame(height: 20)
                HStack(spacing: 8) {
                    ActionTile(title: isFavorite ? BrainStrings.liked : BrainStrings.like,
                               systemImage: isFavorite ? "heart.fill" : "heart",
                               tint: theme.secondaryContainer, foreground: theme.onSecondaryContainer, minHeight: 52) {
                        env.libraryEditor.toggleFavorite(song.id)
                    }
                    .accessibilityIdentifier("whyThisSong.like")
                    ActionTile(title: BrainStrings.notForMe, systemImage: "hand.thumbsdown",
                               tint: theme.surfaceContainerHigh, foreground: theme.onSurface, minHeight: 52) {
                        env.brainActions.notForMe(song)
                        dismiss()
                    }
                    .accessibilityIdentifier("whyThisSong.notForMe")
                }
                Spacer().frame(height: 8)
                HStack(spacing: 8) {
                    ActionTile(title: BrainStrings.moreLikeThis, systemImage: "hand.thumbsup",
                               tint: theme.surfaceContainerHigh, foreground: theme.onSurface, minHeight: 52) {
                        env.brainActions.moreLike(song)
                        dismiss()
                    }
                    .accessibilityIdentifier("whyThisSong.moreLike")
                    ActionTile(title: BrainStrings.dontCount, systemImage: "eye.slash",
                               tint: theme.surfaceContainerHigh, foreground: theme.onSurface, minHeight: 52) {
                        env.brainActions.dontCount(song)
                        dismiss()
                    }
                    .accessibilityIdentifier("whyThisSong.dontCount")
                }
                if !artist.isEmpty {
                    Spacer().frame(height: 8)
                    ActionTile(title: BrainStrings.lessFrom(artist), systemImage: "nosign",
                               tint: theme.surfaceContainerHigh, foreground: theme.onSurface, minHeight: 52) {
                        env.brainActions.lessFrom(artist)
                        dismiss()
                    }
                    .accessibilityIdentifier("whyThisSong.lessFrom")
                }
                Spacer().frame(height: 8)
                Button {
                    showsHowPicksWork = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").font(.system(size: 16, weight: .semibold))
                        Text(BrainStrings.howPicksWork).pixlFont(.labelLarge)
                    }
                    .foregroundStyle(theme.primary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(.capsule)
                }
                .buttonStyle(PressScaleButtonStyle())
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("whyThisSong.howPicksWork")
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .task(id: song.id) {
            facts = await env.brain.whyFacts(for: song)
            factors = await env.brain.whyFactors(for: song, why: why)
        }
        .sheet(isPresented: $showsHowPicksWork) {
            HowPicksWorkSheet().pixlSheet()
        }
        .accessibilityIdentifier("screen.whyThisSong")
    }
}

/// "Why this song" for a song id (the route `AppSheet.whyThisSong`): the library's song, or the queue's own song
/// for a track from outside the library.
struct WhyThisSongRoute: View {
    let songId: String
    let whyKey: String
    let whyArg: String

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if let song = library.song(id: songId) ?? env.brain.song(id: songId) {
            WhyThisSongSheet(song: song, why: QueueWhy(key: whyKey, arg: whyArg))
        } else {
            LibraryEmptyState(systemImage: "music.note", title: "Song not found", subtitle: "")
                .accessibilityIdentifier("screen.whyThisSong")
        }
    }
}
