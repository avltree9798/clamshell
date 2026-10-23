// SPDX-License-Identifier: GPL-3.0-or-later
//
// High-level emulation of the Horizon kernel for one application process:
// handles, threads and their scheduling, synchronisation objects, memory
// management and the SVC interface (register conventions from 3dbrew).

import ARMCore

final class Kernel {
    /// The ARM11 clock: 268,111,856 Hz on an original 3DS.
    static let clockRate: UInt64 = 268_111_856
    static let currentThreadHandle: UInt32 = 0xFFFF_8000
    static let currentProcessHandle: UInt32 = 0xFFFF_8001

    let memory: AddressSpace
    let cpu: ARM<Bus11>
    let process = KProcess(id: 0x28)
    let resourceLimit = KResourceLimit()

    private var handles: [UInt32: KernelObject] = [:]
    private var nextHandle: UInt32 = 0x0001_0000

    private(set) var threads: [KThread] = []
    private(set) var currentThread: KThread?
    private var nextThreadID: UInt32 = 1
    private var freeTLSSlots = Array(0..<32)
    private var yieldRequested = false
    var needsReschedule = false

    private(set) var timers: [KTimer] = []

    /// Services reachable through srv:GetServiceHandle, by name.
    var services: [String: Service] = [:]
    /// Fallback for names nobody registered: accepts every command.
    var makeStubService: ((String) -> Service)?

    /// Debug output (svcOutputDebugString) and diagnostics, newest last.
    private(set) var log: [String] = []
    private(set) var exited = false
    private(set) var breakReason: UInt32?

    // Memory bookkeeping. FCRAM's first 64 MB is the application region: the
    // linear heap grows up from the bottom, the regular heap down from the top.
    static let applicationMemory: UInt32 = 64 << 20
    private var linearUsed: UInt32 = 0
    private var heapUsed: UInt32 = 0
    private var mappedAllocations: [UInt32: UInt32] = [:]  // base -> size, for svcGetSystemInfo

    init(memory: AddressSpace, cpu: ARM<Bus11>) {
        self.memory = memory
        self.cpu = cpu
    }

    var now: UInt64 { cpu.cycles }

    static func cycles(nanoseconds ns: Int64) -> UInt64 {
        guard ns > 0 else { return 0 }
        return UInt64(ns).multipliedFullWidth(by: clockRate).high == 0
            ? UInt64(ns) * clockRate / 1_000_000_000
            : UInt64.max / 2
    }

    func record(_ message: String) {
        log.append(message)
        if log.count > 512 { log.removeFirst(log.count - 512) }
    }

    // MARK: - Handles

    func makeHandle(_ object: KernelObject) -> UInt32 {
        let handle = nextHandle
        nextHandle += 1
        handles[handle] = object
        return handle
    }

    func object(_ handle: UInt32) -> KernelObject? {
        switch handle {
        case Self.currentThreadHandle: return currentThread
        case Self.currentProcessHandle: return process
        default: return handles[handle]
        }
    }

    func object<T: KernelObject>(_ handle: UInt32, as type: T.Type) -> T? { object(handle) as? T }

    // MARK: - Registers of the calling thread

    @inline(__always) func r(_ i: Int) -> UInt32 { cpu.reg(i) }
    @inline(__always) func set(_ i: Int, _ v: UInt32) { cpu.setReg(i, v) }

    private func ns(low: Int, high: Int) -> Int64 {
        Int64(bitPattern: UInt64(r(high)) << 32 | UInt64(r(low)))
    }

    // MARK: - Threads

    @discardableResult
    func createThread(entry: UInt32, argument: UInt32, stackTop: UInt32, priority: Int32) -> KThread? {
        guard let slot = freeTLSSlots.first else { return nil }
        freeTLSSlots.removeFirst()
        let tls = 0x1FF8_2000 + UInt32(slot) * 0x200
        for i in 0..<0x200 as Range<UInt32> where i % 4 == 0 { memory.write32(tls + i, 0) }
        let thread = KThread(id: nextThreadID, priority: priority, tlsAddress: tls)
        nextThreadID += 1
        thread.context.r[0] = argument
        thread.context.r[13] = stackTop & ~7
        thread.context.r[15] = entry & ~1
        thread.context.cpsr = ARMMode.user.rawValue | (entry & 1 != 0 ? 1 << 5 : 0)
        // Horizon starts threads with default NaN, flush-to-zero and round-towards-zero.
        thread.context.fpscr = 0x03C0_0000
        threads.append(thread)
        if let current = currentThread, priority < current.priority { needsReschedule = true }
        return thread
    }

