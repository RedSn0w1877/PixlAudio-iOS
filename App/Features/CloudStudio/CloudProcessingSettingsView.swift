import PixlNet
import SwiftUI

/// Settings › Developer › Experimental › Cloud processing (design §3.5 E, §7.2; iOS-first, Android later): the
/// consent switch, the RunPod endpoint and Restricted key, the R2 bucket and its key pair (fields in the order of the
/// owner's setup steps), Test connection (RunPod and storage reported on their own) with the optional selftest, the
/// outputs, cellular, the GPU price and monthly cap, and the way to the queue. Built from the settings rows; the keys
/// are edited in a local draft and written to the Keychain (this iPhone only) off the main actor.
/// A build with PixlAudio's built-in cloud keys (2026-10-08) shows "Using PixlAudio's built-in cloud keys" instead of
/// the fields, with "Use my own keys" bringing them back; Test connection works with either.
struct CloudProcessingSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var draft = CloudSecrets.empty
    @State private var draftLoaded = false
    @State private var priceText = ""
    @State private var capText = ""
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        let cloud = env.cloud
        @Bindable var settings = cloud.settings
        let builtIn = settings.usesBuiltInKeys
        SettingsScaffold(title: "Cloud processing", screenID: "cloudProcessing") {
            SettingsSubsection(title: "Consent") {
                SwitchSettingRow(title: builtIn ? "Process songs in the cloud" : "Send songs to my RunPod account",
                                 subtitle: "Nothing leaves this iPhone until this is on, and only songs you send yourself go.",
                                 isOn: $settings.isEnabled, systemImage: "icloud.and.arrow.up")
                SettingsPanel {
                    Text(verbatim: builtIn
                         ? "Separates vocals with BS-RoFormer and times lyrics word by word on PixlAudio's RunPod GPU. Songs go to PixlAudio's Cloudflare R2 bucket and are deleted after import."
                         : "Separates vocals with BS-RoFormer and times lyrics word by word on your own RunPod GPU. Songs go to your Cloudflare R2 bucket and are deleted after import.")
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            }
            if settings.keysMissing {
                SettingsPanel(tint: theme.errorContainer) {
                    Label("Cloud keys missing — paste them again.", systemImage: "key.slash")
                        .pixlFont(.titleSmall)
                        .foregroundStyle(theme.onErrorContainer)
                    Text(verbatim: "The app was signed again with another account, so it can't read the keys it saved before.")
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onErrorContainer)
                }
                .padding(.bottom, 10)
            }
            if settings.builtInAvailable {
                keysSection(settings)
            }
            if !builtIn {
                ownKeyFields(settings)
            }
            connectionSection(cloud: cloud, settings: settings)
            SettingsSubsection(title: "Outputs") {
                SwitchSettingRow(title: "Instrumental", subtitle: "For Sing: the song without its vocals.",
                                 isOn: $settings.wantsInstrumental, systemImage: "waveform")
                SwitchSettingRow(title: "Word-timed lyrics", subtitle: "Times your lyrics word by word against the vocals.",
                                 isOn: $settings.wantsLyrics, systemImage: "text.word.spacing")
                SwitchSettingRow(title: "Write lyrics when none are found (AI transcription)",
                                 subtitle: "Saved as \"AI-written lyrics\". Line timing only outside the 11 languages the aligner knows.",
                                 isOn: $settings.transcribeWhenMissing, systemImage: "sparkles",
                                 enabled: settings.wantsLyrics)
                SettingsPanel {
                    Text(verbatim: "Quality").pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
                    GlassPillRow(items: [GlassPillRow<String>.Item(id: CloudSeparationQuality.standard.rawValue, title: "Standard"),
                                         GlassPillRow<String>.Item(id: CloudSeparationQuality.best.rawValue, title: "Best")],
                                 selection: Binding(get: { settings.quality.rawValue },
                                                    set: { settings.quality = CloudSeparationQuality(rawValue: $0) ?? .standard }),
                                 uppercase: false, height: 40, edgePadding: 0, accessibilityIdentifierPrefix: "cloud.quality")
                    Text(verbatim: "Best takes about twice the GPU time, for songs up to 8 minutes.")
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            }
            SettingsSubsection(title: "Network") {
                SwitchSettingRow(title: "Use cellular data",
                                 subtitle: "Off: uploads and downloads wait for Wi-Fi. Low Data Mode always waits.",
                                 isOn: $settings.useCellular, systemImage: "antenna.radiowaves.left.and.right")
            }
            costSection(cloud: cloud, settings: settings)
            SettingsSubsection(title: "Queue") {
                SettingsItemRow(title: "Cloud queue", subtitle: cloud.summaryLine ?? "Send songs and see what comes back.",
                                systemImage: "list.bullet.rectangle", showsChevron: true, identifier: "cloud.openQueue") {
                    router.push(.cloudQueue)
                }
            }
            SettingsPanel {
                Text(verbatim: CloudProcessingCopy.promise(builtIn: builtIn))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                if !builtIn {
                    SettingsFillButton(title: "Forget keys", systemImage: "key", style: .destructive,
                                       enabled: !draft.isEmpty) {
                        draft = .empty
                        Task { await settings.forgetSecrets() }
                    }
                    .accessibilityIdentifier("cloud.forgetKeys")
                }
            }
            Spacer().frame(height: 24)
        }
        .task {
            await settings.loadSecrets()
            if !draftLoaded {
                draft = settings.secrets
                draftLoaded = true
            }
            priceText = CloudProcessingCopy.priceText(settings.pricePerSecondMicroUSD)
            capText = CloudProcessingCopy.dollars(settings.monthlyCapMicroUSD)
        }
        .onChange(of: draft) { _, new in
            guard draftLoaded else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await settings.updateSecrets(new)
            }
        }
        .onDisappear {
            saveTask?.cancel()
            let latest = draft
            if draftLoaded { Task { await settings.updateSecrets(latest) } }
        }
    }

    // MARK: Sections

    /// Built-in keys in this build: which keys are in use, and the way to the person's own.
    private func keysSection(_ model: CloudSettings) -> some View {
        @Bindable var settings = model
        return SettingsSubsection(title: "Keys") {
            if settings.usesBuiltInKeys {
                SettingsPanel {
                    Label("Using PixlAudio's built-in cloud keys", systemImage: "key.fill")
                        .pixlFont(.titleSmall)
                        .foregroundStyle(theme.onSurface)
                        .accessibilityIdentifier("cloud.builtInKeys")
                    Text(verbatim: CloudProcessingCopy.builtInKeysDetail)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            }
            SwitchSettingRow(title: "Use my own keys", subtitle: "Your own RunPod endpoint and Cloudflare R2 bucket instead.",
                             isOn: $settings.useOwnKeys, systemImage: "person.badge.key")
                .accessibilityIdentifier("cloud.useOwnKeys")
        }
    }

    /// The person's own endpoint, key and bucket (the only kind before built-in keys).
    @ViewBuilder
    private func ownKeyFields(_ model: CloudSettings) -> some View {
        @Bindable var settings = model
        SettingsSubsection(title: "RunPod") {
            SettingsPanel {
                SettingsTextField(placeholder: "e.g. abc123xyz", text: $settings.endpointId, label: "Endpoint ID")
                    .accessibilityIdentifier("cloud.endpointId")
                SettingsTextField(placeholder: "rpa_…", text: $draft.runpodKey, secure: true,
                                  label: "RunPod key (Restricted, Read/Write on this endpoint)")
                    .accessibilityIdentifier("cloud.runpodKey")
            }
        }
        SettingsSubsection(title: "Storage (Cloudflare R2)") {
            SettingsPanel {
                SettingsTextField(placeholder: "https://<account-id>.r2.cloudflarestorage.com", text: $settings.r2Endpoint,
                                  label: "R2 endpoint or account ID")
                    .accessibilityIdentifier("cloud.r2Endpoint")
                if let account = CloudConfig.r2AccountId(endpoint: settings.r2Endpoint) {
                    Text(verbatim: "Account \(account)")
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                SettingsTextField(placeholder: CloudConfig.defaultBucket, text: $settings.bucket, label: "Bucket")
                    .accessibilityIdentifier("cloud.bucket")
                SettingsTextField(placeholder: "", text: $draft.accessKeyId, secure: true, label: "Access key ID")
                    .accessibilityIdentifier("cloud.accessKeyId")
                SettingsTextField(placeholder: "", text: $draft.secretAccessKey, secure: true, label: "Secret access key")
                    .accessibilityIdentifier("cloud.secret")
            }
        }
    }

    private func connectionSection(cloud: CloudStudio, settings: CloudSettings) -> some View {
        // Built-in keys are complete by construction (an incomplete blob counts as none), so nothing to list.
        let problems = settings.usesBuiltInKeys ? [] : CloudConfig.problems(settings.configInput(with: draft))
        return SettingsSubsection(title: "Test connection") {
            SettingsPanel {
                if !problems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.circle")
                                .pixlFont(.bodySmall)
                                .foregroundStyle(theme.onSurfaceVariant)
                        }
                    }
                }
                SettingsFillButton(title: cloud.isTesting ? "Testing…" : "Test connection", systemImage: "checkmark.seal",
                                   style: .filled, enabled: problems.isEmpty && !cloud.isTesting) {
                    Task {
                        saveTask?.cancel()
                        await settings.updateSecrets(draft)
                        await cloud.testConnection()
                    }
                }
                .accessibilityIdentifier("cloud.test")
                if let report = cloud.connectionReport {
                    CloudCheckLine(title: "RunPod", check: report.runpod)
                    CloudCheckLine(title: "Storage", check: report.storage)
                }
                SettingsFillButton(title: "Run selftest (~1¢)", systemImage: "cpu", style: .tonal,
                                   enabled: problems.isEmpty && !cloud.isTesting) {
                    Task {
                        // Keys typed a moment ago are saved first (the draft is otherwise saved 0.6 s after typing).
                        saveTask?.cancel()
                        await settings.updateSecrets(draft)
                        await cloud.runSelftest()
                    }
                }
                .accessibilityIdentifier("cloud.selftest")
                if let selftest = cloud.selftestCheck {
                    CloudCheckLine(title: "Worker", check: selftest)
                }
            }
        }
    }

    private func costSection(cloud: CloudStudio, settings: CloudSettings) -> some View {
        SettingsSubsection(title: "Cost") {
            SettingsPanel {
                SettingsTextField(placeholder: "0.000192", text: $priceText, label: "GPU price per second (US$)")
                    .keyboardType(.decimalPad)
                    .onChange(of: priceText) { _, text in
                        if let value = CloudProcessingCopy.parseMicroUSD(text), value > 0 {
                            settings.pricePerSecondMicroUSD = min(value, 10_000)
                        }
                    }
                SettingsTextField(placeholder: "3.00", text: $capText, label: "Monthly cap (US$)")
                    .keyboardType(.decimalPad)
                    .onChange(of: capText) { _, text in
                        if let value = CloudProcessingCopy.parseMicroUSD(text) { settings.monthlyCapMicroUSD = value }
                    }
                Text(verbatim: CloudProcessingCopy.monthLine(committed: cloud.committedThisMonthMicroUSD,
                                                             cap: settings.effectiveMonthlyCapMicroUSD))
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface)
                if settings.usesBuiltInKeys {
                    Text(verbatim: CloudProcessingCopy.builtInCapLine)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                Text(verbatim: "Estimates: about $0.004 a song once a GPU is awake, plus about $0.007 to wake one. The RunPod balance itself is the hard limit.")
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        }
    }
}

