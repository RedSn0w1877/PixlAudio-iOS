import AudioToolbox
import AVFoundation
import Combine
import os
import PixlModel
import SwiftUI
import UIKit

/// Device Capabilities (Android `DeviceCapabilitiesScreen`): the readiness hero (primary or error container, three
/// metric tiles), local music storage, playback path, format compatibility, findings, device info and the
/// performance report — 28 pt cards 12 pt apart, each with a 44 pt status circle and a `titleLarge` semibold title,
/// tiles inside at 18 pt corners. Cards are glass; tiles inside them are fills (no glass on glass).
///
/// iOS adaptation: the values come from AVAudioSession (sample rate, IO buffer, routes), AudioToolbox (installed
/// decoders, hardware or software), `os_proc_available_memory` and the file system. Dropped (no iOS equivalent):
/// the "offload-ready formats" chips and the ExoPlayer engine tile.
struct DeviceCapabilitiesView: View {
    var screenID = "deviceCapabilities"

    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    /// Starts from the last measurement (shown at once; `load` re-measures in the background, as before).
    @State private var model = DeviceCapabilitiesModel(state: ScreenDataCache.deviceCapabilities)
    @State private var toast: String?

    var body: some View {
        SettingsScaffold(title: L10n.settingsCategoryDeviceCapabilitiesTitle, screenID: screenID,
                         expandedHeight: SettingsMetrics.headerExpandedLong, titleMaxLines: 2, spacing: 12) {
            if let state = model.state {
                CapabilitiesReadinessCard(state: state)
                CapabilitiesStorageCard(storage: state.storage)
                CapabilitiesPlaybackPathCard(state: state)
                CapabilitiesFormatsCard(state: state)
                CapabilitiesFindingsCard(state: state)
                CapabilitiesDeviceInfoCard(entries: state.deviceInfo)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
            CapabilitiesReportCard(model: model, experimental: settings.experimental, toast: $toast)
        }
        .settingsToast($toast)
        .task(id: library.songs.count) {
            await model.load(songs: library.songs)
        }
        // Stage 15: follow the live output — plugging in headphones, AirPlay or Bluetooth changes the route and often
        // the hardware sample rate (Android re-reads them on `AudioDeviceCallback`).
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)) { _ in
            Task { await model.load(songs: library.songs) }
        }
    }
}

// MARK: - Model

/// What the screen shows, measured off the main thread.
nonisolated struct DeviceCapabilitiesState: Sendable {
    nonisolated struct Format: Sendable, Identifiable {
        let label: String
        let isDecoderAvailable: Bool
        let isHardwareAccelerated: Bool
        let librarySongCount: Int
        var id: String { label }
    }

    nonisolated struct Route: Sendable, Identifiable {
        let name: String
        let category: Category
        var id: String { name + category.rawValue }

        nonisolated enum Category: String, Sendable { case builtIn, bluetooth, usb, wired, digital, other }
    }

    nonisolated struct Storage: Sendable {
        var localSongCount: Int
        var localMusicBytes: Int64
        var deviceAvailableBytes: Int64
        var deviceTotalBytes: Int64
        var cloudSongCount: Int
        var unavailableLocalFileCount: Int

        var musicFraction: Double { deviceTotalBytes > 0 ? Double(localMusicBytes) / Double(deviceTotalBytes) : 0 }
        var usedFraction: Double {
            deviceTotalBytes > 0 ? Double(deviceTotalBytes - deviceAvailableBytes) / Double(deviceTotalBytes) : 0
        }
    }

    var sampleRate: Int
    var framesPerBuffer: Int
    var ioBufferMs: Double
    var routes: [Route]
    var availableMemory: Int64
    var totalMemory: Int64
    var formats: [Format]
    var storage: Storage
    var supportedSongCount: Int
    var unsupportedSongCount: Int
    var unsupportedFormats: [String]
    var unknownFormatSongCount: Int
    var resampledSongCount: Int
    var maxSampleRate: Int?
    var deviceInfo: [(String, String)]

    var needsReview: Bool { unsupportedSongCount > 0 || resampledSongCount > 0 }
    var hasFindings: Bool { unsupportedSongCount > 0 || unknownFormatSongCount > 0 || resampledSongCount > 0 }
}

