// SPDX-License-Identifier: GPL-3.0-or-later
//
// ARM7TDMI (ARMv4T), ARM946E-S (ARMv5TE) and ARM11 MPCore (ARMv6K + VFPv2)
// interpreter. Written from the ARM Architecture Reference Manual and GBATEK.

/// CPSR bits.
@usableFromInline enum PSR {
    static let n: UInt32 = 1 << 31
    static let z: UInt32 = 1 << 30
    static let c: UInt32 = 1 << 29
    static let v: UInt32 = 1 << 28
    static let q: UInt32 = 1 << 27
    static let i: UInt32 = 1 << 7
    static let f: UInt32 = 1 << 6
    static let t: UInt32 = 1 << 5
    static let modeMask: UInt32 = 0x1F
}

public enum ARMMode: UInt32 {
    case user = 0x10, fiq = 0x11, irq = 0x12, supervisor = 0x13
    case abort = 0x17, undefined = 0x1B, system = 0x1F
}

public final class ARM<Bus: ARMBus>: ARMRegisterFile {
    /// DS ARM7, DS ARM9, 3DS ARM11.
    public enum Model: Sendable { case arm7tdmi, arm946es, arm11mpcore }

    public let model: Model
    /// ARMv5TE instructions (BLX, CLZ, QADD, SMLAxy, LDRD) are only on the ARM9.
    @usableFromInline let isV5: Bool
    /// ARMv6K media, exclusive and VFP instructions, unaligned access: ARM11 only.
    @usableFromInline let isV6: Bool
    // Strong, so calls through it need no retain: the bus never points back at the CPU strongly.
    @usableFromInline let bus: Bus

    // Register storage, one allocation so the hot loop never touches Swift arrays.
    //   0..<16  visible r0-r15
    //  16..<22  banked r13 per bank      22..<28  banked r14 per bank
    //  28..<34  SPSR per bank            34..<39  FIQ r8-r12   39..<44  user r8-r12
    @usableFromInline let regs: UnsafeMutablePointer<UInt32>
    @exclusivity(unchecked) @usableFromInline var cpsr: UInt32 = ARMMode.supervisor.rawValue | PSR.i | PSR.f

    @exclusivity(unchecked) public var cycles: UInt64 = 0
    @exclusivity(unchecked) public private(set) var halted = false
    /// IME && (IE & IF) != 0. Set by the interrupt controller.
    @exclusivity(unchecked) public var irqLine = false
    /// (IE & IF) != 0, which wakes a halted CPU even when IME is off.
    @exclusivity(unchecked) public var wakeLine = false
    /// Base of the exception vectors: 0 on the ARM7, 0xFFFF0000 on the ARM9 by default.
    @exclusivity(unchecked) public var exceptionBase: UInt32
    /// When true, SWIs and IRQ entry are handled in Swift and no BIOS image is needed.
    @exclusivity(unchecked) public var hleBIOS = true
    /// Instructions retired, for benchmarks.
    @exclusivity(unchecked) public private(set) var instructionsRetired: UInt64 = 0

    /// Cycles one instruction costs on the master clock. The ARM7 runs at half the ARM9 clock.
    @usableFromInline let cyclesPerInstruction: UInt64

    /// Set when the current instruction wrote r15, so `step` must not advance the PC.
    @exclusivity(unchecked) @usableFromInline var branched = false

    @exclusivity(unchecked) @usableFromInline var intrWaitMask: UInt32 = 0

    /// Address reserved by LDREX, cleared by STREX, CLREX and context switches.
    @exclusivity(unchecked) @usableFromInline var exclusiveAddress: UInt32? = nil

    /// VFP registers s0-s31 (d0-d15 are pairs of them, low word first), FPSCR and FPEXC.
    @usableFromInline let vfp: UnsafeMutablePointer<UInt32>
    @exclusivity(unchecked) public var fpscr: UInt32 = 0
    @exclusivity(unchecked) public var fpexc: UInt32 = 0

    /// Address the HLE IRQ stub returns to. Inside the BIOS region, never executed.
    @usableFromInline let hleIRQReturn: UInt32

