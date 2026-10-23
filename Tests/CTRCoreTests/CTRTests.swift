// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit
import Testing
@testable import CTRCore

@Suite struct CTRHomebrew {
    struct Report { var magic, frames, color, aSeen, workerRan, mutexOK, gspFirst, sleepOK: UInt32 }

    func report(_ ctr: CTR) -> Report {
        let m = ctr.memory, a = HelloImage.reportAddress
        let w = (0..<8).map { m.read32(a + UInt32($0 * 4)) }
        return Report(magic: w[0], frames: w[1], color: w[2], aSeen: w[3], workerRan: w[4], mutexOK: w[5], gspFirst: w[6], sleepOK: w[7])
    }

    func makeCore() -> (CTR, FrameSink, InputState) {
        let frames = FrameSink(screens: CTR.descriptor.screens)
        let input = InputState()
        let ctr = CTR(frames: frames, audio: AudioRing(frames: 4096), input: input)
        return (ctr, frames, input)
    }

    /// A homebrew built from Tools/ctr-hello/hello.c with clang: services, shared
    /// memory, threads, a mutex, sleep, VBlank interrupts and the framebuffer.
    @Test func helloRunsToCompletion() throws {
        let (ctr, frames, input) = makeCore()
        try ctr.load(image: HelloImage.bytes)
        ctr.runFrame()
        ctr.runFrame()
        input.press(.a)
        for _ in 0..<6 where !ctr.hasExited { ctr.runFrame() }

        let r = report(ctr)
        #expect(ctr.log.contains("hello from the 3DS"), "log: \(ctr.log)")
        #expect(r.magic == 0x5245_5054)
        #expect(r.gspFirst == 1)
        #expect(r.sleepOK == 1)
        #expect(r.workerRan == 1)
        #expect(r.mutexOK == 1)
        #expect(r.frames == 4)
        #expect(r.aSeen == 1)
        #expect(ctr.log.contains("goodbye"))
        #expect(ctr.hasExited)
        #expect(ctr.memoryFaults == 0)

        // The top screen shows the colour drawn while A was held: green.
        let top = frames.acquireNewest()?[0]
        #expect(top?[120 * 400 + 200] == 0xFF00_FF00)
    }

    @Test func rejectsRetailImages() {
        let (ctr, _, _) = makeCore()
        #expect(throws: CoreError.self) { try ctr.load(image: [UInt8](repeating: 0, count: 0x200)) }
    }
}
