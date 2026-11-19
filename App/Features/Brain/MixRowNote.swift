import PixlLibrary
import PixlModel
import SwiftUI

/// The line under a row of Daily Mix or Your Mix (docs/brain-spec.md, 8.2, stage 2a): the reason the track is there
/// when there is something true to say, and, for a track from outside the library, Save. Saving makes it a library
/// track under the id it already plays as; the mix itself is not changed by it. Android's twin is `MixSongRow`.
struct MixRowNote: View {
    let song: Song
    let reason: MixReason?
    let isNew: Bool

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(\.appTheme) private var theme
    @State private var saved = false

    var body: some View {
        let line = reason.flatMap { WhyLineText.line(keyName: $0.key, arg: $0.arg) }.map(BrainStrings.whyLine)
        if line != nil || isNew {
            HStack(alignment: .center, spacing: 8) {
                Text(line ?? "")
                    .pixlFont(.labelMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isNew {
                    let isSaved = saved || library.song(id: song.id) != nil
                    Button {
                        saved = true
                        env.libraryEditor.saveEngineTracks([song.id])
                    } label: {
                        Text(isSaved ? BrainStrings.mixSaved : BrainStrings.mixSave)
                            .pixlFont(.labelLarge)
                            .foregroundStyle(isSaved ? theme.onSurfaceVariant : theme.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaved)
                    .accessibilityIdentifier("mix.save")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
        }
    }
}
