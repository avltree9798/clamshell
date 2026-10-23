// SPDX-License-Identifier: GPL-3.0-or-later

/// What a range of the application's virtual memory is, as svcQueryMemory reports it.
enum MemoryState: UInt32 {
    case free = 0, io = 2, `static` = 3, code = 4, `private` = 5, shared = 6
    case continuous = 7, aliased = 8, alias = 9, aliasCode = 10, locked = 11
}

struct MemoryPermission: OptionSet {
    let rawValue: UInt32
    static let read = MemoryPermission(rawValue: 1)
    static let write = MemoryPermission(rawValue: 2)
    static let execute = MemoryPermission(rawValue: 4)
    static let readWrite: MemoryPermission = [.read, .write]
    static let all: MemoryPermission = [.read, .write, .execute]
}

/// The application process's 4 GB virtual address space, as 4 KB pages that point
/// straight at host memory. One table lookup per access, no bounds checks beyond it.
///
/// Physical memory the 3DS shares between the CPU and the GPU (FCRAM, VRAM) is
/// one host allocation each, so the GPU side can read the same bytes.
final class AddressSpace {
    static let pageSize = 0x1000
    static let pageCount = 1 << 20

    /// Host pointer for each virtual page, or nil when unmapped.
    let pages: UnsafeMutablePointer<UnsafeMutableRawPointer?>

    /// FCRAM: 128 MB, physical 0x20000000. The application's linear heap is a window
    /// onto it at virtual 0x30000000 (firmware 8.0 and later).
    let fcram: UnsafeMutableRawPointer
    static let fcramSize = 128 << 20
    static let fcramPhysical: UInt32 = 0x2000_0000
    static let linearBase: UInt32 = 0x3000_0000

    /// VRAM: 6 MB, physical 0x18000000, virtual 0x1F000000.
    let vram: UnsafeMutableRawPointer
    static let vramSize = 6 << 20
    static let vramVirtual: UInt32 = 0x1F00_0000

    /// Ranges for svcQueryMemory, sorted by base.
    private(set) var regions: [(base: UInt32, size: UInt32, permission: MemoryPermission, state: MemoryState)] = []

    /// Host blocks that are not part of FCRAM (code, stack, shared pages), freed on deinit.
    private var ownedBlocks: [UnsafeMutableRawPointer] = []

    /// Accesses to unmapped pages, for diagnostics.
    private(set) var faults = 0
    var lastFault: UInt32 = 0

    init() {
        pages = .allocate(capacity: Self.pageCount)
        pages.initialize(repeating: nil, count: Self.pageCount)
        fcram = .allocate(byteCount: Self.fcramSize, alignment: Self.pageSize)
        fcram.initializeMemory(as: UInt8.self, repeating: 0, count: Self.fcramSize)
        vram = .allocate(byteCount: Self.vramSize, alignment: Self.pageSize)
        vram.initializeMemory(as: UInt8.self, repeating: 0, count: Self.vramSize)
        map(Self.vramVirtual, host: vram, size: UInt32(Self.vramSize), permission: .readWrite, state: .io)
    }

    deinit {
        pages.deallocate()
        fcram.deallocate()
        vram.deallocate()
        ownedBlocks.forEach { $0.deallocate() }
    }

    // MARK: - Mapping

    func map(_ address: UInt32, host: UnsafeMutableRawPointer, size: UInt32, permission: MemoryPermission, state: MemoryState) {
        precondition(address & 0xFFF == 0 && size & 0xFFF == 0, "mappings are page-aligned")
        for page in 0..<Int(size >> 12) {
            pages[Int(address >> 12) + page] = host + page * Self.pageSize
        }
        addRegion(address, size, permission, state)
    }

