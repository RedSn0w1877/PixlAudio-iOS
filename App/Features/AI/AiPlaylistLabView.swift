import SwiftUI

/// AI Playlist Lab (Android `CreateAiPlaylistDialog`, Library › Create playlist › With AI): a full-screen form —
/// the hero card, Intent (name, feel), Direction (mood / activity / era chips with custom values), Curation engine
/// (energy and discovery 1–5, min / max songs), Filters (genres, language, favourites, explicit), the error card and
/// the live prompt preview — with Reset and Generate at the bottom. Generating saves an AI playlist and closes.
/// Glass for the top-bar button, the cards and the bottom actions; chips, segments and fields inside a card are fills.
struct AiPlaylistLabView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var form = AiPlaylistLabForm()
    @State private var localError: String?
    @State private var requested = false

    private var controller: AIPlaylistController { env.ai.playlist }

    var body: some View {
        let isGenerating = controller.isGenerating
        let enabled = !isGenerating
        ZStack(alignment: .bottom) {
            theme.surface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    Spacer().frame(height: 4)
                    heroCard
                    AiLabSection(title: "Intent", enabled: enabled) {
                        AIFilledField(label: "Playlist name (optional)", text: $form.playlistName, cornerRadius: 12, enabled: enabled)
                        Spacer().frame(height: 10)
                        AIFilledField(label: "What should this playlist feel like?", text: $form.basePrompt, cornerRadius: 12,
                                      placeholder: "Example: sunset drive with warm synths", enabled: enabled)
                            .accessibilityIdentifier("aiLab.feel")
                    }
                    AiLabSection(title: "Direction", enabled: enabled) {
                        label("Mood")
                        AiLabChips(options: AiPlaylistLabForm.moodOptions, selected: $form.mood, enabled: enabled)
                        Spacer().frame(height: 10)
                        label("Activity")
                        AiLabChips(options: AiPlaylistLabForm.activityOptions, selected: $form.activity, enabled: enabled)
                        Spacer().frame(height: 10)
                        label("Era")
                        AiLabChips(options: AiPlaylistLabForm.eraOptions,
                                   selected: Binding(get: { form.era }, set: { form.era = $0 ?? AiPlaylistLabForm.anyEra }),
                                   enabled: enabled, allowsCustom: false)
                    }
                    AiLabSection(title: "Curation engine", enabled: enabled) {
                        AiLabLevelSelector(label: "Energy", level: $form.energy, enabled: enabled,
                                           description: "Controls the intensity and tempo of songs. 1 = calm/slow, 5 = high-energy/fast.")
                        Spacer().frame(height: 10)
                        AiLabLevelSelector(label: "Discovery", level: $form.discovery, enabled: enabled,
                                           description: "Controls how familiar the selections are. 1 = your most played favorites, 5 = rarely played deep cuts.")
                        Spacer().frame(height: 12)
                        HStack(spacing: 8) {
                            AIFilledField(label: "Min songs", text: digits($form.minSongs), cornerRadius: 12, keyboard: .numberPad,
                                          enabled: enabled)
                            AIFilledField(label: "Max songs", text: digits($form.maxSongs), cornerRadius: 12, keyboard: .numberPad,
                                          enabled: enabled)
                        }
                    }
                    AiLabSection(title: "Filters", enabled: enabled) {
                        AIFilledField(label: "Prioritize genres (optional)", text: $form.includeGenres, cornerRadius: 12,
                                      placeholder: "e.g. synthwave, indie pop", enabled: enabled)
                        Spacer().frame(height: 10)
                        AIFilledField(label: "Avoid genres (optional)", text: $form.excludeGenres, cornerRadius: 12,
                                      placeholder: "e.g. metal, hard trap", enabled: enabled)
                        Spacer().frame(height: 10)
                        AIFilledField(label: "Preferred language (optional)", text: $form.preferredLanguage, cornerRadius: 12,
                                      placeholder: "e.g. English, Spanish, instrumental", enabled: enabled)
                        Spacer().frame(height: 10)
                        toggle("Prioritize favorites", $form.prioritizeFavorites, enabled: enabled)
                        toggle("Avoid explicit lyrics", $form.avoidExplicit, enabled: enabled)
                    }
                    if let message = localError ?? controller.error {
                        Text(message)
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onErrorContainer)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                                       tint: theme.errorContainer.opacity(GlassTint.container))
                            .accessibilityIdentifier("aiLab.error")
                    }
                    AiLabSection(title: "Prompt preview") {
                        let preview = form.prompt
                        Text(preview.isEmpty ? "Your final prompt will appear here once you add preferences." : preview)
                            .pixlFont(.bodySmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer().frame(height: 96)
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) { topBar(enabled: enabled) }
            bottomBar(isGenerating: isGenerating)
        }
        .interactiveDismissDisabled(isGenerating)
        .onChange(of: isGenerating) { _, generating in
            // Android closes the Lab when the requested generation ends without an error.
            guard requested, !generating else { return }
            requested = false
            if controller.error == nil { dismiss() }
        }
        .onAppear { controller.clearError() }
        .accessibilityIdentifier("screen.aiPlaylistLab")
    }

    // MARK: Bars

    /// Android `CenterAlignedTopAppBar`: "AI Playlist Lab" (28 pt extra bold) with a close button.
    private func topBar(enabled: Bool) -> some View {
        ZStack {
            Text("AI Playlist Lab")
                .pixlFont(.custom(size: 28, weight: .heavy))
                .foregroundStyle(theme.onSurface)
            HStack {
                GlassCircleButton(systemImage: "xmark", accessibilityLabel: "Close", size: 40, iconSize: 17,
                                  tint: theme.surfaceContainerLow.opacity(GlassTint.surface)) {
                    if enabled { dismiss() }
                }
                .padding(.leading, 10)
                Spacer()
            }
        }
        .frame(height: 64)
        .frame(maxWidth: .infinity)
        // Android's top app bar is opaque: the form scrolls under it, not through it.
        .background(theme.surface.ignoresSafeArea(edges: .top))
    }

    /// Android `BottomAppBar`: the tonal Reset pill and the extended Generate button (`tertiaryContainer`).
    private func bottomBar(isGenerating: Bool) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack {
                GlassPillButton(title: "Reset", tint: theme.secondaryContainer.opacity(GlassTint.container),
                                foreground: theme.onSecondaryContainer, horizontalPadding: 18, verticalPadding: 12) {
                    guard !isGenerating else { return }
                    form = AiPlaylistLabForm()
                    localError = nil
                }
                .padding(.leading, 10)
                Spacer()
                Button {
                    guard !isGenerating else { return }
                    generate()
                } label: {
                    HStack(spacing: 10) {
                        if isGenerating {
                            ProgressView().tint(theme.onTertiaryContainer)
                            Text("Generating…").pixlFont(.titleMedium, weight: .semibold)
                        } else {
                            Image(systemName: "sparkles").font(.system(size: 20, weight: .semibold))
                            Text("Generate").pixlFont(.titleMedium, weight: .semibold)
                        }
                    }
                    .foregroundStyle(theme.onTertiaryContainer)
                    .padding(.horizontal, 24)
                    .frame(height: 64)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: Capsule(), tint: theme.tertiaryContainer.opacity(GlassTint.prominent), interactive: !isGenerating)
                .opacity(isGenerating ? 0.72 : 1)
                .accessibilityIdentifier("aiLab.generate")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        // Android `BottomAppBar(containerColor = surfaceContainerLow)`: an opaque strip, the glass buttons on it.
        .background(theme.surfaceContainerLow.ignoresSafeArea(edges: .bottom))
    }

    private func generate() {
        switch form.validated() {
        case .failure(let error):
            localError = error.message
        case .success(let request):
            localError = nil
            requested = true
            controller.generate(prompt: request.prompt, minLength: request.min, maxLength: request.max, saveAsPlaylist: true,
                                playlistName: request.name)
        }
    }

    // MARK: Pieces

    private var heroCard: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 30, bottomLeadingRadius: 20, bottomTrailingRadius: 30,
                                           topTrailingRadius: 20, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .padding(12)
                    .background(theme.onPrimaryContainer.opacity(0.14),
                                in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 28, bottomTrailingRadius: 14,
                                                           topTrailingRadius: 28, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Curate with precision")
                        .pixlFont(.titleMedium, weight: .bold)
                        .foregroundStyle(theme.onPrimaryContainer)
                    Text("Define mood, activity, constraints and depth.")
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onPrimaryContainer.opacity(0.82))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle()
                .fill(theme.onPrimaryContainer.opacity(0.22))
                .frame(height: 1)
                .padding(.vertical, 12)
            Text("The AI will only use songs from your local library.")
                .pixlFont(.labelMedium)
                .foregroundStyle(theme.onPrimaryContainer.opacity(0.8))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: shape, tint: theme.primaryContainer.opacity(GlassTint.container))
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .pixlFont(.labelLarge, weight: .semibold)
            .foregroundStyle(theme.onSurface)
            .padding(.bottom, 6)
    }

    private func toggle(_ title: LocalizedStringKey, _ isOn: Binding<Bool>, enabled: Bool) -> some View {
        HStack {
            Text(title)
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn).labelsHidden().tint(theme.primary).disabled(!enabled)
        }
        .frame(minHeight: 48)
    }

    private func digits(_ binding: Binding<String>) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = String($0.filter(\.isNumber).prefix(3)) })
    }
}

