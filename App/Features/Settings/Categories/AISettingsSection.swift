import FoundationModels
import PixlNet
import SwiftUI
import UIKit

/// Settings › AI features (Android `SettingsCategoryScreen` AI_INTEGRATION): the automatic-studio and
/// music-intelligence cards, assistant (provider) and "save on usage", sign-in (API key, Keychain), model, base URL
/// for configurable providers, the on-device model, personality (system prompt + presets), and the collapsed
/// "Advanced" block (generation parameters, song data, usage report).
///
/// iOS: the on-device provider uses the system's on-device language model (Foundation Models) instead of importing
/// a MediaPipe file. The model picker lists the provider's chat models (stage 13, `AIService.availableModels`).
struct AISettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.appTheme) private var theme

    @State private var apiKey = ""
    @State private var showsAdvanced = false
    @State private var usage: (recent: [AIUsageEntry], prompt: Int, output: Int, thought: Int) = ([], 0, 0, 0)
    @State private var showsLogs = false
    @State private var models: [GeminiModel] = []
    @State private var isLoadingModels = false
    @State private var selectedModel = ""

    private var provider: AiProvider { AiProvider.fromString(settings.ai.provider) }

    var body: some View {
        @Bindable var ai = settings.ai
        SettingsCategoryScaffold(category: .ai) {
            AutomaticStudioCard()
            Spacer().frame(height: 20)
            MusicIntelligenceCard()
            Spacer().frame(height: 20)
            SettingsSubsection(title: L10n.settingsAiProviderSection) {
                ThemeSelectorRow(label: L10n.settingsAiProviderTitle, description: L10n.settingsAiProviderSubtitle,
                                 options: AiProvider.entries.map {
                                     SettingsOption(key: $0.rawValue,
                                                    label: $0 == .gemini ? "\($0.displayName) (Free)" : $0.displayName)
                                 },
                                 selectedKey: ai.provider, systemImage: "flask") { ai.provider = $0 }
                SwitchSettingRow(title: L10n.settingsSafeTokenTitle,
                                 subtitle: ai.safeTokenLimit ? L10n.settingsSafeTokenOn : L10n.settingsSafeTokenOff,
                                 isOn: $ai.safeTokenLimit, systemImage: "chart.line.uptrend.xyaxis",
                                 iconColor: ai.safeTokenLimit ? theme.primary : theme.tertiary)
            }
            if provider != .onDevice {
                SettingsSubsection(title: L10n.settingsCredentialsSection) {
                    if provider == .gemini && apiKey.isEmpty {
                        SettingsItemRow(title: L10n.settingsAiGetFreeKey, subtitle: L10n.settingsAiGetFreeKeySubtitle,
                                        systemImage: "arrow.up.right.square", iconColor: theme.primary) {
                            if let url = URL(string: "https://aistudio.google.com/apikey") { UIApplication.shared.open(url) }
                        }
                    }
                    AITextSaveRow(value: apiKey, title: L10n.settingsAiApiKeyTitle(provider.displayName),
                                  subtitle: L10n.settingsAiApiKeySubtitle(sourceLabel),
                                  placeholder: L10n.settingsEnterApiKeyPlaceholder, secure: true) { saveKey($0) }
                }
            }
            if !apiKey.isEmpty {
                SettingsSubsection(title: L10n.settingsModelSelectionSection) {
                    modelSelection
                }
            }
            if provider.hasConfigurableUrl {
                SettingsSubsection(title: "API Base URL") {
                    AITextSaveRow(value: ai.baseUrl(for: provider.rawValue), title: "Base URL",
                                  subtitle: provider == .ollama
                                      ? "e.g. http://192.168.1.50:11434/v1 (your Ollama server's LAN address)"
                                      : "e.g. https://api.example.com/v1",
                                  placeholder: "https://", secure: false) {
                        ai.setBaseUrl($0, for: provider.rawValue)
                    }
                }
            }
            if provider == .onDevice {
                SettingsSubsection(title: "On-Device Model") {
                    OnDeviceModelRow()
                }
            }
            SettingsSubsection(title: L10n.settingsPromptBehaviorSection, addBottomSpace: false) {
                AISystemPromptRow(providerName: provider.rawValue)
            }
            Spacer().frame(height: 8)
            advancedToggle
            Spacer().frame(height: 8)
            if showsAdvanced {
                advanced
            }
        }
        .animation(PixlMotion.state, value: showsAdvanced)
        // The Keychain read runs off the main actor (it ran synchronously during the push, and on every return).
        .task(id: provider) {
            apiKey = await Self.loadStoredKey(provider, isUITest: environment.launch.isUITest)
            await AIProviderStatus.refresh(environment)
        }
        .task(id: modelsKey) { await loadModels() }
        .task(id: showsAdvanced) {
            guard showsAdvanced, let persistence = environment.persistence else { return }
            if let loaded = try? await persistence.settingsAiUsage() { usage = loaded }
        }
    }

    // MARK: Models (Android `SettingsViewModel.fetchAvailableModels` + `SearchableModelSelector`)

    /// Reloads when the provider, its key or its base URL changes.
    private var modelsKey: String { "\(provider.rawValue)|\(apiKey)|\(settings.ai.baseUrl(for: provider.rawValue))" }

    @ViewBuilder
    private var modelSelection: some View {
        if isLoadingModels {
            HStack(spacing: 12) {
                ProgressView().tint(theme.primary)
                Text(L10n.settingsLoadingModels).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsRowGlass()
        } else if models.isEmpty {
            Text(L10n.settingsModelsFetchFailed)
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onErrorContainer)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsRowGlass(tint: theme.errorContainer)
        } else {
            ThemeSelectorRow(label: L10n.settingsAiModelTitle, description: L10n.settingsAiModelSubtitle,
                             options: models.map { SettingsOption(key: $0.name, label: $0.displayName) },
                             selectedKey: selectedModel.isEmpty ? (models.first?.name ?? "") : selectedModel,
                             systemImage: "flask") { name in
                settings.ai.setModel(name, for: provider.rawValue)
                selectedModel = name
            }
        }
    }

    /// Fetches the provider's chat models; picks the first when nothing (or a vanished model) is selected.
    private func loadModels() async {
        let key = apiKey
        selectedModel = settings.ai.model(for: provider.rawValue)
        guard !key.isEmpty else {
            models = []
            return
        }
        isLoadingModels = true
        let loaded = await environment.ai.availableModels(for: provider, apiKey: key)
        guard !Task.isCancelled else { return }
        models = loaded
        isLoadingModels = false
        if let first = loaded.first, selectedModel.isEmpty || !loaded.contains(where: { $0.name == selectedModel }) {
            settings.ai.setModel(first.name, for: provider.rawValue)
            selectedModel = first.name
        }
    }

    private var advancedToggle: some View {
        Button { showsAdvanced.toggle() } label: {
            HStack {
                Text("Advanced")
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .rotationEffect(.degrees(showsAdvanced ? 180 : 0))
            }
            .padding(16)
        }
        .buttonStyle(.plain)
        .settingsRowGlass(interactive: true)
        .environment(\.settingsRowCorners, SettingsRowCorners(top: 10, bottom: 10))
        .accessibilityIdentifier("settings.ai.advanced")
    }

    @ViewBuilder
    private var advanced: some View {
        @Bindable var ai = settings.ai
        SettingsSubsection(title: "Generation Parameters") {
            AIParameterRow(label: "Temperature", value: $ai.temperature, range: 0...2, steps: 20,
                           help: "Controls randomness. Lower = more deterministic, higher = more creative.") {
                String(format: "%.2f", $0)
            }
            AIParameterRow(label: "Top P", value: $ai.topP, range: 0...1, steps: 20,
                           help: "Nucleus sampling. Higher = more diverse tokens considered.") { String(format: "%.2f", $0) }
            AIParameterRow(label: "Top K", value: intBinding($ai.topK), range: 1...100, steps: 98,
                           help: "Limits token selection to the K most likely candidates.") { "\(Int($0))" }
            AIParameterRow(label: "Max Output Tokens", value: intBinding($ai.maxTokens), range: 128...8192, steps: 62,
                           help: "Maximum length of the AI response. Higher = longer but more expensive.") { "\(Int($0))" }
            AIParameterRow(label: "Presence Penalty", value: $ai.presencePenalty, range: -2...2, steps: 39,
                           help: "Penalizes repeated topics. Positive = more diverse topics.") { String(format: "%.1f", $0) }
            AIParameterRow(label: "Frequency Penalty", value: $ai.frequencyPenalty, range: -2...2, steps: 39,
                           help: "Penalizes repeated phrases. Positive = more natural language.") {
                String(format: "%.1f", $0)
            }
        }
        SettingsSubsection(title: "Song Data Configuration") {
            AIParameterRow(label: "Sample Size", value: intBinding($ai.sampleSize), range: 10...120, steps: 10,
                           help: "Number of songs sent to the AI for playlist generation. More = better context but higher cost.") {
                "\(Int($0)) songs"
            }
            ThemeSelectorRow(label: "Digest Detail", description: "Controls how much listening history data is included",
                             options: [SettingsOption(key: "safe", label: "Concise (faster)"),
                                       SettingsOption(key: "full", label: "Full (better quality)")],
                             selectedKey: ai.digestMode, systemImage: "chart.line.uptrend.xyaxis") { ai.digestMode = $0 }
            SwitchSettingRow(title: "Extended Song Fields",
                             subtitle: "Include album, year, and genre info in song data sent to AI",
                             isOn: $ai.includeExtendedFields, systemImage: "music.note")
        }
        Spacer().frame(height: 16)
        SettingsSubsection(title: L10n.settingsAiUsageReportSection, addBottomSpace: false) {
            ActionSettingRow(title: L10n.settingsTotalConsumptionTitle,
                             subtitle: L10n.settingsAiUsageTokensSubtitle(
                                 Self.grouped(usage.prompt + usage.output + usage.thought), Self.grouped(usage.prompt),
                                 Self.grouped(usage.output), Self.grouped(usage.thought)),
                             systemImage: "chart.line.uptrend.xyaxis", iconColor: theme.tertiary,
                             primaryLabel: L10n.settingsAiClearLogs) {
                Task {
                    try? await environment.persistence?.settingsClearAiUsage()
                    usage = ([], 0, 0, 0)
                }
            }
            if !usage.recent.isEmpty {
                AIUsageLog(entries: usage.recent, expanded: $showsLogs)
            }
        }
    }

    private func intBinding(_ binding: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0.rounded()) })
    }

    nonisolated static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    private var sourceLabel: String {
        switch provider {
        case .gemini: L10n.settingsAiSourceGemini
        case .deepseek: L10n.settingsAiSourceDeepseek
        case .groq: L10n.settingsAiSourceGroq
        case .mistral: L10n.settingsAiSourceMistral
        case .nvidia: L10n.settingsAiSourceNvidia
        case .kimi: L10n.settingsAiSourceKimi
        case .glm: L10n.settingsAiSourceGlm
        case .openai: L10n.settingsAiSourceOpenai
        case .openrouter: "OpenRouter (openrouter.ai)"
        case .ollama: "Ollama (local server)"
        case .custom: "Custom Provider"
        case .onDevice: "On-Device (Offline)"
        }
    }

    /// The provider's stored API key, read off the main actor (`@concurrent`: a plain nonisolated async function
    /// would run on the caller's actor under approachable concurrency).
    @concurrent
    nonisolated private static func loadStoredKey(_ provider: AiProvider, isUITest: Bool) async -> String {
        guard !isUITest,
              let data = try? KeychainStore.data(for: PreferenceKeys.aiApiKeyAccount(provider.rawValue)) else { return "" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = PreferenceKeys.aiApiKeyAccount(provider.rawValue)
        if !environment.launch.isUITest {
            if trimmed.isEmpty { try? KeychainStore.delete(account: account) }
            else { try? KeychainStore.set(Data(trimmed.utf8), for: account) }
        }
        // Android `clearModelsState`: removing the key forgets the chosen model.
        if trimmed.isEmpty { settings.ai.setModel("", for: provider.rawValue) }
        apiKey = trimmed
        let environment = self.environment
        Task { await AIProviderStatus.refresh(environment) }
    }
}