    /// Instruction class for each value of bits 27-20 and 7-4 (see `ARMKind`).
    @usableFromInline let armDecodeTable: UnsafeMutablePointer<UInt8>
    /// Bit `cond` of entry `NZCV` says whether condition `cond` passes for those flags.
    @usableFromInline let conditionTable: UnsafeMutablePointer<UInt16>

    public init(model: Model, bus: Bus) {
        self.model = model
        self.bus = bus
        isV5 = model != .arm7tdmi
        isV6 = model == .arm11mpcore
        exceptionBase = model == .arm7tdmi ? 0 : 0xFFFF_0000
        cyclesPerInstruction = model == .arm7tdmi ? 2 : 1
        hleIRQReturn = model == .arm7tdmi ? 0x0000_0F00 : 0xFFFF_0F00
        regs = .allocate(capacity: 44)
        regs.initialize(repeating: 0, count: 44)
        armDecodeTable = ARMKind.makeTable(v6: model == .arm11mpcore)
        vfp = .allocate(capacity: 32)
        vfp.initialize(repeating: 0, count: 32)
        conditionTable = .allocate(capacity: 16)
        for flags in 0..<16 {
            var passes: UInt16 = 0
            for cond in 0..<16 where Self.evaluate(UInt32(cond), flags: UInt32(flags)) { passes |= 1 << cond }
            conditionTable[flags] = passes
        }
    }

    deinit {
        regs.deallocate()
        armDecodeTable.deallocate()
        conditionTable.deallocate()
        vfp.deallocate()
    }

    // MARK: - Register file

    @inline(__always) public func reg(_ i: Int) -> UInt32 { regs[i] }

    @inline(__always) public func setReg(_ i: Int, _ value: UInt32) {
        if i == 15 { branch(to: value) } else { regs[i] = value }
    }

    public var pc: UInt32 { regs[15] }
    public var thumb: Bool { cpsr & PSR.t != 0 }
    public var mode: ARMMode? { ARMMode(rawValue: cpsr & PSR.modeMask) }
    public var statusRegister: UInt32 { cpsr }

    /// Jumps without changing state (ARM stays ARM, Thumb stays Thumb).
    @inline(__always) @usableFromInline func branch(to address: UInt32) {
        regs[15] = cpsr & PSR.t != 0 ? address & ~1 : address & ~3
        branched = true
    }

    /// Jumps and selects ARM or Thumb from bit 0, as BX does.
    @inline(__always) @usableFromInline func branchExchange(to address: UInt32) {
        if address & 1 != 0 {
            cpsr |= PSR.t
            regs[15] = address & ~1
        } else {
            cpsr &= ~PSR.t
            regs[15] = address & ~3
        }
        branched = true
    }

    /// Loads into r15: ARMv5 interworks on bit 0, ARMv4 does not.
    @inline(__always) @usableFromInline func loadPC(_ value: UInt32) {
        if isV5 { branchExchange(to: value) } else { branch(to: value) }
    }

    @inline(__always) static func bankIndex(_ mode: UInt32) -> Int {
        switch mode {
        case 0x11: return 1
        case 0x12: return 2
        case 0x13: return 3
        case 0x17: return 4
        case 0x1B: return 5
        default: return 0  // user, system
        }
    }

    @usableFromInline func switchMode(_ newMode: UInt32) {
        let oldMode = cpsr & PSR.modeMask
        if oldMode == newMode { return }
        let oldBank = Self.bankIndex(oldMode), newBank = Self.bankIndex(newMode)
        if oldBank != newBank {
            regs[16 + oldBank] = regs[13]
            regs[22 + oldBank] = regs[14]
            if oldMode == 0x11 {
                for i in 0..<5 { regs[34 + i] = regs[8 + i]; regs[8 + i] = regs[39 + i] }
            }
            if newMode == 0x11 {
                for i in 0..<5 { regs[39 + i] = regs[8 + i]; regs[8 + i] = regs[34 + i] }
            }
            regs[13] = regs[16 + newBank]
            regs[14] = regs[22 + newBank]
        }
        cpsr = (cpsr & ~PSR.modeMask) | newMode
    }

