import Foundation
import PixlModel

// What the Spatial audio screens show (cloud audio spec of 2026-11-10, section 6.5), as plain functions of what
// `env.spatial` exposes, so every mapping is unit-tested (`AppTests/SpatialAudioUITests.swift`) and the views only lay it
// out. No rule lives here: what plays and why comes from the contract (PixlModel's `CloudAudio` folder and
// `SpatialAudioModel`). The Android app's `SpatialAudioUi.kt` (branch `audio-ui`) maps the same states the same way.

/// The words and symbols of Spatial audio.
nonisolated enum SpatialAudioUI {
    /// The feature's symbol (Android's `spatial_audio`: a head with sound around it), on the player's button, the sheet's
    /// header and the Settings row.
    static let symbol = "person.wave.2"

    /// The sheet's choices, in order: Off, then the six profiles in the spec's order (as on Android).
    static let choiceOrder: [SpatialSelection] = SpatialSelection.allChoices

    /// The sheet's rows for the selected profile (or Off): Off first, exactly one selected.
    static func choices(selected: SpatialSelection) -> [SpatialChoice] {
        choiceOrder.map { SpatialChoice(selection: $0, isSelected: $0 == selected) }
    }

    /// A profile's name (spec 6.5; `hall` is "Concert Hall"), or "Off".
    static func name(_ selection: SpatialSelection) -> String {
        switch selection {
        case .off: L10n.spatialOff
        case .profile(let profile): name(profile)
        }
    }

    static func name(_ profile: SpatialProfile) -> String {
        switch profile {
        case .studio: L10n.spatialProfileStudio
        case .wide: L10n.spatialProfileWide
        case .intimate: L10n.spatialProfileIntimate
        case .hall: L10n.spatialProfileHall
        case .surround: L10n.spatialProfileSurround
        case .night: L10n.spatialProfileNight
        }
    }

    /// A profile's one-liner (spec 6.5), or Off's own ("The normal stereo sound.", Android's choice).
    static func line(_ selection: SpatialSelection) -> String {
        switch selection {
        case .off: L10n.spatialOffLine
        case .profile(.studio): L10n.spatialProfileStudioLine
        case .profile(.wide): L10n.spatialProfileWideLine
        case .profile(.intimate): L10n.spatialProfileIntimateLine
        case .profile(.hall): L10n.spatialProfileHallLine
        case .profile(.surround): L10n.spatialProfileSurroundLine
        case .profile(.night): L10n.spatialProfileNightLine
        }
    }

    /// The sheet's status line (spec 6.5: "Every state has one"), or nil for `none`: no line at all.
    static func statusText(_ line: SpatialStatusLine) -> String? {
        switch line {
        case .none: nil
        case .onPhoneForNow: L10n.spatialStatusOnPhoneForNow
        case .waitingForWifi: L10n.spatialStatusWaitingForWifi
        case .cloudLimitReached: L10n.spatialStatusCloudLimitReached
        case .gettingCloudVersion: L10n.spatialStatusGettingCloudVersion
        case .cloudVersion: L10n.spatialStatusCloudVersion
        case .onPhoneOnly: L10n.spatialStatusOnPhoneOnly
        case .cloudFailed: L10n.spatialStatusCloudFailed
        case .headphonesOnly: L10n.spatialStatusHeadphonesOnly
        case .pausedForSing: L10n.spatialStatusPausedForSing
        }
    }

    /// The status line's symbol (Android's icons: hourglass, Wi-Fi, money off, cloud download, cloud done, phone,
    /// error, headphones, mic).
    static func statusSymbol(_ line: SpatialStatusLine) -> String {
        switch line {
        case .onPhoneForNow: "hourglass"
        case .waitingForWifi: "wifi"
        case .cloudLimitReached: "dollarsign.circle"
        case .gettingCloudVersion: "icloud.and.arrow.down"
        case .cloudVersion: "checkmark.icloud"
        case .onPhoneOnly, .none: "iphone"
        case .cloudFailed: "exclamationmark.circle"
        case .headphonesOnly: "headphones"
        case .pausedForSing: "music.mic"
        }
    }

    /// Developer mode's file-info label in the full player while a spatial rendition is audible ("Spatial Studio on
    /// phone", "Spatial Studio cloud render"), or nil while the song plays in stereo.
    static func fileInfo(_ audible: SpatialAudible) -> String? {
        switch audible {
        case .stereo: nil
        case .onDevice(let profile): L10n.spatialFileInfoOnDevice(name(profile))
        case .render(let profile): L10n.spatialFileInfoRender(name(profile))
        }
    }
}

