// swift-tools-version: 6.2
// PixlCore — the pure-Swift logic of PixlAudio. ZERO dependencies. Must build and test on Windows
// (Swift for Windows) and macOS. Every module and test target is declared up front so parallel work
// never needs to edit this manifest (see AGENTS.md).
import PackageDescription

/// Module name → modules it may import. Order matters only for readability.
let modules: [(name: String, dependencies: [String])] = [
    ("PixlFoundation", []),
    ("PixlModel", ["PixlFoundation"]),
    ("PixlLyrics", ["PixlFoundation", "PixlModel"]),
    ("PixlLibrary", ["PixlFoundation", "PixlModel"]),
    ("PixlAudioCore", ["PixlFoundation", "PixlModel"]),
    ("PixlTags", ["PixlFoundation", "PixlModel"]),
    ("PixlNet", ["PixlFoundation", "PixlModel", "PixlLyrics"]),
    ("PixlBackup", ["PixlFoundation", "PixlModel", "PixlLibrary", "PixlLyrics"]),
]

let package = Package(
    name: "PixlCore",
    platforms: [.iOS("26.1"), .macOS("26.0")],
    products: modules.map { Product.library(name: $0.name, targets: [$0.name]) },
    targets: modules.flatMap { module -> [Target] in
        [
            .target(
                name: module.name,
                dependencies: module.dependencies.map { Target.Dependency.target(name: $0) }
            ),
            .testTarget(
                name: "\(module.name)Tests",
                dependencies: [Target.Dependency.target(name: module.name)] + module.dependencies.map { Target.Dependency.target(name: $0) },
                resources: [.copy("Fixtures")]
            ),
        ]
    }
)
