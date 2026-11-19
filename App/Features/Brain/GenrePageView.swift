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
    @State private var loaded = false

    private static let maxLinks = 30

    var body: some View {
        SettingsScaffold(title: facts?.name ?? "", screenID: "genrePage", spacing: 12) {
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
                family(YourSoundStrings.genreComesFrom, facts.parents)
                family(YourSoundStrings.genreBranches, facts.children)
                family(YourSoundStrings.genreCloseTo, facts.related)
                family(YourSoundStrings.genreShapedBy, facts.influences)
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            }
        }
        .task {
            if let reader = env.brain.yourSound { facts = await reader.genrePage(atlasId) }
            loaded = true
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