    @usableFromInline var hasSPSR: Bool { Self.bankIndex(cpsr & PSR.modeMask) != 0 }

    @usableFromInline var spsr: UInt32 {
        get { hasSPSR ? regs[28 + Self.bankIndex(cpsr & PSR.modeMask)] : cpsr }
        set { if hasSPSR { regs[28 + Self.bankIndex(cpsr & PSR.modeMask)] = newValue } }
    }

    /// Writes the whole CPSR, switching register banks if the mode changes.
    @usableFromInline func setCPSR(_ value: UInt32) {
        switchMode(value & PSR.modeMask)
        cpsr = value
    }

    /// Sets up registers as the BIOS leaves them before jumping to a game (direct boot).
    public func directBoot(entry: UInt32, stackSVC: UInt32, stackIRQ: UInt32, stackSYS: UInt32) {
        setCPSR(ARMMode.supervisor.rawValue | PSR.i | PSR.f)
        regs[13] = stackSVC
        setCPSR(ARMMode.irq.rawValue | PSR.i | PSR.f)
        regs[13] = stackIRQ
        setCPSR(ARMMode.system.rawValue)
        regs[13] = stackSYS
        for i in 0..<13 { regs[i] = 0 }
        regs[12] = entry
        regs[14] = entry
        regs[15] = entry
        halted = false
    }

    // MARK: - Halting and interrupts

    public func halt() { halted = true }

    /// Clears a halt without an interrupt (an OS kernel resuming a thread).
    public func resume() { halted = false }

    /// When false, `run(until:)` returns as soon as the CPU halts instead of idling to
    /// the target, so a kernel can switch threads. The 3DS core clears it.
    @exclusivity(unchecked) public var haltConsumesTime = true

    // MARK: - Thread contexts (for an HLE kernel)

    /// User-visible state of one thread: r0-r15, CPSR, VFP registers and FPSCR.
    public struct Context: Sendable {
        public var r = [UInt32](repeating: 0, count: 16)
        public var cpsr: UInt32 = ARMMode.user.rawValue
        public var vfp = [UInt32](repeating: 0, count: 32)
        public var fpscr: UInt32 = 0
        public init() {}
    }

    /// Saves the current thread. Assumes user or system mode (no banked registers in use).
    public func saveContext(into context: inout Context) {
        for i in 0..<16 { context.r[i] = regs[i] }
        context.cpsr = cpsr
        for i in 0..<32 { context.vfp[i] = vfp[i] }
        context.fpscr = fpscr
    }

    public func loadContext(_ context: Context) {
        for i in 0..<16 { regs[i] = context.r[i] }
        cpsr = context.cpsr
        for i in 0..<32 { vfp[i] = context.vfp[i] }
        fpscr = context.fpscr
        exclusiveAddress = nil
        halted = false
    }

    public func waitForInterrupt(mask: UInt32, discardOld: Bool) {
        let flagsAddress = bus.irqCheckFlagsAddress
        if discardOld {
            bus.write32(flagsAddress, bus.read32(flagsAddress) & ~mask)
        } else if bus.read32(flagsAddress) & mask != 0 {
            bus.write32(flagsAddress, bus.read32(flagsAddress) & ~mask)
            return
        }
        intrWaitMask = mask
        halted = true
    }

    @usableFromInline func enterException(vector: UInt32, mode: ARMMode, returnAddress: UInt32) {
        let old = cpsr
        switchMode(mode.rawValue)
        spsr = old
        regs[14] = returnAddress
        cpsr = (cpsr & ~PSR.t) | PSR.i
        if mode == .fiq { cpsr |= PSR.f }
        regs[15] = exceptionBase &+ vector
        branched = true
    }

