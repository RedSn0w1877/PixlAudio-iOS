import PixlNet
import SwiftUI
import UIKit

/// Settings › AI features (Android `SettingsCategoryScreen` AI_INTEGRATION): the assistant rows and the
/// personality (system prompt + presets). Developer mode adds the "Advanced" block: the
/// assistant, sign-in (API key, Keychain), model, base URL for configurable providers, and a collapsed disclosure
/// (generation parameters, song data, usage report). The automatic studio card moved to Sing.
///
/// iOS: the on-device provider uses the system's on-device language model (Foundation Models) instead of importing
/// a MediaPipe file. The model picker lists the provider's chat models (stage 13, `AIService.availableModels`).
///
/// Owner decision 2026-10-07 (a departure from Android, docs/parity.md): the on-device model is the assistant by
/// default and comes first; cloud providers sit in an optional "Cloud assistants" section behind a switch that is
/// off by default, with no automatic fallback to the cloud. With the on-device model selected, Advanced shows only
/// Temperature (the on-device paths size their own prompts and answers), and "Save on usage" is a cloud setting.
///
/// Claude everywhere (2026-10-23): normal users see one assistant row at the top — Ask Taizo, with the router's
/// status line ("Claude (cloud) — switches to this phone when offline"). Developer mode adds the built-in Claude key's
/// monthly cap ($0–$200, default $50) and this month's spend; the own-key cloud assistants stay as an override.
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
    /// The router's answer when the screen opened (cheap; refreshed on every appearance).
    @State private var route: AIRoute?
    @State private var claudeSpent = 0.0

    private var provider: AiProvider { AiProvider.fromString(settings.ai.provider) }

    var body: some View {
        let developerMode = settings.experimental.developerMode
        SettingsCategoryScaffold(category: .ai) {
            SettingsSubsection(title: "Assistant") {
                SettingsItemRow(title: "Ask Taizo", subtitle: AIRouter.statusLine(route ?? .claude), systemImage: "sparkles",
                                iconColor: theme.primary) {
                    environment.router.present(AppSheet.taisChat)
                }
                .accessibilityIdentifier("ai.taizo.settings")
                if hasBuiltInClaude {
                    claudeCloudSwitch
                }
            }
            Spacer().frame(height: 20)
            // The raw system-prompt editor is a developer tool (normal users get the defaults).
            if developerMode {
                SettingsSubsection(title: L10n.settingsPromptBehaviorSection, addBottomSpace: true) {
                    AISystemPromptRow(providerName: provider.rawValue)
                }
                advancedBlock
            }
        }
        .animation(PixlMotion.state, value: showsAdvanced)
        .task {
            // UI tests show the normal state (a build with the key, online) so screenshots don't depend on CI secrets.
            route = environment.launch.isUITest ? .claude : ClaudeCloud.shared.route()
            claudeSpent = environment.launch.isUITest ? 3.42 : ClaudeBudgetStore.spentDollars(.standard)
        }
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

    /// Whether this build carries the built-in Claude key (UI tests show the normal state).
    private var hasBuiltInClaude: Bool { environment.launch.isUITest || ClaudeCloud.shared.hasKey }

    /// For everyone: what goes to the cloud, and a way to stop it. Off is the $0 monthly limit (everything then runs on
    /// this iPhone); on restores the default limit.
    private var claudeCloudSwitch: some View {
        let ai = settings.ai
        let on = ai.claudeMonthlyCap > 0
        return SwitchSettingRow(title: "Use cloud AI",
                                subtitle: on ? "When you're online, AI requests (with the library and listening details they need) go to a cloud AI service. Offline, this iPhone answers."
                                    : "Off: every AI feature runs on this iPhone. Nothing leaves this iPhone.",
                                isOn: Binding(get: { ai.claudeMonthlyCap > 0 },
                                              set: { ai.claudeMonthlyCap = $0 ? ClaudeBudget.defaultCapDollars : 0 }),
                                systemImage: "cloud", iconColor: on ? theme.primary : theme.tertiary)
            .accessibilityIdentifier("settings.ai.claudeCloud")
    }

    /// Developer mode's "Advanced" block: the assistant (the on-device model, the
    /// downloaded one, the optional cloud assistants with their sign-in, model and base URL) and the generation
    /// parameters, song data and usage report disclosure.
    @ViewBuilder
    private var advancedBlock: some View {
        @Bindable var ai = settings.ai
        let cloud = ai.usesCloudAssistant
        SettingsAdvancedHeader()
        SettingsSubsection(title: "Cloud AI (built-in)") {
            AIParameterRow(label: "Monthly limit", value: $ai.claudeMonthlyCap, range: 0...ClaudeBudget.maxCapDollars, steps: 39,
                           help: "This device's monthly spend cap for the built-in cloud AI. Over it, AI runs on this iPhone until next month. $0 turns cloud AI off.") {
                String(format: "$%.0f", $0)
            }
            Text(verbatim: "Spent this month: " + String(format: "$%.2f of $%.0f", claudeSpent, ai.claudeMonthlyCap) + " · "
                     + (environment.launch.isUITest || ClaudeCloud.shared.hasKey ? "built-in key present" : "no built-in key in this build"))
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsRowGlass()
                .accessibilityIdentifier("settings.ai.claudeSpend")
        }
        SettingsSubsection(title: L10n.settingsAiProviderTitle) {
            OnDeviceModelRow(isSelected: !cloud && !ai.useDownloadedModel,
                             downloadedModelOn: !cloud && ai.useDownloadedModel)
            DownloadedModelRows()
        }
        SettingsSubsection(title: "Cloud assistants (optional)") {
            SwitchSettingRow(title: "Use a cloud assistant",
                             subtitle: cloud ? "AI requests go to \(provider.displayName) with your own key."
                                 : "Off: AI uses the built-in cloud AI when online, this iPhone when offline.",
                             isOn: Binding(get: { ai.usesCloudAssistant }, set: { ai.setUsesCloudAssistant($0) }),
                             systemImage: "cloud", iconColor: cloud ? theme.primary : theme.tertiary)
                .accessibilityIdentifier("settings.ai.cloud")
            if cloud {
                ThemeSelectorRow(label: L10n.settingsAiProviderTitle, description: L10n.settingsAiProviderSubtitle,
                                 options: Self.cloudProviders.map { SettingsOption(key: $0.rawValue, label: $0.displayName) },
                                 selectedKey: ai.provider, systemImage: "flask") { ai.provider = $0 }
                SwitchSettingRow(title: L10n.settingsSafeTokenTitle,
                                 subtitle: ai.safeTokenLimit ? L10n.settingsSafeTokenOn : L10n.settingsSafeTokenOff,
                                 isOn: $ai.safeTokenLimit, systemImage: "chart.line.uptrend.xyaxis",
                                 iconColor: ai.safeTokenLimit ? theme.primary : theme.tertiary)
            }
        }
        if cloud {
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
                        // Ollama counts as set up with a base URL alone ("New playlist" › With AI reads this).
                        let environment = self.environment
                        Task { await AIProviderStatus.refresh(environment) }
                    }
                }
            }
        }
        Spacer().frame(height: 8)
        advancedToggle
        Spacer().frame(height: 8)
        if showsAdvanced {
            advanced(cloud: cloud)
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
                Text(L10n.settingsAiAdvancedDisclosure)
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

    /// Cloud providers in Android's order (the on-device model has its own row).
    static let cloudProviders = AiProvider.entries.filter { $0 != .onDevice }

    /// On-device: Temperature only. Cloud: Android's whole block.
    @ViewBuilder
    private func advanced(cloud: Bool) -> some View {
        @Bindable var ai = settings.ai
        SettingsSubsection(title: "Generation Parameters", addBottomSpace: cloud) {
            AIParameterRow(label: "Temperature", value: $ai.temperature, range: 0...2, steps: 20,
                           help: "Controls randomness. Lower = more deterministic, higher = more creative. Used by this iPhone's AI and your own cloud assistant only (the built-in cloud AI sets its own).") {
                String(format: "%.2f", $0)
            }
            if cloud {
                cloudParameters
            }
        }
        if cloud {
            cloudSongData
        }
    }

    @ViewBuilder
    private var cloudParameters: some View {
        @Bindable var ai = settings.ai
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

    @ViewBuilder
    private var cloudSongData: some View {
        @Bindable var ai = settings.ai
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
        case .onDevice: "On-device model"
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

/// The on-device model, the default assistant (iOS stand-in for Android's imported MediaPipe model file): whether it
/// is in use, and why it can't answer when it can't (not on this iPhone, turned off, downloading, language). UI tests
/// show it ready, so the screenshots don't depend on the simulator.
struct OnDeviceModelRow: View {
    /// The on-device model is the selected assistant (off while a cloud assistant or the downloaded model is on).
    var isSelected = true
    /// "Use downloaded AI model" is on: the downloaded model answers instead.
    var downloadedModelOn = false

    @Environment(\.appTheme) private var theme

    var body: some View {
        let (title, detail, ready) = status
        HStack(spacing: 12) {
            SettingsIcon(systemImage: "cpu", color: isSelected && ready ? theme.primary : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).pixlFont(.bodyMedium, weight: .medium).foregroundStyle(theme.onSurface)
                Text(detail).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSelected && ready {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.primary)
                    .accessibilityHidden(true)
            }
        }
        .padding(16)
        .settingsRowGlass()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.ai.onDevice")
    }

    private var status: (title: String, detail: String, ready: Bool) {
        let isUITest = LaunchConfiguration.current.isUITest
        if let issue = isUITest ? nil : OnDeviceModel.unavailability {
            switch issue {
            case .deviceNotEligible:
                return ("Not available on this iPhone", "This iPhone can't run the system's on-device model. Use the downloaded AI model below, or a cloud assistant.", false)
            case .intelligenceOff:
                return ("Turned off in system settings", "Turn on the intelligence features in the iPhone's Settings app to use the on-device model.", false)
            case .notReady:
                return ("Downloading", "The on-device model is still downloading. AI features start working when it's ready.", false)
            default:
                return ("Can't be used right now", issue.message, false)
            }
        }
        if !isUITest, !OnDeviceModel.supportsLocale() {
            return ("Language not supported yet", "The on-device model doesn't support your device language yet.", false)
        }
        if isSelected {
            return ("On-device model · ready", "Answers when you're offline or cloud AI isn't available — privately, on this iPhone.", true)
        }
        if downloadedModelOn {
            return ("On-device model", "Ready. Turn off \"Use downloaded AI model\" to use it instead.", true)
        }
        return ("On-device model", "Ready. Turn off the cloud assistant to use it instead.", true)
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
