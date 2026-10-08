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
        /// Qwen2.5 1.5B Instruct — the downloadable local AI model (Settings › AI features › "Use downloaded AI
        /// model", 2026-10-07). iOS only: Android runs a MediaPipe file the user imports.
        case llm
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
    /// Other files in the tar, next to the package, kept beside the compiled model (the local AI model's tokenizer).
    var extraFiles: [String] = []

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

    /// From `models-v1.json` (pending: ml-convert run): the int4 Core ML program and its tokenizer file.
    static let llm = ModelDescriptor(
        id: .llm, file: "qwen2_5_1_5b_instruct_int4.tar", package: "Qwen25Instruct1_5B.mlpackage",
        bytes: 0, sha256: "pending-ml-convert",
        title: "Local AI model", purpose: "Qwen2.5 1.5B Instruct · runs AI features on this iPhone",
        extraFiles: [LocalLLM.tokenizerFile])

    /// The TAIS Studio models (Experimental › On-device models).
    static let tais: [ModelDescriptor] = [wav2vec2, mdxnet]
    static let all: [ModelDescriptor] = tais + [llm]

    /// "870 MB" (the system's file-size style).
    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func descriptor(_ id: ModelDescriptor.ID) -> ModelDescriptor {
        switch id {
        case .wav2vec2: wav2vec2
        case .mdxnet: mdxnet
        case .llm: llm
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

    /// The local AI model (`ci/ml/convert_llm.py`): `inputIds` int32 [1, Q] (the new tokens) and `causalMask`
    /// float16 [1, 1, Q, P + Q] (0 attends, -inf masks) over the states `keyCache` / `valueCache` (float16, P rows
    /// already filled) → `logits` float16 [1, 1, vocabulary] after the last new token. Q ≤ 512, P + Q ≤ 4,096.
    nonisolated enum LocalLLM {
        static let inputIds = "inputIds"
        static let causalMask = "causalMask"
        static let output = "logits"
        static let context = 4096
        static let maxQuery = 512
        static let vocabulary = 151_936
        static let tokenizerFile = "qwen2_5.pxbpe"
    }
}
