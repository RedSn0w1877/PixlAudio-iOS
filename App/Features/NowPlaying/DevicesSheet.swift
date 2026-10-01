import AVKit
import MediaPlayer
import SwiftUI

/// "AirPlay & devices" — Android `CastBottomSheet` in the same layout, built around the system route picker: Cast
/// doesn't exist on iOS, and apps can neither list nor connect AirPlay / Bluetooth devices themselves, so every
/// "connect" control here opens `AVRoutePickerView`.
/// - "Connect device" title capsule (+ "Scanning nearby" while route detection runs);
/// - CONTROLS: the active output hero (42/20 pt corners, `tertiaryContainer`) with the output's name, status and the
///   phone volume (the system volume slider — apps can't set the volume), then "Connectivity": AirPlay and Bluetooth
///   tiles (72 pt; the icon circle fills with `primary` when that kind of output is active);
/// - DEVICES: "Nearby devices", the current output (selected, `primaryContainer`) and "AirPlay & Bluetooth" rows, or
///   the searching state when no other output is around;
/// - the CONTROLS / DEVICES tab capsule at the bottom (as in the song sheet).
struct DevicesSheet: View {
    @Environment(PlaybackStore.self) private var playback
    @Environment(\.appTheme) private var theme

    @State private var page = 0
    @State private var volume = SystemVolumeObserver()