    private func exitThread(_ thread: KThread) {
        thread.state = .dead
        for mutex in thread.heldMutexes where mutex.owner === thread {
            mutex.owner = nil
            mutex.lockCount = 0
            wakeWaiters(of: mutex)
        }
        thread.heldMutexes.removeAll()
        let slot = Int((thread.tlsAddress - 0x1FF8_2000) / 0x200)
        freeTLSSlots.append(slot)
        wakeWaiters(of: thread)
        if !threads.contains(where: { $0.state != .dead }) { exited = true }
    }

    /// Picks the thread to run next and loads its context into the CPU.
    /// Call whenever `cpu.run` returns.
    func reschedule() {
        let current = currentThread
        let candidates = threads.filter { $0.state == .ready }
        var next = candidates.min { $0.priority < $1.priority }
        if let current, current.state == .ready, let best = next, current.priority <= best.priority, !yieldRequested {
            next = current  // Horizon does not time-slice between equal priorities
        } else if yieldRequested, let current, let best = next, best === current {
            // Round-robin among equal priorities on a yield.
            let peers = candidates.filter { $0.priority == current.priority }
            if peers.count > 1, let i = peers.firstIndex(where: { $0 === current }) {
                next = peers[(i + 1) % peers.count]
            }
        }
        yieldRequested = false
        needsReschedule = false

        if next !== current {
            if let current, current.state != .dead { cpu.saveContext(into: &current.context) }
            if let next { cpu.loadContext(next.context) }
            currentThread = next
        }
        if next != nil { cpu.resume() } else { cpu.halt() }
    }

    // MARK: - Waiting

    /// Index of the object whose acquisition completes the wait, or nil if it must block.
    private func tryComplete(_ thread: KThread, _ objects: [KernelObject], waitAll: Bool) -> Int? {
        if waitAll {
            guard objects.allSatisfy({ !$0.shouldWait(thread) }) else { return nil }
            for o in objects { acquire(o, by: thread) }
            return 0
        }
        guard let i = objects.firstIndex(where: { !$0.shouldWait(thread) }) else { return nil }
        acquire(objects[i], by: thread)
        return i
    }

    private func acquire(_ object: KernelObject, by thread: KThread) {
        object.acquire(thread)
        if let mutex = object as? KMutex, !thread.heldMutexes.contains(where: { $0 === mutex }) {
            thread.heldMutexes.append(mutex)
        }
    }

    /// Starts a wait for the calling thread. Writes the result now if it completes
    /// immediately, otherwise blocks the thread and leaves the CPU loop.
    private func beginWait(_ objects: [KernelObject], waitAll: Bool, timeout: Int64, reportsIndex: Bool) {
        guard let thread = currentThread else { return }
        if !objects.isEmpty, let index = tryComplete(thread, objects, waitAll: waitAll) {
            set(0, ResultCode.success)
            if reportsIndex { set(1, UInt32(index)) }
            return
        }
        if timeout == 0 {
            set(0, ResultCode.timeout)
            return
        }
        thread.state = .waiting
        thread.waitObjects = objects
        thread.waitAll = waitAll
        thread.reportsIndex = reportsIndex
        thread.wakeTime = timeout < 0 ? nil : now &+ Self.cycles(nanoseconds: timeout)
        for o in objects { o.waiters.append(thread) }
        set(0, ResultCode.success)
        cpu.halt()
    }

    private func finishWait(_ thread: KThread, result: UInt32, index: Int?) {
        for o in thread.waitObjects { o.waiters.removeAll { $0 === thread } }
        thread.waitObjects = []
        thread.wakeTime = nil
        thread.arbiterWait = nil
        thread.state = .ready
        thread.context.r[0] = result
        if thread.reportsIndex, let index { thread.context.r[1] = UInt32(index) }
        if let current = currentThread, thread.priority < current.priority {
            needsReschedule = true
            cpu.halt()  // preempt as soon as the current instruction finishes
        } else if currentThread == nil {
            needsReschedule = true
        }
    }

    /// Re-checks every thread blocked on `object` after its state changed.
    func wakeWaiters(of object: KernelObject) {
        for thread in object.waiters.sorted(by: { $0.priority < $1.priority }) where thread.state == .waiting {
            if let index = tryComplete(thread, thread.waitObjects, waitAll: thread.waitAll) {
                finishWait(thread, result: ResultCode.success, index: index)
            }
        }
    }