    /// Takes an IRQ before the instruction at r15.
    @usableFromInline func serviceIRQ() {
        enterException(vector: 0x18, mode: .irq, returnAddress: regs[15] &+ 4)
        guard hleBIOS else { return }
        // What the BIOS stub does: push r0-r3, r12, lr; r0 = 0x04000000;
        // lr = stub return; jump to the handler the game installed.
        var sp = regs[13] &- 24
        regs[13] = sp
        for i in [0, 1, 2, 3, 12, 14] {
            bus.write32(sp, regs[i])
            sp &+= 4
        }
        regs[0] = 0x0400_0000
        regs[14] = hleIRQReturn
        branchExchange(to: bus.read32(bus.irqHandlerPointer))
    }

    /// The BIOS stub's tail: pop r0-r3, r12, lr; SUBS pc, lr, #4.
    @usableFromInline func returnFromHLEIRQ() {
        var sp = regs[13]
        for i in [0, 1, 2, 3, 12, 14] {
            regs[i] = bus.read32(sp)
            sp &+= 4
        }
        regs[13] = sp
        let target = regs[14] &- 4
        setCPSR(spsr)
        branch(to: target)
        if intrWaitMask != 0 {
            let flagsAddress = bus.irqCheckFlagsAddress
            let flags = bus.read32(flagsAddress)
            if flags & intrWaitMask != 0 {
                bus.write32(flagsAddress, flags & ~intrWaitMask)
                intrWaitMask = 0
            } else {
                halted = true
            }
        }
    }

    // MARK: - Run loop

    /// Runs until the master clock reaches `target`.
    public func run(until target: UInt64) {
        while cycles < target {
            if halted {
                if wakeLine || irqLine { halted = false } else {
                    if haltConsumesTime { cycles = target }
                    return
                }
            }
            if irqLine && cpsr & PSR.i == 0 {
                branched = false
                serviceIRQ()
            }
            if cpsr & PSR.t != 0 { runThumb(until: target) } else { runARM(until: target) }
        }
    }

    /// Executes ARM instructions until the target, a switch to Thumb, a halt, or a pending IRQ.
    @inline(__always) func runARM(until target: UInt64) {
        repeat {
            let address = regs[15]
            if hleBIOS && address == hleIRQReturn {
                returnFromHLEIRQ()
            } else {
                branched = false
                let op = bus.fetch32(address)
                regs[15] = address &+ 8
                executeARM(op, address: address)
                if !branched { regs[15] = address &+ 4 }
                instructionsRetired &+= 1
            }
            cycles &+= cyclesPerInstruction
        } while cycles < target && !mustLeaveLoop(stateBit: 0)
    }

    /// Executes Thumb instructions until the target, a switch to ARM, a halt, or a pending IRQ.
    @inline(__always) func runThumb(until target: UInt64) {
        repeat {
            branched = false
            let address = regs[15]
            let op = bus.fetch16(address)
            regs[15] = address &+ 4
            executeThumb(op, address: address)
            if !branched { regs[15] = address &+ 2 }
            instructionsRetired &+= 1
            cycles &+= cyclesPerInstruction
        } while cycles < target && !mustLeaveLoop(stateBit: PSR.t)
    }

    @inline(__always) func mustLeaveLoop(stateBit: UInt32) -> Bool {
        cpsr & PSR.t != stateBit || halted || (irqLine && cpsr & PSR.i == 0)
    }

    public func step() {
        branched = false
        let address = regs[15]
        if cpsr & PSR.t != 0 {
            let op = bus.fetch16(address)
            regs[15] = address &+ 4
            executeThumb(op, address: address)
            if !branched { regs[15] = address &+ 2 }
        } else {
            if hleBIOS && address == hleIRQReturn {
                returnFromHLEIRQ()
                return
            }
            let op = bus.fetch32(address)
            regs[15] = address &+ 8
            executeARM(op, address: address)
            if !branched { regs[15] = address &+ 4 }
        }
        instructionsRetired &+= 1
    }

    // MARK: - Flags and shifter

    @inline(__always) @usableFromInline func conditionPassed(_ cond: UInt32) -> Bool {
        (conditionTable[Int(cpsr >> 28)] >> UInt16(cond)) & 1 != 0
    }