/// Android `AiApiKeyItem` (also the base-URL field): title, subtitle, a field, Save (tonal, enabled when changed) and
/// a transient "Saved!".
struct AITextSaveRow: View {
    let value: String
    let title: String
    let subtitle: String
    let placeholder: String
    var secure = false
    let onSave: (String) -> Void

    @State private var draft = ""
    @State private var showsSaved = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
            Text(subtitle).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
            Spacer().frame(height: 8)
            SettingsTextField(placeholder: placeholder, text: $draft, secure: secure)
            Spacer().frame(height: 12)
            HStack(spacing: 8) {
                SettingsFillButton(title: L10n.commonSave, style: .tonal, enabled: draft != value, fullWidth: false) {
                    onSave(draft)
                    showsSaved = true
                }
                if showsSaved {
                    Text(L10n.commonSaved)
                        .pixlFont(.labelMedium, weight: .bold)
                        .foregroundStyle(theme.primary)
                        .task {
                            try? await Task.sleep(for: .seconds(2))
                            showsSaved = false
                        }
                }
            }
        }
        .padding(16)
        .settingsRowGlass()
        .onAppear { draft = value }
        .onChange(of: value) { _, new in draft = new }
    }
}

/// Android `AiSystemPromptItem`: the six preset personas, the prompt field, Save / Reset / "Saved!".
struct AISystemPromptRow: View {
    let providerName: String

    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme
    @State private var draft = ""
    @State private var showsSaved = false

