// SPDX-License-Identifier: GPL-3.0-or-later

/// Binary save-state format.
///
///     header:  "CLMS" magic, format version u32, SystemID u32
///     section: tag u32, length u32, payload
///
/// Readers skip sections whose tag they do not know, so adding a section is a
/// compatible change. Changing a section's layout means bumping its tag.
public enum SnapshotFormat {
    public static let magic: UInt32 = 0x534D_4C43  // "CLMS" little-endian
    public static let version: UInt32 = 1
}

public struct SnapshotWriter {
    public private(set) var bytes: [UInt8] = []
    private var sectionStart: Int?

    public init(system: SystemID) {
        put(SnapshotFormat.magic)
        put(SnapshotFormat.version)
        put(system.rawValue)
    }

    public mutating func beginSection(_ tag: UInt32) {
        precondition(sectionStart == nil, "sections do not nest")
        put(tag)
        sectionStart = bytes.count
        put(UInt32(0))  // patched in endSection
    }

    public mutating func endSection() {
        guard let start = sectionStart else { preconditionFailure("no open section") }
        let length = UInt32(bytes.count - start - 4)
        withUnsafeBytes(of: length.littleEndian) { raw in
            for i in 0..<4 { bytes[start + i] = raw[i] }
        }
        sectionStart = nil
    }

    public mutating func put<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    public mutating func put(_ value: Bool) { put(UInt8(value ? 1 : 0)) }

    public mutating func put(raw pointer: UnsafeRawPointer, count: Int) {
        bytes.append(contentsOf: UnsafeRawBufferPointer(start: pointer, count: count))
    }
}

public struct SnapshotReader {
    private let bytes: [UInt8]
    private var offset = 0
    public let system: SystemID
    public let version: UInt32

    public init(bytes: [UInt8]) throws(CoreError) {
        self.bytes = bytes
        guard bytes.count >= 12 else { throw .corruptSnapshot("too short") }
        func u32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        guard u32(0) == SnapshotFormat.magic else { throw .corruptSnapshot("bad magic") }
        version = u32(4)
        guard let sys = SystemID(rawValue: u32(8)) else { throw .corruptSnapshot("unknown system") }
        system = sys
        offset = 12
    }

    /// Returns the next section's tag and positions the reader at its payload,
    /// or nil at the end. Call `skipSection` to ignore a section.
    public mutating func nextSection() throws(CoreError) -> (tag: UInt32, length: Int)? {
        if offset == bytes.count { return nil }
        let tag: UInt32 = try get()
        let length = Int(try get() as UInt32)
        guard offset + length <= bytes.count else { throw .corruptSnapshot("section overruns file") }
        return (tag, length)
    }

    public mutating func skip(_ length: Int) { offset += length }

    public mutating func get<T: FixedWidthInteger>() throws(CoreError) -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= bytes.count else { throw .corruptSnapshot("unexpected end") }
        var value: T = 0
        for i in 0..<size { value |= T(bytes[offset + i]) << (8 * i) }
        offset += size
        return value
    }

    public mutating func get() throws(CoreError) -> Bool { (try get() as UInt8) != 0 }

    public mutating func get(raw pointer: UnsafeMutableRawPointer, count: Int) throws(CoreError) {
        guard offset + count <= bytes.count else { throw .corruptSnapshot("unexpected end") }
        bytes.withUnsafeBytes { src in
            pointer.copyMemory(from: src.baseAddress! + offset, byteCount: count)
        }
        offset += count
    }
}