@Observable
final class DeviceCapabilitiesModel {
    private(set) var state: DeviceCapabilitiesState?
    private(set) var report: String?

    init(state: DeviceCapabilitiesState? = nil) {
        self.state = state
    }
    private(set) var isGeneratingReport = false
    @ObservationIgnored private var lagMarks: [Date] = []

    func load(songs: [Song]) async {
        let session = AVAudioSession.sharedInstance()
        let sampleRate = Int(session.sampleRate.rounded())
        let ioBuffer = session.ioBufferDuration
        let routes = session.currentRoute.outputs.map {
            DeviceCapabilitiesState.Route(name: $0.portName, category: Self.category($0.portType))
        }
        let device = UIDevice.current
        let info: [(String, String)] = [
            (String(localized: "settings_devcaps_device_info_model", defaultValue: "Model"), Self.machineIdentifier()),
            (String(localized: "settings_devcaps_device_info_device", defaultValue: "Device"), device.model),
            (String(localized: "settings_devcaps_device_info_system", defaultValue: "System"), device.systemName),
            (String(localized: "settings_devcaps_device_info_system_version", defaultValue: "System Version"),
             device.systemVersion),
            (String(localized: "settings_devcaps_device_info_app_version", defaultValue: "App Version"),
             AppInfo.versionString),
            (String(localized: "settings_devcaps_device_info_cores", defaultValue: "CPU Cores"),
             "\(ProcessInfo.processInfo.activeProcessorCount)"),
        ]
        let measured = await Task.detached(priority: .utility) {
            Self.measure(songs: songs, sampleRate: sampleRate, ioBuffer: ioBuffer, routes: routes, info: info)
        }.value
        state = measured
        ScreenDataCache.deviceCapabilities = measured
    }

    func markLag() { lagMarks.append(Date()) }

    func generateReport() async {
        guard let state else { return }
        isGeneratingReport = true
        let marks = lagMarks
        report = await Task.detached(priority: .utility) { Self.report(state, lagMarks: marks) }.value
        isGeneratingReport = false
    }

    // MARK: Measuring (off the main actor)

    /// The formats the port can decode, with the AudioToolbox format each needs (`nil` = PCM, always available).
    nonisolated private static let knownFormats: [(label: String, formatID: AudioFormatID?, extensions: [String],
                                                   mimes: [String])] = [
        ("MP3", kAudioFormatMPEGLayer3, ["mp3"], ["audio/mpeg", "audio/mp3"]),
        ("AAC", kAudioFormatMPEG4AAC, ["m4a", "aac", "mp4"], ["audio/mp4", "audio/aac", "audio/x-m4a", "audio/mp4a-latm"]),
        ("ALAC", kAudioFormatAppleLossless, ["alac"], ["audio/alac"]),
        ("FLAC", kAudioFormatFLAC, ["flac"], ["audio/flac", "audio/x-flac"]),
        ("Opus", kAudioFormatOpus, ["opus"], ["audio/opus"]),
        ("Vorbis", AudioFormatID(0x766F_7262), ["ogg", "oga"], ["audio/ogg", "audio/vorbis"]),
        ("WAV", nil, ["wav"], ["audio/wav", "audio/x-wav", "audio/wave"]),
        ("AIFF", nil, ["aif", "aiff", "aifc"], ["audio/aiff", "audio/x-aiff"]),
    ]

