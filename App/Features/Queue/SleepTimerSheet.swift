import PixlAudioCore
import SwiftUI

/// The sleep timer (Android `TimerOptionsBottomSheet`), driving `SleepTimerController` (PixlAudioCore's
/// `SleepTimer`):
/// - "Sleep timer" title capsule (`headlineMedium`, `primary`);
/// - the duration slider over Android's stops (Off, 5, 10, 15, 20, 30, 45, 60 min), committed on release;
/// - "Play count: N times" (1…10): pauses after the current song has played that many more times;
/// - "End of current track" (the row fills with `tertiary` and squares its corners when on);
/// - Custom time (hours + minutes wheels) and Cancel timer.
/// The two sliders exclude each other as on Android: one is enabled while the other rests at its first stop.
/// Material's slider/switch become the system controls; the surfaces are glass.
struct SleepTimerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var timerPosition: Double = 0
    @State private var counterPosition: Double = 1
    @State private var isTimerMode = true
    @State private var showsCustomTime = false
    @State private var contentHeight: CGFloat?

    private static let stops = SleepTimer.predefinedMinutes

    /// The sheet's height only changes with Dynamic Type ("Cancel timer" is always laid out, only disabled).
    private var heightKey: String { "sleepTimer|\(dynamicTypeSize)" }

    private var timer: SleepTimerController { env.sleepTimer }

    var body: some View {
        let state = timer.state
        let eotOn = state.isEndOfTrackActive
        ScrollView {
            // The six glass surfaces render together (performance rule). The gaps are 6–24 pt, above the 4 pt
            // spacing, so nothing blends at rest; the VStack inside keeps its padding and measuring, so the fitted
            // detent measures the same height.
            GlassEffectContainer(spacing: 4) {
                VStack(spacing: 0) {
                    Text("Sleep timer")
                        .pixlFont(.headlineMedium)
                        .foregroundStyle(theme.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerLowest.opacity(GlassTint.container))
                    Spacer().frame(height: 24)
                    sliderGroup(label: timerLabel) {
                        Slider(value: $timerPosition, in: 0...Double(Self.stops.count - 1), step: 1,
                               onEditingChanged: { editing in
                                   if editing { isTimerMode = true } else { commitTimer() }
                               })
                        .disabled(!(isTimerMode || counterPosition == 1))
                        .accessibilityIdentifier("sleepTimer.duration")
                    }
                    Spacer().frame(height: 16)
                    sliderGroup(label: counterLabel) {
                        Slider(value: $counterPosition, in: 1...10, step: 1,
                               onEditingChanged: { editing in
                                   if editing { isTimerMode = false } else { commitCounter() }
                               })
                        .disabled(!(!isTimerMode || timerPosition == 0))
                        .accessibilityIdentifier("sleepTimer.count")
                    }
                    Spacer().frame(height: 16)
                    endOfTrackRow(isOn: eotOn)
                    buttons(state: state)
                        .padding(.vertical, 16)
                        .padding(.horizontal, 6)
                    Spacer().frame(height: 16)
                }
                .padding(.horizontal, 18)
                .padding(.top, 28)
                .measuringHeight($contentHeight, rememberedAs: heightKey)
            }
        }
        .fittedSheetDetent(contentHeight ?? FittedSheetHeights.values[heightKey])
        .tint(theme.primary)
        .onAppear(perform: syncFromState)
        .onChange(of: timer.toastMessage) { _, message in
            guard let message else { return }
            LibraryToast.shared.show(message)
            timer.clearToast()
        }
        .sheet(isPresented: $showsCustomTime) {
            CustomTimerDurationSheet { minutes in
                timer.setDuration(minutes: minutes)
                showsCustomTime = false
                dismiss()
            }
            .presentationDetents([.height(340)])
            .presentationDragIndicator(.visible)
        }
        .libraryToast()
        .accessibilityIdentifier("screen.sleepTimer")
    }

    private var timerLabel: String {
        let minutes = Self.stops[min(max(Int(timerPosition.rounded()), 0), Self.stops.count - 1)]
        return minutes == 0 ? String(localized: "Timer") : String(localized: "\(minutes) minutes")
    }

    private var counterLabel: String {
        let count = Int(counterPosition)
        let times = count == 1 ? String(localized: "1 time") : String(localized: "\(count) times")
        return String(localized: "Play count: \(times)")
    }

    private func sliderGroup<Content: View>(label: String, @ViewBuilder slider: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .pixlFont(.labelMedium)
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.leading, 16)
                .padding(.bottom, 8)
            slider()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .pixlGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                           tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
        }
    }

    private func endOfTrackRow(isOn: Bool) -> some View {
        let enabled = isTimerMode || counterPosition == 1
        let shape = RoundedRectangle(cornerRadius: isOn ? 18 : 30, style: .continuous)
        return HStack {
            Text("End of current track")
                .pixlFont(.bodyLarge)
                .foregroundStyle(isOn ? theme.onTertiary : theme.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            Toggle("End of current track", isOn: Binding(get: { isOn }, set: { timer.setEndOfTrack($0) }))
                .labelsHidden()
                .tint(theme.tertiaryContainer)
                .disabled(!enabled)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .frame(minHeight: 60)
        .contentShape(shape)
        .onTapGesture { if enabled { timer.setEndOfTrack(!isOn) } }
        .pixlGlass(in: shape, tint: (isOn ? theme.tertiary : theme.surfaceContainerHigh)
            .opacity(isOn ? GlassTint.prominent : GlassTint.surface), interactive: enabled)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isOn)
        .accessibilityIdentifier("sleepTimer.endOfTrack")
    }

    private func buttons(state: SleepTimer) -> some View {
        let canCancel = state.display != nil || counterPosition != 1
        return HStack(spacing: 6) {
            Button { showsCustomTime = true } label: {
                Text("Custom time")
                    .pixlFont(.labelLarge)
                    .foregroundStyle(theme.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(counterPosition != 1)
            .opacity(counterPosition != 1 ? 0.38 : 1)
            .pixlGlass(in: UnevenRoundedRectangle(topLeadingRadius: 34, bottomLeadingRadius: 34,
                                                  bottomTrailingRadius: 8, topTrailingRadius: 8, style: .continuous),
                       tint: theme.primary.opacity(GlassTint.prominent), interactive: true)
            Button {
                timer.cancel()
                timer.cancelCountedPlay()
                dismiss()
            } label: {
                Text("Cancel timer")
                    .pixlFont(.labelLarge)
                    .foregroundStyle(canCancel ? theme.onErrorContainer : theme.onSurface.opacity(0.38))
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!canCancel)
            .pixlGlass(in: UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8,
                                                  bottomTrailingRadius: 34, topTrailingRadius: 34, style: .continuous),
                       tint: canCancel ? theme.errorContainer.opacity(GlassTint.prominent)
                                       : theme.onSurface.opacity(0.12),
                       interactive: canCancel)
            // Disabled (no timer running) = Android's disabled button: a faint onSurface container, 38 % label.
        }
    }

    // MARK: Commands

    /// Android: the "Off" stop cancels a running duration timer; any other stop sets it.
    private func commitTimer() {
        let minutes = Self.stops[min(max(Int(timerPosition.rounded()), 0), Self.stops.count - 1)]
        if minutes == 0 {
            if timer.state.activeDurationMinutes != nil { timer.cancel() }
        } else {
            timer.setDuration(minutes: minutes)
        }
    }

    /// Android: a counted play replaces the timer and end of track.
    private func commitCounter() {
        timer.cancel()
        timer.setEndOfTrack(false)
        timer.startCountedPlay(Int(counterPosition))
    }

    private func syncFromState() {
        let state = timer.state
        if let minutes = state.activeDurationMinutes, let index = Self.stops.firstIndex(of: minutes) {
            timerPosition = Double(index)
        } else {
            timerPosition = 0
        }
        counterPosition = Double(state.playCount)
        if state.playCount > 1 { isTimerMode = false }
    }
}

extension View {
    /// The timer sheet's presentation. The sheet sizes its own wrap-content detent (`fittedSheetDetent`), as
    /// Android's `TimerOptionsBottomSheet` wraps its content.
    func sleepTimerPresentation() -> some View {
        presentationDragIndicator(.visible)
    }
}

/// Android's custom-duration `TimePicker` dialog (24 h, a duration): hours and minutes wheels, 0 h 15 min to
/// start; OK sets the timer when the total is above zero.
private struct CustomTimerDurationSheet: View {
    let onConfirm: (Int) -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var hours = 0
    @State private var minutes = 15

    var body: some View {
        VStack(spacing: 12) {
            Text("Set custom duration")
                .pixlFont(.titleLarge, weight: .bold)
                .foregroundStyle(theme.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                Picker("Hours", selection: $hours) {
                    ForEach(0..<24, id: \.self) { Text("\($0) h").tag($0) }
                }
                .pickerStyle(.wheel)
                Picker("Minutes", selection: $minutes) {
                    ForEach(0..<60, id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.wheel)
            }
            .frame(height: 160)
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                Button("OK") {
                    let total = hours * 60 + minutes
                    if total > 0 { onConfirm(total) } else { dismiss() }
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(24)
    }
}
