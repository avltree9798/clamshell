// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import NDSCore

/// Draws through the geometry command ports and checks what engine A shows as BG0.
@Suite struct Video3DTests {
    static let red: UInt32 = 0x001F, green: UInt32 = 0x03E0, blue: UInt32 = 0x7C00, white: UInt32 = 0x7FFF

    /// One unit in the DS's 4.12 vertex format.
    static let one: Int32 = 4096

    struct Scene {
        let nds: NDS
        var bus: Bus9 { nds.bus9! }

        func command(_ id: UInt32, _ params: UInt32...) {
            if params.isEmpty { bus.write32(0x0400_0400 + id * 4, 0) }
            for p in params { bus.write32(0x0400_0400 + id * 4, p) }
        }

        func vertex(_ x: Int32, _ y: Int32, _ z: Int32) {
            command(0x23, UInt32(UInt16(bitPattern: Int16(x))) | UInt32(UInt16(bitPattern: Int16(y))) << 16,
                    UInt32(UInt16(bitPattern: Int16(z))))
        }

        /// Shows a frame: the swap renders at VBlank and engine A displays it during the next frame.
        func show() {
            command(0x50, 0)
            nds.runFrame()
            nds.runFrame()
        }

        func pixel(_ x: Int, _ y: Int) -> UInt32 { nds.engineA.frame[y * 256 + x] }
    }

    func scene() throws -> Scene {
        let nds = NDS()
        try nds.load(image: SyntheticROM.make())
        let s = Scene(nds: nds)
        s.bus.write32(0x0400_0304, 0x820F)        // POWCNT1: everything on, A on top
        s.bus.write32(0x0400_0000, 0x0001_0108)   // display on, BG0 on, BG0 is 3D
        s.bus.write16(0x0500_0000, 0)             // black backdrop
        s.command(0x10, 0); s.command(0x15)       // projection = identity
        s.command(0x10, 2); s.command(0x15)       // position and vector = identity
        s.command(0x60, 0 | 0 << 8 | 255 << 16 | 191 << 24)
        s.command(0x29, 0xC0 | 31 << 16)          // both sides, opaque
        return s
    }

    func argb(_ c: UInt32) -> UInt32 { NDS.bgra(from: UInt16(c)) }

    @Test func flatTriangle() throws {
        let s = try scene()
        s.command(0x40, 0)
        s.command(0x20, Self.red)
        s.vertex(-Self.one / 2, -Self.one / 2, 0)
        s.vertex(Self.one / 2, -Self.one / 2, 0)
        s.vertex(0, Self.one / 2, 0)
        s.command(0x41)
        s.show()
        #expect(s.pixel(128, 96) == argb(Self.red))
        #expect(s.pixel(5, 5) == argb(0))  // clear colour has alpha 0: the backdrop shows
    }

    @Test func vertexDiffAddsWholeSteps() throws {
        // VTX_DIFF offsets are 1.0.9, the same step as the 1.3.12 coordinates' last bit.
        func diff(_ x: Int32, _ y: Int32, _ z: Int32) -> UInt32 {
            UInt32(bitPattern: x & 0x3FF | (y & 0x3FF) << 10 | (z & 0x3FF) << 20)
        }
        let s = try scene()
        s.command(0x40, 0)
        s.command(0x20, Self.red)
        s.vertex(-256, -256, 0)
        s.command(0x28, diff(511, 0, 0))
        s.command(0x28, diff(-255, 511, 0))
        s.command(0x41)
        s.show()
        // Each side is 1/8 of the view, about 16 pixels: the middle is covered, 20 pixels out is not.
        #expect(s.pixel(128, 96) == argb(Self.red))
        #expect(s.pixel(148, 96) == argb(0))
        #expect(s.pixel(128, 116) == argb(0))
    }

