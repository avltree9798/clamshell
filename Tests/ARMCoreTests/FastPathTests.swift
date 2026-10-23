// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import ARMCore
import CARM
import Foundation

/// 1 MB of flat RAM at address 0; everything above reads as zero.
final class PagedBus: ARMBus {
    static let size = 0x10_0000
    let memory = UnsafeMutableRawPointer.allocate(byteCount: PagedBus.size, alignment: 4096)
    var swis: [UInt32] = []

    init(copying other: PagedBus? = nil) {
        if let other { memory.copyMemory(from: other.memory, byteCount: Self.size) } else {
            memory.initializeMemory(as: UInt8.self, repeating: 0, count: Self.size)
        }
    }
    deinit { memory.deallocate() }

    func read8(_ a: UInt32) -> UInt8 { Int(a) < Self.size ? memory.load(fromByteOffset: Int(a), as: UInt8.self) : 0 }
    func read16(_ a: UInt32) -> UInt16 { UInt16(read8(a)) | UInt16(read8(a &+ 1)) << 8 }
    func read32(_ a: UInt32) -> UInt32 { UInt32(read16(a)) | UInt32(read16(a &+ 2)) << 16 }
    func write8(_ a: UInt32, _ v: UInt8) { if Int(a) < Self.size { memory.storeBytes(of: v, toByteOffset: Int(a), as: UInt8.self) } }
    func write16(_ a: UInt32, _ v: UInt16) { write8(a, UInt8(truncatingIfNeeded: v)); write8(a &+ 1, UInt8(truncatingIfNeeded: v >> 8)) }
    func write32(_ a: UInt32, _ v: UInt32) { write16(a, UInt16(truncatingIfNeeded: v)); write16(a &+ 2, UInt16(truncatingIfNeeded: v >> 16)) }
    func fetch16(_ a: UInt32) -> UInt16 { read16(a) }
    func fetch32(_ a: UInt32) -> UInt32 { read32(a) }
    func hleSWI(_ number: UInt32, cpu: ARMRegisterFile) -> Bool { swis.append(number); return true }
    func cp15Read(cn: Int, cm: Int, cp: Int) -> UInt32 { 0 }
    func cp15Write(cn: Int, cm: Int, cp: Int, value: UInt32, cpu: ARMRegisterFile) {}
    var irqHandlerPointer: UInt32 { 0 }
    var irqCheckFlagsAddress: UInt32 { 0 }
}

/// A small deterministic generator, so a failure always reproduces.
struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt32 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return UInt32(truncatingIfNeeded: z ^ (z >> 31))
    }
    mutating func below(_ n: UInt32) -> UInt32 { next() % n }
}