    nonisolated private static func measure(songs: [Song], sampleRate: Int, ioBuffer: TimeInterval,
                                            routes: [DeviceCapabilitiesState.Route],
                                            info: [(String, String)]) -> DeviceCapabilitiesState {
        let decoders = knownFormats.map { format -> (available: Bool, hardware: Bool) in
            guard let id = format.formatID else { return (true, false) }
            return decoderInfo(id)
        }
        var counts = Array(repeating: 0, count: knownFormats.count)
        var unknown = 0
        var resampled = 0
        var maxRate: Int?
        var cloud = 0
        var local = 0
        let unavailable = 0
        var bytes: Int64 = 0
        let fm = FileManager.default
        for song in songs {
            if song.spotifyId != nil || song.path.hasPrefix("yt:") || song.contentUriString.hasPrefix("http") {
                cloud += 1
                continue
            }
            local += 1
            let ext = (song.path as NSString).pathExtension.lowercased()
            let mime = song.mimeType?.lowercased() ?? ""
            if let index = knownFormats.firstIndex(where: { $0.extensions.contains(ext) || $0.mimes.contains(mime) }) {
                counts[index] += 1
            } else {
                unknown += 1
            }
            if let rate = song.sampleRate, rate > 0 {
                maxRate = max(maxRate ?? 0, rate)
                if rate > sampleRate { resampled += 1 }
            }
            // Sizes of the files we can read. Unreadable files aren't counted as "unavailable": folder files need
            // their security scope opened first, so a failed read here doesn't mean the file is gone.
            if song.path.hasPrefix("/"), let size = (try? fm.attributesOfItem(atPath: song.path))?[.size] as? NSNumber {
                bytes += size.int64Value
            }
        }
        let formats = knownFormats.indices.map { i in
            DeviceCapabilitiesState.Format(label: knownFormats[i].label, isDecoderAvailable: decoders[i].available,
                                           isHardwareAccelerated: decoders[i].hardware, librarySongCount: counts[i])
        }
        let unsupported = formats.filter { !$0.isDecoderAvailable && $0.librarySongCount > 0 }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                        .volumeTotalCapacityKey])
        let storage = DeviceCapabilitiesState.Storage(
            localSongCount: local, localMusicBytes: bytes,
            deviceAvailableBytes: values?.volumeAvailableCapacityForImportantUsage ?? 0,
            deviceTotalBytes: Int64(values?.volumeTotalCapacity ?? 0),
            cloudSongCount: cloud, unavailableLocalFileCount: unavailable)
        return DeviceCapabilitiesState(
            sampleRate: sampleRate, framesPerBuffer: Int((Double(sampleRate) * ioBuffer).rounded()),
            ioBufferMs: ioBuffer * 1000, routes: routes,
            availableMemory: Int64(os_proc_available_memory()),
            totalMemory: Int64(ProcessInfo.processInfo.physicalMemory),
            formats: formats, storage: storage,
            supportedSongCount: formats.filter(\.isDecoderAvailable).reduce(0) { $0 + $1.librarySongCount },
            unsupportedSongCount: unsupported.reduce(0) { $0 + $1.librarySongCount },
            unsupportedFormats: unsupported.map(\.label), unknownFormatSongCount: unknown,
            resampledSongCount: resampled, maxSampleRate: maxRate, deviceInfo: info)
    }

    /// Whether AudioToolbox has a decoder for `formatID`, and whether one of them is a hardware codec.
    nonisolated private static func decoderInfo(_ formatID: AudioFormatID) -> (available: Bool, hardware: Bool) {
        var format = formatID
        var size: UInt32 = 0
        let specifierSize = UInt32(MemoryLayout<AudioFormatID>.size)
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders, specifierSize, &format, &size) == noErr,
              size > 0 else { return (false, false) }
        let count = Int(size) / MemoryLayout<AudioClassDescription>.size
        var descriptions = [AudioClassDescription](repeating: AudioClassDescription(), count: count)
        guard AudioFormatGetProperty(kAudioFormatProperty_Decoders, specifierSize, &format, &size,
                                     &descriptions) == noErr else { return (count > 0, false) }
        let hardware = UInt32(kAppleHardwareAudioCodecManufacturer)
        return (count > 0, descriptions.contains { $0.mManufacturer == hardware })
    }

    nonisolated private static func category(_ port: AVAudioSession.Port) -> DeviceCapabilitiesState.Route.Category {
        switch port {
        case .builtInSpeaker, .builtInReceiver: .builtIn
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: .bluetooth
        case .usbAudio: .usb
        case .headphones, .lineOut: .wired
        case .airPlay, .HDMI: .digital
        default: .other
        }
    }

    nonisolated private static func machineIdentifier() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    nonisolated private static func report(_ s: DeviceCapabilitiesState, lagMarks: [Date]) -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["PixlAudio performance report", "Generated: \(iso.string(from: Date()))", ""]
        lines.append("[Device]")
        lines += s.deviceInfo.map { "\($0.0): \($0.1)" }
        lines.append("Thermal state: \(ProcessInfo.processInfo.thermalState.rawValue)")
        lines.append("Low power mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        lines.append("Memory available: \(ByteFormat.short(s.availableMemory)) of \(ByteFormat.short(s.totalMemory))")
        lines.append("")
        lines.append("[Audio]")
        lines.append("Sample rate: \(s.sampleRate) Hz, IO buffer: \(String(format: "%.1f", s.ioBufferMs)) ms "
                     + "(\(s.framesPerBuffer) frames)")
        lines += s.routes.map { "Output: \($0.name) (\($0.category.rawValue))" }
        lines.append("")
        lines.append("[Library]")
        lines.append("Local songs: \(s.storage.localSongCount), cloud: \(s.storage.cloudSongCount), "
                     + "unavailable files: \(s.storage.unavailableLocalFileCount)")
        lines += s.formats.map {
            "\($0.label): decoder \($0.isDecoderAvailable ? ($0.isHardwareAccelerated ? "hardware" : "software") : "none"), "
                + "\($0.librarySongCount) songs"
        }
        lines.append("Unknown format: \(s.unknownFormatSongCount), above output rate: \(s.resampledSongCount)")
        if !lagMarks.isEmpty {
            lines.append("")
            lines.append("[Lag marks]")
            lines += lagMarks.map { iso.string(from: $0) }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Cards

/// Android `CapabilityCard`: a 28 pt `surfaceContainer` panel (here glass), 14 pt padding, header row.
private struct CapabilityCard<Content: View>: View {
    let title: String
    let systemImage: String
    var spacing: CGFloat = 10
    var topSpacer = false
    @ViewBuilder var content: Content
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: 12) {
                CapabilityStatusIcon(systemImage: systemImage, fill: theme.secondaryContainer,
                                     content: theme.onSecondaryContainer)
                Text(title)
                    .pixlFont(.titleLarge, weight: .semibold)
                    .foregroundStyle(theme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
            if topSpacer { Spacer().frame(height: 12) }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                   tint: theme.surfaceContainer.opacity(SettingsTint.row))
    }
}

private struct CapabilityStatusIcon: View {
    let systemImage: String
    let fill: Color
    let content: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(content)
            .frame(width: 44, height: 44)
            .background(fill, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Android `InfoTile`: label (`labelMedium`), value (`titleMedium` semibold), supporting (`bodySmall`); ≥ 86 pt.
private struct CapabilityInfoTile: View {
    let label: String
    let value: String
    var supporting: String?
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).pixlFont(.labelMedium).foregroundStyle(theme.onSurfaceVariant).lineLimit(2)
            Text(value).pixlFont(.titleMedium, weight: .semibold).foregroundStyle(theme.onSurface).lineLimit(2)
            if let supporting {
                Text(supporting).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant).lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 86, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surfaceContainerLow.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Android `TonalChip`.
private struct CapabilityChip: View {
    let text: String
    var systemImage: String?
    var compact = false
    var fill: Color?
    var content: Color?
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: compact ? 12 : 14, weight: .semibold))
            }
            Text(text).pixlFont(compact ? .labelSmall : .labelMedium, weight: .medium).lineLimit(1)
        }
        .foregroundStyle(content ?? theme.onSurfaceVariant)
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 5 : 7)
        .background(fill ?? theme.surfaceContainerHighest, in: Capsule())
    }
}

