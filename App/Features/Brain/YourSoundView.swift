import PixlLibrary
import PixlModel
import SwiftUI

/// Your sound (docs/brain-spec.md, 8.6; Android `YourSoundScreen`): what the listener's own plays say, worked out on the phone,
/// and what the model may honestly say about itself. Settings › Library & storage › Listening history › Your sound.
///
/// Only sections that have data are drawn. Every figure and every sentence about the model is decided in PixlLibrary
/// (`YourSoundReader`, `YourSound`, `ModelVoice`); this view draws them. Nothing here claims learning unless the learned
/// weights are in use at that moment, and no accuracy is shown before 300 graded plays. The figures are read once when the
/// screen opens, off the main actor; nothing is animated and nothing runs per frame.
struct YourSoundView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var model = YourSoundModel()
    @State private var confirmsReset = false
    @State private var toast: String?
    /// The island whose sheet is open (8.6 point 1), and the families of the genre tree that are open (8.6 point 2).
    @State private var openIsland: YourSoundReader.IslandRow?
    @State private var openFamilies: Set<Int> = []

    var body: some View {
        SettingsScaffold(title: YourSoundStrings.title, screenID: "yourSound", spacing: 12, contentToast: $toast) {
            if let state = model.state {
                if state.isEmpty {
                    line(YourSoundStrings.empty)
                } else {
                    sections(state)
                }
            } else if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                line(YourSoundStrings.empty)
            }
            controls
            Text(YourSoundStrings.footer)
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.refresh(env.brain) }
        .confirmationDialog(YourSoundStrings.resetTitle, isPresented: $confirmsReset, titleVisibility: .visible) {
            Button(YourSoundStrings.resetConfirm, role: .destructive) {
                Task {
                    await model.reset(env.brain)
                    toast = YourSoundStrings.resetDone
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(YourSoundStrings.resetBody)
        }
        .sheet(item: $openIsland) { island in
            islandSheet(island)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func sections(_ state: YourSoundReader.State) -> some View {
        if !state.islands.isEmpty {
            section(YourSoundStrings.now, hint: YourSoundStrings.nowHint) {
                ForEach(Array(state.islands.prefix(6)), id: \.id) { row in
                    Button { openIsland = row } label: { bar(row.name ?? YourSoundStrings.islandUnnamed, row.permille) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("yourSound.island.\(row.id)")
                }
            }
        }
        if !state.genres.isEmpty {
            section(YourSoundStrings.genres) {
                if state.genreTree.isEmpty {
                    ForEach(state.genres, id: \.atlasId) { row in genreButton(row) }
                } else {
                    // The atlas tree: a family opens to the genres played inside it; a genre opens its page.
                    ForEach(state.genreTree, id: \.rootId) { family in
                        let open = openFamilies.contains(family.rootId)
                        Button {
                            if open { openFamilies.remove(family.rootId) } else { openFamilies.insert(family.rootId) }
                        } label: { bar(family.name, family.permille) }
                            .buttonStyle(.plain)
                            .accessibilityHint(YourSoundStrings.familyOpen)
                            .accessibilityValue(open ? "expanded" : "collapsed")
                            .accessibilityIdentifier("yourSound.family.\(family.rootId)")
                        if open {
                            ForEach(family.children, id: \.atlasId) { row in genreButton(row).padding(.leading, 16) }
                        }
                    }
                }
            }
        }
        if !state.decades.isEmpty {
            section(YourSoundStrings.eras) {
                ForEach(state.decades, id: \.decade) { d in bar(YourSoundStrings.decade(d.decade), d.permille) }
            }
        }
        let dayparts = state.dayparts.filter { $0.plays > 0 && $0.leadingIsland != nil }
        if !dayparts.isEmpty {
            section(YourSoundStrings.day) {
                ForEach(dayparts, id: \.daypart) { d in
                    line(YourSoundStrings.daypartLine(YourSoundStrings.daypartName(d.daypart), d.leadingIsland ?? ""))
                }
            }
        }
        if state.months.count >= 2 {
            section(YourSoundStrings.months) {
                ForEach(Array(state.months.suffix(12).reversed()), id: \.month) { m in
                    line(YourSoundStrings.monthLine(Self.monthLabel(m.month), m.plays))
                    if let top = m.islands.first?.name { line(top, dim: true) }
                }
            }
        }
        if !state.lately.isEmpty {
            section(YourSoundStrings.lately) {
                if !state.lately.up.isEmpty { line(YourSoundStrings.latelyUp(state.lately.up.joined(separator: ", "))) }
                if !state.lately.down.isEmpty { line(YourSoundStrings.latelyDown(state.lately.down.joined(separator: ", "))) }
            }
        }
        if let novelty = state.novelty {
            section(YourSoundStrings.newAndFamiliar) {
                line(YourSoundStrings.novelty(YourSoundStrings.percentOf(permille: novelty.permille)))
            }
        }
        section(YourSoundStrings.model) { modelLines(state) }
    }

    private func genreButton(_ row: YourSoundReader.GenreRow) -> some View {
        Button { router.push(.genrePage(atlasId: row.atlasId)) } label: { bar(row.name, row.permille) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("yourSound.genre.\(row.atlasId)")
    }

    /// What tapping an island shows (8.6 point 1): its top artists and songs by name, and, when the island has a genre the app may
    /// name, Play station and More of this / Less of this on that genre. Names the brain does not know are not here.
    private func islandSheet(_ island: YourSoundReader.IslandRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(island.name ?? YourSoundStrings.islandUnnamed)
                    .pixlFont(.headlineSmall, weight: .bold).foregroundStyle(theme.onSurface)
                    .accessibilityAddTraits(.isHeader)
                if !island.topArtists.isEmpty {
                    Text(YourSoundStrings.islandArtists).pixlFont(.titleSmall).foregroundStyle(theme.primary)
                    ForEach(island.topArtists, id: \.self) { name in line(name) }
                }
                if !island.topSongs.isEmpty {
                    Text(YourSoundStrings.islandSongs).pixlFont(.titleSmall).foregroundStyle(theme.primary)
                    ForEach(island.topSongs, id: \.self) { name in line(name) }
                }
                if let genre = island.genreName {
                    HStack(spacing: 8) {
                        Button(YourSoundStrings.islandMore) { adjust(genre, more: true) }.buttonStyle(.bordered)
                        Button(YourSoundStrings.islandLess) { adjust(genre, more: false) }.buttonStyle(.bordered)
                    }
                    Button {
                        let id = island.genreId
                        openIsland = nil
                        env.brainActions.startGenreStation(kind: StationCard.kindGenre, atlasId: id, name: genre)
                    } label: {
                        Text(YourSoundStrings.islandPlayStation).pixlFont(.labelLarge).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("yourSound.island.playStation")
                }
                Button(YourSoundStrings.islandClose) { openIsland = nil }
                    .buttonStyle(.plain).foregroundStyle(theme.primary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .presentationDetents([.medium, .large])
    }

    /// One tap, one change: the sheet closes first, so the confirmation (which lives on the screen under it) is seen, and a second tap
    /// cannot add the same change twice.
    private func adjust(_ genre: String, more: Bool) {
        openIsland = nil
        Task {
            let ok = await env.brainActions.adjustGenre(genre, more: more)
            toast = ok ? (more ? YourSoundStrings.genreMoreDone(genre) : YourSoundStrings.genreLessDone(genre))
                : YourSoundStrings.genreAdjustFailed
        }
    }

    /// The model's lines: only what is true of its state right now (`ModelVoice`); a figure only when it was computed from graded plays.
    @ViewBuilder
    private func modelLines(_ state: YourSoundReader.State) -> some View {
        let m = state.model
        switch m.kind {
        case ModelVoice.gettingToKnow:
            line(YourSoundStrings.modelGetting)
            line(YourSoundStrings.modelGettingCount(m.gradedPlays, Gate.minPlays), dim: true)
        case ModelVoice.standardRecipe:
            line(YourSoundStrings.modelStandard)
            if let p = m.accPriorPercent { line(YourSoundStrings.modelStandardAccuracy(p), dim: true) }
        default:
            line(YourSoundStrings.modelLearning(Int(m.learnedFrom)))
            // The share called right is shown only when it is not below the standard recipe's: the gate decides on log-loss, and a
            // line that reads as "better" under a lower figure would claim more than the plays show.
            if m.showsAccuracy {
                if let p = m.accNowPercent { line(YourSoundStrings.modelAccuracy(p)) }
                if let p = m.accBeforePercent { line(YourSoundStrings.modelAccuracyBefore(p), dim: true) }
                if let p = m.accPriorPercent { line(YourSoundStrings.modelAccuracyPrior(p), dim: true) }
            }
        }
        // The check exists only while the learned weights are in use (a control session is ranked with the standard recipe to compare
        // with them); on the standard recipe everywhere there is nothing to compare, so nothing is said.
        if m.kind == ModelVoice.learning, let control = state.control {
            if let a = control.controlPermille, let b = control.learnedPermille {
                line(YourSoundStrings.control(YourSoundStrings.percentOf(permille: a), YourSoundStrings.percentOf(permille: b)), dim: true)
            } else {
                line(YourSoundStrings.controlWaiting(Gate.controlMinPlays), dim: true)
            }
        }
    }

    private var controls: some View {
        section(YourSoundStrings.controls) {
            // "Reset what I've learned" is offered only once something has been learned (a play moved the weights).
            if (model.state?.modelUpdates ?? 0) > 0 {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(YourSoundStrings.reset).pixlFont(.titleSmall).foregroundStyle(theme.onSurface)
                    Text(YourSoundStrings.resetSubtitle).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(YourSoundStrings.resetConfirm) { confirmsReset = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("yourSound.reset")
            }
            }
            Button { router.push(.tasteChanges) } label: {
                Text(YourSoundStrings.tasteChanges).pixlFont(.bodyMedium).foregroundStyle(theme.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Pieces

    private func section(_ title: String, hint: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).pixlFont(.titleMedium).foregroundStyle(theme.primary).accessibilityAddTraits(.isHeader)
            if let hint { Text(hint).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant) }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), tint: theme.surfaceContainer.opacity(SettingsTint.row))
    }

    private func line(_ text: String, dim: Bool = false) -> some View {
        Text(text)
            .pixlFont(dim ? .bodySmall : .bodyMedium)
            .foregroundStyle(dim ? theme.onSurfaceVariant : theme.onSurface)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A name with its share as a static bar.
    private func bar(_ label: String, _ permille: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).pixlFont(.bodyMedium).foregroundStyle(theme.onSurface).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(YourSoundStrings.sharePermille(permille)).pixlFont(.labelMedium).foregroundStyle(theme.onSurfaceVariant)
            }
            ProgressView(value: min(max(Double(permille) / 1000.0, 0.0), 1.0)).tint(theme.primary)
        }
    }

    /// "Mar 2026" for the month code `year * 12 + month0`.
    private static func monthLabel(_ code: Int) -> String {
        let symbols = Calendar.current.shortMonthSymbols
        let month = code % 12
        let name = month >= 0 && month < symbols.count ? symbols[month] : ""
        return "\(name) \(code / 12)"
    }
}

/// The screen's state: read when it opens, again after a reset. Off the main actor; nothing at app start.
@MainActor
@Observable
final class YourSoundModel {
    var state: YourSoundReader.State?
    var isLoading = true

    func refresh(_ brain: BrainService) async {
        if let reader = brain.yourSound { state = await reader.load() }
        isLoading = false
    }

    func reset(_ brain: BrainService) async {
        guard let reader = brain.yourSound else { return }
        await reader.resetLearned()
        state = await reader.load(force: true)
    }
}