/// One row of the sheet's list (spec 6.5): a profile, or Off.
nonisolated struct SpatialChoice: Hashable, Sendable, Identifiable {
    let selection: SpatialSelection
    let isSelected: Bool

    /// The stored form: `off` or the profile id.
    var id: String { selection.storageValue }
    var name: String { SpatialAudioUI.name(selection) }
    var line: String { SpatialAudioUI.line(selection) }
}

/// The full player's Spatial audio button (spec 6.5 "an entry in the full player"): "Off", or the selected profile's
/// name with the selected look. `isHeldBack`: a selected profile the listener can't hear right now for a reason the
/// sheet's status line explains (the route rule or Sing): the button keeps the name and drops its emphasis.
nonisolated struct SpatialButtonUI: Hashable, Sendable {
    let selection: SpatialSelection
    let isHeldBack: Bool

    static let off = SpatialButtonUI(selection: .off, isHeldBack: false)

    var isOn: Bool { selection.isOn }
    /// The filled ("selected") look: a profile is on and nothing holds it back.
    var isEmphasized: Bool { isOn && !isHeldBack }
    /// "Off" or the profile's name: the button's text and its VoiceOver value.
    var label: String { SpatialAudioUI.name(selection) }
    var accessibilityValue: String { isHeldBack ? L10n.spatialHeldValue(label) : label }

    /// The button for the stored selection and what holds it back (`SpatialPlaybackSnapshot.blockedBy`). Only the blocks
    /// with a status line of their own dim it: `route` ("Headphones only. Plug in to hear it.") and `sing` ("Paused
    /// while Sing is on."). `remote` and `format` have no line (spec 6.3, 6.5), so the button doesn't hint at something
    /// the sheet won't explain. Android's `SpatialButtonUi.of` does the same.
    static func of(selection: SpatialSelection, blockedBy: SpatialBlock?) -> SpatialButtonUI {
        let held: Bool
        switch blockedBy {
        case .route?, .sing?: held = selection.isOn
        case .remote?, .format?, nil: held = false
        }
        return SpatialButtonUI(selection: selection, isHeldBack: held)
    }
}

