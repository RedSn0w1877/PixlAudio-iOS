import PixlLibrary
import PixlModel
import SwiftUI

/// Settings › Library & storage › Blocked artists (iOS-first, 2026-10-18): the artists whose songs never play by themselves.
/// A search field over the list, each artist with an Unblock button (a long press or VoiceOver's actions do the same),
/// and Unblock all at the end. Songs by a blocked artist stay visible in playlists and albums, dimmed and tagged.
struct BlockedArtistsView: View {
    @Environment(BlockedArtistsStore.self) private var blocked
    @Environment(\.appTheme) private var theme
    @State private var query = ""
    @State private var confirmsUnblockAll = false

    var body: some View {
        SettingsScaffold(title: "Blocked artists", screenID: "blockedArtists") {
            if blocked.isEmpty {
                emptyCard
                    .padding(.vertical, 8)
            } else {
                SettingsSubsection(title: "\(blocked.count) blocked") {
                    searchField
                        .padding(.bottom, 8)
                    let shown = filtered
                    if shown.isEmpty {
                        noMatches
                    } else {
                        SettingsGroup {
                            ForEach(shown) { entry in
                                row(entry)
                            }
                        }
                    }
                }
                SettingsFillButton(title: "Unblock all", systemImage: "arrow.uturn.backward", style: .destructive) {
                    confirmsUnblockAll = true
                }
                .padding(.vertical, 8)
                .accessibilityIdentifier("blockedArtists.unblockAll")
            }
            Text("Songs by a blocked artist are skipped when music plays by itself: in the queue, on shuffle, in mixes and on Home. In playlists and albums they stay, dimmed.")
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .confirmationDialog("Unblock all artists?", isPresented: $confirmsUnblockAll, titleVisibility: .visible) {
            Button("Unblock all", role: .destructive) {
                withAnimation(PixlMotion.state) { blocked.unblockAll() }
                query = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their songs will play by themselves again.")
        }
        .animation(PixlMotion.state, value: blocked.revision)
    }

    private var filtered: [BlockedArtist] {
        let words = SongFilterIndex.words(of: query)
        guard !words.isEmpty else { return blocked.entries }
        return blocked.entries.filter { entry in
            let folded = SearchFolding.fold(entry.name)
            return words.allSatisfy { folded.contains($0) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.onSurfaceVariant)
                .accessibilityHidden(true)
            TextField("Search blocked artists", text: $query)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurface)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("blockedArtists.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.onSurfaceVariant)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.container))
    }

    private var noMatches: some View {
        Text("No blocked artists match \"\(query)\".")
            .pixlFont(.bodyMedium)
            .foregroundStyle(theme.onSurfaceVariant)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("blockedArtists.noMatches")
    }

    private func row(_ entry: BlockedArtist) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(systemImage: "nosign")
            Text(entry.name)
                .pixlFont(.titleMedium)
                .foregroundStyle(theme.onSurface)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            SettingsFillButton(title: "Unblock", style: .tonal, fullWidth: false) {
                withAnimation(PixlMotion.state) { blocked.unblock(artistId: entry.artistId, name: entry.name) }
            }
            .accessibilityLabel("Unblock \(entry.name)")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .settingsRowGlass()
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Unblock") {
            withAnimation(PixlMotion.state) { blocked.unblock(artistId: entry.artistId, name: entry.name) }
        }
        .accessibilityIdentifier("blockedArtists.row.\(entry.artistId)")
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "nosign")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant)
                .accessibilityHidden(true)
            Text("No blocked artists")
                .pixlFont(.titleMedium)
                .foregroundStyle(theme.onSurface)
            Text("Block an artist from their page's ⋯ menu or from a song's options. Their songs will never play by themselves.")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .settingsRowGlass()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("blockedArtists.empty")
    }
}
