import AVFoundation
import MediaPlayer
import PixlAudioCore
import PixlModel
import SwiftUI
import UIKit

/// Ten editable frequency bands, independent audio effects and the volume of the current output.
struct EqualizerView: View {
    var screenID = "equalizer"

    @Environment(SettingsStore.self) private var settings

    var body: some View {
        EqualizerContent(prefs: settings.equalizer, screenID: screenID)
    }
}

private struct EqualizerContent: View {
    @State private var model: EqualizerModel
    let screenID: String

    @State private var showsCustomPresets = false
    @State private var showsReorder = false
    @State private var showsSave = false
    @State private var nameDraft = ""

    init(prefs: EqualizerPreferences, screenID: String) {
        _model = State(initialValue: EqualizerModel(prefs: prefs))
        self.screenID = screenID
    }

    var body: some View {
        SettingsScaffold(title: L10n.settingsCategoryEqualizerTitle, screenID: screenID,
                         horizontalPadding: 0, spacing: 12) {
            PresetTabsRow(model: model) { showsReorder = true }
            EqualizerBandCard(model: model,
                              onSave: { nameDraft = ""; showsSave = true },
                              onUpdate: { if let name = model.editingPresetName { model.updateCustomPresetBands(name) } },
                              onPresetsList: { showsCustomPresets = true })
            EqualizerEffects(prefs: model.prefs)
            EqualizerVolumeCard()
        }
        .alert(L10n.equalizerPresetsSaveCustomTitle, isPresented: $showsSave) {
            TextField(L10n.equalizerPresetNamePlaceholder, text: $nameDraft)
            Button(L10n.commonCancel, role: .cancel) {}
            Button(L10n.commonSave) { model.saveCurrentAsCustomPreset(nameDraft) }
            .disabled(!model.canNamePreset(nameDraft))
        } message: {
            Text(L10n.equalizerPresetsSaveCustomBody)
        }
        .sheet(isPresented: $showsCustomPresets) {
            CustomPresetsSheet(model: model)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showsReorder) {
            ReorderPresetsView(model: model)
        }
    }
}

private struct PresetTabsRow: View {
    let model: EqualizerModel
    let onEdit: () -> Void

    var body: some View {
        let presets = model.tabPresets
        let selected = model.currentPreset.name
        GlassPillRow(items: presets.map { GlassPillRow<String>.Item(id: $0.name, title: $0.displayName,
                                                                    systemImage: $0.isCustom ? "star.fill" : nil) },
                     selection: Binding(get: { selected }, set: { name in
                         if let preset = presets.first(where: { $0.name == name }) { model.select(preset) }
                     }),
                     uppercase: false, edgePadding: 16, accessibilityIdentifierPrefix: "eq.preset",
                     accessory: .init(systemImage: "pencil", accessibilityLabel: L10n.equalizerEditPresetsCd,
                                     action: onEdit))
            .frame(height: 56)
    }
}

private struct EqualizerBandCard: View {
    let model: EqualizerModel
    let onSave: () -> Void
    let onUpdate: () -> Void
    let onPresetsList: () -> Void

    @State private var page = 0
    @Environment(\.appTheme) private var theme