/// The C fast path must leave the CPU exactly as the Swift interpreter would.
@Suite struct FastPathTests {
    /// Instructions the fast path handles, with random fields, plus a few it hands back.
    static func instruction(_ rng: inout SplitMix) -> UInt32 {
        let cond: UInt32 = rng.below(4) == 0 ? rng.below(15) << 28 : 0xE000_0000
        let r = { (rng: inout SplitMix) -> UInt32 in rng.below(16) }
        switch rng.below(14) {
        case 0, 1, 2:  // data processing, immediate
            return cond | 1 << 25 | rng.below(16) << 21 | rng.below(2) << 20 | r(&rng) << 16 | r(&rng) << 12 | rng.below(0x1000)
        case 3, 4:  // data processing, shifted register
            return cond | rng.below(16) << 21 | rng.below(2) << 20 | r(&rng) << 16 | r(&rng) << 12 | rng.below(0x100) << 4 & 0xFE0 | r(&rng)
        case 5:  // data processing, register-shifted register
            return cond | rng.below(16) << 21 | rng.below(2) << 20 | r(&rng) << 16 | r(&rng) << 12 | r(&rng) << 8 | rng.below(4) << 5 | 1 << 4 | r(&rng)
        case 6:  // multiplies
            let long = rng.below(2)
            return cond | long << 23 | rng.below(4) << 20 | r(&rng) << 16 | r(&rng) << 12 | r(&rng) << 8 | 0x90 | r(&rng)
        case 7, 8:  // LDR/STR immediate, base near the data area
            return cond | 0x0400_0000 | rng.below(32) << 20 | rng.below(8) << 16 | r(&rng) << 12 | rng.below(0x1000)
        case 9:  // LDR/STR register offset
            return cond | 0x0600_0000 | rng.below(32) << 20 | rng.below(8) << 16 | r(&rng) << 12 | rng.below(0x100) << 4 & 0xFE0 | rng.below(8)
        case 10:  // halfword, signed and doubleword transfers
            let sh = [UInt32(1), 2, 3][Int(rng.below(3))]
            return cond | rng.below(32) << 20 | rng.below(8) << 16 | r(&rng) << 12 | rng.below(16) << 8 | 0x90 | sh << 5 | rng.below(16)
        case 11:  // LDM/STM, base near the data area, without the S bit
            return cond | 0x0800_0000 | rng.below(4) << 23 | rng.below(4) << 20 | rng.below(8) << 16 | rng.below(0x1_0000) & 0x7FFF | 1
        case 12:  // extend and reverse
            let forms: [UInt32] = [0x06AF_0070, 0x06BF_0070, 0x06EF_0070, 0x06FF_0070, 0x06A0_0070, 0x06E0_0070,
                                   0x06BF_0F30, 0x06BF_0FB0, 0x06FF_0FB0]
            let base = forms[Int(rng.below(UInt32(forms.count)))]
            let rn: UInt32 = base & 0x000F_0000 == 0 ? r(&rng) << 16 : 0
            return cond | base | rn | rng.below(15) << 12 | (base & 0xF00 == 0 ? rng.below(4) << 10 : 0) | rng.below(15)
        default:  // short forward branches, and BX to ARM code
            if rng.below(2) == 0 { return cond | 0x0A00_0000 | rng.below(2) << 24 | rng.below(4) }
            return cond | 0x012F_FF10 | rng.below(15)
        }
    }

    /// Two CPUs with the same random program, registers and memory.
    static func setup(_ model: ARM<PagedBus>.Model, _ rng: inout SplitMix, round: Int, count: Int)
        -> (ARM<PagedBus>, PagedBus, ARM<PagedBus>, PagedBus) {
        let reference = PagedBus()
        // Code at 0x1000, data around 0x8000-0x20000.
        for i in 0..<count { reference.write32(0x1000 + UInt32(i * 4), instruction(&rng)) }
        for i in 0..<0x6000 { reference.write32(0x8000 + UInt32(i * 4), rng.next()) }
        let fast = PagedBus(copying: reference)
        let a = ARM(model: model, bus: reference)
        let b = ARM(model: model, bus: fast)
        for cpu in [a, b] {
            cpu.directBoot(entry: 0x1000, stackSVC: 0xF_0000, stackIRQ: 0xE_0000, stackSYS: 0xF_0000)
        }
        var seed = SplitMix(state: UInt64(round))
        for i in 0..<15 {
            // Low registers point into the data area; the rest are random.
            let v = i < 8 ? 0x8000 + seed.below(0x10000) : seed.next()
            a.setReg(i, v)
            b.setReg(i, v)
        }
        a.rawCPSR = (a.rawCPSR & 0x0FFF_FFFF) | rng.below(16) << 28
        b.rawCPSR = a.rawCPSR
        return (a, reference, b, fast)
    }

