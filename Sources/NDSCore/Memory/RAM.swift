// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit

/// A power-of-two block of guest memory, mirrored across its address range.
/// Hosts are little-endian (arm64, x86-64), like the DS, so loads need no swapping.
@usableFromInline struct RAM {
    @usableFromInline let base: UnsafeMutableRawPointer
    @usableFromInline let mask: UInt32
    let size: Int

    init(size: Int) {
        precondition(size > 0 && size & (size - 1) == 0, "RAM size must be a power of two")
        self.size = size
        mask = UInt32(size - 1)
        base = .allocate(byteCount: size, alignment: 16)
        base.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    }

    func free() { base.deallocate() }

    func clear() { base.initializeMemory(as: UInt8.self, repeating: 0, count: size) }

    @inline(__always) func read8(_ a: UInt32) -> UInt8 {
        base.load(fromByteOffset: Int(a & mask), as: UInt8.self)
    }
    @inline(__always) func read16(_ a: UInt32) -> UInt16 {
        base.load(fromByteOffset: Int(a & mask & ~1), as: UInt16.self)
    }
    @inline(__always) func read32(_ a: UInt32) -> UInt32 {
        base.load(fromByteOffset: Int(a & mask & ~3), as: UInt32.self)
    }
    @inline(__always) func write8(_ a: UInt32, _ v: UInt8) {
        base.storeBytes(of: v, toByteOffset: Int(a & mask), as: UInt8.self)
    }
    @inline(__always) func write16(_ a: UInt32, _ v: UInt16) {
        base.storeBytes(of: v, toByteOffset: Int(a & mask & ~1), as: UInt16.self)
    }
    @inline(__always) func write32(_ a: UInt32, _ v: UInt32) {
        base.storeBytes(of: v, toByteOffset: Int(a & mask & ~3), as: UInt32.self)
    }

    func copy(from bytes: ArraySlice<UInt8>, to address: UInt32) {
        var a = address
        for b in bytes {
            write8(a, b)
            a &+= 1
        }
    }

    func snapshot(into w: inout SnapshotWriter) { w.put(raw: base, count: size) }

    func restore(from r: inout SnapshotReader) throws(CoreError) { try r.get(raw: base, count: size) }
}
