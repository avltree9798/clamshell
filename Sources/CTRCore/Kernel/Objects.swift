// SPDX-License-Identifier: GPL-3.0-or-later
//
// Horizon kernel objects, emulated at the level of their observable behaviour
// (written from the 3dbrew documentation of the SVC interface).

import ARMCore

/// Result codes the kernel and services return.
enum ResultCode {
    static let success: UInt32 = 0
    static let timeout: UInt32 = 0x0940_1BFE
    static let invalidHandle: UInt32 = 0xD8E0_07F7
    static let outOfMemory: UInt32 = 0xD860_07F3
    static let invalidAddress: UInt32 = 0xE0E0_1BF5
    static let invalidCombination: UInt32 = 0xE0E0_1BEE
    static let notFound: UInt32 = 0xD880_07FA
    static let serviceNotRegistered: UInt32 = 0xD040_6401
    static let notImplemented: UInt32 = 0xF960_07F4
}

/// Anything a handle can name. Waitable objects override `shouldWait` and `acquire`.
class KernelObject {
    /// Threads blocked in WaitSynchronization on this object.
    var waiters: [KThread] = []

    var typeName: String { "object" }

    /// True if a wait by `thread` must block now.
    func shouldWait(_ thread: KThread) -> Bool { true }

    /// Called when `thread`'s wait on this object completes.
    func acquire(_ thread: KThread) {}
}

enum ResetType: UInt32 {
    case oneShot = 0, sticky = 1, pulse = 2
}

final class KEvent: KernelObject {
    let resetType: ResetType
    var signaled = false
    let name: String

    init(resetType: ResetType, name: String = "") {
        self.resetType = resetType
        self.name = name
    }

    override var typeName: String { "event \(name)" }
    override func shouldWait(_ thread: KThread) -> Bool { !signaled }
    override func acquire(_ thread: KThread) {
        if resetType == .oneShot { signaled = false }
    }
}

final class KMutex: KernelObject {
    var owner: KThread?
    var lockCount = 0

    override var typeName: String { "mutex" }
    override func shouldWait(_ thread: KThread) -> Bool { owner != nil && owner !== thread }
    override func acquire(_ thread: KThread) {
        owner = thread
        lockCount += 1
    }
}

final class KSemaphore: KernelObject {
    var count: Int32
    let maximum: Int32

    init(count: Int32, maximum: Int32) {
        self.count = count
        self.maximum = maximum
    }

    override var typeName: String { "semaphore" }
    override func shouldWait(_ thread: KThread) -> Bool { count <= 0 }
    override func acquire(_ thread: KThread) { count -= 1 }
}

final class KTimer: KernelObject {
    let resetType: ResetType
    var signaled = false
    /// Next expiry on the ARM11 clock, or nil when stopped.
    var fireTime: UInt64?
    var interval: UInt64 = 0

    init(resetType: ResetType) { self.resetType = resetType }

    override var typeName: String { "timer" }
    override func shouldWait(_ thread: KThread) -> Bool { !signaled }
    override func acquire(_ thread: KThread) {
        if resetType == .oneShot { signaled = false }
    }
}

final class KAddressArbiter: KernelObject {
    override var typeName: String { "address arbiter" }
}

/// A block of memory shared between the application and a service (or another process).
final class KSharedMemory: KernelObject {
    let host: UnsafeMutableRawPointer
    let size: UInt32
    /// Where the application mapped it, if it has.
    var mappedAddress: UInt32?
    private let owned: Bool

    /// Memory the kernel allocates (service shared memory).
    init(size: UInt32) {
        host = .allocate(byteCount: Int(size), alignment: AddressSpace.pageSize)
        host.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        self.size = size
        owned = true
    }

    /// Memory the application already owns (svcCreateMemoryBlock on its own pages).
    init(existing: UnsafeMutableRawPointer, size: UInt32, at address: UInt32) {
        host = existing
        self.size = size
        mappedAddress = address
        owned = false
    }

    deinit { if owned { host.deallocate() } }

    override var typeName: String { "shared memory" }

    func load32(_ offset: Int) -> UInt32 { host.load(fromByteOffset: offset, as: UInt32.self) }
    func store32(_ offset: Int, _ v: UInt32) { host.storeBytes(of: v, toByteOffset: offset, as: UInt32.self) }
    func load8(_ offset: Int) -> UInt8 { host.load(fromByteOffset: offset, as: UInt8.self) }
    func store8(_ offset: Int, _ v: UInt8) { host.storeBytes(of: v, toByteOffset: offset, as: UInt8.self) }
}

/// A client session to an HLE service.
final class KSession: KernelObject {
    let service: Service
    init(service: Service) { self.service = service }
    override var typeName: String { "session \(service.name)" }
}

/// A named port (only "srv:" exists for applications).
final class KPort: KernelObject {
    let name: String
    init(name: String) { self.name = name }
    override var typeName: String { "port \(name)" }
}

final class KProcess: KernelObject {
    let id: UInt32
    init(id: UInt32) { self.id = id }
    override var typeName: String { "process" }
}

final class KResourceLimit: KernelObject {
    override var typeName: String { "resource limit" }
}

final class KThread: KernelObject {
    enum State { case ready, waiting, dead }

    let id: UInt32
    var priority: Int32
    var state: State = .ready
    var context = ARM<Bus11>.Context()
    let tlsAddress: UInt32

    // Wait bookkeeping.
    var waitObjects: [KernelObject] = []
    var waitAll = false
    /// When a timed wait or sleep ends, on the ARM11 clock.
    var wakeTime: UInt64?
    /// Set when waiting in ArbitrateAddress.
    var arbiterWait: (arbiter: KAddressArbiter, address: UInt32)?
    /// WaitSynchronizationN reports which handle fired in r1.
    var reportsIndex = false
    /// Mutexes this thread holds, released if it exits.
    var heldMutexes: [KMutex] = []

    init(id: UInt32, priority: Int32, tlsAddress: UInt32) {
        self.id = id
        self.priority = priority
        self.tlsAddress = tlsAddress
    }

    override var typeName: String { "thread \(id)" }
    override func shouldWait(_ thread: KThread) -> Bool { state != .dead }
}
