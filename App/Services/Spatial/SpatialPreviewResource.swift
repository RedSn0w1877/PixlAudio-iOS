import Foundation
import PixlAudioCore

/// The on-device stage's coefficient tables as the app carries them: `App/Resources/spatial_preview_v1.json`, a
/// byte-identical copy of the worker's file (`cloud/runpod-worker/schema/v1/spatial/`; never edited by hand,
/// `ci/check-spatial-fixtures.sh` fails when it drifts).
nonisolated enum SpatialPreviewResource {
    /// The bundled file, or nil when the build lost it.
    static var url: URL? {
        Bundle.main.url(forResource: SpatialPreviewTables.resourceName,
                        withExtension: SpatialPreviewTables.resourceExtension)
    }

    /// Reads and decodes the tables on the calling thread (about 70 KB of JSON: never on the main thread while
    /// something animates, never on the audio thread).
    static func loadNow() throws -> SpatialPreviewTables {
        guard let url else {
            throw SpatialPreviewError.unreadable("\(SpatialPreviewTables.resourceName).json is not in the app bundle")
        }
        return try SpatialPreviewTables.decode(try Data(contentsOf: url))
    }

    /// Reads and decodes the tables off the caller's actor.
    @concurrent
    static func load() async throws -> SpatialPreviewTables {
        try loadNow()
    }
}
