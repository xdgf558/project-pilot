// swift-tools-version: 6.0
import PackageDescription

// ── 模块依赖规则(P0-02)────────────────────────────────────────────────
//
//   pilotctl ──┬──> PilotInfrastructure ──> PilotCore
//              └───────────────────────────────^
//
// 方向由 SPM 在编译期强制:PilotCore 没有声明任何依赖,
// 因此它在语法上就无法 import PilotInfrastructure。
//
// SPM 管不了的那一半 —— PilotCore 内部不许出现 Process、FileManager、
// URLSession 等 IO 符号 —— 由 Scripts/check-module-boundaries.sh 检查,
// 该脚本在 CI 中运行。
//
// 这里没有 ProjectPilot.app:界面在 Phase 8 才需要,届时以独立 Xcode
// 工程链接本 package。理由见 Docs/DECISIONS.md 的 ADR-0001。

/// P0-03:全部 target 使用 Swift 6 语言模式,严格并发检查默认开启。
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "ProjectPilot",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PilotCore", targets: ["PilotCore"]),
        .library(name: "PilotInfrastructure", targets: ["PilotInfrastructure"]),
        .executable(name: "pilotctl", targets: ["pilotctl"]),
    ],
    targets: [
        .target(
            name: "PilotCore",
            swiftSettings: strictSettings
        ),
        .target(
            name: "PilotInfrastructure",
            dependencies: ["PilotCore"],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "pilotctl",
            dependencies: ["PilotCore", "PilotInfrastructure"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "PilotCoreTests",
            dependencies: ["PilotCore"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "PilotInfrastructureTests",
            dependencies: ["PilotInfrastructure"],
            swiftSettings: strictSettings
        ),
    ]
)
