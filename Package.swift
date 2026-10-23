// swift-tools-version: 6.0
// Clamshell: Nintendo DS (and later 3DS) emulation for iPhone, iPad and iPhone Duo.
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// The cores are hot loops: build them without runtime safety checks in release.
let coreSettings: [SwiftSetting] = [
    .unsafeFlags(["-Ounchecked", "-wmo", "-enforce-exclusivity=unchecked", "-Xfrontend", "-disable-llvm-merge-functions-pass",
                   "-cross-module-optimization"], .when(configuration: .release)),
]

let package = Package(
    name: "Clamshell",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "EmuKit", targets: ["EmuKit"]),
        .library(name: "ARMCore", targets: ["ARMCore"]),
        .library(name: "NDSCore", targets: ["NDSCore"]),
        .library(name: "CTRCore", targets: ["CTRCore"]),
        .executable(name: "clamshell-bench", targets: ["ClamshellBench"]),
    ],
    targets: [
        .target(name: "EmuKit"),
        // The ARM interpreter shared by the DS (ARM7, ARM9) and 3DS (ARM11) cores.
        .target(name: "ARMCore", swiftSettings: coreSettings),
        .target(name: "NDSCore", dependencies: ["EmuKit", "ARMCore"], swiftSettings: coreSettings),
        .target(name: "CTRCore", dependencies: ["EmuKit", "ARMCore"], swiftSettings: coreSettings),
        .executableTarget(name: "ClamshellBench", dependencies: ["NDSCore"], swiftSettings: coreSettings),
        .testTarget(name: "EmuKitTests", dependencies: ["EmuKit"]),
        .testTarget(name: "ARMCoreTests", dependencies: ["ARMCore"]),
        .testTarget(name: "NDSCoreTests", dependencies: ["NDSCore", "ARMCore"]),
        .testTarget(name: "CTRCoreTests", dependencies: ["CTRCore", "ARMCore"]),
    ]
)