/// Settings › Playback › Sound, the Spatial audio rows (spec 6.5): the profile, "Cloud renders", "Prepare ahead", and
/// "Songs ready: N · X GB on this phone" with "Remove downloaded renders".
nonisolated struct SpatialSettingsUI: Hashable, Sendable {
    /// The selected profile, or Off.
    let selection: SpatialSelection
    /// "Cloud renders": `spatial.cloud` only (spec 6.1 "Two switches"; the master stays on the Cloud processing screen).
    let cloudChecked: Bool
    /// The switch is on but cloud renders can't happen: Cloud Studio's master switch is off (6.1 "Two switches"). The
    /// section then says so and leads to the master, rather than look switched on and do nothing.
    let masterOff: Bool
    /// "Prepare ahead" (`spatial.prepareAhead`).
    let prepareAheadChecked: Bool
    /// "Prepare ahead" can only do something while "Cloud renders" is on (6.4 sends cloud work); its value is kept.
    let prepareAheadEnabled: Bool
    /// "Songs ready: N".
    let songsReady: Int
    /// "X" of "X GB on this phone".
    let gigabytesOnPhone: String
    /// "Remove downloaded renders" has something to remove (and isn't already removing it).
    let canRemove: Bool

    /// "Studio · Clean and close, like good speakers in a quiet room."
    var profileSubtitle: String {
        L10n.spatialSettingsProfileSubtitle(SpatialAudioUI.name(selection), SpatialAudioUI.line(selection))
    }
    var prepareAheadSubtitle: String {
        prepareAheadEnabled ? L10n.spatialSettingsPrepareSubtitle : L10n.spatialSettingsPrepareNeedsCloud
    }
    /// "Songs ready: 12 · 1.4 GB on this phone"
    var songsReadyTitle: String { L10n.spatialSettingsSongsReady(songsReady, gigabytesOnPhone) }

    /// - Parameters:
    ///   - cloudRendersOn: `SpatialAudioModel.cloudRendersOn` (both switches).
    ///   - isRemoving: `SpatialAudioModel.isRemovingRenders`.
    static func of(settings: CloudAudioSettings, usage: CloudAudioUsage, cloudRendersOn: Bool,
                   isRemoving: Bool = false) -> SpatialSettingsUI {
        SpatialSettingsUI(selection: settings.profile,
                          cloudChecked: settings.cloud,
                          masterOff: settings.cloud && !cloudRendersOn,
                          prepareAheadChecked: settings.prepareAhead,
                          prepareAheadEnabled: settings.cloud,
                          songsReady: max(usage.songsReady, 0),
                          gigabytesOnPhone: SpatialFormat.gigabytes(usage.bytes),
                          canRemove: !isRemoving && (usage.songsReady > 0 || usage.bytes > 0))
    }
}

/// Numbers as the Spatial audio rows print them. Binary units, like `cloudAudio.storageMB` (1 MB = 1,048,576 bytes).
nonisolated enum SpatialFormat {
    private static let bytesPerGB = 1_073_741_824.0
    private static let megabytesPerGB = 1024

    /// "X" of "X GB on this phone": "0" for nothing, one decimal otherwise (halves round up, as on Android), and never
    /// "0.0" for a store that holds something (anything under 0.1 GB reads 0.1).
    static func gigabytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0" }
        let gigabytes = max(Double(bytes) / bytesPerGB, 0.1)
        return oneDecimal(gigabytes)
    }

    /// A storage budget for its row: whole megabytes under 1 GB ("512 MB"), else gigabytes with one decimal only when
    /// it isn't whole ("1.5 GB", "3 GB", "64 GB").
    static func storage(megabytes: Int) -> String {
        guard megabytes >= megabytesPerGB else { return L10n.spatialDevStorageMB(megabytes) }
        if megabytes % megabytesPerGB == 0 { return L10n.spatialDevStorageGB(String(megabytes / megabytesPerGB)) }
        return L10n.spatialDevStorageGB(oneDecimal(Double(megabytes) / Double(megabytesPerGB)))
    }

    /// "%.1f" with halves rounded away from zero (Java's `String.format` does that; C's rounds a tie to even).
    static func oneDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded(.toNearestOrAwayFromZero) / 10
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
    }
}

/// Developer mode's storage budget slider (spec 6.1 `cloudAudio.storageMB`, kept within 256 … 65536): fixed stops from
/// 256 MB to 64 GB, so the slider moves in steps that mean something at both ends (Android's stops).
nonisolated enum SpatialStorageStops {
    static let megabytes: [Int] = [256, 512, 1024, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152, 65536]

    static var lastIndex: Int { megabytes.count - 1 }

    /// The stop for a stored budget: the nearest one (the first of two equally near), so a value set elsewhere still
    /// lands somewhere sensible.
    static func index(ofStored storedMB: Int) -> Int {
        var best = 0
        for index in megabytes.indices where abs(megabytes[index] - storedMB) < abs(megabytes[best] - storedMB) {
            best = index
        }
        return best
    }

    /// The budget at a slider position.
    static func megabytes(at position: Double) -> Int {
        guard position.isFinite else { return megabytes[0] }
        let index = Int(position.rounded())
        return megabytes[min(max(index, 0), lastIndex)]
    }
}

