// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveSub",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "LiveSub", targets: ["LiveSub"]),
        .library(name: "LiveSubAudio", targets: ["LiveSubAudio"]),
        .library(name: "LiveSubOverlay", targets: ["LiveSubOverlay"]),
        .library(name: "LiveSubBackend", targets: ["LiveSubBackend"]),
        .library(name: "LiveSubSubtitles", targets: ["LiveSubSubtitles"]),
    ],
    targets: [
        .executableTarget(
            name: "LiveSub",
            dependencies: ["LiveSubAudio", "LiveSubBackend", "LiveSubOverlay", "LiveSubSubtitles"],
            path: "app/LiveSub",
            exclude: ["Audio", "Backend", "Overlay", "Subtitles"],
            sources: ["App/AppController.swift", "App/LiveSubApp.swift", "App/TerminologySettingsView.swift", "MainWindow/TranscriptView.swift"]
        ),
        .target(
            name: "LiveSubAudio",
            path: "app/LiveSub/Audio"
        ),
        .target(
            name: "LiveSubOverlay",
            dependencies: ["LiveSubSubtitles"],
            path: "app/LiveSub/Overlay"
        ),
        .target(
            name: "LiveSubBackend",
            dependencies: ["LiveSubAudio"],
            path: "app/LiveSub/Backend"
        ),
        .target(
            name: "LiveSubSubtitles",
            path: "app/LiveSub/Subtitles"
        ),
        .executableTarget(
            name: "AudioPipelineChecks",
            dependencies: ["LiveSubAudio"],
            path: "app/LiveSubTests",
            exclude: ["OverlayPlacementChecks.swift", "SubtitleStoreChecks.swift", "BackendProtocolChecks.swift"],
            sources: ["AudioPipelineTests.swift"]
        ),
        .executableTarget(
            name: "OverlayPlacementChecks",
            dependencies: ["LiveSubOverlay"],
            path: "app/LiveSubTests",
            exclude: ["AudioPipelineTests.swift", "SubtitleStoreChecks.swift", "BackendProtocolChecks.swift"],
            sources: ["OverlayPlacementChecks.swift"]
        ),
        .executableTarget(
            name: "SubtitleStoreChecks",
            dependencies: ["LiveSubSubtitles"],
            path: "app/LiveSubTests",
            exclude: ["AudioPipelineTests.swift", "OverlayPlacementChecks.swift", "BackendProtocolChecks.swift"],
            sources: ["SubtitleStoreChecks.swift"]
        ),
        .executableTarget(
            name: "BackendProtocolChecks",
            dependencies: ["LiveSubBackend"],
            path: "app/LiveSubTests",
            exclude: ["AudioPipelineTests.swift", "OverlayPlacementChecks.swift", "SubtitleStoreChecks.swift"],
            sources: ["BackendProtocolChecks.swift"]
        ),
    ]
)
