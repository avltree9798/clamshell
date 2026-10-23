// SPDX-License-Identifier: GPL-3.0-or-later
//
// Where each VRAM bank appears, per VRAMCNT_A...I. Mapping tables from GBATEK
// "DS Memory Control - VRAM".

/// Page tables from each VRAM region to offsets in `NDS.vram` (the banks back to
/// back, as the LCDC window sees them). Pages are 16 KB, the smallest bank size.
/// Tables are raw pointers so the renderer's inner loops carry no bounds checks.
final class VRAMMap {
    static let none: Int32 = -1
    static let bankOffset: [Int32] = [0, 0x20000, 0x40000, 0x60000, 0x80000, 0x90000, 0x94000, 0x98000, 0xA0000]
    static let bankSize: [Int32] = [0x20000, 0x20000, 0x20000, 0x20000, 0x10000, 0x4000, 0x4000, 0x8000, 0x4000]
    /// Size of the LCDC window: all nine banks.
    static let totalSize: UInt32 = 0xA4000

    /// Engine A backgrounds (512 KB), engine B backgrounds (128 KB), engine A
    /// objects (256 KB), engine B objects (128 KB), ARM7 (256 KB).
    let bgA = Table(pages: 32), bgB = Table(pages: 8), objA = Table(pages: 16), objB = Table(pages: 8), arm7 = Table(pages: 16)
    /// Extended palettes, 8 KB per slot: four BG slots and one OBJ slot per engine.
    let bgExtA = Table(pages: 4), bgExtB = Table(pages: 4), objExtA = Table(pages: 1), objExtB = Table(pages: 1)
    /// 3D texture image slots (128 KB) and texture palette slots (16 KB).
    let texture = Table(pages: 4), texturePalette = Table(pages: 6)

    /// A table of bank offsets, one per page, or `none`.
    final class Table {
        let entries: UnsafeMutablePointer<Int32>
        let count: Int

        init(pages: Int) {
            count = pages
            entries = .allocate(capacity: pages)
            entries.initialize(repeating: VRAMMap.none, count: pages)
        }

        deinit { entries.deallocate() }

        func clear() { entries.update(repeating: VRAMMap.none, count: count) }

        /// Maps `size` bytes of bank memory at `offset` into the table from `page`, in `pageSize` steps.
        func map(page: Int, offset: Int32, size: Int32, pageSize: Int32 = 0x4000) {
            for i in 0..<Int(size / pageSize) { entries[(page + i) % count] = offset + Int32(i) * pageSize }
        }

        @inline(__always) subscript(_ i: Int) -> Int32 { entries[i] }
    }

    private var tables: [Table] { [bgA, bgB, objA, objB, arm7, bgExtA, bgExtB, objExtA, objExtB, texture, texturePalette] }

    /// Rebuilds every table from the nine VRAMCNT registers.
    func rebuild(_ control: [UInt8]) {
        tables.forEach { $0.clear() }
        for bank in 0..<9 {
            let cnt = control[bank]
            guard cnt & 0x80 != 0 else { continue }
            let base = Self.bankOffset[bank], size = Self.bankSize[bank]
            let ofs = Int((cnt >> 3) & 3)
            let mst = Int(cnt & 7)
            switch bank {
            case 0, 1:  // A, B
                switch mst & 3 {
                case 1: bgA.map(page: ofs * 8, offset: base, size: size)
                case 2: objA.map(page: (ofs & 1) * 8, offset: base, size: size)
                case 3: texture.map(page: ofs, offset: base, size: size, pageSize: size)
                default: break
                }
            case 2, 3:  // C, D
                switch mst {
                case 1: bgA.map(page: ofs * 8, offset: base, size: size)
                case 2: arm7.map(page: (ofs & 1) * 8, offset: base, size: size)
                case 3: texture.map(page: ofs, offset: base, size: size, pageSize: size)
                case 4: (bank == 2 ? bgB : objB).map(page: 0, offset: base, size: size)
                default: break
                }
            case 4:  // E
                switch mst {
                case 1: bgA.map(page: 0, offset: base, size: size)
                case 2: objA.map(page: 0, offset: base, size: size)
                case 3: texturePalette.map(page: 0, offset: base, size: size)
                case 4: bgExtA.map(page: 0, offset: base, size: 0x8000, pageSize: 0x2000)
                default: break
                }
            case 5, 6:  // F, G
                let page = (ofs & 1) + (ofs >> 1) * 4
                switch mst {
                case 1: bgA.map(page: page, offset: base, size: size)
                case 2: objA.map(page: page, offset: base, size: size)
                case 3: texturePalette.map(page: (ofs & 1) + (ofs >> 1) * 4, offset: base, size: size)
                case 4: bgExtA.map(page: (ofs & 1) * 2, offset: base, size: size, pageSize: 0x2000)
                case 5: objExtA.map(page: 0, offset: base, size: 0x2000, pageSize: 0x2000)
                default: break
                }
            case 7:  // H
                switch mst & 3 {
                case 1: bgB.map(page: 0, offset: base, size: size)
                case 2: bgExtB.map(page: 0, offset: base, size: size, pageSize: 0x2000)
                default: break
                }
            default:  // I
                switch mst & 3 {
                case 1: bgB.map(page: 2, offset: base, size: size)
                case 2: objB.map(page: 0, offset: base, size: size)
                case 3: objExtB.map(page: 0, offset: base, size: 0x2000, pageSize: 0x2000)
                default: break
                }
            }
        }
    }
}
