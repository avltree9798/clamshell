// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import ARMCore

/// 1 MB of flat little-endian RAM at address 0 for ARM11 programs.
final class BigBus: ARMBus {
    let memory = UnsafeMutableRawPointer.allocate(byteCount: 0x10_0000, alignment: 16)
    var swis: [UInt32] = []

    init() { memory.initializeMemory(as: UInt8.self, repeating: 0, count: 0x10_0000) }
    deinit { memory.deallocate() }

    func read8(_ a: UInt32) -> UInt8 { memory.load(fromByteOffset: Int(a & 0xF_FFFF), as: UInt8.self) }
    func read16(_ a: UInt32) -> UInt16 { memory.loadUnaligned(fromByteOffset: Int(a & 0xF_FFFF), as: UInt16.self) }
    func read32(_ a: UInt32) -> UInt32 { memory.loadUnaligned(fromByteOffset: Int(a & 0xF_FFFF), as: UInt32.self) }
    func write8(_ a: UInt32, _ v: UInt8) { memory.storeBytes(of: v, toByteOffset: Int(a & 0xF_FFFF), as: UInt8.self) }
    func write16(_ a: UInt32, _ v: UInt16) { memory.storeBytes(of: v, toByteOffset: Int(a & 0xF_FFFF), as: UInt16.self) }
    func write32(_ a: UInt32, _ v: UInt32) { memory.storeBytes(of: v, toByteOffset: Int(a & 0xF_FFFF), as: UInt32.self) }
    func fetch16(_ a: UInt32) -> UInt16 { read16(a) }
    func fetch32(_ a: UInt32) -> UInt32 { read32(a) }
    func hleSWI(_ number: UInt32, cpu: ARMRegisterFile) -> Bool { swis.append(number); return true }
    func cp15Read(cn: Int, cm: Int, cp: Int) -> UInt32 { 0 }
    func cp15Write(cn: Int, cm: Int, cp: Int, value: UInt32, cpu: ARMRegisterFile) {}
    var irqHandlerPointer: UInt32 { 0 }
    var irqCheckFlagsAddress: UInt32 { 0 }
}

/// Runs ARM11 code at 0x100 for `code.count` instructions (or until an SVC).
func runARM11(_ code: [UInt32], setup: (ARM<BigBus>) -> Void = { _ in }) -> ARM<BigBus> {
    let bus = BigBus()
    for (i, w) in code.enumerated() { bus.write32(0x100 + UInt32(i * 4), w) }
    let cpu = ARM(model: .arm11mpcore, bus: bus)
    cpu.directBoot(entry: 0x100, stackSVC: 0x8000, stackIRQ: 0x7000, stackSYS: 0x6000)
    setup(cpu)
    for _ in 0..<code.count where bus.swis.isEmpty { cpu.step() }
    return cpu
}

@Suite struct ARM11SelfTest {
    /// A C program compiled for ARMv6K + VFPv2 by clang, checked against the same
    /// program compiled for the host. See Tools/arm11-selftest/selftest.c.
    @Test func compiledProgramMatchesHost() {
        let bus = BigBus()
        for (i, b) in SelfTestImage.bytes.enumerated() { bus.write8(SelfTestImage.loadAddress + UInt32(i), b) }
        let cpu = ARM(model: .arm11mpcore, bus: bus)
        cpu.directBoot(entry: SelfTestImage.entry, stackSVC: 0xF_0000, stackIRQ: 0xE_0000, stackSYS: 0xF_0000)
        var steps = 0
        while bus.swis.isEmpty && steps < 1_000_000 {
            cpu.step()
            steps += 1
        }
        #expect(bus.swis == [0], "program did not finish (pc = \(String(cpu.pc, radix: 16)))")
        #expect(cpu.reg(0) == UInt32(SelfTestImage.expected.count))
        for (i, expected) in SelfTestImage.expected.enumerated() {
            let actual = bus.read32(SelfTestImage.resultsAddress + UInt32(i * 4))
            #expect(actual == expected, "result \(i): got 0x\(String(actual, radix: 16)), want 0x\(String(expected, radix: 16))")
        }
    }
}

@Suite struct ARMv6Media {
    // Encodings from llvm-mc -triple=armv6k.
    @Test func uadd8SetsGEOnCarry() {
        // uadd8 r0, r1, r2
        let cpu = runARM11([0xE651_0F92]) { $0.setReg(1, 0xFF01_0203); $0.setReg(2, 0x0101_0101) }
        #expect(cpu.reg(0) == 0x0002_0304)
        #expect((cpu.statusRegister >> 16) & 0xF == 0b1000)
    }

    @Test func selPicksBytesByGE() {
        // uadd8 r0, r1, r2; sel r3, r4, r5
        let cpu = runARM11([0xE651_0F92, 0xE684_3FB5]) {
            $0.setReg(1, 0xFF01_FF01); $0.setReg(2, 0x0101_0101)
            $0.setReg(4, 0xAAAA_AAAA); $0.setReg(5, 0x5555_5555)
        }
        #expect(cpu.reg(3) == 0xAA55_AA55)
    }

    @Test func qadd16Saturates() {
        // qadd16 r0, r1, r2
        let cpu = runARM11([0xE621_0F12]) { $0.setReg(1, 0x7FFF_8000); $0.setReg(2, 0x0001_FFFF) }
        #expect(cpu.reg(0) == 0x7FFF_8000)
    }