/// The Lab's form state and its prompt (Android `buildAiPlaylistPrompt`) and validation.
nonisolated struct AiPlaylistLabForm: Equatable, Sendable {
    static let anyEra = "Any era"
    static let moodOptions = ["Chill", "Energetic", "Happy", "Dark", "Romantic", "Melancholic"]
    static let activityOptions = ["Workout", "Focus", "Road trip", "Party", "Study", "Late night"]
    static let eraOptions = [anyEra, "70s", "80s", "90s", "2000s", "2010s", "2020s"]

    var playlistName = ""
    var basePrompt = ""
    var includeGenres = ""
    var excludeGenres = ""
    var preferredLanguage = ""
    var minSongs = "12"
    var maxSongs = "24"
    var mood: String?
    var activity: String?
    var era = anyEra
    var energy = 3
    var discovery = 3
    var prioritizeFavorites = true
    var avoidExplicit = false

    nonisolated struct Request: Equatable, Sendable {
        var name: String?
        var prompt: String
        var min: Int
        var max: Int
    }

    nonisolated struct ValidationError: Error, Equatable, Sendable {
        var message: String
    }

    /// `buildAiPlaylistPrompt`: the sentences joined with spaces.
    var prompt: String {
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var parts: [String] = []
        if !trimmed(basePrompt).isEmpty { parts.append("Core request: \(trimmed(basePrompt)).") }
        if let mood, !trimmed(mood).isEmpty { parts.append("Mood target: \(mood).") }
        if let activity, !trimmed(activity).isEmpty { parts.append("Activity context: \(activity).") }
        if era != Self.anyEra { parts.append("Era focus: \(era).") }
        if !trimmed(includeGenres).isEmpty { parts.append("Prioritize genres: \(trimmed(includeGenres)).") }
        if !trimmed(excludeGenres).isEmpty { parts.append("Avoid genres: \(trimmed(excludeGenres)).") }
        if !trimmed(preferredLanguage).isEmpty { parts.append("Preferred language: \(trimmed(preferredLanguage)).") }
        parts.append("Energy level target: \(min(max(energy, 1), 5))/5.")
        parts.append("Discovery target: \(min(max(discovery, 1), 5))/5 where 1 is familiar and 5 is deep cuts.")
        if prioritizeFavorites { parts.append("Prioritize songs closer to listener favorites when possible.") }
        if avoidExplicit { parts.append("Avoid explicit lyrics whenever alternatives exist.") }
        parts.append("Keep transitions smooth and avoid repetitive artist clustering.")
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `triggerGeneration`: a non-empty prompt and a numeric range, each end clamped to 5…150 and ordered.
    func validated() -> Result<Request, ValidationError> {
        let text = prompt
        if text.isEmpty { return .failure(ValidationError(message: "Add at least one instruction for AI.")) }
        guard let low = Int(minSongs), let high = Int(maxSongs) else {
            return .failure(ValidationError(message: "Set a valid song range."))
        }
        let a = min(max(low, 5), 150), b = min(max(high, 5), 150)
        let name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(Request(name: name.isEmpty ? nil : name, prompt: text, min: min(a, b), max: max(a, b)))
    }
}

/// Android `AiSectionCard`: 20 pt `surfaceContainerHigh` card, 14 pt padding, a bold title; dimmed while disabled.
struct AiLabSection<Content: View>: View {
    let title: LocalizedStringKey
    var enabled = true
    @ViewBuilder var content: Content
    @Environment(\.appTheme) private var theme

    init(title: LocalizedStringKey, enabled: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.enabled = enabled
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .pixlFont(.titleMedium, weight: .bold)
                .foregroundStyle(theme.onSurface)
            Spacer().frame(height: 10)
            content
        }
        .opacity(enabled ? 1 : 0.6)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                   tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
    }
}