    private var stored: String { settings.ai.systemPrompt(for: providerName) ?? AiPromptEngine.defaultSystemPrompt }

    private var presets: [(String, String)] {
        [(L10n.settingsPresetProfessionalCuratorName, L10n.settingsPresetProfessionalCuratorPrompt),
         (L10n.settingsPresetCreativeMaverickName, L10n.settingsPresetCreativeMaverickPrompt),
         (L10n.settingsPresetStrictLibrarianName, L10n.settingsPresetStrictLibrarianPrompt),
         (L10n.settingsPresetAtmosphericGuideName, L10n.settingsPresetAtmosphericGuidePrompt),
         (L10n.settingsPresetSonicEnthusiastName, L10n.settingsPresetSonicEnthusiastPrompt),
         (L10n.settingsPresetEnergyCatalystName, L10n.settingsPresetEnergyCatalystPrompt)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.settingsSystemPromptTitle).pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
            Text(L10n.settingsSystemPromptSubtitle).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
            Spacer().frame(height: 12)
            Text(L10n.settingsPresetPrompts).pixlFont(.labelLarge).foregroundStyle(theme.onSurface)
            Spacer().frame(height: 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.0) { preset in
                        SettingsFillButton(title: preset.0, style: .outlined, fullWidth: false) { draft = preset.1 }
                    }
                }
            }
            Spacer().frame(height: 8)
            SettingsTextField(placeholder: L10n.settingsSystemPromptPlaceholder, text: $draft, axis: .vertical)
                .lineLimit(3...6)
            Spacer().frame(height: 12)
            HStack(spacing: 8) {
                SettingsFillButton(title: L10n.commonSave, style: .tonal, enabled: draft != stored, fullWidth: false) {
                    settings.ai.setSystemPrompt(draft, for: providerName)
                    showsSaved = true
                }
                if stored != AiPromptEngine.defaultSystemPrompt {
                    SettingsFillButton(title: L10n.commonReset, style: .outlined, fullWidth: false) {
                        settings.ai.setSystemPrompt(nil, for: providerName)
                        draft = AiPromptEngine.defaultSystemPrompt
                    }
                }
                if showsSaved {
                    Text(L10n.commonSaved)
                        .pixlFont(.labelMedium, weight: .bold)
                        .foregroundStyle(theme.primary)
                        .task {
                            try? await Task.sleep(for: .seconds(2))
                            showsSaved = false
                        }
                }
            }
        }
        .padding(16)
        .settingsRowGlass()
        .onAppear { draft = stored }
        .onChange(of: providerName) { _, _ in draft = stored }
    }
}

