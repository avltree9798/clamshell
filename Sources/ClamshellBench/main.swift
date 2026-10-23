// SPDX-License-Identifier: GPL-3.0-or-later
//
// M0 benchmark: how many guest instructions per second the Swift interpreter
// runs. The spec's bar is 300 million on an A17 Pro.
//
//   swift run -c release clamshell-bench [game.nds] [frames]
//   swift run -c release clamshell-bench [frames]
//
// With no game, it runs a built-in ARM loop that mixes ALU, load/store and
// branch instructions, which is closer to game code than a tight NOP loop.

import Foundation
import NDSCore

let arguments = CommandLine.arguments.dropFirst().filter { !$0.isEmpty }
let path = arguments.first { Int($0) == nil }
let frames = arguments.compactMap { Int($0) }.first ?? 600

let nds = NDS()
if let path {
    guard let data = FileManager.default.contents(atPath: path) else {
        print("cannot read \(path)")
        exit(1)
    }
    try nds.load(image: [UInt8](data))
} else {
    try nds.load(image: SyntheticROM.make())
}

let start = Date()
for _ in 0..<frames { nds.runFrame() }
let seconds = Date().timeIntervalSince(start)

let instructions = Double(nds.instructionsRetired)
let emulatedSeconds = Double(frames) / NDS.descriptor.frameRate
print(String(format: "%d frames in %.2f s: %.1f fps, %.0f%% of full speed", frames, seconds,
             Double(frames) / seconds, emulatedSeconds / seconds * 100))
print(String(format: "%.1f M guest instructions per second (target 300)", instructions / seconds / 1e6))
