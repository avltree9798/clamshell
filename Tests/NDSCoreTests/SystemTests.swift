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

    @Test func huffmanDecompression() {
        // 8-bit data, 4 bytes. A one-node tree: bit 0 gives 0xAA, bit 1 gives 0x55.
        // The stream 0110 decodes to AA 55 55 AA.
        let nds = NDS()
        let data: [UInt8] = [0x28, 0x04, 0x00, 0x00, 0x01, 0xC0, 0xAA, 0x55, 0x00, 0x00, 0x00, 0x60]
        for (i, b) in data.enumerated() { nds.bus9.write8(0x0200_0000 + UInt32(i), b) }
        nds.arm9.setReg(0, 0x0200_0000)
        nds.arm9.setReg(1, 0x0200_1000)
        #expect(HLEBIOS.call(0x13, cpu: nds.arm9, bus: nds.bus9, isARM9: true))
        #expect(nds.bus9.read32(0x0200_1000) == 0xAA55_55AA)
    }

    @Test func diffUnfilter() {
        let nds = NDS()
        let data: [UInt8] = [0x81, 0x04, 0x00, 0x00, 1, 1, 2, 0xFF]
        for (i, b) in data.enumerated() { nds.bus9.write8(0x0200_0000 + UInt32(i), b) }
        nds.arm9.setReg(0, 0x0200_0000)
        nds.arm9.setReg(1, 0x0200_1000)
        #expect(HLEBIOS.call(0x16, cpu: nds.arm9, bus: nds.bus9, isARM9: true))
        #expect(nds.bus9.read32(0x0200_1000) == 0x0304_0201)
    }

    /// Reads the date and time over the bit-banged RTC port, LSB first.
    @Test func rtcReturnsTheTime() {
        let nds = NDS()
        func port(_ v: UInt8) { nds.bus7.write8(0x0400_0138, v) }
        port(0x16)  // select low, clock high, writing
        port(0x16 | 4)
        // Command 0110 010 1 (read date and time), sent LSB first.
        let command: UInt8 = 0x65
        for bit in 0..<8 {
            let b = (command >> UInt8(bit)) & 1
            port(0x74 | b)       // clock low
            port(0x76 | b)       // clock high: bit taken
        }
        var bytes: [UInt8] = []
        for _ in 0..<7 {
            var byte: UInt8 = 0
            for bit in 0..<8 {
                port(0x64)
                port(0x66)
                byte |= UInt8(nds.bus7.read8(0x0400_0138) & 1) << UInt8(bit)
            }
            bytes.append(byte)
        }
        port(0x16)
        let expected = RTC.dateTime()
        #expect(bytes[0] == expected[0] && bytes[1] == expected[1] && bytes[2] == expected[2])
        #expect(bytes[1] >= 1 && bytes[1] <= 0x12)
    }
}