/// A slider row with its explanation under it (Android: `SliderSettingsItem` + a `bodySmall` caption).
struct AIParameterRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let steps: Int
    let help: String
    let format: (Double) -> String

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SliderSettingRow(label: label, value: $value, range: range, steps: steps, valueText: format)
            Text(help)
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
    }
}

/// The on-device model's availability (iOS stand-in for Android's imported MediaPipe model file).
struct OnDeviceModelRow: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        let (title, detail) = status
        HStack(spacing: 12) {
            SettingsIcon(systemImage: "cpu")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).pixlFont(.bodyMedium, weight: .medium).foregroundStyle(theme.onSurface)
                Text(detail).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .settingsRowGlass()
    }

    private var status: (String, String) {
        switch SystemLanguageModel.default.availability {
        case .available:
            return ("On-device model ready", "AI features run privately on this iPhone, offline.")
        case .unavailable(.deviceNotEligible):
            return ("Not available on this device", "This iPhone can't run the on-device model; pick another assistant.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return ("Turned off in system settings", "Enable the system's intelligence features to use the on-device model.")
        case .unavailable(.modelNotReady):
            return ("Downloading", "The on-device model is still being prepared; try again later.")
        case .unavailable:
            return ("Unavailable", "The on-device model can't be used right now.")
        }
    }
}

