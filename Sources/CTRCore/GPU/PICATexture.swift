// SPDX-License-Identifier: GPL-3.0-or-later
//
// PICA200 texture and framebuffer formats. Everything is stored in 8 × 8 tiles with
// the pixels of a tile in Morton (Z) order, rows from bottom to top. ETC1 textures
// are 8 × 8 tiles of four 4 × 4 blocks. Layouts as 3dbrew and Citra describe them.

/// An RGBA colour with 0...255 channels, as the PICA's fixed-function units use.
typealias PICAColor = SIMD4<Int32>

enum PICAMemoryLayout {
    /// Interleaves the low three bits of x and y: x in the even bits, y in the odd ones.
    @inline(__always) static func morton(_ x: Int, _ y: Int) -> Int {
        var m = 0
        for bit in 0..<3 {
            m |= ((x >> bit) & 1) << (bit * 2)
            m |= ((y >> bit) & 1) << (bit * 2 + 1)
        }
        return m
    }

    /// Byte offset of pixel (x, y) in a tiled image `width` pixels wide.
    @inline(__always) static func tiledOffset(_ x: Int, _ y: Int, width: Int, bytesPerPixel: Int) -> Int {
        ((y & ~7) * width + (x & ~7) * 8 + morton(x & 7, y & 7)) * bytesPerPixel
    }
}

enum PICATextureFormat: UInt32 {
    case rgba8 = 0, rgb8, rgb5a1, rgb565, rgba4, ia8, hilo8, i8, a8, ia4, i4, a4, etc1, etc1a4

    /// Bits per texel.
    var bits: Int {
        switch self {
        case .rgba8: 32
        case .rgb8: 24
        case .rgb5a1, .rgb565, .rgba4, .ia8, .hilo8: 16
        case .i8, .a8, .ia4, .etc1a4: 8
        case .i4, .a4, .etc1: 4
        }
    }
}

enum PICATexture {
    @inline(__always) static func expand5(_ v: UInt32) -> Int32 { Int32(v << 3 | v >> 2) }
    @inline(__always) static func expand6(_ v: UInt32) -> Int32 { Int32(v << 2 | v >> 4) }
    @inline(__always) static func expand4(_ v: UInt32) -> Int32 { Int32(v * 17) }

    /// Decodes a 16- or 32-bit colour-buffer style pixel (shared by textures and framebuffers).
    @inline(__always) static func decode(_ format: PICATextureFormat, _ p: UnsafeRawPointer) -> PICAColor {
        switch format {
        case .rgba8:
            return PICAColor(Int32(p.load(fromByteOffset: 3, as: UInt8.self)), Int32(p.load(fromByteOffset: 2, as: UInt8.self)),
                             Int32(p.load(fromByteOffset: 1, as: UInt8.self)), Int32(p.load(as: UInt8.self)))
        case .rgb8:
            return PICAColor(Int32(p.load(fromByteOffset: 2, as: UInt8.self)), Int32(p.load(fromByteOffset: 1, as: UInt8.self)),
                             Int32(p.load(as: UInt8.self)), 255)
        case .rgb5a1:
            let v = UInt32(p.loadUnaligned(as: UInt16.self))
            return PICAColor(expand5((v >> 11) & 0x1F), expand5((v >> 6) & 0x1F), expand5((v >> 1) & 0x1F), v & 1 != 0 ? 255 : 0)
        case .rgb565:
            let v = UInt32(p.loadUnaligned(as: UInt16.self))
            return PICAColor(expand5(v >> 11), expand6((v >> 5) & 0x3F), expand5(v & 0x1F), 255)
        case .rgba4:
            let v = UInt32(p.loadUnaligned(as: UInt16.self))
            return PICAColor(expand4(v >> 12), expand4((v >> 8) & 0xF), expand4((v >> 4) & 0xF), expand4(v & 0xF))
        case .ia8:
            let i = Int32(p.load(fromByteOffset: 1, as: UInt8.self))
            return PICAColor(i, i, i, Int32(p.load(as: UInt8.self)))
        case .hilo8:
            return PICAColor(Int32(p.load(fromByteOffset: 1, as: UInt8.self)), Int32(p.load(as: UInt8.self)), 0, 255)
        case .i8:
            let i = Int32(p.load(as: UInt8.self))
            return PICAColor(i, i, i, 255)
        case .a8:
            return PICAColor(0, 0, 0, Int32(p.load(as: UInt8.self)))
        case .ia4:
            let v = UInt32(p.load(as: UInt8.self))
            let i = expand4(v >> 4)
            return PICAColor(i, i, i, expand4(v & 0xF))
        default:
            return PICAColor(0, 0, 0, 255)
        }
    }