    /// Maps fresh zeroed host memory that the address space owns.
    @discardableResult
    func mapNew(_ address: UInt32, size: UInt32, permission: MemoryPermission, state: MemoryState) -> UnsafeMutableRawPointer {
        let block = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: Self.pageSize)
        block.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        ownedBlocks.append(block)
        map(address, host: block, size: size, permission: permission, state: state)
        return block
    }

    func unmap(_ address: UInt32, size: UInt32) {
        for page in 0..<Int(size >> 12) { pages[Int(address >> 12) + page] = nil }
        removeRegion(address, size)
    }

    func isMapped(_ address: UInt32, size: UInt32) -> Bool {
        var page = address >> 12
        let end = (address &+ size &- 1) >> 12
        while page <= end {
            if pages[Int(page)] == nil { return false }
            page += 1
        }
        return true
    }

    /// Physical address for a virtual one, for GPU registers (0 if not in FCRAM or VRAM).
    func physical(_ virtual: UInt32) -> UInt32 {
        if virtual >= Self.linearBase && virtual < Self.linearBase + UInt32(Self.fcramSize) {
            return virtual - Self.linearBase + Self.fcramPhysical
        }
        if virtual >= Self.vramVirtual && virtual < Self.vramVirtual + UInt32(Self.vramSize) {
            return virtual - Self.vramVirtual + 0x1800_0000
        }
        return 0
    }

    /// Host pointer for a physical address in FCRAM or VRAM, for the GPU.
    func host(physical: UInt32) -> UnsafeMutableRawPointer? {
        if physical >= Self.fcramPhysical && physical < Self.fcramPhysical + UInt32(Self.fcramSize) {
            return fcram + Int(physical - Self.fcramPhysical)
        }
        if physical >= 0x1800_0000 && physical < 0x1800_0000 + UInt32(Self.vramSize) {
            return vram + Int(physical - 0x1800_0000)
        }
        return nil
    }

    func region(containing address: UInt32) -> (base: UInt32, size: UInt32, permission: MemoryPermission, state: MemoryState) {
        for r in regions where address >= r.base && address &- r.base < r.size { return r }
        // Free space between mappings.
        var base: UInt32 = 0, end: UInt32 = 0xFFFF_FFFF
        for r in regions {
            if r.base &+ r.size <= address { base = max(base, r.base &+ r.size) }
            if r.base > address { end = min(end, r.base); break }
        }
        return (base, end &- base, [], .free)
    }

    private func addRegion(_ base: UInt32, _ size: UInt32, _ permission: MemoryPermission, _ state: MemoryState) {
        removeRegion(base, size)
        regions.append((base, size, permission, state))
        regions.sort { $0.base < $1.base }
    }

    private func removeRegion(_ base: UInt32, _ size: UInt32) {
        let end = base &+ size
        var kept: [(base: UInt32, size: UInt32, permission: MemoryPermission, state: MemoryState)] = []
        for r in regions {
            let rEnd = r.base &+ r.size
            if rEnd <= base || r.base >= end { kept.append(r); continue }
            if r.base < base { kept.append((r.base, base - r.base, r.permission, r.state)) }
            if rEnd > end { kept.append((end, rEnd - end, r.permission, r.state)) }
        }
        regions = kept
    }

    // MARK: - Access

    @inline(__always) func pointer(_ address: UInt32) -> UnsafeMutableRawPointer? {
        guard let page = pages[Int(address >> 12)] else { return nil }
        return page + Int(address & 0xFFF)
    }

    @inline(never) func fault(_ address: UInt32) {
        faults += 1
        lastFault = address
    }

    @inline(__always) func read8(_ a: UInt32) -> UInt8 {
        guard let p = pointer(a) else { fault(a); return 0 }
        return p.load(as: UInt8.self)
    }
    @inline(__always) func read16(_ a: UInt32) -> UInt16 {
        guard let p = pointer(a & ~1) else { fault(a); return 0 }
        return p.load(as: UInt16.self)
    }
    @inline(__always) func read32(_ a: UInt32) -> UInt32 {
        guard let p = pointer(a & ~3) else { fault(a); return 0 }
        return p.load(as: UInt32.self)
    }
    @inline(__always) func write8(_ a: UInt32, _ v: UInt8) {
        guard let p = pointer(a) else { fault(a); return }
        p.storeBytes(of: v, as: UInt8.self)
    }
    @inline(__always) func write16(_ a: UInt32, _ v: UInt16) {
        guard let p = pointer(a & ~1) else { fault(a); return }
        p.storeBytes(of: v, as: UInt16.self)
    }
    @inline(__always) func write32(_ a: UInt32, _ v: UInt32) {
        guard let p = pointer(a & ~3) else { fault(a); return }
        p.storeBytes(of: v, as: UInt32.self)
    }

    func readBytes(_ address: UInt32, count: Int) -> [UInt8] {
        (0..<count).map { read8(address &+ UInt32($0)) }
    }

    func writeBytes(_ address: UInt32, _ bytes: some Sequence<UInt8>) {
        var a = address
        for b in bytes {
            write8(a, b)
            a &+= 1
        }
    }

    /// A NUL-terminated string, at most `limit` bytes.
    func readString(_ address: UInt32, limit: Int = 256) -> String {
        var bytes: [UInt8] = []
        var a = address
        while bytes.count < limit {
            let b = read8(a)
            if b == 0 { break }
            bytes.append(b)
            a &+= 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
