// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import NDSCore

@Suite struct SystemTests {
    @Test func syntheticROMBootsAndRuns() throws {
        let nds = NDS()
        try nds.load(image: SyntheticROM.make())
        nds.runFrame()
        #expect(nds.instructionsRetired > 100_000)
        #expect(nds.arm9.pc >= SyntheticROM.arm9Address && nds.arm9.pc < SyntheticROM.arm9Address + 64)
        #expect(nds.arm7.pc >= SyntheticROM.arm7Address && nds.arm7.pc < SyntheticROM.arm7Address + 64)
    }

    @Test func oneFrameIsOneVideoFrame() throws {
        let nds = NDS()
        try nds.load(image: SyntheticROM.make())
        nds.runFrame()
        #expect(nds.scheduler.now == NDSClock.cyclesPerFrame)
        // The frame boundary falls at the end of line 262, so VCOUNT wraps to 0.
        #expect(nds.vcount == 0)
    }

    @Test func hardwareDivider() {
        let m = MathUnit()
        m.divControl = 0
        m.numerator = UInt64(bitPattern: -7)
        m.denominator = 2
        m.divide()
        #expect(Int64(bitPattern: m.quotient) == -3)
        #expect(Int64(bitPattern: m.remainder) == -1)
    }

    @Test func hardwareSquareRoot() {
        let m = MathUnit()
        m.sqrtControl = 1
        m.sqrtParameter = UInt64.max
        m.squareRoot()
        #expect(m.sqrtResult == 0xFFFF_FFFF)
        m.sqrtParameter = 1_000_000
        m.squareRoot()
        #expect(m.sqrtResult == 1000)
    }

    @Test func timerOverflowRaisesIRQ() throws {
        let nds = NDS()
        try nds.load(image: SyntheticROM.make())
        nds.bus9.write32(0x0400_0210, IRQ.timer(0))       // IE
        nds.bus9.write16(0x0400_0100, 0xFF00)             // reload: 256 ticks to overflow
        nds.bus9.write16(0x0400_0102, 0x00C0)             // enable, IRQ, prescaler 1
        nds.runFrame()
        #expect(nds.irq9.iflags & IRQ.timer(0) != 0)
    }

    @Test func ipcFIFOPassesWords() {
        let nds = NDS()
        nds.bus9.write16(0x0400_0184, 0x8000)  // enable ARM9 FIFO
        nds.bus7.write16(0x0400_0184, 0x8000)  // enable ARM7 FIFO
        nds.bus9.write32(0x0400_0188, 0x1234_5678)
        #expect(nds.bus7.read32(0x0410_0000) == 0x1234_5678)
        #expect(nds.bus7.read16(0x0400_0184) & 0x100 != 0)  // receive FIFO empty again
    }

    @Test func lz77Decompression() {
        // Header: type 0x10, size 8. Block flags 0b0100_0000: one literal 'A', then a
        // back-reference of length 7 at distance 1, giving "AAAAAAAA".
        let nds = NDS()
        let data: [UInt8] = [0x10, 0x08, 0x00, 0x00, 0x40, 0x41, 0x40, 0x00]
        for (i, b) in data.enumerated() { nds.bus9.write8(0x0200_0000 + UInt32(i), b) }
        nds.arm9.setReg(0, 0x0200_0000)
        nds.arm9.setReg(1, 0x0200_1000)
        #expect(HLEBIOS.call(0x11, cpu: nds.arm9, bus: nds.bus9, isARM9: true))
        for i in 0..<8 { #expect(nds.bus9.read8(0x0200_1000 + UInt32(i)) == 0x41) }
    }
}