/// Android's AI activity log: a "N requests" header that expands into the requests grouped by day.
struct AIUsageLog: View {
    let entries: [AIUsageEntry]
    @Binding var expanded: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.onSurfaceVariant)
                    Text(L10n.settingsAiActivityLogTitle(entries.count))
                        .pixlFont(.titleMedium)
                        .foregroundStyle(theme.onSurface)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .foregroundStyle(theme.onSurfaceVariant)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .accessibilityLabel(expanded ? L10n.settingsAiHideLogs : L10n.settingsAiShowLogs)
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(groups, id: \.0) { group in
                    HStack(spacing: 12) {
                        Text(group.0).pixlFont(.labelLarge, weight: .bold).foregroundStyle(theme.primary)
                        Rectangle().fill(theme.outlineVariant.opacity(0.5)).frame(height: 0.5)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                    ForEach(group.1) { entry in
                        AIUsageItem(entry: entry)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .settingsRowGlass()
    }

    private var groups: [(String, [AIUsageEntry])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        var order: [String] = []
        var map: [String: [AIUsageEntry]] = [:]
        for entry in entries {
            let day = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(entry.timestamp) / 1000))
            if map[day] == nil { order.append(day) }
            map[day, default: []].append(entry)
        }
        return order.map { ($0, map[$0] ?? []) }
    }
}

/// Android `AiUsageLogItem`.
struct AIUsageItem: View {
    let entry: AIUsageEntry
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(Date(timeIntervalSince1970: TimeInterval(entry.timestamp) / 1000)
                        .formatted(date: .omitted, time: .shortened), systemImage: "clock")
                    .pixlFont(.labelMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                Spacer()
                Text(entry.promptType.replacingOccurrences(of: "_", with: " ").capitalized)
                    .pixlFont(.labelSmall, weight: .bold)
                    .foregroundStyle(theme.onSecondaryContainer)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(theme.secondaryContainer.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            }
            Text(L10n.settingsAiUsageProvierModel(entry.provider, entry.model))
                .pixlFont(.titleSmall, weight: .bold)
                .foregroundStyle(theme.onSurface)
            HStack(spacing: 8) {
                chip("In", entry.promptTokens, theme.primaryContainer, theme.onPrimaryContainer)
                chip("Out", entry.outputTokens, theme.tertiaryContainer, theme.onTertiaryContainer)
                if entry.thoughtTokens > 0 {
                    chip("Th", entry.thoughtTokens, theme.secondaryContainer, theme.onSecondaryContainer)
                }
            }
        }
        .padding(14)
        .background(theme.surfaceContainerLow.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.vertical, 6)
    }

    private func chip(_ label: String, _ count: Int, _ fill: Color, _ text: Color) -> some View {
        Text("\(label): \(AISettingsSection.grouped(count))")
            .pixlFont(.labelSmall)
            .foregroundStyle(text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Android `AutomaticStudioSettingsCard` (tertiary-container card): automatic lyric sync and instrumentals.
struct AutomaticStudioCard: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme
    @State private var showsDetails = false

    var body: some View {
        @Bindable var lyrics = settings.lyrics
        @Bindable var playback = settings.playback
        GlassCard(cornerRadius: 28, tint: theme.tertiaryContainer) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ready when you play").pixlFont(.headlineSmall).foregroundStyle(theme.onTertiaryContainer)
                Text("Prepare lyrics and instrumentals quietly while PixlAudio is open.")
                    .pixlFont(.bodyMedium).foregroundStyle(theme.onTertiaryContainer)
                cardToggle("Automatic lyric sync", "Looks for word timings first.", $lyrics.automaticLyrics)
                cardToggle("Automatic instrumentals", "Processes songs already on your device, one at a time.",
                           $playback.automaticInstrumentals)
                Text("No automatic notifications. Manual sync and instrumental buttons remain available.")
                    .pixlFont(.bodySmall).foregroundStyle(theme.onTertiaryContainer)
                Text(lyrics.automaticLyrics || playback.automaticInstrumentals ? "Waiting for songs to prepare" : "Off")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surfaceContainerHighest.opacity(0.8),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                SettingsFillButton(title: showsDetails ? "Hide queue details" : "Queue and diagnostics", style: .tonal) {
                    showsDetails.toggle()
                }
                if showsDetails {
                    Text("Runs quietly in the background when the phone is idle. It pauses during playback, low battery, heat, storage pressure, or manual processing; longer tracks remain available through the manual controls.")
                        .pixlFont(.bodySmall).foregroundStyle(theme.onTertiaryContainer)
                    SettingsFillButton(title: "Check queue now", style: .outlined,
                                       enabled: lyrics.automaticLyrics || playback.automaticInstrumentals) {}
                }
            }
            .padding(20)
        }
        .animation(PixlMotion.state, value: showsDetails)
    }

    private func cardToggle(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading) {
                Text(title).pixlFont(.titleMedium).foregroundStyle(theme.onTertiaryContainer)
                Text(detail).pixlFont(.bodySmall).foregroundStyle(theme.onTertiaryContainer)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn).labelsHidden().tint(theme.tertiary)
        }
        .frame(minHeight: 64)
    }
}

