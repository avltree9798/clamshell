// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import ARMCore

/// 64 KB of flat RAM at address 0, enough to run instruction sequences.
final class FlatBus: ARMBus {
    var memory = [UInt8](repeating: 0, count: 0x10000)
    var swis: [UInt32] = []

    func read8(_ a: UInt32) -> UInt8 { memory[Int(a & 0xFFFF)] }
    func read16(_ a: UInt32) -> UInt16 { UInt16(read8(a)) | UInt16(read8(a + 1)) << 8 }
    func read32(_ a: UInt32) -> UInt32 { UInt32(read16(a)) | UInt32(read16(a + 2)) << 16 }
    func write8(_ a: UInt32, _ v: UInt8) { memory[Int(a & 0xFFFF)] = v }
    func write16(_ a: UInt32, _ v: UInt16) { write8(a, UInt8(v & 0xFF)); write8(a + 1, UInt8(v >> 8)) }
    func write32(_ a: UInt32, _ v: UInt32) { write16(a, UInt16(v & 0xFFFF)); write16(a + 2, UInt16(v >> 16)) }
    func fetch16(_ a: UInt32) -> UInt16 { read16(a) }
    func fetch32(_ a: UInt32) -> UInt32 { read32(a) }
    func hleSWI(_ number: UInt32, cpu: ARMRegisterFile) -> Bool { swis.append(number); return true }
    func cp15Read(cn: Int, cm: Int, cp: Int) -> UInt32 { 0 }
    func cp15Write(cn: Int, cm: Int, cp: Int, value: UInt32, cpu: ARMRegisterFile) {}
    var irqHandlerPointer: UInt32 { 0xFFFC }
    var irqCheckFlagsAddress: UInt32 { 0xFFF8 }
}

/// Loads `code` at 0x100 and runs `steps` instructions.
func run(_ code: [UInt32], steps: Int? = nil, model: ARM<FlatBus>.Model = .arm946es,
         setup: (ARM<FlatBus>) -> Void = { _ in }) -> ARM<FlatBus> {
    let bus = FlatBus()
    for (i, w) in code.enumerated() { bus.write32(0x100 + UInt32(i * 4), w) }
    let cpu = ARM(model: model, bus: bus)
    cpu.directBoot(entry: 0x100, stackSVC: 0x8000, stackIRQ: 0x7000, stackSYS: 0x6000)
    setup(cpu)
    for _ in 0..<(steps ?? code.count) { cpu.step() }
    return cpu
}

func runThumb(_ code: [UInt16], steps: Int? = nil) -> ARM<FlatBus> {
    let bus = FlatBus()
    // ARM stub at 0x100: add r0, pc, #1; bx r0  -> Thumb code at 0x108.
    bus.write32(0x100, 0xE28F_0001)
    bus.write32(0x104, 0xE12F_FF10)
    for (i, h) in code.enumerated() { bus.write16(0x108 + UInt32(i * 2), h) }
    let cpu = ARM(model: .arm946es, bus: bus)
    cpu.directBoot(entry: 0x100, stackSVC: 0x8000, stackIRQ: 0x7000, stackSYS: 0x6000)
    for _ in 0..<(2 + (steps ?? code.count)) { cpu.step() }
    return cpu
}

let flagN: UInt32 = 1 << 31, flagZ: UInt32 = 1 << 30, flagC: UInt32 = 1 << 29, flagV: UInt32 = 1 << 28

@Suite struct ARMDataProcessing {
    @Test func movAndAdd() {
        let cpu = run([0xE3A0_0005, 0xE3A0_1007, 0xE080_2001])  // mov r0,#5; mov r1,#7; add r2,r0,r1
        #expect(cpu.reg(2) == 12)
    }

    @Test func subsSetsZeroAndCarry() {
        let cpu = run([0xE3A0_0003, 0xE250_0003])  // mov r0,#3; subs r0,r0,#3
        #expect(cpu.reg(0) == 0)
        #expect(cpu.statusRegister & flagZ != 0)
        #expect(cpu.statusRegister & flagC != 0)  // no borrow
    }

    @Test func addsOverflow() {
        // mvn r0,#0x80000000 (r0 = 0x7FFFFFFF); adds r0,r0,#1
        let cpu = run([0xE3E0_0102, 0xE290_0001])
        #expect(cpu.reg(0) == 0x8000_0000)
        #expect(cpu.statusRegister & flagV != 0)
        #expect(cpu.statusRegister & flagN != 0)
    }

    @Test func immediateRotation() {
        let cpu = run([0xE3A0_04FF])  // mov r0, #0xFF000000
        #expect(cpu.reg(0) == 0xFF00_0000)
    }

    @Test func registerShiftByRegister() {
        // mov r0,#1; mov r1,#4; mov r2, r0, lsl r1
        let cpu = run([0xE3A0_0001, 0xE3A0_1004, 0xE1A0_2110])
        #expect(cpu.reg(2) == 16)
    }

    @Test func conditionalExecutionSkips() {
        // mov r0,#1; cmp r0,#2; moveq r0,#9
        let cpu = run([0xE3A0_0001, 0xE350_0002, 0x03A0_0009])
        #expect(cpu.reg(0) == 1)
    }

    @Test func countLeadingZeros() {
        let cpu = run([0xE3A0_0801, 0xE16F_1F10])  // mov r0,#0x10000; clz r1,r0
        #expect(cpu.reg(1) == 15)
    }

    @Test func saturatingAddSetsQ() {
        // mvn r0,#0x80000000; mov r1,#1; qadd r2,r0,r1
        let cpu = run([0xE3E0_0102, 0xE3A0_1001, 0xE101_2050])
        #expect(cpu.reg(2) == 0x7FFF_FFFF)
        #expect(cpu.statusRegister & (1 << 27) != 0)
    }
}

