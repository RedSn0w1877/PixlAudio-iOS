import AuthenticationServices
import PixlNet
import SwiftUI

/// The devices sheet's "Spotify Connect" section (shared spec with Android): the account's Connect devices from
/// `GET /me/player/devices` as the sheet's glass device rows — name, an SF Symbol for the device type, whether it is
/// active — with a refresh circle (and pull to refresh on the page). Tapping one plays PixlAudio's queue there; while
/// one plays, "Stop playing on <device>" brings it back to this phone. Shown only while Spotify is linked; a login
/// from before Connect's scopes gets the reconnect row instead of the list.
struct SpotifyConnectSection: View {
    let connect: SpotifyConnectController

    @Environment(\.appTheme) private var theme
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch connect.availability {
            case .needsReconnect:
                reconnectRow
            case .ready, .notLinked:
                if let active = connect.active {
                    stopRow(active)
                }
                ForEach(connect.devices) { device in
                    deviceButton(device)
                }
                if connect.devices.isEmpty, connect.hasLoadedDevices {
                    emptyHint
                }
                if let error = connect.deviceListError {
                    Text(error)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.error)
                        .padding(.horizontal, 4)
                }
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: connect.devices)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: connect.active)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("devices.spotifyConnect")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spotify Connect")
                    .pixlFont(.titleMedium, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                Text(connect.isRefreshing ? "Looking for devices…" : "Play on speakers signed in to your Spotify")
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .padding(.horizontal, 4)
            Spacer()
            Button {
                Task { await connect.refreshDevices() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.onSurface)
                    .frame(width: 40, height: 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(connect.isRefreshing || connect.availability != .ready)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                       tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), interactive: true)
            .accessibilityLabel("Refresh Spotify devices")
            .accessibilityIdentifier("spotifyConnect.refresh")
        }
    }

    private func deviceButton(_ device: SpotifyConnectDevice) -> some View {
        let isPlayingHere = connect.active?.id == device.deviceId
        let isConnecting = connect.connectingDeviceId == device.deviceId
        return Button {
            connect.connect(to: device)
        } label: {
            DeviceRow(name: device.name, status: status(device, playingHere: isPlayingHere, connecting: isConnecting),
                      systemImage: device.symbolName, selected: isPlayingHere,
                      badgeImage: badgeImage(device, playingHere: isPlayingHere, connecting: isConnecting),
                      dimmed: !device.isControllable)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!device.isControllable || connect.connectingDeviceId != nil)
        .accessibilityHint(device.isControllable ? "Plays your queue on this device" : "")
        .accessibilityIdentifier("spotifyConnect.device.\(device.deviceId ?? device.name)")
    }

    private func status(_ device: SpotifyConnectDevice, playingHere: Bool, connecting: Bool) -> LocalizedStringKey {
        if connecting { return "Connecting…" }
        if playingHere { return "Playing here" }
        if device.deviceId == nil { return "Unavailable" }
        if device.isRestricted { return "Can't be controlled" }
        if device.isActive { return "Active in Spotify" }
        return "Available"
    }

    private func badgeImage(_ device: SpotifyConnectDevice, playingHere: Bool, connecting: Bool) -> String {
        if connecting { return "ellipsis" }
        if playingHere { return "speaker.wave.2.fill" }
        if !device.isControllable { return "nosign" }
        if device.isActive { return "dot.radiowaves.left.and.right" }
        return "wifi"
    }

    private func stopRow(_ active: SpotifyConnectController.ActiveDevice) -> some View {
        Button {
            connect.disconnect()
        } label: {
            DeviceRow(name: String(localized: "Stop playing on \(active.name)"), status: "Back to this phone",
                      systemImage: "stop.circle", selected: false, badgeImage: "iphone")
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("spotifyConnect.stop")
    }

    private var reconnectRow: some View {
        Button {
            Task { await connect.reconnect(authenticate: authenticate) }
        } label: {
            DeviceRow(name: String(localized: "Reconnect Spotify to use Connect"), status: "Sign in again once",
                      systemImage: "arrow.triangle.2.circlepath", selected: false, badgeImage: "person.crop.circle")
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Your Spotify login is from before PixlAudio could control speakers")
        .accessibilityIdentifier("spotifyConnect.reconnect")
    }

    /// Android `EmptyDeviceState`, with the Connect hint.
    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "hifispeaker.2")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(theme.primary)
            Text("No Spotify devices found")
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Text("Devices appear when they're online and signed in to your Spotify. For an Echo, link Spotify in the Alexa app.")
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                   tint: theme.surfaceContainer.opacity(GlassTint.surface))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("spotifyConnect.empty")
    }

    private func authenticate(_ url: URL) async throws -> URL {
        try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: SpotifyAuth.redirectScheme,
                                                        preferredBrowserSession: .shared)
    }
}

/// The Connect device's volume in the devices sheet's hero (instead of the phone's): a slider while the device
/// takes volume commands (`supports_volume`), a note otherwise.
struct SpotifyConnectVolume: View {
    let device: SpotifyConnectController.ActiveDevice
    let tint: Color

    @State private var level: Double = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(device.name) volume")
                    .pixlFont(.titleSmall)
                    .lineLimit(1)
                Spacer()
                if device.supportsVolume {
                    Text("\(Int(level.rounded()))%")
                        .pixlFont(.labelMedium)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(tint)
            if device.supportsVolume {
                SpotifyConnectVolumeSlider(level: $level, label: Text("\(device.name) volume"), tint: tint)
                    .frame(height: 34)
            } else {
                Text("This device sets its own volume")
                    .pixlFont(.bodySmall)
                    .foregroundStyle(tint.opacity(0.8))
            }
        }
    }
}

/// The Connect device's volume as a slider (the devices sheet's hero, the Equalizer's volume card). It follows the
/// device — polls, the volume buttons, the other slider — except under the user's finger, and sends on release
/// (`SpotifyConnectController.setVolume`, throttled there). A VoiceOver adjustment is sent as it happens.
struct SpotifyConnectVolumeSlider: View {
    @Binding var level: Double
    let label: Text
    let tint: Color
    var identifier = "spotifyConnect.volume"

    @Environment(AppEnvironment.self) private var env
    @State private var isEditing = false
    /// The last value taken from the device (a change to anything else came from the user).
    @State private var synced: Double?

    var body: some View {
        Slider(value: $level, in: 0...100, step: 1, onEditingChanged: { editing in
            isEditing = editing
            if !editing { send(level) }
        })
        .tint(tint)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .onAppear { follow(env.spotifyConnect.volumePercent) }
        .onChange(of: env.spotifyConnect.volumePercent) { _, newValue in
            if !isEditing { follow(newValue) }
        }
        .onChange(of: level) { _, newValue in
            if !isEditing, let synced, newValue != synced { send(newValue) }
        }
    }

    private func follow(_ percent: Int?) {
        let value = Double(percent ?? 50)
        synced = value
        if level != value { level = value }
    }

    private func send(_ value: Double) {
        synced = value
        env.spotifyConnect.setVolume(Int(value.rounded()))
    }
}
