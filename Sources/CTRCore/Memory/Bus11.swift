// SPDX-License-Identifier: GPL-3.0-or-later

import ARMCore

/// The application ARM11 core's view of memory: the process address space, with
/// SVCs going to the HLE kernel and CP15 c13 giving the thread-local storage pointer.
final class Bus11: ARMBus {
    let memory: AddressSpace
    unowned(unsafe) var kernel: Kernel!

    init(memory: AddressSpace) { self.memory = memory }

    @inline(__always) func read8(_ a: UInt32) -> UInt8 { memory.read8(a) }
    @inline(__always) func read16(_ a: UInt32) -> UInt16 { memory.read16(a) }
    @inline(__always) func read32(_ a: UInt32) -> UInt32 { memory.read32(a) }
    @inline(__always) func write8(_ a: UInt32, _ v: UInt8) { memory.write8(a, v) }
    @inline(__always) func write16(_ a: UInt32, _ v: UInt16) { memory.write16(a, v) }
    @inline(__always) func write32(_ a: UInt32, _ v: UInt32) { memory.write32(a, v) }
    @inline(__always) func fetch16(_ a: UInt32) -> UInt16 { memory.read16(a) }
    @inline(__always) func fetch32(_ a: UInt32) -> UInt32 { memory.read32(a) }

    func hleSWI(_ number: UInt32, cpu: ARMRegisterFile) -> Bool {
        kernel.supervisorCall(number)
        return true
    }

    func cp15Read(cn: Int, cm: Int, cp: Int) -> UInt32 {
        // c13, c0, 3: user read-only thread ID register, which Horizon sets to the TLS address.
        if cn == 13 && cm == 0 && cp == 3 { return kernel.currentThread?.tlsAddress ?? 0 }
        return 0
    }

    // Cache maintenance and barriers (c7) need no emulation.
    func cp15Write(cn: Int, cm: Int, cp: Int, value: UInt32, cpu: ARMRegisterFile) {}

    var irqHandlerPointer: UInt32 { 0 }
    var irqCheckFlagsAddress: UInt32 { 0 }
}