/// One Test connection result: a tick or a cross, the sentence, and the detail.
struct CloudCheckLine: View {
    let title: String
    let check: CloudCheck
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(check.ok ? theme.primary : theme.error)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).pixlFont(.titleSmall).foregroundStyle(theme.onSurface)
                Text(verbatim: check.message).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
                if let detail = check.detail {
                    Text(verbatim: detail).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cloud.check.\(title)")
    }
}

/// Text the cloud screens share (no formatting in `body`).
nonisolated enum CloudProcessingCopy {
    /// What the UI promises about the app being closed (design §7.4): on the person's own RunPod account, or on
    /// PixlAudio's with the built-in keys.
    static func promise(builtIn: Bool) -> String { builtIn ? builtInPromise : ownPromise }
    static let ownPromise = "Songs are processed on your RunPod account even when PixlAudio is closed. Results come back the next time PixlAudio runs, and are kept for 30 days. Swiping PixlAudio away stops uploads that haven't finished."
    static let builtInPromise = "Songs are processed in the cloud even when PixlAudio is closed. Results come back the next time PixlAudio runs, and are kept for 30 days. Swiping PixlAudio away stops uploads that haven't finished."
    /// The Keys panel with the built-in keys in use.
    static let builtInKeysDetail = "Nothing to fill in. Songs you send go to PixlAudio's own RunPod endpoint and R2 bucket, up to \(CloudCost.format(microUSD: CloudKeyChoice.builtInMonthlyCapMicroUSD)) a month from this iPhone."
    /// Experimental's Cloud processing row: on or off, with whose GPU.
    @MainActor
    static func experimentalRow(settings: CloudSettings, summary: String?) -> String {
        if settings.isEnabled {
            return summary ?? (settings.usesBuiltInKeys ? "On — instrumentals and word-timed lyrics in the cloud."
                : "On — instrumentals and word-timed lyrics on your RunPod GPU.")
        }
        return settings.builtInAvailable && !settings.useOwnKeys
            ? "Instrumentals and word-timed lyrics in the cloud, nothing to set up. Off."
            : "Instrumentals and word-timed lyrics on your own RunPod GPU. Off until you set it up."
    }
    static let builtInCapLine = "With PixlAudio's built-in keys the cap is at most \(CloudCost.format(microUSD: CloudKeyChoice.builtInMonthlyCapMicroUSD)) a month."

    static func dollars(_ microUSD: Int64) -> String {
        let cents = (max(microUSD, 0) + 5_000) / 10_000
        let tail = cents % 100
        return "\(cents / 100).\(tail < 10 ? "0" : "")\(tail)"
    }

    /// µ$ per second as dollars with six decimals ("0.000192").
    static func priceText(_ microUSD: Int64) -> String {
        let whole = microUSD / 1_000_000
        let fraction = String(microUSD % 1_000_000)
        return "\(whole)." + String(repeating: "0", count: max(0, 6 - fraction.count)) + fraction
    }

    /// "3", "3.5", "0.000192", "$1.20" → µ$; nil for anything else.
    static func parseMicroUSD(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite, value >= 0, value < 1_000 else { return nil }
        return Int64((value * 1_000_000).rounded())
    }

    static func monthLine(committed: Int64, cap: Int64) -> String {
        "This month: \(CloudCost.format(microUSD: committed)) of \(CloudCost.format(microUSD: cap)) used or on its way."
    }
}

extension CloudSettings {
    /// The fields with an unsaved key draft (the screen checks what is typed, not what was last saved); the built-in
    /// keys when those are in use.
    func configInput(with draft: CloudSecrets) -> CloudConfigInput {
        if usesBuiltInKeys { return configInput }
        return CloudConfigInput(endpointId: endpointId, runpodKey: draft.runpodKey, endpoint: r2Endpoint, bucket: bucket,
                                accessKeyId: draft.accessKeyId, secretAccessKey: draft.secretAccessKey)
    }
}