    private var route: AudioRouteMonitor { AudioRouteMonitor.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Connect device")
                    .pixlFont(.headlineMedium, weight: .semibold)
                    .foregroundStyle(theme.onSurface)
                    .padding(.leading, 6)
                    .padding(.trailing, 8)
                if route.hasOtherRoutes == false {
                    badge("Scanning nearby", systemImage: "arrow.clockwise", color: theme.primary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            Spacer().frame(height: 8)
            ZStack(alignment: .top) {
                if page == 0 {
                    ScrollView { controlsPage }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    ScrollView { devicesPage }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: page)
            .frame(maxHeight: .infinity, alignment: .top)
            tabBar
        }
        .onAppear {
            volume.start()
            route.setDetecting(true)
        }
        .onDisappear {
            volume.stop()
            route.setDetecting(false)
        }
        .accessibilityIdentifier("screen.devices")
    }

    // MARK: Controls

    private var controlsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            hero
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connectivity")
                            .pixlFont(.titleMedium, weight: .bold)
                            .foregroundStyle(theme.onSurface)
                        Text("Choose where your music plays")
                            .pixlFont(.bodySmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                    Spacer()
                    pickerCircle
                }
                HStack(spacing: 12) {
                    tile(label: route.kind == .airPlay ? route.name : "AirPlay",
                         subtitle: route.kind == .airPlay ? "Connected" : (route.hasOtherRoutes ? "Available" : "Off"),
                         systemImage: "airplayaudio", isActive: route.kind == .airPlay)
                    tile(label: route.kind == .bluetooth ? route.name : "Bluetooth",
                         subtitle: route.kind == .bluetooth ? "Connected" : "Not connected",
                         systemImage: "headphones", isActive: route.kind == .bluetooth)
                }
            }
            Spacer().frame(height: 20)
        }
        .padding(.horizontal, 20)
    }

    /// Android `ActiveDeviceHero`.
    private var hero: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 42, bottomLeadingRadius: 20, bottomTrailingRadius: 42,
                                           topTrailingRadius: 20, style: .continuous)
        let on = theme.onTertiaryContainer
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: route.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(on)
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(on.opacity(0.12)))
                VStack(alignment: .leading, spacing: 8) {
                    Text(outputTitle)
                        .pixlFont(.titleLarge, weight: .bold)
                        .foregroundStyle(on)
                        .lineLimit(2)
                    Text("\(outputSubtitle) \u{2022} \(playback.isPlaying ? "Playing" : "Paused")")
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(on)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Phone volume")
                        .pixlFont(.titleSmall)
                    Spacer()
                    Text("\(Int((volume.level * 100).rounded()))%")
                        .pixlFont(.labelMedium)
                        .monospacedDigit()
                }
                .foregroundStyle(on)
                DeviceVolumeSlider(tint: on)
                    .frame(height: 34)
            }
        }
        .padding(20)
        .pixlGlass(in: shape, tint: theme.tertiaryContainer.opacity(GlassTint.prominent))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("devices.hero")
    }

    private var outputTitle: String {
        switch route.kind {
        case .phone: String(localized: "This phone")
        default: route.name.isEmpty ? String(localized: "This phone") : route.name
        }
    }

    private var outputSubtitle: String {
        switch route.kind {
        case .phone: String(localized: "Local playback")
        case .headphones: String(localized: "Headphones")
        case .bluetooth: String(localized: "Bluetooth audio")
        case .airPlay: String(localized: "AirPlay")
        case .carAudio: String(localized: "Car audio")
        case .other: String(localized: "Audio output")
        }
    }

    /// Android `QuickSettingTile`; opens the system route picker.
    private func tile(label: String, subtitle: String, systemImage: String, isActive: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: isActive ? 18 : 36, style: .continuous)
        return HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isActive ? theme.onPrimary : theme.onSurface)
                .frame(width: 40, height: 40)
                .background(Circle().fill(isActive ? theme.primary : theme.onSurface.opacity(0.1)))
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .pixlFont(.titleSmall, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Text(subtitle)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurface.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .pixlGlass(in: shape, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), interactive: true)
        .overlay { AirPlayRoutePicker(tint: .clear, activeTint: .clear) }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isActive)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the output picker")
    }

    /// The system route button (Android's refresh circle): opens the picker.
    private var pickerCircle: some View {
        AirPlayRoutePicker(tint: theme.onSurface, activeTint: theme.primary)
            .frame(width: 40, height: 40)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                       tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), interactive: true)
            .accessibilityLabel("Choose output")
    }

    // MARK: Devices

    private var devicesPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nearby devices")
                        .pixlFont(.titleMedium, weight: .bold)
                        .foregroundStyle(theme.onSurface)
                    Text(route.hasOtherRoutes ? "Tap to connect" : "No devices yet")
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                .padding(.horizontal, 4)
                Spacer()
                pickerCircle
            }
            deviceRow(name: outputTitle, status: "Connected", systemImage: route.systemImage, selected: true)
            if route.hasOtherRoutes {
                deviceRow(name: String(localized: "AirPlay & Bluetooth"), status: "Available",
                          systemImage: "airplayaudio", selected: false)
                    .overlay { AirPlayRoutePicker(tint: .clear, activeTint: .clear) }
            } else {
                emptyState
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    /// Android `CastDeviceRow`: a capsule with a 52 pt icon circle, the name and a status badge.
    private func deviceRow(name: String, status: LocalizedStringKey, systemImage: String, selected: Bool) -> some View {
        let container = selected ? theme.primaryContainer : theme.surfaceVariant
        let on = selected ? theme.onPrimaryContainer : theme.onSurface
        return HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(on)
                .frame(width: 48, height: 48)
                .background(Circle().fill(on.opacity(0.12)))
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .pixlFont(.titleMedium, weight: .semibold)
                    .foregroundStyle(on)
                    .lineLimit(1)
                badge(status, systemImage: selected ? "checkmark.circle.fill" : "wifi", color: on)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .pixlGlass(in: Capsule(), tint: container.opacity(selected ? GlassTint.prominent : GlassTint.container),
                   interactive: !selected)
    }

    /// Android `EmptyDeviceState`.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "hifispeaker.2")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(theme.primary)
            Text("Searching for devices…")
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Text("Make sure your TV or speaker is on and sharing the same Wi‑Fi network.")
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                   tint: theme.surfaceContainer.opacity(GlassTint.surface))
    }

    /// Android `BadgeChip`.
    private func badge(_ text: LocalizedStringKey, systemImage: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
            Text(text).pixlFont(.labelMedium).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.08)))
    }

    // MARK: Tabs

    private var tabBar: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 0) {
                tab(0, title: "CONTROLS", systemImage: "hifispeaker.fill")
                tab(1, title: "DEVICES", systemImage: "laptopcomputer.and.iphone")
            }
            .padding(5)
        }
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.container))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .sensoryFeedback(.selection, trigger: page)
    }

    private func tab(_ index: Int, title: LocalizedStringKey, systemImage: String) -> some View {
        let selected = page == index
        return Button {
            withAnimation(PixlMotion.selection) { page = index }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
                Text(title).pixlFont(.labelLarge, weight: .bold).lineLimit(1)
            }
            .foregroundStyle(selected ? theme.onPrimary : theme.onSurface.opacity(0.9))
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background {
            if selected { Capsule().fill(theme.primary) }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("devices.tab.\(index)")
    }
}

/// The system volume slider (`MPVolumeView`) in the output hero.
private struct DeviceVolumeSlider: UIViewRepresentable {
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
