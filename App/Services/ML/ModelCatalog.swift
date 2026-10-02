import Foundation

/// The on-device ML models (stage 14), published by `.github/workflows/ml-convert.yml` as assets of the GitHub
/// Release `models-v1` and downloaded on demand by `ModelManager`. Each asset is an uncompressed ustar `.tar` of an
/// `.mlpackage` (`ci/ml/common.py tar_mlpackage`); its byte size and SHA-256 are pinned here, so a replaced asset is
/// refused until this file is updated with the new `models-v1.json` values.
///
/// Android bundles both models in the APK (`assets/tais/`); iOS keeps the IPA small and fetches them the first time
/// a TAIS job needs one.
nonisolated struct ModelDescriptor: Sendable, Hashable, Identifiable {
    nonisolated enum ID: String, Sendable, Hashable, CaseIterable {
        /// facebook/wav2vec2-base-960h — word-by-word lyric sync (Android `TaisWav2Vec2Aligner`).
        case wav2vec2
        /// UVR-MDX-NET-Voc_FT — on-device instrumentals (Android `TaisStemSeparator`).
        case mdxnet
    }

    let id: ID
    /// The release asset.
    let file: String
    /// The `.mlpackage` directory inside the tar.
    let package: String
    let bytes: Int64
    let sha256: String
    /// What the user sees (Experimental › On-device models).
    let title: String
    let purpose: String

    var downloadURL: URL {
        URL(string: "https://github.com/RedSn0w1877/PixlAudio-iOS/releases/download/\(ModelCatalog.release)/\(file)")!
    }
}

nonisolated enum ModelCatalog {
    static let release = "models-v1"

    /// From `models-v1.json` (ml-convert run 36943723854).
    static let wav2vec2 = ModelDescriptor(
        id: .wav2vec2, file: "wav2vec2_base_960h.mlpackage.tar", package: "Wav2Vec2Base960h.mlpackage",
        bytes: 189_071_360, sha256: "fd7dd9f8eaef6b2ab47ffb95a608daeeae62354efd525c62074f03c5ff2fc84b",
        title: "Lyric Sync model", purpose: "wav2vec2 · syncs lyrics word by word")

    static let mdxnet = ModelDescriptor(
        id: .mdxnet, file: "mdx_net_voc_ft.mlpackage.tar", package: "MdxNetVocFT.mlpackage",
        bytes: 33_505_280, sha256: "e6cc0e50c7eb5a321ded78f88ba52445d451be9e48975113f4a487426cef800b",
        title: "Instrumental model", purpose: "MDX-Net · separates vocals for instrumentals")

    static let all: [ModelDescriptor] = [wav2vec2, mdxnet]

    static func descriptor(_ id: ModelDescriptor.ID) -> ModelDescriptor {
        switch id {
        case .wav2vec2: wav2vec2
        case .mdxnet: mdxnet
        }
    }

    // MARK: Model contracts (ci/ml/convert_*.py)

    /// wav2vec2: `input_values` float32 [1, 160000] (10 s of 16 kHz mono, normalised per window) → `logits`
    /// float32 [1, 499, 32].
    nonisolated enum Wav2Vec2 {
        static let input = "input_values"
        static let output = "logits"
        static let inputSamples = 160_000
        static let frames = 499
    }

    /// MDX-Net: `spectrum` float32 [1, 4, 3072, 256] (L-re, L-im, R-re, R-im) → `vocals`, same shape.
    nonisolated enum Mdx {
        static let input = "spectrum"
        static let output = "vocals"
    }
}
