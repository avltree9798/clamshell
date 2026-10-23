// swift-tools-version: 6.0
// Clamshell: Nintendo DS (and later 3DS) emulation for iPhone, iPad and iPhone Duo.
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// The cores are hot loops. Not -Ounchecked or -enforce-exclusivity=unchecked: with
// Swift 6.1 on arm64 either one miscompiles the cores (release tests crash). The CPU's
// hot properties opt out of exclusivity checks one by one with @exclusivity(unchecked).
let coreSettings: [SwiftSetting] = [
    .unsafeFlags(["-O", "-wmo", "-Xfrontend", "-disable-llvm-merge-functions-pass",
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
        // The 3DS CPU's fast path in C (ARM-state integer instructions straight from the page table).
        .target(name: "CARM11", cSettings: [.unsafeFlags(["-O3"], .when(configuration: .release))]),
        .target(name: "CTRCore", dependencies: ["EmuKit", "ARMCore", "CARM11"], swiftSettings: coreSettings),
        .executableTarget(name: "ClamshellBench", dependencies: ["NDSCore", "CTRCore", "EmuKit"], swiftSettings: coreSettings),
        .testTarget(name: "EmuKitTests", dependencies: ["EmuKit"]),
        .testTarget(name: "ARMCoreTests", dependencies: ["ARMCore"]),
        .testTarget(name: "NDSCoreTests", dependencies: ["NDSCore", "ARMCore"]),
        .testTarget(name: "CTRCoreTests", dependencies: ["CTRCore", "ARMCore", "CARM11"]),
    ]
)