    func signal(_ event: KEvent) {
        event.signaled = true
        wakeWaiters(of: event)
        if event.resetType == .pulse { event.signaled = false }
    }

    // MARK: - Time

    /// The earliest moment a sleeping thread or a timer needs attention.
    var nextWakeTime: UInt64? {
        var t: UInt64? = nil
        for thread in threads where thread.state == .waiting {
            if let w = thread.wakeTime { t = min(t ?? .max, w) }
        }
        for timer in timers {
            if let f = timer.fireTime { t = min(t ?? .max, f) }
        }
        return t
    }

    /// Fires timers and ends timed waits that are due.
    func processTimedEvents() {
        for timer in timers {
            guard let fire = timer.fireTime, fire <= now else { continue }
            timer.fireTime = timer.interval > 0 ? fire &+ timer.interval : nil
            timer.signaled = true
            wakeWaiters(of: timer)
            if timer.resetType == .pulse { timer.signaled = false }
        }
        for thread in threads where thread.state == .waiting {
            guard let wake = thread.wakeTime, wake <= now else { continue }
            // A plain sleep (no objects) ends successfully; a wait with objects times out.
            let isSleep = thread.waitObjects.isEmpty && thread.arbiterWait == nil
            finishWait(thread, result: isSleep ? ResultCode.success : ResultCode.timeout, index: nil)
        }
    }

    // MARK: - SVC dispatch