private struct CapabilitiesReadinessCard: View {
    let state: DeviceCapabilitiesState
    @Environment(\.appTheme) private var theme

    var body: some View {
        let review = state.needsReview
        let content = review ? theme.onErrorContainer : theme.onPrimaryContainer
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CapabilityStatusIcon(systemImage: review ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                                     fill: content.opacity(0.12), content: content)
                Text(review ? L10n.settingsDevcapsReviewTitle : L10n.settingsDevcapsReadyTitle)
                    .pixlFont(.headlineSmall, weight: .semibold)
                    .foregroundStyle(content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 8) {
                metric(L10n.settingsDevcapsMetricFormats, "\(state.formats.filter(\.isDecoderAvailable).count)", content)
                metric(L10n.settingsDevcapsMetricHwDecoders,
                       "\(state.formats.filter(\.isHardwareAccelerated).count)", content)
                metric(L10n.settingsDevcapsMetricLocalMusic, "\(state.storage.localSongCount)", content)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 32, style: .continuous),
                   tint: (review ? theme.errorContainer : theme.primaryContainer).opacity(GlassTint.container))
        .accessibilityIdentifier("devcaps.readiness")
    }

    /// Android `HeroMetricTile`.
    private func metric(_ label: String, _ value: String, _ content: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).pixlFont(.titleLarge, weight: .bold).foregroundStyle(content).lineLimit(1)
            Text(label).pixlFont(.labelSmall).foregroundStyle(content.opacity(0.76)).lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 82, maxHeight: .infinity)
        .background(content.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct CapabilitiesStorageCard: View {
    let storage: DeviceCapabilitiesState.Storage
    @Environment(\.appTheme) private var theme

    var body: some View {
        CapabilityCard(title: L10n.settingsDevcapsStorageTitle, systemImage: "externaldrive.fill") {
            HStack(spacing: 8) {
                CapabilityInfoTile(label: L10n.settingsDevcapsStorageMusicSize,
                                   value: ByteFormat.short(storage.localMusicBytes),
                                   supporting: L10n.settingsDevcapsStorageMusicCount(storage.localSongCount))
                CapabilityInfoTile(label: L10n.settingsDevcapsStorageAvailable,
                                   value: ByteFormat.short(storage.deviceAvailableBytes),
                                   supporting: L10n.settingsDevcapsStorageTotal(ByteFormat.short(storage.deviceTotalBytes)))
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                progress(L10n.settingsDevcapsStorageMusicFootprint, storage.musicFraction, theme.primary)
                progress(L10n.settingsDevcapsStorageDeviceUsed, storage.usedFraction, theme.secondary)
            }
            .padding([.horizontal, .bottom], 6)
            if storage.cloudSongCount > 0 || storage.unavailableLocalFileCount > 0 {
                HStack(spacing: 8) {
                    if storage.cloudSongCount > 0 {
                        CapabilityChip(text: L10n.settingsDevcapsStorageCloudCount(storage.cloudSongCount))
                    }
                    if storage.unavailableLocalFileCount > 0 {
                        CapabilityChip(text: L10n.settingsDevcapsStorageUnavailableCount(storage.unavailableLocalFileCount),
                                       fill: theme.errorContainer, content: theme.onErrorContainer)
                    }
                }
            }
        }
    }

    /// Android `ProgressReadout`: label and percentage over an 8 pt capsule bar (≥ 1 % when non-zero).
    private func progress(_ label: String, _ fraction: Double, _ color: Color) -> some View {
        let clamped = min(max(fraction, 0), 1)
        let visible = clamped > 0 && clamped < 0.01 ? 0.01 : clamped
        let percent = clamped * 100
        let text = clamped <= 0 ? L10n.settingsDevcapsStoragePercent(0)
            : percent < 1 ? L10n.settingsDevcapsStorageLessThanOnePercent
            : L10n.settingsDevcapsStoragePercent(Int(percent.rounded()))
        return VStack(spacing: 6) {
            HStack {
                Text(label).pixlFont(.labelLarge).foregroundStyle(theme.onSurface)
                Spacer()
                Text(text).pixlFont(.labelLarge, weight: .semibold).foregroundStyle(theme.onSurface)
            }
            Capsule()
                .fill(theme.surfaceContainerHighest)
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(color).frame(width: proxy.size.width * visible)
                    }
                }
                .clipShape(Capsule())
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CapabilitiesPlaybackPathCard: View {
    let state: DeviceCapabilitiesState
    @Environment(\.appTheme) private var theme

    var body: some View {
        CapabilityCard(title: L10n.settingsDevcapsPlaybackPathTitle, systemImage: "hifispeaker.fill") {
            HStack(spacing: 8) {
                CapabilityInfoTile(label: L10n.settingsDevcapsSampleRateTitle,
                                   value: L10n.settingsDevcapsSampleRateValueHz(state.sampleRate),
                                   supporting: L10n.settingsDevcapsBufferFrames(state.framesPerBuffer))
                CapabilityInfoTile(label: L10n.settingsDevcapsHifiPcmFloatTitle, value: L10n.settingsDevcapsStatusYes,
                                   supporting: L10n.settingsDevcapsHifiPcmFloatSupporting)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                CapabilityInfoTile(label: L10n.settingsDevcapsLowLatencyTitle,
                                   value: state.ioBufferMs <= 12 ? L10n.settingsDevcapsStatusYes
                                                                 : L10n.settingsDevcapsStatusNo,
                                   supporting: String(format: "%.1f ms", state.ioBufferMs))
                CapabilityInfoTile(label: L10n.settingsDevcapsMemoryTitle,
                                   value: ByteFormat.short(state.availableMemory),
                                   supporting: L10n.settingsDevcapsMemoryAvailableOf(ByteFormat.short(state.totalMemory)))
            }
            .fixedSize(horizontal: false, vertical: true)
            Text(L10n.settingsDevcapsOutputsTitle)
                .pixlFont(.titleSmall, weight: .semibold)
                .foregroundStyle(theme.onSurface)
                .accessibilityAddTraits(.isHeader)
            if state.routes.isEmpty {
                Text(String(localized: "settings_devcaps_outputs_empty_ios", defaultValue: "No output routes were reported."))
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
            } else {
                VStack(spacing: 8) {
                    ForEach(state.routes.prefix(5)) { route in routeRow(route) }
                }
            }
        }
    }

    /// Android `OutputRouteRow`.
    private func routeRow(_ route: DeviceCapabilitiesState.Route) -> some View {
        HStack(spacing: 10) {
            Image(systemName: route.category == .builtIn ? "hifispeaker" : "headphones")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(route.name).pixlFont(.titleSmall).foregroundStyle(theme.onSurface).lineLimit(1)
                Text(label(route.category)).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.surfaceContainerLow.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func label(_ category: DeviceCapabilitiesState.Route.Category) -> String {
        switch category {
        case .builtIn: L10n.settingsDevcapsOutputBuiltin
        case .bluetooth: L10n.settingsDevcapsOutputBluetooth
        case .usb: L10n.settingsDevcapsOutputUsb
        case .wired: L10n.settingsDevcapsOutputWired
        case .digital: L10n.settingsDevcapsOutputDigital
        case .other: L10n.settingsDevcapsOutputOther
        }
    }
}

private struct CapabilitiesFormatsCard: View {
    let state: DeviceCapabilitiesState
    @Environment(\.appTheme) private var theme

    var body: some View {
        CapabilityCard(title: L10n.settingsDevcapsFormatsTitle, systemImage: "waveform", spacing: 0) {
            Spacer().frame(height: 12)
            let rows = stride(from: 0, to: state.formats.count, by: 2).map {
                Array(state.formats[$0..<min($0 + 2, state.formats.count)])
            }
            VStack(spacing: 8) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        ForEach(rows[index]) { tile($0) }
                        if rows[index].count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer().frame(height: 12)
            HStack(spacing: 8) {
                CapabilityChip(text: L10n.settingsDevcapsFormatsSupportedCount(state.supportedSongCount),
                               systemImage: "checkmark.circle.fill")
                if state.unknownFormatSongCount > 0 {
                    CapabilityChip(text: L10n.settingsDevcapsFormatsUnknownCount(state.unknownFormatSongCount),
                                   systemImage: "info.circle.fill")
                }
            }
        }
    }

    /// Android `FormatSupportTile` (≥ 112 pt).
    private func tile(_ format: DeviceCapabilitiesState.Format) -> some View {
        let fill = !format.isDecoderAvailable ? theme.errorContainer
            : format.isHardwareAccelerated ? theme.primaryContainer : theme.tertiaryContainer
        let content = !format.isDecoderAvailable ? theme.onErrorContainer
            : format.isHardwareAccelerated ? theme.onPrimaryContainer : theme.onTertiaryContainer
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(format.label).pixlFont(.titleMedium, weight: .semibold).foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: format.isDecoderAvailable ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(content)
                    .padding(4)
                    .background(fill, in: Circle())
            }
            Text(!format.isDecoderAvailable ? L10n.settingsDevcapsFormatUnsupported
                 : format.isHardwareAccelerated ? L10n.settingsDevcapsFormatHardware : L10n.settingsDevcapsFormatSoftware)
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
            if format.librarySongCount > 0 {
                CapabilityChip(text: L10n.settingsDevcapsFormatLibraryCount(format.librarySongCount), compact: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surfaceContainerLow.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct CapabilitiesFindingsCard: View {
    let state: DeviceCapabilitiesState
    @Environment(\.appTheme) private var theme

    var body: some View {
        CapabilityCard(title: L10n.settingsDevcapsFindingsTitle,
                       systemImage: state.hasFindings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill") {
            if !state.hasFindings {
                finding("checkmark.circle.fill", L10n.settingsDevcapsFindingClearTitle,
                        String(localized: "settings_devcaps_finding_clear_body_ios",
                               defaultValue: "Your indexed tracks match the decoders this device reports."),
                        theme.primaryContainer, theme.onPrimaryContainer)
            } else {
                VStack(spacing: 8) {
                    if state.unsupportedSongCount > 0 {
                        finding("exclamationmark.circle", L10n.settingsDevcapsFindingUnsupportedTitle(state.unsupportedSongCount),
                                L10n.settingsDevcapsFindingUnsupportedBody(state.unsupportedFormats.prefix(4).joined(separator: ", ")),
                                theme.errorContainer, theme.onErrorContainer)
                    }
                    if state.resampledSongCount > 0 {
                        finding("exclamationmark.triangle.fill", L10n.settingsDevcapsFindingResampleTitle(state.resampledSongCount),
                                L10n.settingsDevcapsFindingResampleBody(state.maxSampleRate ?? 0),
                                theme.tertiaryContainer, theme.onTertiaryContainer)
                    }
                    if state.unknownFormatSongCount > 0 {
                        finding("info.circle.fill", L10n.settingsDevcapsFindingUnknownTitle(state.unknownFormatSongCount),
                                L10n.settingsDevcapsFindingUnknownBody, theme.secondaryContainer,
                                theme.onSecondaryContainer)
                    }
                }
            }
        }
    }

    /// Android `FindingRow`.
    private func finding(_ symbol: String, _ title: String, _ body: String, _ fill: Color, _ content: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 19, weight: .semibold)).foregroundStyle(content)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).pixlFont(.titleSmall, weight: .semibold).foregroundStyle(content)
                Text(body).pixlFont(.bodySmall).foregroundStyle(content.opacity(0.78))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct CapabilitiesDeviceInfoCard: View {
    let entries: [(String, String)]

    var body: some View {
        CapabilityCard(title: L10n.settingsDevcapsDeviceInfoTitle, systemImage: "info.circle.fill", spacing: 0,
                       topSpacer: true) {
            let rows = stride(from: 0, to: entries.count, by: 2).map { Array(entries[$0..<min($0 + 2, entries.count)]) }
            VStack(spacing: 8) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        ForEach(rows[index].indices, id: \.self) { i in
                            CapabilityInfoTile(label: rows[index][i].0, value: rows[index][i].1)
                        }
                        if rows[index].count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Android `PerformanceReportCard`.
private struct CapabilitiesReportCard: View {
    let model: DeviceCapabilitiesModel
    let experimental: ExperimentalSettings
    @Binding var toast: String?
    @Environment(\.appTheme) private var theme

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdHHmm")
        return formatter
    }()

    var body: some View {
        CapabilityCard(title: L10n.settingsDevcapsReportTitle, systemImage: "chart.bar.doc.horizontal") {
            Text(L10n.settingsDevcapsReportDescription)
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.settingsDevcapsAdvancedDiagnosticsTitle)
                        .pixlFont(.titleSmall, weight: .semibold)
                        .foregroundStyle(theme.onSurface)
                    Text(subtitle)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(L10n.settingsDevcapsAdvancedDiagnosticsTitle,
                       isOn: Binding(get: { experimental.advancedDiagnosticsEnabled },
                                     set: { experimental.setAdvancedDiagnostics($0) }))
                    .labelsHidden()
                    .tint(theme.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.surfaceContainerLow.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if experimental.advancedDiagnosticsEnabled {
                SettingsFillButton(title: L10n.settingsDevcapsAdvancedDiagnosticsMarkLag, style: .outlined) {
                    model.markLag()
                    toast = L10n.settingsDevcapsAdvancedDiagnosticsMarked
                }
            }
            SettingsFillButton(title: model.report == nil ? L10n.settingsDevcapsReportGenerate
                                                          : L10n.settingsDevcapsReportRegenerate,
                               style: .filled, enabled: !model.isGeneratingReport) {
                Task { await model.generateReport() }
            }
            .accessibilityIdentifier("devcaps.generateReport")
            if let report = model.report {
                HStack(spacing: 8) {
                    SettingsFillButton(title: L10n.settingsDevcapsReportCopy, systemImage: "doc.on.doc", style: .outlined) {
                        UIPasteboard.general.string = report
                        toast = L10n.settingsDevcapsReportCopied
                    }
                    ShareLink(item: report, subject: Text(L10n.settingsDevcapsReportShareTitle)) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .semibold))
                            Text(L10n.settingsDevcapsReportShare).pixlFont(.labelLarge)
                        }
                        .foregroundStyle(theme.primary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .overlay(Capsule().strokeBorder(theme.outline, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
                }
                ScrollView {
                    Text(report)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 260)
                .background(theme.surfaceContainerLow.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var subtitle: String {
        if experimental.advancedDiagnosticsEnabled, let expires = experimental.advancedDiagnosticsExpiresAtMs {
            let date = Date(timeIntervalSince1970: Double(expires) / 1000)
            return L10n.settingsDevcapsAdvancedDiagnosticsExpires(Self.expiryFormatter.string(from: date))
        }
        return L10n.settingsDevcapsAdvancedDiagnosticsDescription
    }
}