    static func pageTable(_ bus: PagedBus) -> [UnsafeMutablePointer<UInt8>?] {
        var pages = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 1 << 20)
        for p in 0..<(PagedBus.size >> 12) { pages[p] = (bus.memory + p * 4096).assumingMemoryBound(to: UInt8.self) }
        return pages
    }

    static func inCode(_ cpu: ARM<PagedBus>, count: Int) -> Bool {
        cpu.rawCPSR & 0x20 == 0 && cpu.pc >= 0x1000 && cpu.pc < 0x1000 + UInt32(count * 4)
    }

    static func arch(_ model: ARM<PagedBus>.Model) -> UInt32 {
        switch model { case .arm7tdmi: 4; case .arm946es: 5; case .arm11mpcore: 6 }
    }

    @Test(arguments: [ARM<PagedBus>.Model.arm7tdmi, .arm946es, .arm11mpcore])
    func matchesSwiftInterpreter(_ model: ARM<PagedBus>.Model) {
        var rng = SplitMix(state: 0xC1A5_5E11)
        let count = 64
        for round in 0..<300 {
            let (a, reference, b, fast) = Self.setup(model, &rng, round: round, count: count)
            let pages = Self.pageTable(fast)
            for step in 0..<count {
                if !Self.inCode(a, count: count) { break }
                let pc = a.pc
                a.step()
                pages.withUnsafeBufferPointer { table in
                    var state = CARMState(regs: b.registerStorage, pages: table.baseAddress!, code_pages: table.baseAddress!, cycles: 0, target: 1,
                                            retired: 0, cpsr: b.rawCPSR, arch: Self.arch(model))
                    let exit = carm_run(&state)
                    b.rawCPSR = state.cpsr
                    if exit == CARMExitSlow { b.step() }
                }
                let op = reference.read32(pc)
                for i in 0..<16 where a.reg(i) != b.reg(i) {
                    Issue.record("\(model) round \(round) step \(step) pc \(String(pc, radix: 16)) op \(String(op, radix: 16)): r\(i) swift \(String(a.reg(i), radix: 16)) c \(String(b.reg(i), radix: 16))")
                    return
                }
                if memcmp(reference.memory, fast.memory, PagedBus.size) != 0 {
                    var at = 0
                    while reference.memory.load(fromByteOffset: at, as: UInt8.self) == fast.memory.load(fromByteOffset: at, as: UInt8.self) { at += 1 }
                    Issue.record("\(model) round \(round) step \(step) pc \(String(pc, radix: 16)) op \(String(op, radix: 16)): memory at \(String(at, radix: 16))")
                    return
                }
                if a.rawCPSR != b.rawCPSR {
                    Issue.record("\(model) round \(round) step \(step) pc \(String(pc, radix: 16)) op \(String(op, radix: 16)): cpsr swift \(String(a.rawCPSR, radix: 16)) c \(String(b.rawCPSR, radix: 16))")
                    return
                }
            }
        }
    }

    /// Whole runs, so the C path's own dispatch between instructions and its stop at the
    /// cycle target are covered too.
    @Test(arguments: [ARM<PagedBus>.Model.arm7tdmi, .arm946es, .arm11mpcore])
    func runsToTheSameState(_ model: ARM<PagedBus>.Model) {
        var rng = SplitMix(state: 0x5EED_0F_C0DE)
        let count = 64
        for round in 0..<300 {
            let (a, reference, b, fast) = Self.setup(model, &rng, round: round, count: count)
            let pages = Self.pageTable(fast)
            var steps: UInt64 = 0
            while steps < UInt64(count) && Self.inCode(a, count: count) { a.step(); steps += 1 }
            pages.withUnsafeBufferPointer { table in
                var state = CARMState(regs: b.registerStorage, pages: table.baseAddress!, code_pages: table.baseAddress!, cycles: 0, target: steps,
                                        retired: 0, cpsr: b.rawCPSR, arch: Self.arch(model))
                while state.cycles < steps {
                    if state.cycles > 0 && !Self.inCode(b, count: count) { break }
                    let exit = carm_run(&state)
                    b.rawCPSR = state.cpsr
                    if exit == CARMExitSlow { b.step(); state.cycles += 1 }
                    if exit == CARMExitThumb { break }
                    state.cpsr = b.rawCPSR
                }
            }
            for i in 0..<16 where a.reg(i) != b.reg(i) {
                Issue.record("\(model) round \(round) after \(steps): r\(i) swift \(String(a.reg(i), radix: 16)) c \(String(b.reg(i), radix: 16))")
                return
            }
            #expect(a.rawCPSR == b.rawCPSR, "round \(round)")
            #expect(memcmp(reference.memory, fast.memory, PagedBus.size) == 0, "round \(round)")
        }
    }
}