/// Android `MusicIntelligenceSettingsCard` (secondary-container card): learning, discovery, exploration.
struct MusicIntelligenceCard: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme
    @State private var expanded = false
    @State private var exploration = 0.25
    @State private var showsReset = false

    var body: some View {
        @Bindable var ai = settings.ai
        GlassCard(cornerRadius: 28, tint: theme.secondaryContainer) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.musicIntelligenceTitle).pixlFont(.headlineSmall).foregroundStyle(theme.onSecondaryContainer)
                Text(L10n.musicIntelligenceDescription).pixlFont(.bodyMedium).foregroundStyle(theme.onSecondaryContainer)
                toggle(L10n.musicIntelligenceLearning, $ai.musicLearningEnabled)
                toggle(L10n.musicIntelligenceDiscovery, $ai.musicDiscoveryEnabled)
                Text(L10n.musicIntelligenceExploration(Int(exploration * 100)))
                    .pixlFont(.titleSmall).foregroundStyle(theme.onSecondaryContainer)
                Slider(value: $exploration, in: 0...0.6, step: 0.05) { editing in
                    if !editing { ai.musicExploration = exploration }
                }
                .tint(theme.primary)
                Text(L10n.musicIntelligenceLearningCount(0, 0, 0))
                    .pixlFont(.bodySmall).foregroundStyle(theme.onSecondaryContainer)
                SettingsFillButton(title: expanded ? L10n.musicIntelligenceHideTools : L10n.musicIntelligenceTools,
                                   style: .filled) { expanded.toggle() }
                if expanded {
                    Text(L10n.musicIntelligenceToolsDescription)
                        .pixlFont(.bodySmall).foregroundStyle(theme.onSecondaryContainer)
                    SettingsFillButton(title: L10n.musicIntelligencePreview, style: .filled) {}
                    SettingsFillButton(title: L10n.musicIntelligenceRefresh, style: .outlined) {}
                    SettingsFillButton(title: L10n.musicIntelligenceReset, style: .outlined) { showsReset = true }
                }
            }
            .padding(20)
        }
        .animation(PixlMotion.state, value: expanded)
        .onAppear { exploration = ai.musicExploration }
        .alert(L10n.musicIntelligenceReset, isPresented: $showsReset) {
            Button(L10n.commonCancel, role: .cancel) {}
            Button(L10n.musicIntelligenceResetConfirm, role: .destructive) {}
        } message: {
            Text(L10n.musicIntelligenceResetDescription)
        }
    }

    private func toggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title).pixlFont(.titleSmall).foregroundStyle(theme.onSecondaryContainer)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn).labelsHidden().tint(theme.primary)
        }
        .frame(minHeight: 48)
    }
}
