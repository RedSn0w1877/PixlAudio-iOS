import Foundation
import PixlAudioCore
import PixlModel
import Synchronization

/// What Spatial audio does with one player item (`TapItemParameters.spatialRole`). Plain integers: the render thread
/// reads them from an `Atomic`.
nonisolated enum SpatialItemRole {
    /// Other audio for the entry (Sing's instrumental or preview piece), or an item built before Spatial audio existed:
    /// never spatialized.
    static let none = 0
    /// The song's own audio (stream, cached or downloaded file): the on-device stage runs on it while Spatial audio is
    /// active.
    static let stage = 1
    /// A spatial cloud render: the stage never runs on it; the level rule gives its headroom back.
    static let render = 2
}

/// Whether the on-device stage can run on an item's decoded format (`TapItemParameters.spatialFormat`).
nonisolated enum SpatialItemFormat {
    /// The tap has not been prepared yet.
    static let unknown = 0
    /// Stereo float at 44.1 or 48 kHz: the stage runs.
    static let supported = 1
    /// Anything else (mono, another rate): the song plays without the stage (spec 6.3), its render is still wanted.
    static let unsupported = 2
}

/// Spatial audio's part of the global tap parameters (`AudioEffectsParameters.spatial`): the profile every tap's stage
/// plays, and the coefficients they all read.
nonisolated final class SpatialTapShared: @unchecked Sendable {
    /// The profile the stage plays while Spatial audio is active (`SpatialStageCoefficients.index(of:)`), or
    /// `SpatialStage.bypass`. One write per change on the main actor; every tap reads it once per buffer.
    let profileIndex = Atomic<Int>(SpatialStage.bypass)
    private let installed = Mutex<SpatialStageCoefficients?>(nil)

    /// The decoded tables, once loaded (taps read them in `prepare`, never on the render thread).
    var coefficients: SpatialStageCoefficients? { installed.withLock { $0 } }

    /// Installs the tables (once per launch; a second call replaces them for later items).
    func install(_ coefficients: SpatialStageCoefficients) {
        installed.withLock { $0 = coefficients }
    }

    /// The profile taps play from now on (nil: bypass). Taps ramp to it over about 80 ms.
    func play(_ profile: SpatialProfile?) {
        let index = profile.map(SpatialStageCoefficients.index(of:)) ?? SpatialStage.bypass
        profileIndex.store(index, ordering: .releasing)
    }

    /// The profile taps play now (nil: bypass).
    var playing: SpatialProfile? {
        let index = profileIndex.load(ordering: .acquiring)
        return SpatialStageCoefficients.profiles.indices.contains(index) ? SpatialStageCoefficients.profiles[index] : nil
    }
}