    func supervisorCall(_ number: UInt32) {
        switch number {
        case 0x01: controlMemory()
        case 0x02: queryMemory()
        case 0x03:  // ExitProcess
            exited = true
            for t in threads where t.state != .dead { t.state = .dead }
            cpu.halt()
        case 0x08: svcCreateThread()
        case 0x09:  // ExitThread
            if let t = currentThread { exitThread(t) }
            cpu.halt()
        case 0x0A:  // SleepThread
            let duration = ns(low: 0, high: 1)
            if duration <= 0 {
                yieldRequested = true
                needsReschedule = true
                cpu.halt()
            } else {
                beginWait([], waitAll: false, timeout: duration, reportsIndex: false)
            }
        case 0x0B:  // GetThreadPriority
            guard let t = object(r(1), as: KThread.self) else { set(0, ResultCode.invalidHandle); return }
            set(0, 0); set(1, UInt32(bitPattern: t.priority))
        case 0x0C:  // SetThreadPriority
            guard let t = object(r(0), as: KThread.self) else { set(0, ResultCode.invalidHandle); return }
            t.priority = Int32(bitPattern: r(1))
            needsReschedule = true
            set(0, 0)
        case 0x13:  // CreateMutex
            let mutex = KMutex()
            if r(1) != 0, let t = currentThread { acquire(mutex, by: t) }
            set(0, 0); set(1, makeHandle(mutex))
        case 0x14: releaseMutex()
        case 0x15:  // CreateSemaphore
            let s = KSemaphore(count: Int32(bitPattern: r(1)), maximum: Int32(bitPattern: r(2)))
            set(0, 0); set(1, makeHandle(s))
        case 0x16:  // ReleaseSemaphore(r1 handle, r2 count) -> r1 previous count
            guard let s = object(r(1), as: KSemaphore.self) else { set(0, ResultCode.invalidHandle); return }
            let previous = s.count
            s.count = min(s.maximum, s.count + Int32(bitPattern: r(2)))
            set(0, 0); set(1, UInt32(bitPattern: previous))
            wakeWaiters(of: s)
        case 0x17:  // CreateEvent
            set(0, 0); set(1, makeHandle(KEvent(resetType: ResetType(rawValue: r(1)) ?? .oneShot)))
        case 0x18:  // SignalEvent
            guard let e = object(r(0), as: KEvent.self) else { set(0, ResultCode.invalidHandle); return }
            set(0, 0)
            signal(e)
        case 0x19:  // ClearEvent
            guard let e = object(r(0), as: KEvent.self) else { set(0, ResultCode.invalidHandle); return }
            e.signaled = false
            set(0, 0)
        case 0x1A:  // CreateTimer
            let timer = KTimer(resetType: ResetType(rawValue: r(1)) ?? .oneShot)
            timers.append(timer)
            set(0, 0); set(1, makeHandle(timer))
        case 0x1B:  // SetTimer(r0 handle, r2:r3 initial, r1:r4 interval)
            guard let t = object(r(0), as: KTimer.self) else { set(0, ResultCode.invalidHandle); return }
            let initial = Int64(bitPattern: UInt64(r(3)) << 32 | UInt64(r(2)))
            let interval = Int64(bitPattern: UInt64(r(4)) << 32 | UInt64(r(1)))
            t.fireTime = now &+ Self.cycles(nanoseconds: initial)
            t.interval = Self.cycles(nanoseconds: interval)
            set(0, 0)
        case 0x1C:  // CancelTimer
            object(r(0), as: KTimer.self)?.fireTime = nil
            set(0, 0)
        case 0x1D:  // ClearTimer
            object(r(0), as: KTimer.self)?.signaled = false
            set(0, 0)
        case 0x1E: createMemoryBlock()
        case 0x1F: mapMemoryBlock()
        case 0x20:  // UnmapMemoryBlock(r0 handle, r1 address)
            if let block = object(r(0), as: KSharedMemory.self) {
                memory.unmap(r(1), size: (block.size + 0xFFF) & ~0xFFF)
                block.mappedAddress = nil
            }
            set(0, 0)
        case 0x21:  // CreateAddressArbiter
            set(0, 0); set(1, makeHandle(KAddressArbiter()))
        case 0x22: arbitrateAddress()
        case 0x23:  // CloseHandle
            if r(0) < 0xFFFF_8000 { handles[r(0)] = nil }
            set(0, 0)
        case 0x24:  // WaitSynchronization1(r0 handle, r2:r3 timeout)
            guard let o = object(r(0)) else { set(0, ResultCode.invalidHandle); return }
            beginWait([o], waitAll: false, timeout: ns(low: 2, high: 3), reportsIndex: false)
        case 0x25: waitSynchronizationN()
        case 0x27:  // DuplicateHandle
            guard let o = object(r(1)) else { set(0, ResultCode.invalidHandle); return }
            set(0, 0); set(1, makeHandle(o))
        case 0x28:  // GetSystemTick
            set(0, UInt32(truncatingIfNeeded: now)); set(1, UInt32(truncatingIfNeeded: now >> 32))
        case 0x2A: getSystemInfo()
        case 0x2B: getProcessInfo()
        case 0x2D:  // ConnectToPort(r1 name)
            let name = memory.readString(r(1), limit: 12)
            guard name == "srv:" else {
                record("ConnectToPort(\(name)): no such port")
                set(0, ResultCode.notFound)
                return
            }
            guard let srv = services["srv:"] else { set(0, ResultCode.notFound); return }
            set(0, 0); set(1, makeHandle(KSession(service: srv)))
        case 0x32:  // SendSyncRequest
            guard let session = object(r(0), as: KSession.self), let thread = currentThread else {
                set(0, ResultCode.invalidHandle)
                return
            }
            var ipc = IPC(memory: memory, address: thread.tlsAddress + 0x80)
            session.service.handle(&ipc)
            set(0, 0)
        case 0x35:  // GetProcessId
            set(0, 0); set(1, process.id)
        case 0x37:  // GetThreadId
            guard let t = object(r(1), as: KThread.self) else { set(0, ResultCode.invalidHandle); return }
            set(0, 0); set(1, t.id)
        case 0x38:  // GetResourceLimit
            set(0, 0); set(1, makeHandle(resourceLimit))
        case 0x39, 0x3A: resourceLimitValues(current: number == 0x3A)
        case 0x3C:  // Break
            breakReason = r(0)
            record("svcBreak(\(r(0))) at \(String(cpu.reg(14), radix: 16))")
            exited = true
            cpu.halt()
        case 0x3D:  // OutputDebugString(r0 string, r1 length)
            let text = String(decoding: memory.readBytes(r(0), count: Int(min(r(1), 1024))), as: UTF8.self)
            record(text)
            set(0, 0)
        case 0x52, 0x53, 0x54:  // Invalidate/Store/FlushProcessDataCache
            set(0, 0)
        default:
            record("unimplemented SVC 0x\(String(number, radix: 16))")
            set(0, ResultCode.notImplemented)
        }
    }

    // MARK: - SVC bodies

    private func svcCreateThread() {
        // r0 priority, r1 entry, r2 argument, r3 stack top, r4 processor
        let priority = Int32(bitPattern: r(0))
        guard (0...0x3F).contains(priority) else { set(0, 0xE0E0_1BFD); return }
        guard let thread = createThread(entry: r(1), argument: r(2), stackTop: r(3), priority: priority) else {
            set(0, ResultCode.outOfMemory)
            return
        }
        set(0, 0); set(1, makeHandle(thread))
        if needsReschedule { cpu.halt() }
    }

