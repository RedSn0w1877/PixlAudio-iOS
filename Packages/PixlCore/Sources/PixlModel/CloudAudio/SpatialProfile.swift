// Spatial audio's vocabulary (cloud audio spec of 2026-11-10, sections 1, 2, 6.1, 6.3 and 6.5): the six headphone
// profiles, the "off or a profile" selection, the route rule and the level rule. The spec is
// docs/handoff/2026-11-10-plans/cloud-audio-spec.md; when this file and the spec disagree, fix one of them in the
// same change. The Android app carries the same ids and rules.

import Foundation

/// A Spatial audio profile. The raw values are the spec's profile ids: library keys, job requests, manifests and the
/// on-device table file all use them. The cases are in the spec's order, which is also the order of the list the
/// person picks from.
public enum SpatialProfile: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case studio
    case wide
    case intimate
    case hall
    case surround
    case night

    public var id: String { rawValue }

    /// The spec's default profile.
    public static let `default`: SpatialProfile = .studio

    /// The profile with this id, or nil for anything else (ids are lower case and exact).
    public init?(id: String) { self.init(rawValue: id) }

    /// The name in the profile list (the English source text; the apps localise from it).
    public var displayName: String {
        switch self {
        case .studio: "Studio"
        case .wide: "Wide"
        case .intimate: "Intimate"
        case .hall: "Concert Hall"
        case .surround: "Surround"
        case .night: "Night"
        }
    }

    /// The one line under the name (spec 6.5; the English source text).
    public var summary: String {
        switch self {
        case .studio: "Clean and close, like good speakers in a quiet room."
        case .wide: "Instruments pushed out to the sides."
        case .intimate: "The voice right in front of you."
        case .hall: "A big room, a few rows back."
        case .surround: "Sound beside and behind you."
        case .night: "Softer and gentler for late listening."
        }
    }
}

/// The setting `spatial.profile`: off, or a profile. Picking a profile is what turns Spatial audio on.
public enum SpatialSelection: Sendable, Hashable {
    case off
    case profile(SpatialProfile)

    /// What `off` is stored as.
    public static let offValue = "off"

    /// From the stored text. A missing value, or one this build does not know (a profile a newer build added), is off.
    public init(storageValue: String?) {
        if let storageValue, let profile = SpatialProfile(rawValue: storageValue) {
            self = .profile(profile)
        } else {
            self = .off
        }
    }

    /// `off` or the profile id.
    public var storageValue: String {
        switch self {
        case .off: Self.offValue
        case .profile(let profile): profile.rawValue
        }
    }

    public var profile: SpatialProfile? {
        if case .profile(let profile) = self { return profile }
        return nil
    }

    public var isOn: Bool { profile != nil }

    /// Off first, then every profile: the rows of the picker.
    public static let allChoices: [SpatialSelection] = [.off] + SpatialProfile.allCases.map(SpatialSelection.profile)
}

/// The setting `spatial.route`: where Spatial audio may play.
public enum SpatialRouteMode: String, Sendable, Hashable, CaseIterable {
    /// Wired, Bluetooth and USB headphones only (a Bluetooth speaker counts, the phone cannot tell them apart).
    case headphones
    /// Any output of this phone. Offered in Developer mode only.
    case always

    /// From the stored text; anything else is `headphones`.
    public init(storageValue: String?) {
        self = storageValue.flatMap(SpatialRouteMode.init(rawValue:)) ?? .headphones
    }
}

/// Where the phone's audio goes, as far as the route rule cares. Each app maps its platform's routes onto these
/// (iOS: the audio session's output port; Android: the selected audio device).
public enum SpatialOutputKind: String, Sendable, Hashable, CaseIterable {
    /// The phone's own speaker or earpiece.
    case phoneSpeaker
    /// Wired headphones (jack or adapter).
    case wiredHeadphones
    /// A USB headset or USB audio adapter.
    case usbHeadset
    /// Bluetooth audio for music (A2DP, LE Audio). A Bluetooth speaker counts.
    case bluetooth
    /// AirPlay or another cast of this phone's audio.
    case airPlay
    /// A car (CarPlay, Android Auto, a car's own audio port).
    case car
    /// Another device plays the music itself (Spotify Connect): nothing is rendered on this phone.
    case remote
    /// Anything else (HDMI, a line out, a dock, a call route).
    case other

    /// The outputs the `headphones` route mode accepts.
    public var countsAsHeadphones: Bool {
        switch self {
        case .wiredHeadphones, .usbHeadset, .bluetooth: true
        case .phoneSpeaker, .airPlay, .car, .remote, .other: false
        }
    }
}

/// When Spatial audio is "active" (spec 6.3): a profile is selected AND the route rule passes AND Sing's instrumental
/// mode is not on. While it is active the song plays through the on-device stage or as a spatial cloud render; while
/// it is not, the song plays in plain (or Enhanced) stereo.
public enum SpatialActivation {
    /// The route rule alone. A device that plays the music itself never passes: nothing is rendered here for it.
    public static func routePasses(mode: SpatialRouteMode, output: SpatialOutputKind) -> Bool {
        if output == .remote { return false }
        switch mode {
        case .always: return true
        case .headphones: return output.countsAsHeadphones
        }
    }

    public static func isActive(selection: SpatialSelection, mode: SpatialRouteMode, output: SpatialOutputKind,
                                singInstrumentalOn: Bool) -> Bool {
        selection.isOn && routePasses(mode: mode, output: output) && !singInstrumentalOn
    }
}

/// The level rule (spec 3.1 and 6.3 "Level"). Both spatial paths play `headroomDb` under the source, so while a
/// spatial rendition is audible the app multiplies the gain it already applies to the item (ReplayGain / volume
/// normalisation; 1 when there is none) by that headroom, capped at unity. Spatial is then exactly as loud as stereo
/// whenever normalisation already pulls the song down by the headroom or more, and never clips otherwise.
public enum SpatialLevel {
    /// Today's headroom. Use the manifest's `loudness.headroomDb` for a render and the table file's `headroomDb` for
    /// the on-device stage; this is the fallback when one of them is missing.
    public static let defaultHeadroomDb: Double = 4.0

    /// A decibel value as a linear factor.
    public static func linear(db: Double) -> Double { pow(10.0, db / 20.0) }

    /// `min(1, gain × 10^(headroomDb / 20))`: the playback gain of an item while a spatial rendition is audible.
    /// `gain` is the item's playback gain without Spatial (1 = unchanged). A negative or non-finite headroom counts
    /// as none.
    public static func playbackGain(_ gain: Float, headroomDb: Double) -> Float {
        let headroom = headroomDb.isFinite ? max(headroomDb, 0) : 0
        return min(1, gain * Float(linear(db: headroom)))
    }
}
