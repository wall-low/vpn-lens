// swift-tools-version: 6.0
import PackageDescription

// VPNLensCoreFFI.xcframework и Sources/VPNLensCore/vpnlens_core.swift собирает scripts/build-app.sh
// из Rust-крейта crates/core. Руками их не правим.
let package = Package(
    name: "VPNLens",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "VPNLensCoreFFI", path: "Frameworks/VPNLensCoreFFI.xcframework"),
        .target(
            name: "VPNLensCore",
            dependencies: ["VPNLensCoreFFI"],
            linkerSettings: [.linkedFramework("SystemConfiguration")]
        ),
        // Логика без AppKit и системных вызовов: её проверяют тесты.
        .target(name: "VPNLensLogic"),
        .executableTarget(name: "VPNLens", dependencies: ["VPNLensCore", "VPNLensLogic"]),
        .testTarget(name: "VPNLensLogicTests", dependencies: ["VPNLensLogic"]),
    ]
)