    /// Condition `cond` against NZCV flags given as a 4-bit value; builds `conditionTable`.
    static func evaluate(_ cond: UInt32, flags: UInt32) -> Bool {
        let n = flags & 8 != 0, z = flags & 4 != 0
        let c = flags & 2 != 0, v = flags & 1 != 0
        switch cond {
        case 0x0: return z
        case 0x1: return !z
        case 0x2: return c
        case 0x3: return !c
        case 0x4: return n
        case 0x5: return !n
        case 0x6: return v
        case 0x7: return !v
        case 0x8: return c && !z
        case 0x9: return !c || z
        case 0xA: return n == v
        case 0xB: return n != v
        case 0xC: return !z && n == v
        case 0xD: return z || n != v
        case 0xE: return true
        default: return false
        }
    }

    @inline(__always) @usableFromInline var carry: UInt32 { (cpsr >> 29) & 1 }

    @inline(__always) @usableFromInline func setNZ(_ result: UInt32) {
        cpsr = (cpsr & ~(PSR.n | PSR.z)) | (result & PSR.n) | (result == 0 ? PSR.z : 0)
    }

    @inline(__always) @usableFromInline func setNZC(_ result: UInt32, _ c: Bool) {
        cpsr = (cpsr & ~(PSR.n | PSR.z | PSR.c)) | (result & PSR.n) | (result == 0 ? PSR.z : 0) | (c ? PSR.c : 0)
    }

    /// a + b + carryIn, setting NZCV when `setFlags`.
    @inline(__always) @usableFromInline
    func addWithCarry(_ a: UInt32, _ b: UInt32, _ carryIn: UInt32, setFlags: Bool) -> UInt32 {
        let wide = UInt64(a) &+ UInt64(b) &+ UInt64(carryIn)
        let result = UInt32(truncatingIfNeeded: wide)
        if setFlags {
            let c = wide >> 32 != 0
            let v = (~(a ^ b) & (a ^ result)) >> 31 != 0
            cpsr = (cpsr & ~(PSR.n | PSR.z | PSR.c | PSR.v)) | (result & PSR.n) | (result == 0 ? PSR.z : 0)
                | (c ? PSR.c : 0) | (v ? PSR.v : 0)
        }
        return result
    }

    /// Barrel shifter with an immediate amount (encodings where 0 has special meanings).
    @inline(__always) @usableFromInline
    func shiftImmediate(_ type: UInt32, _ value: UInt32, _ amount: UInt32) -> (UInt32, Bool) {
        let c = cpsr & PSR.c != 0
        switch type {
        case 0:  // LSL
            if amount == 0 { return (value, c) }
            return (value << amount, (value >> (32 - amount)) & 1 != 0)
        case 1:  // LSR, 0 means 32
            if amount == 0 { return (0, value >> 31 != 0) }
            return (value >> amount, (value >> (amount - 1)) & 1 != 0)
        case 2:  // ASR, 0 means 32
            if amount == 0 {
                let s = value >> 31 != 0
                return (s ? 0xFFFF_FFFF : 0, s)
            }
            return (UInt32(bitPattern: Int32(bitPattern: value) >> Int32(amount)), (value >> (amount - 1)) & 1 != 0)
        default:  // ROR, 0 means RRX
            if amount == 0 { return ((c ? 0x8000_0000 : 0) | value >> 1, value & 1 != 0) }
            return (value.rotatedRight(amount), (value >> (amount - 1)) & 1 != 0)
        }
    }

    /// Barrel shifter with the amount taken from a register (bottom byte).
    @inline(__always) @usableFromInline
    func shiftRegister(_ type: UInt32, _ value: UInt32, _ amount: UInt32) -> (UInt32, Bool) {
        let c = cpsr & PSR.c != 0
        if amount == 0 { return (value, c) }
        switch type {
        case 0:
            if amount < 32 { return (value << amount, (value >> (32 - amount)) & 1 != 0) }
            return (0, amount == 32 ? value & 1 != 0 : false)
        case 1:
            if amount < 32 { return (value >> amount, (value >> (amount - 1)) & 1 != 0) }
            return (0, amount == 32 ? value >> 31 != 0 : false)
        case 2:
            if amount < 32 {
                return (UInt32(bitPattern: Int32(bitPattern: value) >> Int32(amount)), (value >> (amount - 1)) & 1 != 0)
            }
            let s = value >> 31 != 0
            return (s ? 0xFFFF_FFFF : 0, s)
        default:
            let r = amount & 31
            if r == 0 { return (value, value >> 31 != 0) }
            return (value.rotatedRight(r), (value >> (r - 1)) & 1 != 0)
        }
    }