/// Android `ChipsSingleSelect`: filter chips in a flow, alternating `primaryContainer` / `tertiaryContainer` when
/// selected (24 % of it when not), plus "Custom…" which asks for a value.
struct AiLabChips: View {
    let options: [String]
    @Binding var selected: String?
    var enabled = true
    var allowsCustom = true

    @Environment(\.appTheme) private var theme
    @State private var showsCustom = false
    @State private var customValue = ""

    var body: some View {
        let isCustom = selected.map { !options.contains($0) } ?? false
        AIFlowLayout(horizontalSpacing: 8, verticalSpacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                chip(option, index: index, isSelected: selected == option) {
                    selected = selected == option ? nil : option
                }
            }
            if allowsCustom {
                chip(isCustom ? (selected ?? "") : "Custom…", index: options.count, isSelected: isCustom,
                     systemImage: isCustom ? nil : "plus") {
                    if isCustom {
                        selected = nil
                    } else {
                        customValue = selected ?? ""
                        showsCustom = true
                    }
                }
            }
        }
        .alert("Enter custom value", isPresented: $showsCustom) {
            TextField("Enter your custom value", text: $customValue)
            Button("Save") {
                let value = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { selected = value }
                customValue = ""
            }
            Button("Dismiss", role: .cancel) { customValue = "" }
        }
    }

    private func chip(_ title: String, index: Int, isSelected: Bool, systemImage: String? = nil,
                      action: @escaping () -> Void) -> some View {
        let primary = index % 2 == 0
        let container = primary ? theme.primaryContainer : theme.tertiaryContainer
        let onContainer = primary ? theme.onPrimaryContainer : theme.onTertiaryContainer
        return Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                }
                Text(title).pixlFont(.labelLarge).lineLimit(1)
            }
            .foregroundStyle(isSelected ? onContainer : theme.onSurfaceVariant)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(isSelected ? container : container.opacity(0.24), in: Capsule())
            .contentShape(.capsule)
            .padding(.vertical, 4)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
        .disabled(!enabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Android `LevelSelector`: label + info toggle, "N/5", the optional description and a 1–5 segmented row (the
/// selected segment is a `secondaryContainer` fill with a check, gliding between segments).
struct AiLabLevelSelector: View {
    let label: LocalizedStringKey
    @Binding var level: Int
    var enabled = true
    var description: String?

    @Environment(\.appTheme) private var theme
    @State private var showsDescription = false
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 4) {
                    Text(label).pixlFont(.labelLarge, weight: .semibold).foregroundStyle(theme.onSurface)
                    if description != nil {
                        Button { showsDescription.toggle() } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 16))
                                .foregroundStyle(showsDescription ? theme.primary : theme.onSurfaceVariant.opacity(0.6))
                                .frame(width: 28, height: 28)
                                // A 44 pt touch area around the 28 pt glyph, without moving it.
                                .contentShape(Rectangle().inset(by: -8))
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .accessibilityLabel("More info")
                    }
                }
                Spacer()
                Text("\(level)/5").pixlFont(.labelLarge, weight: .bold).foregroundStyle(theme.primary)
            }
            if showsDescription, let description {
                Text(description)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
            Spacer().frame(height: 8)
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        withAnimation(PixlMotion.selection) { level = value }
                    } label: {
                        HStack(spacing: 4) {
                            if level == value {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                            }
                            Text("\(value)").pixlFont(.labelLarge)
                        }
                        .foregroundStyle(level == value ? theme.onSecondaryContainer : theme.onSurface)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background {
                            if level == value {
                                Capsule().fill(theme.secondaryContainer)
                                    .matchedGeometryEffect(id: "segment", in: selection)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .accessibilityAddTraits(level == value ? .isSelected : [])
                }
            }
            .overlay(Capsule().strokeBorder(theme.outline, lineWidth: 1))
        }
        .animation(PixlMotion.state, value: showsDescription)
    }
}