/// Developer mode's monthly limit for library jobs (spec 6.1 `cloudAudio.monthlyCapUSD`: default 30, at most 200, or
/// "No limit"). A choice list rather than a slider, because "No limit" is not a number.
nonisolated enum SpatialCapOptions {
    /// The amounts offered, in whole dollars (Android's list).
    static let dollars: [Double] = [5, 10, 15, 20, 30, 50, 75, 100, 150, CloudAudioSettings.maxMonthlyCapUSD]

    /// The key of "No limit" in the choice list.
    static let noLimitKey = "none"

    /// What picking a choice stores: `usd` nil for "No limit".
    nonisolated struct Pick: Hashable, Sendable {
        let usd: Double?
    }

    /// The choice list's key for a cap (nil is "No limit"): "30", "12.5".
    static func key(of usd: Double?) -> String {
        guard let usd else { return noLimitKey }
        if usd.isFinite, usd == usd.rounded(), abs(usd) < 1_000_000 { return String(Int(usd)) }
        return String(usd)
    }

    /// "$30", "$12.50", "No limit".
    static func label(of usd: Double?) -> String {
        guard let usd else { return L10n.spatialDevCapNone }
        if usd.isFinite, usd == usd.rounded(), abs(usd) < 1_000_000 { return L10n.spatialDevCapUSD(Int(usd)) }
        return String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), usd)
    }

    /// The choices to show for a stored cap, in order: the amounts, the stored one among them if it is not one of them
    /// (so the row never shows a value the list lacks), then "No limit" (nil).
    static func choices(stored: Double?) -> [Double?] {
        var amounts = dollars
        if let stored, !dollars.contains(stored) {
            amounts.append(stored)
            amounts.sort()
        }
        return amounts.map { Optional($0) } + [nil]
    }

    /// The choices as the settings row's options.
    static func options(stored: Double?) -> [SettingsOption] {
        choices(stored: stored).map { SettingsOption(key: key(of: $0), label: label(of: $0)) }
    }

    /// What picking `key` stores; nil for a key that is not a choice.
    static func pick(_ key: String) -> Pick? {
        if key == noLimitKey { return Pick(usd: nil) }
        guard let value = Double(key), value.isFinite, value >= 0, value <= CloudAudioSettings.maxMonthlyCapUSD else {
            return nil
        }
        return Pick(usd: value)
    }
}

/// Developer mode's "songs a day ahead" slider (spec 6.1 `cloudAudio.dailyAhead`, kept within 1 … 100). Continuous, as on
/// Android (a hundred stops would draw a hundred ticks); the value is rounded.
nonisolated enum SpatialDailyAhead {
    static let range: ClosedRange<Double> = {
        let songs = CloudAudioSettings.dailyAheadRange
        return Double(songs.lowerBound)...Double(songs.upperBound)
    }()

    static func songs(at position: Double) -> Int {
        guard position.isFinite else { return CloudAudioSettings.dailyAheadRange.lowerBound }
        return CloudAudioSettings.clampedDailyAhead(Int(position.rounded()))
    }
}

/// One line of Developer mode's per-song diagnostics: a label from the strings and a technical value.
nonisolated struct SpatialDiagnosticRow: Hashable, Sendable, Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

