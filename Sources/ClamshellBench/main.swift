// SPDX-License-Identifier: GPL-3.0-or-later
//
// CPU benchmark: how fast the interpreters run guest code, as a share of the
// real console's speed.
//
//   swift run -c release clamshell-bench [game.nds | homebrew.3dsx] [frames]
//   swift run -c release clamshell-bench [frames]          (both built-in loops)
//
// The built-in loops mix ALU, load/store and branch instructions and never
// idle, so they are a worst case: real games spend part of every frame waiting
// for VBlank. Speed assumes one instruction per CPU cycle, which overstates the
// work (real ARM9 and ARM11 code averages more than one cycle per instruction).

import CTRCore
import EmuKit
import Foundation
import NDSCore

let arguments = CommandLine.arguments.dropFirst().filter { !$0.isEmpty }
let path = arguments.first { Int($0) == nil }
let frames = arguments.compactMap { Int($0) }.first ?? 600

func measure(_ name: String, frameRate: Double, instructions: () -> UInt64, frame: () -> Void) {
    let start = Date()
    for _ in 0..<frames { frame() }
    let seconds = Date().timeIntervalSince(start)
    let emulated = Double(frames) / frameRate
    print(String(format: "%@: %d frames in %.2f s, %.1f fps, %.0f%% of full speed, %.1f M guest instructions/s",
                 name, frames, seconds, Double(frames) / seconds, emulated / seconds * 100,
                 Double(instructions()) / seconds / 1e6))
}

func runDS(_ image: [UInt8]) throws {
    let nds = NDS()
    try nds.load(image: image)
    measure("DS ", frameRate: NDS.descriptor.frameRate, instructions: { nds.instructionsRetired }) { nds.runFrame() }
}

func run3DS(_ image: [UInt8]) throws {
    let ctr = CTR(frames: FrameSink(screens: CTR.descriptor.screens), audio: AudioRing(frames: 4096), input: InputState())
    try ctr.load(image: image)
    measure("3DS", frameRate: CTR.descriptor.frameRate, instructions: { ctr.instructionsRetired }) { ctr.runFrame() }
}

do {
    if let path {
        guard let data = FileManager.default.contents(atPath: path) else {
            print("cannot read \(path)")
            exit(1)
        }
        if path.lowercased().hasSuffix(".3dsx") { try run3DS([UInt8](data)) } else { try runDS([UInt8](data)) }
    } else {
        try runDS(SyntheticROM.make())
        try run3DS(SyntheticHomebrew.make())
    }
} catch {
    print("error: \(error)")
    exit(1)
}
