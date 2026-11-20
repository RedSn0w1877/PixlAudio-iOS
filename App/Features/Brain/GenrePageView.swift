import PixlLibrary
import PixlModel
import SwiftUI

/// A genre page (docs/brain-spec.md, 8.7; Android `GenrePageScreen`), built from the atlas alone: its name, where and when it
/// began, the atlas's own paragraph for the genres it describes, and its family as links. Nothing is guessed and nothing is
/// asked of an assistant at run time. Reached from Your sound and from the links of another genre page.
struct GenrePageView: View {
    let atlasId: Int
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var facts: YourSoundReader.GenreFacts?
    @State private var extras = YourSoundReader.GenreExtras.none
    @State private var loaded = false
    @State private var toast: String?

    private static let maxLinks = 30

    var body: some View {
        SettingsScaffold(title: facts?.name ?? "", screenID: "genrePage", spacing: 12, contentToast: $toast) {
            if let facts {
                VStack(alignment: .leading, spacing: 8) {
                    if let origin = facts.origin {
                        Text(origin).pixlFont(.titleMedium).foregroundStyle(theme.onSurfaceVariant)
                    }
                    if let description = facts.description {
                        Text(description).pixlFont(.bodyLarge).foregroundStyle(theme.onSurface)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                Button {
                    env.brainActions.startGenreStation(kind: StationCard.kindGenre, atlasId: facts.id, name: facts.name)
                } label: {
                    Text(YourSoundStrings.genrePlayStation).pixlFont(.labelLarge).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("genrePage.playStation")
                HStack(spacing: 8) {
                    Button(YourSoundStrings.genreMore) { adjust(facts.name, more: true) }.buttonStyle(.bordered)
                        .accessibilityIdentifier("genrePage.more")
                    Button(YourSoundStrings.genreLess) { adjust(facts.name, more: false) }.buttonStyle(.bordered)
                        .accessibilityIdentifier("genrePage.less")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                names(YourSoundStrings.genreKeyArtists, extras.keyArtists)
                names(YourSoundStrings.genreFromLibrary, extras.libraryArtists)
                you(extras.you)
                family(YourSoundStrings.genreComesFrom, facts.parents)
                family(YourSoundStrings.genreBranches, facts.children)
                family(YourSoundStrings.genreCloseTo, facts.related)
                family(YourSoundStrings.genreShapedBy, facts.influences)
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                // The atlas could not be read, or does not hold this genre: one plain sentence instead of a blank screen.
                Text(YourSoundStrings.genreUnavailable).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }
        }
        .task {
            if let reader = env.brain.yourSound {
                facts = await reader.genrePage(atlasId)
                loaded = true
                extras = await reader.genreExtras(atlasId)
            }
            loaded = true
        }
    }

    private func adjust(_ name: String, more: Bool) {
        Task {
            let ok = await env.brainActions.adjustGenre(name, more: more)
            toast = ok ? (more ? YourSoundStrings.genreMoreDone(name) : YourSoundStrings.genreLessDone(name))
                : YourSoundStrings.genreAdjustFailed
        }
    }

    /// A list of names the brain knows; absent when there is none.
    @ViewBuilder
    private func names(_ title: String, _ list: [String]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).pixlFont(.titleSmall).foregroundStyle(theme.primary).accessibilityAddTraits(.isHeader)
                ForEach(list, id: \.self) { name in
                    Text(name).pixlFont(.bodyMedium).foregroundStyle(theme.onSurface)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    /// "You and this genre" (8.7): first play, share and the tracks played most; absent for a genre never played.
    @ViewBuilder
    private func you(_ you: YourSoundReader.You?) -> some View {
        if let you {
            VStack(alignment: .leading, spacing: 4) {
                Text(YourSoundStrings.genreYou).pixlFont(.titleSmall).foregroundStyle(theme.primary).accessibilityAddTraits(.isHeader)
                Text(YourSoundStrings.genreYouFirst(Date(timeIntervalSince1970: TimeInterval(you.firstPlayedMs) / 1000)
                    .formatted(.dateTime.day().month(.abbreviated).year())))
                    .pixlFont(.bodyMedium).foregroundStyle(theme.onSurface)
                Text(YourSoundStrings.genreYouShare(YourSoundStrings.sharePermille(you.permille), you.plays))
                    .pixlFont(.bodyMedium).foregroundStyle(theme.onSurface)
                if !you.topSongs.isEmpty {
                    Text(YourSoundStrings.genreYouTop).pixlFont(.labelLarge).foregroundStyle(theme.onSurfaceVariant)
                    ForEach(you.topSongs, id: \.self) { name in
                        Text(name).pixlFont(.bodyMedium).foregroundStyle(theme.onSurface).lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func family(_ title: String, _ links: [YourSoundReader.Link]) -> some View {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).pixlFont(.titleSmall).foregroundStyle(theme.primary).accessibilityAddTraits(.isHeader)
                AIFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(links.prefix(Self.maxLinks), id: \.id) { link in
                        Button { router.push(.genrePage(atlasId: link.id)) } label: {
                            Text(link.name).pixlFont(.labelLarge)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }
}
