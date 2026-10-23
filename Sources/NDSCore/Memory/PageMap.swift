// SPDX-License-Identifier: GPL-3.0-or-later

import ARMCore

/// Host pointers to the 4 KB pages of plain RAM a CPU sees, for the C fast path.
/// Pages with side effects or odd mirroring (I/O, VRAM, palette, BIOS) stay nil and
/// go through the bus. Code and data have separate tables because the ARM9 fetches
/// main RAM even where DTCM covers it.
final class PageMap {
    static let pageCount = 1 << 20
    let data: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>
    let code: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>

    init() {
        data = .allocate(capacity: Self.pageCount)
        data.initialize(repeating: nil, count: Self.pageCount)
        code = .allocate(capacity: Self.pageCount)
        code.initialize(repeating: nil, count: Self.pageCount)
    }

    deinit {
        data.deallocate()
        code.deallocate()
    }

    var dataTable: ARMPageTable { UnsafePointer(data) }
    var codeTable: ARMPageTable { UnsafePointer(code) }

    /// Maps `count` pages from `firstPage`, repeating `ram` from `offset` every `size` bytes.
    func map(_ firstPage: Int, count: Int, _ ram: RAM, offset: Int = 0, size: Int? = nil, in table: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>) {
        let span = size ?? ram.size
        for i in 0..<count {
            table[firstPage + i] = (ram.base + offset + (i * 4096) % span).assumingMemoryBound(to: UInt8.self)
        }
    }

    func clear(_ firstPage: Int, count: Int) {
        for i in firstPage..<min(firstPage + count, Self.pageCount) {
            data[i] = nil
            code[i] = nil
        }
    }
}