    @Test func nearerQuadWinsDepthTest() throws {
        let s = try scene()
        s.command(0x40, 1)
        s.command(0x20, Self.red)  // near, drawn first
        for (x, y) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] { s.vertex(Int32(x) * Self.one / 2, Int32(y) * Self.one / 2, -Self.one / 2) }
        s.command(0x20, Self.green)  // far, drawn second
        for (x, y) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] { s.vertex(Int32(x) * Self.one, Int32(y) * Self.one, Self.one / 2) }
        s.show()
        #expect(s.pixel(128, 96) == argb(Self.red))
        #expect(s.pixel(10, 96) == argb(Self.green))
    }

    @Test func packedFIFOCommands() throws {
        let s = try scene()
        // BEGIN_VTXS, COLOR, VTX_16, VTX_16 packed in one word, then their parameters in order.
        s.bus.write32(0x0400_0400, 0x40 | 0x20 << 8 | 0x23 << 16 | 0x23 << 24)
        s.bus.write32(0x0400_0400, 0)                 // triangles
        s.bus.write32(0x0400_0400, Self.blue)
        for (x, y) in [(-1, -1), (1, -1)] {
            s.bus.write32(0x0400_0400, UInt32(UInt16(bitPattern: Int16(x * 2048))) | UInt32(UInt16(bitPattern: Int16(y * 2048))) << 16)
            s.bus.write32(0x0400_0400, 0)
        }
        s.bus.write32(0x0400_0400, 0x23)
        s.bus.write32(0x0400_0400, UInt32(UInt16(bitPattern: Int16(2048))) << 16)
        s.bus.write32(0x0400_0400, 0)
        s.show()
        #expect(s.pixel(128, 96) == argb(Self.blue))
    }

    @Test func directColourTexture() throws {
        let s = try scene()
        s.bus.write8(0x0400_0240, 0x80)               // VRAM A in the LCDC window to fill it
        for i in 0..<64 { s.bus.write16(0x0680_0000 + UInt32(i * 2), UInt16(0x8000 | Self.blue)) }
        s.bus.write8(0x0400_0240, 0x83)               // then texture slot 0
        s.bus.write32(0x0400_0060, 1)                 // DISP3DCNT: textures on
        s.command(0x2A, 7 << 26 | 3 << 16)            // direct colour, 8 × 8, repeat
        s.command(0x40, 0)
        s.command(0x20, Self.white)
        for (x, y) in [(-1, -1), (1, -1), (0, 1)] {
            s.command(0x22, UInt32(UInt16(bitPattern: Int16((x + 1) * 4 * 16))) | UInt32(UInt16(bitPattern: Int16((y + 1) * 4 * 16))) << 16)
            s.vertex(Int32(x) * Self.one / 2, Int32(y) * Self.one / 2, 0)
        }
        s.show()
        #expect(s.pixel(128, 96) == argb(Self.blue))
    }

    @Test func translationReachesClipMatrix() throws {
        let s = try scene()
        s.command(0x1C, UInt32(bitPattern: Self.one), 0, 0)
        #expect(s.bus.read32(0x0400_0640 + 12 * 4) == UInt32(Self.one))
    }

    @Test func backFacesCulled() throws {
        let s = try scene()
        s.command(0x29, 0x80 | 31 << 16)              // front only
        s.command(0x40, 0)
        s.command(0x20, Self.red)
        // Wound the other way from flatTriangle.
        s.vertex(0, Self.one / 2, 0)
        s.vertex(Self.one / 2, -Self.one / 2, 0)
        s.vertex(-Self.one / 2, -Self.one / 2, 0)
        s.show()
        let culled = s.pixel(128, 96) == argb(0)
        // And the opposite winding is drawn.
        let t = try scene()
        t.command(0x29, 0x80 | 31 << 16)
        t.command(0x40, 0)
        t.command(0x20, Self.red)
        t.vertex(-Self.one / 2, -Self.one / 2, 0)
        t.vertex(Self.one / 2, -Self.one / 2, 0)
        t.vertex(0, Self.one / 2, 0)
        t.show()
        #expect(culled != (t.pixel(128, 96) == argb(0)))
    }
}
