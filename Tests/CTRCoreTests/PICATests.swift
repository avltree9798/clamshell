// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import CTRCore

/// Draws through the PICA200 front end and rasteriser with a pass-through vertex
/// shader, then reads the tiled colour buffer back.
@Suite struct PICATests {
    static let vertexPhysical: UInt32 = 0x2010_0000
    static let colorPhysical: UInt32 = 0x2020_0000
    static let size = 64

    static func float24(_ f: Float) -> UInt32 {
        guard f != 0 else { return 0 }
        let bits = f.bitPattern
        let exponent = Int((bits >> 23) & 0xFF) - 127 + 63
        return (bits >> 31) << 23 | UInt32(exponent) << 16 | (bits >> 7) & 0xFFFF
    }

    /// Three words, w first, as attribute and uniform uploads pack them.
    static func packed(_ v: SIMD4<Float>) -> [UInt32] {
        let x = float24(v.x), y = float24(v.y), z = float24(v.z), w = float24(v.w)
        return [w << 8 | z >> 16, (z & 0xFFFF) << 16 | y >> 8, (y & 0xFF) << 24 | x]
    }

    /// A PICA with a 64×64 RGBA8 target, copy logic op and a shader that moves
    /// v0 to the position and v1 to the colour.
    func makePICA() -> (AddressSpace, PICA) {
        let memory = AddressSpace()
        let pica = PICA(memory: memory)
        let mov: UInt32 = 0x13 << 26
        let program = [mov | 0 << 21 | 0 << 12, mov | 1 << 21 | 1 << 12, 0x22 << 26]
        pica.write(0x2CB, 0)
        for word in program { pica.write(0x2CC, word) }
        pica.write(0x2D5, 0)
        pica.write(0x2D6, 0xF | 0x1B << 5)  // xyzw mask, identity swizzle
        pica.write(0x2BA, 0)
        pica.write(0x2BD, 0b11)
        pica.write(0x50, 0x0302_0100)  // position
        pica.write(0x51, 0x0B0A_0908)  // colour
        pica.write(0x242, 1)  // two attributes
        pica.write(0x2BB, 0x10)
        pica.write(0x41, Self.float24(Float(Self.size / 2)))
        pica.write(0x43, Self.float24(Float(Self.size / 2)))
        pica.write(0x102, 3)  // copy
        pica.write(0x107, 0xF00)  // colour writes on, no depth test
        pica.write(0x112, 0xF)
        pica.write(0x113, 0xF)
        pica.write(0x117, 0)  // RGBA8
        pica.write(0x11D, Self.colorPhysical >> 3)
        pica.write(0x11E, UInt32(Self.size) | UInt32(Self.size - 1) << 12)
        return (memory, pica)
    }

    /// The colour at (x, y), y up from the bottom of the target.
    func pixel(_ memory: AddressSpace, _ x: Int, _ y: Int) -> PICAColor {
        let base = memory.host(physical: Self.colorPhysical)!
        let offset = PICAMemoryLayout.tiledOffset(x, Self.size - 1 - y, width: Self.size, bytesPerPixel: 4)
        return PICATexture.decode(.rgba8, base + offset)
    }

    let triangle: [(SIMD4<Float>, SIMD4<Float>)] = [
        (SIMD4(-1, -1, -0.5, 1), SIMD4(1, 0, 0, 1)),
        (SIMD4(1, -1, -0.5, 1), SIMD4(1, 0, 0, 1)),
        (SIMD4(0, 1, -0.5, 1), SIMD4(1, 0, 0, 1)),
    ]

    func checkTriangle(_ memory: AddressSpace, _ pica: PICA) {
        #expect(pica.drawCalls <= 1)
        // Inside: near the bottom middle. Outside: the top corners.
        #expect(pixel(memory, 32, 8) == PICAColor(255, 0, 0, 255))
        #expect(pixel(memory, 2, 60) == PICAColor(0, 0, 0, 0))
        #expect(pixel(memory, 61, 60) == PICAColor(0, 0, 0, 0))
        // Half the target, give or take the edges.
        #expect(abs(pica.rasterizer.fragments - Self.size * Self.size / 2) < Self.size * 2)
    }

    @Test func drawsATriangleFromAVertexBuffer() {
        let (memory, pica) = makePICA()
        let vertices = memory.host(physical: Self.vertexPhysical)!.assumingMemoryBound(to: Float.self)
        for (i, (position, color)) in triangle.enumerated() {
            for c in 0..<4 { vertices[i * 8 + c] = position[c]; vertices[i * 8 + 4 + c] = color[c] }
        }
        pica.write(0x200, Self.vertexPhysical >> 3)
        pica.write(0x201, 0xFF)  // two float vec4s
        pica.write(0x202, 0)
        pica.write(0x203, 0)
        pica.write(0x204, 0x10)
        pica.write(0x205, 32 << 16 | 2 << 28)
        pica.write(0x25E, 0)  // triangle list
        pica.write(0x228, 3)
        pica.write(0x22A, 0)
        pica.write(0x22E, 1)
        #expect(pica.drawCalls == 1)
        checkTriangle(memory, pica)
    }

    @Test func drawsATriangleInImmediateMode() {
        let (memory, pica) = makePICA()
        pica.write(0x25E, 0)
        pica.write(0x232, 0xF)
        for (position, color) in triangle {
            for word in Self.packed(position) + Self.packed(color) { pica.write(0x233, word) }
        }
        checkTriangle(memory, pica)
    }

    @Test func float24RoundTrips() {
        for f: Float in [1, -1, 0.5, 32, 0.15625, -1000] {
            #expect(Float24.float(Self.float24(f)) == f)
        }
        let v = SIMD4<Float>(1, -2, 0.25, 8)
        let p = Self.packed(v)
        #expect(Float24.vector(p[0], p[1], p[2]) == v)
    }

    @Test func commandListsUseMasksAndConsecutiveWrites() {
        let memory = AddressSpace()
        let pica = PICA(memory: memory)
        let base: UInt32 = 0x0800_0000
        memory.mapNew(base, size: 0x1000, permission: .readWrite, state: .private)
        let words: [UInt32] = [
            0x1234_5678, 0x000F_0041,             // full write
            0xAAAA_AAAA, 0x0003_0043,             // low half only
            1, 0x802F_0050, 2, 3,                 // 0x50, 0x51, 0x52 consecutive
        ]
        for (i, w) in words.enumerated() { memory.write32(base + UInt32(i * 4), w) }
        pica.write(0x43, 0xFFFF_0000)
        pica.run(commandList: base, size: words.count * 4)
        #expect(pica.regs[0x41] == 0x1234_5678)
        #expect(pica.regs[0x43] == 0xFFFF_AAAA)
        #expect(pica.regs[0x50] == 1 && pica.regs[0x51] == 2 && pica.regs[0x52] == 3)
    }
}
