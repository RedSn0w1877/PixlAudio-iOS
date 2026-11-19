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
    }

    // MARK: Sections

    @ViewBuilder
    private func sections(_ state: YourSoundReader.State) -> some View {
        if !state.islands.isEmpty {
            section(YourSoundStrings.now, hint: YourSoundStrings.nowHint) {
                ForEach(Array(state.islands.prefix(6)), id: \.id) { row in
                    bar(row.name ?? YourSoundStrings.islandUnnamed, row.permille)
                }
            }
        }
        if !state.genres.isEmpty {
            section(YourSoundStrings.genres) {
                ForEach(state.genres, id: \.atlasId) { row in
                    Button { router.push(.genrePage(atlasId: row.atlasId)) } label: { bar(row.name, row.permille) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("yourSound.genre.\(row.atlasId)")
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
        if let novelty = state.novelty {
            section(YourSoundStrings.newAndFamiliar) {
                line(YourSoundStrings.novelty(novelty.permille / 10))
            }
        }
        section(YourSoundStrings.model) { modelLines(state) }
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
            if let p = m.accNowPercent { line(YourSoundStrings.modelAccuracy(p)) }
            if let p = m.accBeforePercent { line(YourSoundStrings.modelAccuracyBefore(p), dim: true) }
            if let p = m.accPriorPercent { line(YourSoundStrings.modelAccuracyPrior(p), dim: true) }
        }
        if let control = state.control, m.kind != ModelVoice.gettingToKnow {
            if let a = control.controlPermille, let b = control.learnedPermille {
                line(YourSoundStrings.control(a / 10, b / 10), dim: true)
            } else {
                line(YourSoundStrings.controlWaiting(Gate.controlMinPlays), dim: true)
            }
        }
    }

    private var controls: some View {
        section(YourSoundStrings.controls) {
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
                Text(YourSoundStrings.share(permille / 10)).pixlFont(.labelMedium).foregroundStyle(theme.onSurfaceVariant)
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
