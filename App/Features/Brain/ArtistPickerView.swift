import Observation
import PixlLibrary
import PixlModel
import PixlNet
import SwiftUI

/// One artist the search found.
nonisolated struct PickerArtist: Identifiable, Equatable, Sendable {
    let name: String
    let art: String?
    var id: String { name }
}

/// "Pick three artists you love" (docs/brain-spec.md, 8.10), for a thin or empty library. The spec's grid is the device
/// country's chart; there is no chart call in the app's YouTube Music layer, so this is the search it names as the other way:
/// type an artist, the artists of the songs found are listed, pick up to three. A port of Android's `ArtistPickerViewModel`.
@MainActor @Observable
final class ArtistPickerModel {
    var query = ""
    private(set) var results: [PickerArtist] = []
    private(set) var selected: [String] = []
    private(set) var searching = false
    private(set) var starting = false
    private(set) var done = false
    /// True when a search or the start failed: the screen says so in plain words.
    private(set) var failed = false

    @ObservationIgnored var search: (String) async throws -> [PickerArtist] = { _ in [] }
    @ObservationIgnored var pick: ([String]) async -> [String] = { _ in [] }
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    func onQuery(_ text: String) {
        query = text
        failed = false
        searchTask?.cancel()
        if text.trimmingCharacters(in: .whitespaces).count < 2 {
            results = []
            searching = false
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            self.searching = true
            do {
                let found = try await self.search(text.trimmingCharacters(in: .whitespaces))
                guard !Task.isCancelled else { return }
                self.results = found
                self.searching = false
            } catch {
                guard !Task.isCancelled else { return }
                self.searching = false
                self.failed = true
            }
        }
    }

    func toggle(_ name: String) {
        if let i = selected.firstIndex(of: name) {
            selected.remove(at: i)
        } else if selected.count < PickedArtists.picks {
            selected.append(name)
        }
    }

    /// Starts the picked artists' radios; the screen closes when at least one worked.
    func confirm() {
        guard !selected.isEmpty, !starting else { return }
        starting = true
        failed = false
        let names = selected
        Task { [weak self] in
            guard let self else { return }
            let worked = await self.pick(names)
            self.starting = false
            self.done = !worked.isEmpty
            self.failed = worked.isEmpty
        }
    }
}

struct ArtistPickerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var model = ArtistPickerModel()

    var body: some View {
        ZStack(alignment: .top) {
            theme.surface.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                Text(verbatim: BrainStrings.pickArtistsSubtitle)
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.horizontal, 20)
                searchField
                if model.failed {
                    Text(verbatim: BrainStrings.pickArtistsFailed)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.error)
                        .padding(.horizontal, 20)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.results) { artist in row(artist) }
                    }
                    .padding(.bottom, 96)
                }
                .scrollIndicators(.hidden)
            }
            VStack {
                Spacer()
                confirmButton
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("screen.artistPicker")
        .onAppear(perform: wire)
        .onChange(of: model.done) { _, done in
            if done {
                env.homePlan.onArtistsPicked()
                router.pop()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            GlassCircleButton(systemImage: "arrow.backward", accessibilityLabel: "Back",
                              tint: theme.surface.opacity(GlassTint.surface)) { router.pop() }
            Text(verbatim: BrainStrings.pickArtistsTitle)
                .pixlFont(.titleLarge, weight: .bold)
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.onSurfaceVariant)
            TextField(BrainStrings.pickArtistsSearch, text: Binding(get: { model.query }, set: { model.onQuery($0) }))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("artistPicker.search")
            if model.searching { ProgressView().controlSize(.small).tint(theme.primary) }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainer.opacity(GlassTint.surface))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row(_ artist: PickerArtist) -> some View {
        let isSelected = model.selected.contains(artist.name)
        return Button { model.toggle(artist.name) } label: {
            HStack(spacing: 14) {
                ArtworkView(source: ArtworkSource(uriString: artist.art), size: 52, cornerRadius: 26)
                Text(verbatim: artist.name)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.primary).font(.system(size: 24))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("artistPicker.row.\(artist.name)")
    }

    private var confirmButton: some View {
        let enabled = !model.selected.isEmpty && !model.starting
        return Button { model.confirm() } label: {
            Text(verbatim: model.starting ? BrainStrings.pickArtistsStarting : BrainStrings.pickArtistsStart(model.selected.count))
                .pixlFont(.labelLarge, weight: .semibold)
                .foregroundStyle(theme.onPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pixlGlass(in: Capsule(), tint: theme.primary.opacity(enabled ? GlassTint.prominent : GlassTint.surface), interactive: enabled)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityIdentifier("artistPicker.confirm")
    }

    /// What the search and the start call, set once when the screen appears.
    private func wire() {
        let client = env.youtube.service?.client
        let picked = env.brain.stage2b?.picked
        model.search = { text in
            guard let client else { return [] }
            let found = try await client.searchSongs(text, limit: 20)
            var seen = Set<String>()
            var out: [PickerArtist] = []
            for r in found {
                // The first artist of the credit: "A, B" and "A & B" are A's.
                let first = r.artist.components(separatedBy: ",")[0].components(separatedBy: " & ")[0]
                    .trimmingCharacters(in: .whitespaces)
                if first.isEmpty || !seen.insert(first.lowercased()).inserted { continue }
                out.append(PickerArtist(name: first, art: r.thumbnailUrl))
            }
            return out
        }
        model.pick = { names in await picked?.pick(names) ?? [] }
    }
}
