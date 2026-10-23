// SPDX-License-Identifier: GPL-3.0-or-later

/// Memory as one ARM CPU sees it. The DS has two buses, one per CPU.
///
/// `ARM` is generic over its bus so every call is statically dispatched and
/// inlined after specialisation; there is no protocol witness in the hot loop.
public protocol ARMBus: AnyObject {
    func read8(_ address: UInt32) -> UInt8
    func read16(_ address: UInt32) -> UInt16
    func read32(_ address: UInt32) -> UInt32
    func write8(_ address: UInt32, _ value: UInt8)
    func write16(_ address: UInt32, _ value: UInt16)
    func write32(_ address: UInt32, _ value: UInt32)

    /// Instruction fetches. Separate so ITCM and code caches can short-circuit them.
    func fetch16(_ address: UInt32) -> UInt16
    func fetch32(_ address: UInt32) -> UInt32

    /// Software interrupt handled in Swift instead of BIOS code. Return true if handled.
    /// Not on the hot path, so the CPU is passed as an existential.
    func hleSWI(_ number: UInt32, cpu: ARMRegisterFile) -> Bool

    /// Coprocessor 15 (ARM9 only). The ARM7 bus returns 0 and ignores writes.
    func cp15Read(cn: Int, cm: Int, cp: Int) -> UInt32
    func cp15Write(cn: Int, cm: Int, cp: Int, value: UInt32, cpu: ARMRegisterFile)

    /// Where the game stores its IRQ handler address, which the BIOS jumps through.
    var irqHandlerPointer: UInt32 { get }
    /// Where the game's IRQ handler records serviced interrupts for BIOS IntrWait.
    var irqCheckFlagsAddress: UInt32 { get }
}

/// CPU state as seen by HLE BIOS calls and coprocessor writes.
public protocol ARMRegisterFile: AnyObject {
    func reg(_ i: Int) -> UInt32
    func setReg(_ i: Int, _ value: UInt32)
    var cycles: UInt64 { get set }
    /// Stops the CPU until an enabled interrupt is pending.
    func halt()
    /// Halts until one of `mask` is raised in IF (BIOS IntrWait semantics).
    func waitForInterrupt(mask: UInt32, discardOld: Bool)
}