    @Test func shadd8Halves() {
        // shadd8 r0, r1, r2
        let cpu = runARM11([0xE631_0F92]) { $0.setReg(1, 0x0480_FF10); $0.setReg(2, 0x0280_FF10) }
        #expect(cpu.reg(0) == 0x0380_FF10)
    }

    @Test func usatAndSsat() {
        // usat r0, #8, r1; ssat r2, #8, r1; ssat r3, #16, r4, asr #4
        let cpu = runARM11([0xE6E8_0011, 0xE6A7_2011, 0xE6AF_3254]) { $0.setReg(1, 300); $0.setReg(4, 0x0001_0000) }
        #expect(cpu.reg(0) == 255)
        #expect(cpu.reg(2) == 127)
        #expect(cpu.reg(3) == 0x1000)
        #expect(cpu.statusRegister & (1 << 27) != 0)
    }

    @Test func pkhbtAndPkhtb() {
        // pkhbt r0, r1, r2, lsl #16; pkhtb r3, r1, r2, asr #16
        let cpu = runARM11([0xE681_0812, 0xE681_3852]) { $0.setReg(1, 0x1111_2222); $0.setReg(2, 0x3333_4444) }
        #expect(cpu.reg(0) == 0x4444_2222)
        #expect(cpu.reg(3) == 0x1111_3333)
    }

    @Test func extendWithRotateAndAdd() {
        // sxtab r0, r1, r2, ror #8; uxtb16 r3, r2
        let cpu = runARM11([0xE6A1_0472, 0xE6CF_3072]) { $0.setReg(1, 10); $0.setReg(2, 0x1122_F344) }
        #expect(cpu.reg(0) == 10 &- 13)
        #expect(cpu.reg(3) == 0x0022_0044)
    }

    @Test func reverses() {
        // rev16 r0, r1; revsh r2, r1
        let cpu = runARM11([0xE6BF_0FB1, 0xE6FF_2FB1]) { $0.setReg(1, 0x1122_80FF) }
        #expect(cpu.reg(0) == 0x2211_FF80)
        #expect(cpu.reg(2) == 0xFFFF_FF80)
    }

    @Test func dualMultiplies() {
        // smuad r0, r1, r2; smlsd r3, r1, r2, r4; smmul r5, r1, r2
        let cpu = runARM11([0xE700_F211, 0xE703_4251, 0xE755_F211]) {
            $0.setReg(1, 0x0003_0002); $0.setReg(2, 0x0005_0004); $0.setReg(4, 100)
        }
        #expect(cpu.reg(0) == 3 * 5 + 2 * 4)
        #expect(cpu.reg(3) == 100 + 2 * 4 - 3 * 5)
        #expect(cpu.reg(5) == UInt32((Int64(0x0003_0002) * 0x0005_0004) >> 32))
    }

    @Test func umaal() {
        // umaal r0, r1, r2, r3
        let cpu = runARM11([0xE041_0392]) {
            $0.setReg(0, 0xFFFF_FFFF); $0.setReg(1, 0xFFFF_FFFF)
            $0.setReg(2, 0xFFFF_FFFF); $0.setReg(3, 0xFFFF_FFFF)
        }
        #expect(cpu.reg(0) == 0xFFFF_FFFF)
        #expect(cpu.reg(1) == 0xFFFF_FFFF)
    }

    @Test func strexFailsWithoutReservation() {
        // strex r0, r1, [r2]; ldrex r3, [r2]; strex r0, r1, [r2]
        let cpu = runARM11([0xE182_0F91, 0xE192_3F9F, 0xE182_4F91]) { $0.setReg(1, 77); $0.setReg(2, 0x2000) }
        #expect(cpu.reg(0) == 1)
        #expect(cpu.reg(4) == 0)
        #expect(cpu.bus.read32(0x2000) == 77)
    }

    @Test func svcNumberIsLowByte() {
        let cpu = runARM11([0xEF00_0032])  // svc #0x32
        #expect(cpu.bus.swis == [0x32])
    }

    @Test func vfpCompareSetsFlagsViaVMRS() {
        // vcmp.f32 s0, s1; vmrs APSR_nzcv, fpscr
        let cpu = runARM11([0xEEB4_0A60, 0xEEF1_FA10]) { cpu in
            cpu.vfp[0] = Float(1.0).bitPattern
            cpu.vfp[1] = Float(2.0).bitPattern
        }
        #expect(cpu.statusRegister >> 28 == 0x8)
    }

    @Test func roundTowardsZero() {
        // vadd.f32 s0, s1, s2 with FPSCR.RMode = towards zero
        let cpu = runARM11([0xEE30_0A81]) { cpu in
            cpu.fpscr = 3 << 22
            cpu.vfp[1] = Float(1.0).bitPattern
            cpu.vfp[2] = Float(1.0e-8).bitPattern
        }
        #expect(Float(bitPattern: cpu.vfp[0]) == 1.0)
        let up = runARM11([0xEE30_0A81]) { cpu in
            cpu.fpscr = 1 << 22
            cpu.vfp[1] = Float(1.0).bitPattern
            cpu.vfp[2] = Float(1.0e-8).bitPattern
        }
        #expect(Float(bitPattern: up.vfp[0]) == Float(1.0).nextUp)
    }
}