    /// Texel (x, y) of a texture, with y counted from the bottom row in memory.
    static func texel(_ format: PICATextureFormat, base: UnsafeRawPointer, width: Int, x: Int, y: Int) -> PICAColor {
        switch format {
        case .i4, .a4:
            let index = (y & ~7) * width + (x & ~7) * 8 + PICAMemoryLayout.morton(x & 7, y & 7)
            let byte = UInt32(base.load(fromByteOffset: index / 2, as: UInt8.self))
            let v = expand4(index & 1 != 0 ? byte >> 4 : byte & 0xF)
            return format == .i4 ? PICAColor(v, v, v, 255) : PICAColor(0, 0, 0, v)
        case .etc1, .etc1a4:
            return etc(format == .etc1a4, base: base, width: width, x: x, y: y)
        default:
            let bpp = format.bits / 8
            return decode(format, base + PICAMemoryLayout.tiledOffset(x, y, width: width, bytesPerPixel: bpp))
        }
    }

    private static let etcModifiers: [(Int32, Int32)] = [(2, 8), (5, 17), (9, 29), (13, 42), (18, 60), (24, 80), (33, 106), (47, 183)]

    /// ETC1: 8 × 8 tiles of four 4 × 4 blocks, each a little-endian 64-bit word,
    /// preceded by 64 bits of 4-bit alpha in ETC1A4.
    static func etc(_ alpha: Bool, base: UnsafeRawPointer, width: Int, x: Int, y: Int) -> PICAColor {
        let blockSize = alpha ? 16 : 8
        let tile = (y / 8) * (width / 8) + x / 8
        let subtile = (x % 8) / 4 + 2 * ((y % 8) / 4)
        let block = base + (tile * 4 + subtile) * blockSize
        let u = x % 4, v = y % 4
        var a: Int32 = 255
        if alpha {
            let bits = block.loadUnaligned(as: UInt64.self)
            a = expand4(UInt32((bits >> UInt64(4 * (u * 4 + v))) & 0xF))
        }
        let word = (block + (alpha ? 8 : 0)).loadUnaligned(as: UInt64.self)
        let flip = (word >> 32) & 1 != 0, differential = (word >> 33) & 1 != 0
        let second = flip ? v >= 2 : u >= 2
        var r: Int32, g: Int32, b: Int32
        func bits(_ shift: UInt64, _ count: UInt64) -> UInt32 {
            let mask: UInt64 = (1 << count) - 1
            return UInt32((word >> shift) & mask)
        }
        if differential {
            func channel(_ baseShift: UInt64, _ deltaShift: UInt64) -> Int32 {
                var c = Int32(bits(baseShift, 5))
                if second { c += Int32(bits(deltaShift, 3) << 29) >> 29 }
                return expand5(UInt32(c & 0x1F))
            }
            r = channel(59, 56); g = channel(51, 48); b = channel(43, 40)
        } else {
            r = expand4(second ? bits(56, 4) : bits(60, 4))
            g = expand4(second ? bits(48, 4) : bits(52, 4))
            b = expand4(second ? bits(40, 4) : bits(44, 4))
        }
        let table = Int(second ? bits(34, 3) : bits(37, 3))
        let index = UInt64(u * 4 + v)
        let low = (word >> index) & 1, high = (word >> (16 + index)) & 1
        var modifier = low != 0 ? etcModifiers[table].1 : etcModifiers[table].0
        if high != 0 { modifier = -modifier }
        func clamp(_ c: Int32) -> Int32 { min(max(c + modifier, 0), 255) }
        return PICAColor(clamp(r), clamp(g), clamp(b), a)
    }
}
