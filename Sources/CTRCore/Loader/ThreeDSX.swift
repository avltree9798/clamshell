// SPDX-License-Identifier: GPL-3.0-or-later
//
// The .3dsx homebrew executable format (layout from 3dbrew): a header, three
// segments (code, rodata, data + bss) and relocation tables that rebase
// pointers to where the loader places each segment.

import EmuKit

struct ThreeDSX {
    static let codeAddress: UInt32 = 0x0010_0000

    var code: [UInt8]
    var rodata: [UInt8]
    /// Data without bss.
    var data: [UInt8]
    var bssSize: UInt32
    /// Per segment: (absolute, relative) relocation runs as (skip, patch) word counts.
    var relocations: [[(skip: UInt16, patch: UInt16, relative: Bool)]]

    static func looksLike(_ bytes: [UInt8]) -> Bool { bytes.count >= 0x20 && bytes.prefix(4).elementsEqual("3DSX".utf8) }

    init(_ bytes: [UInt8]) throws(CoreError) {
        guard Self.looksLike(bytes) else { throw .unsupportedImage("not a .3dsx file") }
        func u16(_ o: Int) -> UInt16 { UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }

        let headerSize = Int(u16(4)), relocHeaderSize = Int(u16(6))
        let codeSize = Int(u32(0x10)), rodataSize = Int(u32(0x14)), dataSize = Int(u32(0x18))
        bssSize = u32(0x1C)
        guard relocHeaderSize >= 8, UInt32(dataSize) >= bssSize else { throw .unsupportedImage("bad .3dsx header") }

        var offset = headerSize
        var counts: [(absolute: Int, relative: Int)] = []
        for _ in 0..<3 {
            guard offset + relocHeaderSize <= bytes.count else { throw .unsupportedImage("truncated .3dsx") }
            counts.append((Int(u32(offset)), Int(u32(offset + 4))))
            offset += relocHeaderSize
        }
        let fileDataSize = dataSize - Int(bssSize)
        guard offset + codeSize + rodataSize + fileDataSize <= bytes.count else { throw .unsupportedImage("truncated .3dsx") }
        code = Array(bytes[offset..<offset + codeSize]); offset += codeSize
        rodata = Array(bytes[offset..<offset + rodataSize]); offset += rodataSize
        data = Array(bytes[offset..<offset + fileDataSize]); offset += fileDataSize

        relocations = []
        for (absolute, relative) in counts {
            var list: [(skip: UInt16, patch: UInt16, relative: Bool)] = []
            for i in 0..<(absolute + relative) {
                guard offset + 4 <= bytes.count else { throw .unsupportedImage("truncated .3dsx relocations") }
                list.append((u16(offset), u16(offset + 2), i >= absolute))
                offset += 4
            }
            relocations.append(list)
        }
    }

    static func pageAligned(_ n: Int) -> UInt32 { UInt32((n + 0xFFF) & ~0xFFF) }

    /// Maps the segments at 0x00100000 and applies relocations. Returns the entry point.
    func load(into memory: AddressSpace) -> UInt32 {
        let codeBase = Self.codeAddress
        let rodataBase = codeBase + Self.pageAligned(code.count)
        let dataBase = rodataBase + Self.pageAligned(rodata.count)
        let dataTotal = data.count + Int(bssSize)
        let total = Self.pageAligned(code.count) + Self.pageAligned(rodata.count) + Self.pageAligned(dataTotal)
        memory.mapNew(codeBase, size: total, permission: .all, state: .code)
        memory.writeBytes(codeBase, code)
        memory.writeBytes(rodataBase, rodata)
        memory.writeBytes(dataBase, data)

        // Pointers in the file are offsets into code, rodata and data laid end to end.
        let codeEnd = UInt32(code.count), rodataEnd = codeEnd + UInt32(rodata.count)
        func translate(_ offset: UInt32) -> UInt32 {
            if offset < codeEnd { return codeBase + offset }
            if offset < rodataEnd { return rodataBase + offset - codeEnd }
            return dataBase + offset - rodataEnd
        }
        let bases = [codeBase, rodataBase, dataBase]
        let sizes = [code.count, rodata.count, dataTotal]
        for segment in 0..<3 {
            var position = bases[segment]
            let end = bases[segment] + UInt32(sizes[segment])
            for run in relocations[segment] {
                position += UInt32(run.skip) * 4
                for _ in 0..<run.patch where position < end {
                    let original = memory.read32(position)
                    let target = translate(original & 0x0FFF_FFFF)
                    memory.write32(position, run.relative ? target &- position : target)
                    position += 4
                }
            }
        }
        return codeBase
    }
}
