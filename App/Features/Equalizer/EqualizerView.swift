import AVFoundation
import MediaPlayer
import PixlAudioCore
import PixlModel
import SwiftUI
import UIKit

/// Equalizer (Android `EqualizerScreen`): the collapsing "Equalizer" header with the view-mode and power circles,
/// the preset tabs (pinned built-in presets, "Custom", and the "Edit" tab), the band card (preset chip + save /
/// update chips over the sliders, the graph or the hybrid view), the three effect cards (bass boost, virtualizer,
/// loudness — the loudness gain is the chain's preamp) and the volume card. Rows 6 pt apart.
///
/// iOS: every effect is our own DSP (PixlAudioCore), so the "not supported on this device" cards never show; the
/// volume card hosts the system volume slider (`MPVolumeView` — apps can't set the system volume themselves).
struct EqualizerView: View {
    var screenID = "equalizer"

    @Environment(SettingsStore.self) private var settings
    @State private var model: EqualizerModel?

    var body: some View {
        Group {
            if let model {
                EqualizerContent(model: model, screenID: screenID)
            } else {
                Color.clear
            }
        }
        .onAppear { if model == nil { model = EqualizerModel(prefs: settings.equalizer) } }
    }
}

private struct EqualizerContent: View {
    let model: EqualizerModel
    let screenID: String

    @State private var showsCustomPresets = false
    @State private var showsReorder = false
    @State private var showsSave = false
    @State private var renameTarget: EqualizerPreset?
    @State private var nameDraft = ""
    @State private var appeared = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        let prefs = model.prefs
        SettingsScaffold(title: L10n.settingsCategoryEqualizerTitle, screenID: screenID, collapsedTitleLeading: 72,
                         horizontalPadding: 0, spacing: 6) {
            GlassCircleButton(systemImage: model.viewMode.systemImage,
                              accessibilityLabel: LocalizedStringKey(L10n.equalizerChangeViewModeCd),
                              tint: theme.surfaceContainerLow.opacity(GlassTint.surface)) {
                withAnimation(PixlMotion.state) { model.cycleViewMode() }
            }
            .accessibilityIdentifier("eq.viewMode")
            Spacer().frame(width: 12)
            // Android's power toggle: a filled `primary` circle when on, a 12 % rounded square when off.
            EqualizerPowerButton(isOn: prefs.isEnabled) { withAnimation(PixlMotion.selection) { model.toggleEnabled() } }
            Spacer().frame(width: 12)
        } content: {
            PresetTabsRow(model: model) { showsReorder = true }
            EqualizerBandCard(model: model,
                              onSave: { nameDraft = ""; showsSave = true },
                              onUpdate: { if let name = model.editingPresetName { model.updateCustomPresetBands(name) } },
                              onPresetsList: { showsCustomPresets = true })
            EqualizerEffectsRow(prefs: prefs)
            EqualizerVolumeCard()
            Spacer().frame(height: 4)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 40)
        .onAppear { withAnimation(.easeOut(duration: 0.4)) { appeared = true } }
        .alert(L10n.equalizerPresetsSaveCustomTitle, isPresented: $showsSave) {
            TextField(L10n.equalizerPresetNamePlaceholder, text: $nameDraft)
            Button(L10n.commonCancel, role: .cancel) {}
            Button(L10n.commonSave) {
                let name = nameDraft.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.saveCurrentAsCustomPreset(name) }
            }
            .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text(L10n.equalizerPresetsSaveCustomBody)
        }
        .alert(L10n.equalizerPresetsRenameTitle, isPresented: Binding(
            get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField(L10n.equalizerPresetNamePlaceholder, text: $nameDraft)
            Button(L10n.commonCancel, role: .cancel) {}
            Button(L10n.equalizerActionRename) {
                if let target = renameTarget { model.renameCustomPreset(target.name, to: nameDraft) }
            }
            .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .sheet(isPresented: $showsCustomPresets) {
            CustomPresetsSheet(model: model) { preset in
                nameDraft = preset.displayName
                renameTarget = preset
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showsReorder) {
            ReorderPresetsView(model: model)
        }
    }
}

/// Android's `FilledIconToggleButton` power button: corners animate from 12 % (off) to a circle (on); on = `primary`.
private struct EqualizerPowerButton: View {
    let isOn: Bool
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: isOn ? 20 : 40 * 0.12, style: .continuous)
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isOn ? theme.onPrimary : theme.onSurface)
                .frame(width: 40, height: 40)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: isOn ? theme.primary.opacity(GlassTint.prominent)
                                         : theme.surfaceContainerLow.opacity(GlassTint.surface), interactive: true)
        .accessibilityLabel(isOn ? L10n.equalizerDisableCd : L10n.equalizerEnableCd)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("eq.power")
        .pixlHaptic(.impact(weight: .medium), trigger: isOn)
    }
}