    // MARK: - Memory helpers

    /// LDR semantics: before ARMv6, an aligned read rotated by the low address bits.
    /// The 3DS runs the ARM11 with unaligned access enabled, so it reads the bytes as addressed.
    @inline(__always) @usableFromInline func loadWord(_ address: UInt32) -> UInt32 {
        if address & 3 != 0 && isV6 { return unalignedRead32(address) }
        let v = bus.read32(address & ~3)
        return v.rotatedRight((address & 3) * 8)
    }

    @inline(__always) @usableFromInline func storeWord(_ address: UInt32, _ value: UInt32) {
        if address & 3 != 0 && isV6 { unalignedWrite32(address, value); return }
        bus.write32(address & ~3, value)
    }

    @inline(__always) @usableFromInline func loadHalf(_ address: UInt32) -> UInt32 {
        if address & 1 != 0 && isV6 { return UInt32(bus.read8(address)) | UInt32(bus.read8(address &+ 1)) << 8 }
        let v = UInt32(bus.read16(address & ~1))
        if !isV5 && address & 1 != 0 { return v.rotatedRight(8) }
        return v
    }

    @inline(__always) @usableFromInline func storeHalf(_ address: UInt32, _ value: UInt32) {
        if address & 1 != 0 && isV6 {
            bus.write8(address, UInt8(truncatingIfNeeded: value))
            bus.write8(address &+ 1, UInt8(truncatingIfNeeded: value >> 8))
            return
        }
        bus.write16(address & ~1, UInt16(truncatingIfNeeded: value))
    }

    @inline(__always) @usableFromInline func loadSignedHalf(_ address: UInt32) -> UInt32 {
        if address & 1 != 0 && isV6 { return UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(loadHalf(address))))) }
        if !isV5 && address & 1 != 0 {
            return UInt32(bitPattern: Int32(Int8(bitPattern: bus.read8(address))))
        }
        return UInt32(bitPattern: Int32(Int16(bitPattern: bus.read16(address & ~1))))
    }

    @usableFromInline func unalignedRead32(_ address: UInt32) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 as Range<UInt32> { v |= UInt32(bus.read8(address &+ i)) << (i * 8) }
        return v
    }

    @usableFromInline func unalignedWrite32(_ address: UInt32, _ value: UInt32) {
        for i in 0..<4 as Range<UInt32> { bus.write8(address &+ i, UInt8(truncatingIfNeeded: value >> (i * 8))) }
    }

    @inline(__always) @usableFromInline func loadSignedByte(_ address: UInt32) -> UInt32 {
        UInt32(bitPattern: Int32(Int8(bitPattern: bus.read8(address))))
    }

    // MARK: - Saturating arithmetic (ARMv5TE)

    @inline(__always) @usableFromInline func saturatingAdd(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let (r, o) = Int32(bitPattern: a).addingReportingOverflow(Int32(bitPattern: b))
        if o { cpsr |= PSR.q; return r < 0 ? 0x7FFF_FFFF : 0x8000_0000 }
        return UInt32(bitPattern: r)
    }

    @inline(__always) @usableFromInline func saturatingSub(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let (r, o) = Int32(bitPattern: a).subtractingReportingOverflow(Int32(bitPattern: b))
        if o { cpsr |= PSR.q; return r < 0 ? 0x7FFF_FFFF : 0x8000_0000 }
        return UInt32(bitPattern: r)
    }

    @inline(__always) @usableFromInline func halfword(_ v: UInt32, top: Bool) -> Int32 {
        Int32(Int16(truncatingIfNeeded: top ? v >> 16 : v))
    }
}