    private func releaseMutex() {
        guard let mutex = object(r(0), as: KMutex.self) else { set(0, ResultCode.invalidHandle); return }
        guard let thread = currentThread, mutex.owner === thread else { set(0, 0xD8E0_041F); return }
        mutex.lockCount -= 1
        if mutex.lockCount <= 0 {
            mutex.owner = nil
            mutex.lockCount = 0
            thread.heldMutexes.removeAll { $0 === mutex }
            wakeWaiters(of: mutex)
        }
        set(0, 0)
    }

    private func waitSynchronizationN() {
        // r0 timeout low, r1 handle array, r2 count, r3 wait all, r4 timeout high
        let count = Int(Int32(bitPattern: r(2)))
        guard (0...64).contains(count) else { set(0, 0xE0E0_1BFD); return }
        var objects: [KernelObject] = []
        for i in 0..<count {
            guard let o = object(memory.read32(r(1) &+ UInt32(i * 4))) else { set(0, ResultCode.invalidHandle); return }
            objects.append(o)
        }
        beginWait(objects, waitAll: r(3) != 0, timeout: ns(low: 0, high: 4), reportsIndex: true)
    }

    private func arbitrateAddress() {
        // r0 arbiter, r1 address, r2 type, r3 value, r4:r5 timeout
        guard let arbiter = object(r(0), as: KAddressArbiter.self) else { set(0, ResultCode.invalidHandle); return }
        let address = r(1), value = Int32(bitPattern: r(3))
        let timeout = Int64(bitPattern: UInt64(r(5)) << 32 | UInt64(r(4)))
        let current = Int32(bitPattern: memory.read32(address))
        func wait(timed: Bool) {
            guard let thread = currentThread else { return }
            thread.arbiterWait = (arbiter, address)
            thread.state = .waiting
            thread.reportsIndex = false
            thread.wakeTime = timed && timeout >= 0 ? now &+ Self.cycles(nanoseconds: timeout) : nil
            set(0, 0)
            cpu.halt()
        }
        switch r(2) {
        case 0:  // Signal: wake `value` waiters (all if negative), highest priority first.
            var waiting = threads.filter { $0.state == .waiting && $0.arbiterWait?.arbiter === arbiter && $0.arbiterWait?.address == address }
            waiting.sort { $0.priority < $1.priority }
            let n = value < 0 ? waiting.count : min(Int(value), waiting.count)
            set(0, 0)
            for t in waiting.prefix(n) { finishWait(t, result: 0, index: nil) }
        case 1, 3:  // WaitIfLessThan (3: with timeout)
            set(0, 0)
            if current < value { wait(timed: r(2) == 3) }
        case 2, 4:  // DecrementAndWaitIfLessThan (4: with timeout)
            set(0, 0)
            if current < value {
                memory.write32(address, UInt32(bitPattern: current &- 1))
                wait(timed: r(2) == 4)
            }
        default:
            set(0, ResultCode.invalidCombination)
        }
    }

    private func controlMemory() {
        // r0 operation, r1 addr0, r2 addr1, r3 size, r4 permission -> r1 address
        let operation = r(0)
        let addr0 = r(1), addr1 = r(2)
        let size = (r(3) + 0xFFF) & ~0xFFF
        let linear = operation & 0x1_0000 != 0
        switch operation & 0xFF {
        case 3:  // COMMIT
            if linear {
                guard linearUsed + heapUsed + size <= Self.applicationMemory else { set(0, ResultCode.outOfMemory); return }
                let virtualAddress = AddressSpace.linearBase + linearUsed
                memory.map(virtualAddress, host: memory.fcram + Int(linearUsed), size: size, permission: .readWrite, state: .continuous)
                linearUsed += size
                mappedAllocations[virtualAddress] = size
                set(0, 0); set(1, virtualAddress)
            } else {
                guard addr0 >= 0x0800_0000 && addr0 &+ size <= 0x1000_0000 else { set(0, ResultCode.invalidAddress); return }
                guard linearUsed + heapUsed + size <= Self.applicationMemory else { set(0, ResultCode.outOfMemory); return }
                heapUsed += size
                let offset = Int(Self.applicationMemory - heapUsed)
                memory.map(addr0, host: memory.fcram + offset, size: size, permission: .readWrite, state: .private)
                mappedAllocations[addr0] = size
                set(0, 0); set(1, addr0)
            }
        case 1:  // FREE
            memory.unmap(addr0, size: size)
            mappedAllocations[addr0] = nil
            set(0, 0); set(1, addr0)
        case 4:  // MAP: alias addr1's pages at addr0
            for page in 0..<(size >> 12) {
                guard let host = memory.pointer(addr1 + page << 12) else { set(0, ResultCode.invalidAddress); return }
                memory.map(addr0 + page << 12, host: host, size: 0x1000, permission: .readWrite, state: .alias)
            }
            set(0, 0); set(1, addr0)
        case 5:  // UNMAP
            memory.unmap(addr0, size: size)
            set(0, 0); set(1, addr0)
        case 6:  // PROTECT
            set(0, 0); set(1, addr0)
        default:
            set(0, ResultCode.invalidCombination)
        }
    }