/// Android `PresetTabsRow`: a scrollable row of capsules (pinned built-in presets, then "Custom" with a star) and an
/// unselectable "Edit" capsule that opens Manage presets.
private struct PresetTabsRow: View {
    let model: EqualizerModel
    let onEdit: () -> Void

    var body: some View {
        let presets = model.tabPresets
        let current = model.currentPreset
        let selected = (current.isCustom || current.name == "custom") ? "custom"
            : (presets.first { $0.name == current.name }?.name ?? presets.first?.name ?? "flat")
        GlassPillRow(items: presets.map { GlassPillRow<String>.Item(id: $0.name, title: $0.displayName,
                                                                    systemImage: $0.isCustom ? "star.fill" : nil) },
                     selection: Binding(get: { selected }, set: { name in
                         if let preset = presets.first(where: { $0.name == name }) { model.select(preset) }
                     }),
                     uppercase: false, edgePadding: 12, accessibilityIdentifierPrefix: "eq.preset",
                     accessory: .init(systemImage: "pencil", accessibilityLabel: L10n.equalizerEditPresetsCd,
                                     action: onEdit))
            .frame(height: 56)
    }
}

/// Android `BandSlidersSection`: a 24 pt card (here glass) with the preset chips and the sliders for the view mode.
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
        let enabled = prefs.isEnabled
        VStack(spacing: 0) {
            chips
            Spacer().frame(height: 10)
            switch model.viewMode {
            case .graph:
                EqualizerGraphSliders(levels: levels, enabled: enabled) { model.setBandLevel($0, $1) }
            case .hybrid:
                EqualizerHybridSliders(levels: levels, enabled: enabled, settings: prefs.engineSettings) {
                    model.setBandLevel($0, $1)
                }
            case .sliders:
                TabView(selection: $page) {
                    ForEach(0..<2, id: \.self) { pageIndex in
                        HStack(spacing: 0) {
                            ForEach(pageIndex * 5..<min(pageIndex * 5 + 5, levels.count), id: \.self) { index in
                                Spacer(minLength: 0)
                                EqualizerBandColumn(frequency: EqualizerPreset.bandFrequencies[index],
                                                    level: levels[index], enabled: enabled) {
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
                Spacer().frame(height: 16)
                HStack(spacing: 0) {
                    ForEach(0..<2, id: \.self) { index in
                        Circle()
                            .fill(page == index ? theme.primary : theme.surfaceContainerHighest)
                            .frame(width: page == index ? 10 : 8, height: page == index ? 10 : 8)
                            .padding(4)
                    }
                }
                .animation(PixlMotion.selection, value: page)
                .accessibilityElement()
                .accessibilityLabel(L10n.equalizerPageN(page + 1))
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(SettingsTint.row))
        .padding(.horizontal, 16)
    }

    private var chips: some View {
        let current = model.currentPreset
        let editing = model.editingPresetName
        let isCustomOrSaved = editing != nil || current.name == "custom" || current.isCustom
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button(action: onPresetsList) {
                    HStack(spacing: 8) {
                        Text(editing ?? current.displayName)
                            .pixlFont(.labelLarge, weight: .bold)
                        if isCustomOrSaved {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 14, weight: .bold))
                                .accessibilityLabel(L10n.equalizerPresetsCd)
                        }
                    }
                    .foregroundStyle(theme.onSecondaryContainer)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(theme.secondaryContainer, in: Capsule())
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
                .disabled(!isCustomOrSaved)
                .accessibilityIdentifier("eq.presetChip")
                if current.name == "custom" && editing == nil {
                    chip(L10n.commonSave, fill: theme.tertiaryContainer, content: theme.onTertiaryContainer,
                         id: "eq.save", action: onSave)
                }
                if editing != nil {
                    chip(L10n.equalizerActionUpdate, fill: theme.primaryContainer, content: theme.onPrimaryContainer,
                         id: "eq.update", action: onUpdate)
                    chip(L10n.equalizerActionSaveNew, fill: theme.tertiaryContainer, content: theme.onTertiaryContainer,
                         id: "eq.saveNew", action: onSave)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity)
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
            .padding(.vertical, 8)
            .background(fill, in: Capsule())
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
        .accessibilityIdentifier(id)
    }
}

/// Android `EffectControlsSection`: the 150 pt effect cards side by side, scrolling horizontally.
private struct EqualizerEffectsRow: View {
    let prefs: EqualizerPreferences

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                EqualizerEffectCard(title: L10n.equalizerBassBoost, value: prefs.bassBoostStrength,
                                    isEnabled: prefs.bassBoostEnabled,
                                    onValue: { prefs.bassBoostStrength = $0 },
                                    onEnabled: { prefs.bassBoostEnabled = $0 })
                EqualizerEffectCard(title: L10n.equalizerVirtualizer, value: prefs.virtualizerStrength,
                                    isEnabled: prefs.virtualizerEnabled,
                                    onValue: { prefs.virtualizerStrength = $0 },
                                    onEnabled: { prefs.virtualizerEnabled = $0 })
                EqualizerEffectCard(title: L10n.equalizerLoudness, value: prefs.loudnessEnhancerStrength,
                                    isEnabled: prefs.loudnessEnhancerEnabled,
                                    onValue: { prefs.loudnessEnhancerStrength = $0 },
                                    onEnabled: { prefs.loudnessEnhancerEnabled = $0 })
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollClipDisabled()
    }
}

/// Android `EffectCard`: the wavy arc slider with the percentage inside, a switch (0.8×) and the title.
private struct EqualizerEffectCard: View {
    let title: String
    let value: Int
    let isEnabled: Bool
    let onValue: (Int) -> Void
    let onEnabled: (Bool) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let percent = value * 100 / EqualizerBands.maxStrength
        VStack(spacing: 4) {
            ZStack {
                WavyArcSlider(value: value, enabled: isEnabled,
                              activeColor: isEnabled ? theme.primary : theme.onSurfaceVariant.opacity(0.3),
                              inactiveColor: theme.surfaceContainerHighest,
                              thumbColor: isEnabled ? theme.primary : theme.onSurfaceVariant, onChange: onValue)
                    .frame(width: 150, height: 150)
                Text("\(percent)%")
                    .pixlFont(.titleMedium)
                    .foregroundStyle(isEnabled ? theme.onSurface : theme.onSurfaceVariant)
                    .monospacedDigit()
            }
            .offset(y: 5)
            .frame(width: 150, height: 110)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue("\(percent)%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onValue(min(value + 50, EqualizerBands.maxStrength))
                case .decrement: onValue(max(value - 50, 0))
                @unknown default: break
                }
            }
            Toggle(title, isOn: Binding(get: { isEnabled }, set: onEnabled))
                .labelsHidden()
                .tint(theme.primary)
                .scaleEffect(0.8)
            Text(title)
                .pixlFont(.labelLarge)
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
        }
        .padding(12)
        .frame(width: 150)
        .frame(maxHeight: .infinity, alignment: .top)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(SettingsTint.row))
        .accessibilityIdentifier("eq.effect.\(title)")
    }
}

/// Android `VolumeControlCard`: "Volume", the speaker icon, the system volume slider and the percentage.
private struct EqualizerVolumeCard: View {
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
    let onRename: (EqualizerPreset) -> Void

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
                onRename(preset)
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