@Suite struct ARMMultiply {
    @Test func mla() {
        // mov r0,#3; mov r1,#4; mov r2,#5; mla r3,r0,r1,r2
        let cpu = run([0xE3A0_0003, 0xE3A0_1004, 0xE3A0_2005, 0xE023_2190])
        #expect(cpu.reg(3) == 17)
    }

    @Test func smullNegative() {
        // mvn r0,#0 (-1); mov r1,#2; smull r2,r3,r0,r1  -> -2
        let cpu = run([0xE3E0_0000, 0xE3A0_1002, 0xE0C3_2190])
        #expect(cpu.reg(2) == 0xFFFF_FFFE)
        #expect(cpu.reg(3) == 0xFFFF_FFFF)
    }

    @Test func smulbt() {
        // mov r0,#3; mov r1,#0x50000 (top half 5); smulbt r2,r0,r1
        let cpu = run([0xE3A0_0003, 0xE3A0_1805, 0xE162_01C0])
        #expect(cpu.reg(2) == 15)
    }
}

@Suite struct ARMMemory {
    @Test func storeAndLoadWithWriteback() {
        // mov r0,#0x1000; mov r1,#42; str r1,[r0],#4; ldr r2,[r0,#-4]
        let cpu = run([0xE3A0_0A01, 0xE3A0_102A, 0xE480_1004, 0xE510_2004])
        #expect(cpu.reg(0) == 0x1004)
        #expect(cpu.reg(2) == 42)
    }

    @Test func unalignedLoadRotates() {
        // mov r0,#0x1000; ldr r1,=0x44332211 via mov/orr; str r1,[r0]; ldr r2,[r0,#1]
        let cpu = run([0xE3A0_0A01, 0xE3A0_1011, 0xE381_1C22, 0xE381_1833, 0xE381_1311, 0xE580_1000, 0xE590_2001],
                      setup: { _ in })
        // r1 = 0x11 | 0x2200 | 0x330000 | 0x44000000 = 0x44332211
        #expect(cpu.reg(1) == 0x4433_2211)
        #expect(cpu.reg(2) == 0x1144_3322)
    }

    @Test func halfwordSignedLoad() {
        // mov r0,#0x1000; mvn r1,#0; strh r1,[r0]; ldrsh r2,[r0]; ldrh r3,[r0]
        let cpu = run([0xE3A0_0A01, 0xE3E0_1000, 0xE1C0_10B0, 0xE1D0_20F0, 0xE1D0_30B0])
        #expect(cpu.reg(2) == 0xFFFF_FFFF)
        #expect(cpu.reg(3) == 0xFFFF)
    }

    @Test func pushAndPop() {
        // mov r0,#1; mov r1,#2; stmfd sp!,{r0,r1}; mov r0,#0; mov r1,#0; ldmfd sp!,{r0,r1}
        let cpu = run([0xE3A0_0001, 0xE3A0_1002, 0xE92D_0003, 0xE3A0_0000, 0xE3A0_1000, 0xE8BD_0003])
        #expect(cpu.reg(0) == 1)
        #expect(cpu.reg(1) == 2)
        #expect(cpu.reg(13) == 0x6000)
    }
}

@Suite struct ARMBranches {
    @Test func branchAndLink() {
        // bl +8 (to 0x10C); mov r0,#1; mov r0,#2 (skipped); mov r1,#3
        let cpu = run([0xEB00_0001, 0xE3A0_0001, 0xE3A0_0002, 0xE3A0_1003], steps: 2)
        #expect(cpu.reg(14) == 0x104)
        #expect(cpu.reg(1) == 3)
        #expect(cpu.reg(0) == 0)
    }

    @Test func bxToThumb() {
        let cpu = runThumb([0x2007], steps: 1)  // movs r0,#7
        #expect(cpu.thumb)
        #expect(cpu.reg(0) == 7)
    }

    @Test func swiIsHandledByHLE() {
        let bus = FlatBus()
        bus.write32(0x100, 0xEF06_0000)  // swi 0x06 (NDS ARM-mode SWI number is in bits 16-23)
        let cpu = ARM(model: .arm946es, bus: bus)
        cpu.directBoot(entry: 0x100, stackSVC: 0x8000, stackIRQ: 0x7000, stackSYS: 0x6000)
        cpu.step()
        #expect(bus.swis == [6])
        #expect(cpu.pc == 0x104)
    }
}

@Suite struct ThumbInstructions {
    @Test func aluAndShifts() {
        // movs r0,#3; lsls r1,r0,#2; adds r2,r1,r0; subs r3,r2,#1
        let cpu = runThumb([0x2003, 0x0081, 0x180A, 0x1E53])
        #expect(cpu.reg(1) == 12)
        #expect(cpu.reg(2) == 15)
        #expect(cpu.reg(3) == 14)
    }

    @Test func pushPopRoundTrip() {
        // movs r0,#5; push {r0}; movs r0,#0; pop {r1}
        let cpu = runThumb([0x2005, 0xB401, 0x2000, 0xBC02])
        #expect(cpu.reg(1) == 5)
        #expect(cpu.reg(13) == 0x6000)
    }

    @Test func longBranchWithLink() {
        // bl +4 (two halves), movs r0,#1 (skipped), movs r0,#2 (skipped), movs r1,#9
        let cpu = runThumb([0xF000, 0xF802, 0x2001, 0x2002, 0x2109], steps: 3)
        #expect(cpu.reg(1) == 9)
        #expect(cpu.reg(14) == 0x10D)  // return address 0x10C, Thumb bit set
    }
}