/// Developer mode's per-song diagnostics for the playing song (spec 6.5: rendition, source codec, stem mode, loudness and
/// sample rate). The values are technical words, not translated, like the player's file-info label; the rows and their
/// order are Android's (`SpatialDiagnostics.rows`).
nonisolated enum SpatialDiagnostics {
    private static let none = "none"
    private static let unknown = "?"

    /// The rows for what plays, its status under the selected profile (`SpatialAudioModel.status`) and its local render
    /// for the selected profile once it is ready (`rendition`); empty when nothing is loaded.
    static func rows(snapshot: SpatialPlaybackSnapshot, status: RenditionStatus,
                     rendition: LocalRendition?) -> [SpatialDiagnosticRow] {
        guard snapshot.songId != nil else { return [] }
        var rows: [SpatialDiagnosticRow] = []
        rows.reserveCapacity(8)
        rows.append(SpatialDiagnosticRow(label: L10n.spatialDevDiagRendition, value: renditionWords(snapshot.audible)))
        if let block = snapshot.blockedBy {
            rows.append(SpatialDiagnosticRow(label: L10n.spatialDevDiagHeld, value: blockWords(block)))
        }
        rows.append(SpatialDiagnosticRow(label: L10n.spatialDevDiagStatus, value: statusWords(status)))
        guard let rendition else {
            rows.append(SpatialDiagnosticRow(label: L10n.spatialDevDiagRender, value: none))
            return rows
        }
        let manifest = rendition.manifest
        rows.append(SpatialDiagnosticRow(label: L10n.spatialDevDiagRender, value: rendition.key.profile.rawValue))
        rows.append(SpatialDiagnosticRow(label: L10n.spatialDevDiagCodec, value: manifest.source?.codec ?? unknown))
        rows.append(SpatialDiagnosticRow(label: L10n.spatialDevDiagStems, value: manifest.render?.stemMode ?? unknown))
        rows.append(SpatialDiagnosticRow(label: L10n.spatialDevDiagLoudness,
                                         value: loudness(manifest.loudness, headroomDb: rendition.headroomDb)))
        let rate = rendition.sampleRate.map { String($0) } ?? unknown
        rows.append(SpatialDiagnosticRow(label: L10n.spatialDevDiagRate, value: rate + " Hz"))
        return rows
    }

    /// The selected profile's local render among the playing song's, once its status is `ready` (Android reads it only
    /// then); nil otherwise.
    static func currentRendition(among renditions: [LocalRendition], selection: SpatialSelection,
                                 status: RenditionStatus) -> LocalRendition? {
        guard status == .ready, let profile = selection.profile else { return nil }
        return renditions.first { $0.key.profile == profile }
    }

    static func renditionWords(_ audible: SpatialAudible) -> String {
        switch audible {
        case .stereo: "stereo"
        case .onDevice(let profile): "on device · \(profile.rawValue)"
        case .render(let profile): "cloud render · \(profile.rawValue)"
        }
    }

    static func blockWords(_ block: SpatialBlock) -> String {
        switch block {
        case .route: "route"
        case .sing: "sing"
        case .remote: "another device"
        case .format: "sample rate"
        }
    }

    /// The status as Android prints its enum name: lower case, words apart ("waiting for network").
    static func statusWords(_ status: RenditionStatus) -> String {
        switch status {
        case .none: "none"
        case .preview: "preview"
        case .queued: "queued"
        case .waitingForNetwork: "waiting for network"
        case .capReached: "cap reached"
        case .processing: "processing"
        case .downloading: "downloading"
        case .ready: "ready"
        case .failed: "failed"
        }
    }

    /// "-14.0 LUFS, source -9.8, headroom 4.0 dB" (Android's form).
    static func loudness(_ loudness: CloudLibraryManifest.Loudness?, headroomDb: Double) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        let integrated = loudness?.integratedLufs.map { String(format: "%.1f LUFS", locale: posix, $0) }
            ?? "\(unknown) LUFS"
        let source = loudness?.sourceLufs.map { String(format: ", source %.1f", locale: posix, $0) } ?? ""
        let headroom = String(format: ", headroom %.1f dB", locale: posix, headroomDb)
        return integrated + source + headroom
    }
}
