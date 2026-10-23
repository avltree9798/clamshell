// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import NDSCore

/// Sets up a scene through the ARM9's registers, runs one frame and checks pixels.
@Suite struct VideoTests {
    static let red: UInt16 = 0x001F, green: UInt16 = 0x03E0, blue: UInt16 = 0x7C00, white: UInt16 = 0x7FFF

    func machine() throws -> NDS {
        let nds = NDS()
        try nds.load(image: SyntheticROM.make())
        nds.bus9!.write32(0x0400_0304, 0x8203)  // POWCNT1: both engines on, A on top
        return nds
    }

    func pixel(_ engine: Engine2D!, _ x: Int, _ y: Int) -> UInt32 { engine.frame[y * 256 + x] }
    func argb(_ c: UInt16) -> UInt32 { NDS.bgra(from: c) }

    @Test func textBackground16Colour() throws {
        let nds = try machine()
        let bus = nds.bus9!
        bus.write8(0x0400_0240, 0x81)                // VRAM A: engine A BG at 0x06000000
        bus.write32(0x0400_0000, 0x0001_0100)        // display on, mode 0, BG0
        bus.write16(0x0400_0008, 1 << 2)             // BG0: chars at 16 KB, map at 0
        bus.write16(0x0600_0000, 1 | 2 << 12)        // map (0,0): tile 1, palette 2
        bus.write16(0x0600_4020, 0x0021)             // tile 1, row 0: colours 1, 2
        bus.write16(0x0500_0000, Self.green)         // backdrop
        bus.write16(0x0500_0000 + (2 * 16 + 1) * 2, Self.red)
        bus.write16(0x0500_0000 + (2 * 16 + 2) * 2, Self.blue)
        nds.runFrame()
        #expect(pixel(nds.engineA, 0, 0) == argb(Self.red))
        #expect(pixel(nds.engineA, 1, 0) == argb(Self.blue))
        #expect(pixel(nds.engineA, 2, 0) == argb(Self.green))
        #expect(pixel(nds.engineA, 8, 0) == argb(Self.green))
    }

    @Test func scrolledTextBackground() throws {
        let nds = try machine()
        let bus = nds.bus9!
        bus.write8(0x0400_0240, 0x81)
        bus.write32(0x0400_0000, 0x0001_0100)
        bus.write16(0x0400_0008, 1 << 2)
        bus.write16(0x0600_0000, 1)                  // map (0,0): tile 1
        bus.write16(0x0600_4020 + 2 * 4, 0x0001)     // tile 1, row 2, pixel 0: colour 1
        bus.write16(0x0500_0002, Self.red)
        bus.write32(0x0400_0010, UInt32(504) | 510 << 16)  // scroll x by -8, y by -2
        nds.runFrame()
        #expect(pixel(nds.engineA, 8, 4) == argb(Self.red))
        #expect(pixel(nds.engineA, 0, 2) == argb(0))
    }

    @Test func spriteOverBackground() throws {
        let nds = try machine()
        let bus = nds.bus9!
        bus.write8(0x0400_0241, 0x82)                // VRAM B: engine A OBJ at 0x06400000
        bus.write32(0x0400_0000, 0x0001_1010)        // display on, OBJ on, 1D tile mapping
        bus.write16(0x0640_0000, 0x0005)             // tile 0, pixel (0,0): colour 5
        bus.write16(0x0500_0200 + 5 * 2, Self.white)
        bus.write16(0x0700_0000, 20 | 0x2000)        // y 20, 256 colours, 8 × 8
        bus.write16(0x0700_0002, 10)                 // x 10
        bus.write16(0x0700_0004, 0)                  // tile 0
        for n in 1..<128 { bus.write16(0x0700_0000 + UInt32(n * 8), 0x200) }  // hide the rest
        nds.runFrame()
        #expect(pixel(nds.engineA, 10, 20) == argb(Self.white))
        #expect(pixel(nds.engineA, 11, 20) == argb(0))
    }

    @Test func directColourBitmap() throws {
        let nds = try machine()
        let bus = nds.bus9!
        bus.write8(0x0400_0240, 0x81)
        bus.write32(0x0400_0000, 0x0001_0805)        // mode 5, BG3
        bus.write16(0x0400_000E, 0x4084)             // BG3: direct-colour bitmap, 256 × 256
        bus.write32(0x0400_0030, 0x0000_0100)        // PA = 1, PB = 0
        bus.write32(0x0400_0034, 0x0100_0000)        // PC = 0, PD = 1
        bus.write16(0x0600_0000 + (5 * 256 + 3) * 2, 0x8000 | Self.blue)
        nds.runFrame()
        #expect(pixel(nds.engineA, 3, 5) == argb(Self.blue))
        #expect(pixel(nds.engineA, 4, 5) == argb(0))
    }

    @Test func engineBOnBottomScreen() throws {
        let nds = try machine()
        let bus = nds.bus9!
        bus.write8(0x0400_0242, 0x84)                // VRAM C: engine B BG at 0x06200000
        bus.write32(0x0400_1000, 0x0001_0100)
        bus.write16(0x0400_1008, 1 << 2)
        bus.write16(0x0620_0000, 1)
        bus.write16(0x0620_4020, 0x0001)
        bus.write16(0x0500_0402, Self.red)
        nds.runFrame()
        #expect(pixel(nds.engineB, 0, 0) == argb(Self.red))
        let bottom = nds.frames.acquireNewest()![1]
        #expect(bottom[0] == argb(Self.red))
    }

    @Test func alphaBlendAndMasterBrightness() throws {
        let nds = try machine()
        let bus = nds.bus9!
        bus.write8(0x0400_0240, 0x81)
        bus.write32(0x0400_0000, 0x0001_0100)
        bus.write16(0x0400_0008, 1 << 2)
        bus.write16(0x0600_0000, 1)
        bus.write16(0x0600_4020, 0x0001)
        bus.write16(0x0500_0000, 0)                  // black backdrop
        bus.write16(0x0500_0002, 0x001E)             // red 30
        bus.write16(0x0400_0050, 0x2041)             // BG0 over backdrop, alpha blend
        bus.write16(0x0400_0052, 0x0808)             // EVA = EVB = 8/16
        nds.runFrame()
        #expect(pixel(nds.engineA, 0, 0) == argb(0x000F))

        bus.write16(0x0400_0050, 0)
        bus.write16(0x0400_006C, 0x8010)             // master brightness: fully dark
        nds.runFrame()
        #expect(pixel(nds.engineA, 0, 0) == 0xFF00_0000)
    }
}