    var body: some View {
        let prefs = model.prefs
        let levels = model.bandLevels
        GlassCard(cornerRadius: 24, tint: theme.surfaceContainerLow) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { prefs.isEnabled }, set: { prefs.isEnabled = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.equalizerFrequencyResponse)
                            .pixlFont(.titleMedium, weight: .semibold)
                            .foregroundStyle(theme.onSurface)
                        Text(model.editingPresetName ?? model.currentPreset.displayName)
                            .pixlFont(.bodySmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                }
                .accessibilityLabel(L10n.settingsCategoryEqualizerTitle)
                .accessibilityIdentifier("eq.power")
                .tint(theme.primary)
                .padding(.horizontal, 16)

                Picker(L10n.equalizerChangeViewModeCd, selection: Binding(get: { model.viewMode },
                       set: { prefs.viewMode = $0.rawValue })) {
                    ForEach(EqualizerViewMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("eq.viewMode")

                bandEditor(levels)
                presetActions
            }
            .padding(.vertical, 16)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func bandEditor(_ levels: [Int]) -> some View {
        switch model.viewMode {
        case .graph:
            EqualizerGraphSliders(levels: levels) { model.setBandLevel($0, $1) }
        case .hybrid:
            EqualizerHybridSliders(levels: levels) {
                model.setBandLevel($0, $1)
            }
        case .sliders:
            TabView(selection: $page) {
                ForEach(0..<2, id: \.self) { pageIndex in
                    HStack(spacing: 0) {
                        ForEach(pageIndex * 5..<min(pageIndex * 5 + 5, levels.count), id: \.self) { index in
                            Spacer(minLength: 0)
                            EqualizerBandColumn(frequency: EqualizerPreset.bandFrequencies[index],
                                                level: levels[index]) {
                                model.setBandLevel(index, $0)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .tag(pageIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 270)

            HStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { index in
                    Circle()
                        .fill(page == index ? theme.primary : theme.surfaceContainerHighest)
                        .frame(width: page == index ? 10 : 8, height: page == index ? 10 : 8)
                        .padding(4)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(PixlMotion.selection, value: page)
            .accessibilityElement()
            .accessibilityLabel(L10n.equalizerPageN(page + 1))
        }
    }

    private var presetActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button(action: onPresetsList) {
                    Label(L10n.equalizerPresetsSavedTitle, systemImage: "list.bullet")
                        .pixlFont(.labelLarge)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .foregroundStyle(theme.onSecondaryContainer)
                        .background(theme.secondaryContainer, in: Capsule())
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityIdentifier("eq.presetChip")
                if model.editingPresetName != nil {
                    chip(L10n.equalizerActionUpdate, fill: theme.primaryContainer, content: theme.onPrimaryContainer,
                         id: "eq.update", action: onUpdate)
                    chip(L10n.equalizerActionSaveNew, fill: theme.tertiaryContainer, content: theme.onTertiaryContainer,
                         id: "eq.saveNew", action: onSave)
                } else if model.currentPreset.name == "custom" {
                    chip(L10n.commonSave, fill: theme.tertiaryContainer, content: theme.onTertiaryContainer,
                         id: "eq.save", action: onSave)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func chip(_ title: String, fill: Color, content: Color, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                Text(title).pixlFont(.labelLarge, weight: .bold)
            }
            .foregroundStyle(content)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(fill, in: Capsule())
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
        .accessibilityIdentifier(id)
    }
}

private struct EqualizerEffects: View {
    @Bindable var prefs: EqualizerPreferences
    @Environment(\.appTheme) private var theme

    var body: some View {
        GlassCard(cornerRadius: 24, tint: theme.surfaceContainerLow) {
            VStack(spacing: 0) {
                effect(L10n.equalizerBassBoost, enabled: $prefs.bassBoostEnabled, strength: $prefs.bassBoostStrength)
                Divider()
                effect(L10n.equalizerVirtualizer, enabled: $prefs.virtualizerEnabled, strength: $prefs.virtualizerStrength)
                Divider()
                effect(L10n.equalizerLoudness, enabled: $prefs.loudnessEnhancerEnabled, strength: $prefs.loudnessEnhancerStrength)
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, 16)
    }

    private func effect(_ title: String, enabled: Binding<Bool>, strength: Binding<Int>) -> some View {
        VStack(spacing: 4) {
            Toggle(isOn: enabled) {
                HStack(spacing: 8) {
                    Text(title).pixlFont(.titleSmall, weight: .semibold)
                    Spacer(minLength: 0)
                    if enabled.wrappedValue {
                        Text("\(strength.wrappedValue / 10)%")
                            .pixlFont(.labelMedium)
                            .monospacedDigit()
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                }
            }
            .frame(minHeight: 44)
            .accessibilityLabel(title)
            .accessibilityIdentifier("eq.effect.\(title)")
            if enabled.wrappedValue {
                Slider(value: Binding(get: { Double(strength.wrappedValue) },
                                      set: { strength.wrappedValue = Int($0.rounded()) }),
                       in: 0...Double(EqualizerBands.maxStrength), step: 10)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(strength.wrappedValue / 10)%")
            }
        }
        .padding(.vertical, 8)
        .tint(theme.primary)
        .foregroundStyle(theme.onSurface)
    }
}

/// Android `VolumeControlCard`: "Volume", the speaker icon, the system volume slider and the percentage. While a
/// Spotify Connect device plays, the phone's volume does nothing audible: the card shows and drives the device's
/// instead (owner decision 2026-10-07), the same value the devices sheet's hero and the volume buttons change.
private struct EqualizerVolumeCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let device = env.spotifyConnect.active {
            EqualizerConnectVolumeCard(device: device)
        } else {
            EqualizerPhoneVolumeCard()
        }
    }
}

/// The volume card for the Spotify Connect device: "Volume", the device's name, its symbol, its volume slider and the
/// percentage (or a note when it sets its own volume).
private struct EqualizerConnectVolumeCard: View {
    let device: SpotifyConnectController.ActiveDevice

    @Environment(\.appTheme) private var theme
    @State private var level: Double = 50

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(L10n.equalizerVolume)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface)
                Text("\(device.name) \u{2022} Spotify Connect")
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 16) {
                Image(systemName: device.symbolName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                if device.supportsVolume {
                    SpotifyConnectVolumeSlider(level: $level, label: Text("\(device.name) volume"), tint: theme.primary,
                                               identifier: "eq.volume.connect")
                        .frame(height: 36)
                    Text("\(Int(level.rounded()))%")
                        .pixlFont(.labelLarge)
                        .foregroundStyle(theme.onSurface)
                        .monospacedDigit()
                        .frame(width: 46)
                } else {
                    Text("This device sets its own volume")
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(SettingsTint.row))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("eq.volume")
    }
}

/// The phone's volume (the system slider): this phone plays.
private struct EqualizerPhoneVolumeCard: View {
    @State private var volume = SystemVolumeObserver()
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.equalizerVolume)
                .pixlFont(.titleMedium)
                .foregroundStyle(theme.onSurface)
            HStack(spacing: 16) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .accessibilityHidden(true)
                SystemVolumeSlider(tint: theme.primary)
                    .frame(height: 36)
                Text("\(Int((volume.level * 100).rounded()))%")
                    .pixlFont(.labelLarge)
                    .foregroundStyle(theme.onSurface)
                    .monospacedDigit()
                    .frame(width: 46)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(SettingsTint.row))
        .padding(.horizontal, 16)
        .onAppear { volume.start() }
        .onDisappear { volume.stop() }
        .accessibilityIdentifier("eq.volume")
    }
}

/// The audio session's output volume (key-value observed; it changes only when the user moves a volume control).
@Observable
final class SystemVolumeObserver {
    private(set) var level: Float = AVAudioSession.sharedInstance().outputVolume
    @ObservationIgnored private var observation: NSKeyValueObservation?

    func start() {
        guard observation == nil else { return }
        level = AVAudioSession.sharedInstance().outputVolume
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new],
                                                              changeHandler: Self.handler { [weak self] value in
            Task { @MainActor in self?.level = value }
        })
    }

    /// KVO may call back on any thread: the handler is built outside the main actor and hops back explicitly.
    nonisolated private static func handler(_ sink: @escaping @Sendable (Float) -> Void)
        -> (AVAudioSession, NSKeyValueObservedChange<Float>) -> Void {
        { _, change in
            if let value = change.newValue { sink(value) }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }
}

/// The system volume slider (`MPVolumeView`), tinted with the scheme's primary.
private struct SystemVolumeSlider: UIViewRepresentable {
    let tint: Color

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = UIColor(tint)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        uiView.tintColor = UIColor(tint)
    }
}

// MARK: - Saved presets (Android `CustomPresetsSheet`)

private struct CustomPresetsSheet: View {
    let model: EqualizerModel
    @State private var renameTarget: EqualizerPreset?
    @State private var nameDraft = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    var body: some View {
        let presets = model.customPresets
        let pinned = model.pinnedNames
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.equalizerPresetsSavedTitle)
                .pixlFont(.titleLarge, weight: .bold)
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            if presets.isEmpty {
                Text(L10n.equalizerPresetsEmpty)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                    .padding(32)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(presets) { preset in
                            row(preset, isPinned: pinned.contains(preset.name))
                            Rectangle()
                                .fill(theme.outlineVariant.opacity(0.5))
                                .frame(height: 0.5)
                                .padding(.leading, 72)
                        }
                    }
                }
            }
            Spacer(minLength: 32)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(L10n.equalizerPresetsRenameTitle, isPresented: Binding(
            get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField(L10n.equalizerPresetNamePlaceholder, text: $nameDraft)
            Button(L10n.commonCancel, role: .cancel) {}
            Button(L10n.equalizerActionRename) {
                if let target = renameTarget { model.renameCustomPreset(target.name, to: nameDraft) }
            }
            .disabled(!model.canNamePreset(nameDraft))
        }
    }

    private func row(_ preset: EqualizerPreset, isPinned: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                model.select(preset)
                dismiss()
            } label: {
                HStack(spacing: 16) {
                    Text(preset.displayName.first.map { String($0).uppercased() } ?? "C")
                        .pixlFont(.titleMedium)
                        .foregroundStyle(theme.onSecondaryContainer)
                        .frame(width: 40, height: 40)
                        .background(theme.secondaryContainer, in: Circle())
                    Text(preset.displayName)
                        .pixlFont(.bodyLarge, weight: .medium)
                        .foregroundStyle(theme.onSurface)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            iconButton(isPinned ? "star.fill" : "star", color: isPinned ? theme.primary : theme.onSurfaceVariant,
                       label: isPinned ? L10n.equalizerPresetsCdUnpin : L10n.equalizerPresetsCdPin) {
                model.togglePin(preset.name)
            }
            iconButton("pencil", color: theme.onSurfaceVariant, label: L10n.equalizerPresetsCdRename) {
                nameDraft = preset.displayName
                renameTarget = preset
            }
            iconButton("trash", color: theme.error, label: L10n.equalizerPresetsCdDelete) {
                model.deleteCustomPreset(preset)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func iconButton(_ symbol: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - Manage presets (Android `ReorderPresetsSheet`, a full-screen dialog)

private struct ReorderPresetsView: View {
    let model: EqualizerModel

    private struct Item: Identifiable, Equatable {
        let preset: EqualizerPreset
        var isPinned: Bool
        var id: String { preset.name }
    }

    @State private var items: [Item] = []
    @State private var showsReset = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    GlassCircleButton(systemImage: "xmark", accessibilityLabel: LocalizedStringKey(L10n.commonClose),
                                      tint: theme.surfaceContainerLowest.opacity(GlassTint.surface)) { dismiss() }
                    Spacer()
                    Text(L10n.equalizerManagePresetsTitle)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(theme.onSurface)
                    Spacer()
                    GlassCircleButton(systemImage: "arrow.counterclockwise",
                                      accessibilityLabel: LocalizedStringKey(L10n.equalizerCdResetPresetsDefault),
                                      tint: theme.errorContainer.opacity(0.6), foreground: theme.error) {
                        showsReset = true
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 64)
                Text(L10n.equalizerPresetsDragHint)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.horizontal, 18)
                List {
                    ForEach($items) { $item in
                        row($item)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 8))
                            .moveDisabled(!item.isPinned)
                    }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                    Color.clear.frame(height: 90).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
            }
            Button {
                model.setPinnedOrder(items.filter(\.isPinned).map(\.preset.name))
                dismiss()
            } label: {
                Label(L10n.commonDone, systemImage: "checkmark")
                    .pixlFont(.labelLarge, weight: .semibold)
                    .foregroundStyle(theme.onPrimaryContainer)
                    .padding(.horizontal, 24)
                    .frame(height: 56)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pixlGlass(in: Capsule(), tint: theme.primaryContainer.opacity(GlassTint.prominent), interactive: true)
            .padding(.trailing, 28)
            .padding(.bottom, 16)
            .accessibilityIdentifier("eq.reorder.done")
        }
        .background(theme.surfaceContainerLow.ignoresSafeArea())
        .onAppear(perform: load)
        .alert(L10n.equalizerResetPresetsTitle, isPresented: $showsReset) {
            Button(L10n.commonCancel, role: .cancel) {}
            Button(L10n.commonReset, role: .destructive) {
                model.resetPinnedToDefault()
                dismiss()
            }
        } message: {
            Text(L10n.equalizerResetPresetsMessage)
        }
    }

    private func load() {
        let all = model.allAvailablePresets
        let pinned = model.pinnedNames
        let pinnedItems = pinned.compactMap { name in
            all.first { $0.name == name }.map { Item(preset: $0, isPinned: true) }
        }
        let rest = all.filter { !pinned.contains($0.name) }.map { Item(preset: $0, isPinned: false) }
        items = pinnedItems + rest
    }

    private func row(_ item: Binding<Item>) -> some View {
        let pinned = item.wrappedValue.isPinned
        return HStack(spacing: 14) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(pinned ? theme.onSurfaceVariant : theme.outline.opacity(0.5))
                .frame(width: 32, height: 32)
                .background(pinned ? theme.surfaceContainerHighest : theme.surfaceContainerLow, in: Circle())
                .accessibilityLabel(L10n.equalizerCdReorder)
            Text(item.wrappedValue.preset.displayName)
                .pixlFont(.bodyLarge, weight: pinned ? .medium : .regular)
                .foregroundStyle(pinned ? theme.onSurface : theme.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(PixlMotion.state) { item.wrappedValue.isPinned.toggle() }
            } label: {
                Image(systemName: pinned ? "eye" : "eye.slash")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(pinned ? theme.primary : theme.onSurfaceVariant)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(pinned ? L10n.equalizerCdVisible : L10n.equalizerCdHidden)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                   tint: (pinned ? theme.surfaceContainer : theme.surfaceContainerLowest).opacity(SettingsTint.row))
    }
}