    private func queryMemory() {
        // r2 address -> r1 base, r2 size, r3 permission, r4 state, r5 page flags
        let info = memory.region(containing: r(2))
        set(0, 0)
        set(1, info.base); set(2, info.size); set(3, info.permission.rawValue)
        set(4, info.state.rawValue); set(5, 0)
    }

    private func createMemoryBlock() {
        // r0 other permission, r1 address, r2 size, r3 my permission -> r1 handle
        let address = r(1), size = r(2)
        let block: KSharedMemory
        if address == 0 {
            block = KSharedMemory(size: (size + 0xFFF) & ~0xFFF)
        } else {
            guard let host = memory.pointer(address) else { set(0, ResultCode.invalidAddress); return }
            block = KSharedMemory(existing: host, size: size, at: address)
        }
        set(0, 0); set(1, makeHandle(block))
    }

    private func mapMemoryBlock() {
        // r0 handle, r1 address, r2 my permission, r3 other permission
        guard let block = object(r(0), as: KSharedMemory.self) else { set(0, ResultCode.invalidHandle); return }
        let address = r(1)
        guard address & 0xFFF == 0, address != 0 else { set(0, ResultCode.invalidAddress); return }
        memory.map(address, host: block.host, size: (block.size + 0xFFF) & ~0xFFF, permission: .readWrite, state: .shared)
        block.mappedAddress = address
        set(0, 0)
    }

    private func getSystemInfo() {
        // r1 type, r2 parameter -> r1:r2 (s64)
        var value: UInt64 = 0
        switch (r(1), r(2)) {
        case (0, 1): value = UInt64(linearUsed + heapUsed)  // memory used by the application region
        case (0, _): value = UInt64(linearUsed + heapUsed)
        case (26, _): value = 1                            // processes started by the kernel
        default: break
        }
        set(0, 0); set(1, UInt32(truncatingIfNeeded: value)); set(2, UInt32(truncatingIfNeeded: value >> 32))
    }

    private func getProcessInfo() {
        // r1 process, r2 type -> r1:r2 (s64)
        var value: Int64 = 0
        switch r(2) {
        case 0, 2: value = Int64(linearUsed + heapUsed)
        case 20: value = Int64(AddressSpace.fcramPhysical) - Int64(AddressSpace.linearBase)  // linear -> physical
        case 22: value = Int64(AddressSpace.linearBase)
        default: break
        }
        let bits = UInt64(bitPattern: value)
        set(0, 0); set(1, UInt32(truncatingIfNeeded: bits)); set(2, UInt32(truncatingIfNeeded: bits >> 32))
    }

    private func resourceLimitValues(current: Bool) {
        // r0 values (s64[]), r1 handle, r2 names (u32[]), r3 count
        for i in 0..<Int(min(r(3), 16)) {
            let name = memory.read32(r(2) &+ UInt32(i * 4))
            let value: UInt64
            switch name {
            case 0: value = current ? 0x30 : 0x18                                   // priority
            case 1: value = UInt64(current ? linearUsed + heapUsed : Self.applicationMemory)  // commit
            case 2: value = current ? UInt64(threads.filter { $0.state != .dead }.count) : 32
            default: value = current ? 0 : 32
            }
            memory.write32(r(0) &+ UInt32(i * 8), UInt32(truncatingIfNeeded: value))
            memory.write32(r(0) &+ UInt32(i * 8 + 4), UInt32(truncatingIfNeeded: value >> 32))
        }
        set(0, 0)
    }
}
