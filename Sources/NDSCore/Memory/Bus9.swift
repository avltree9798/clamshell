// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit

/// The ARM9's view of memory, including its tightly coupled memories and CP15.
final class Bus9: ARMBus {
    unowned let s: NDS

    var postflg: UInt32 = 0
    var exmemcnt: UInt32 = 0
    var dmaFill = [UInt32](repeating: 0, count: 4)

    // CP15 state
    var cp15Control: UInt32 = 0x0001_2078
    var dtcmRegister: UInt32 = 0x0080_000A
    var itcmRegister: UInt32 = 0x0000_0020
    private(set) var dtcmBase: UInt32 = 0x0080_0000
    /// Bytes of address space each TCM answers for; 0 when disabled.
    private(set) var dtcmLimit: UInt32 = 0
    private(set) var itcmLimit: UInt32 = 0

    init(system: NDS) { s = system }

    // MARK: - CP15

    func resetCP15() {
        cp15Control = 0x0001_2078
        dtcmRegister = 0x0080_000A
        itcmRegister = 0x0000_0020
        updateTCM()
    }

    /// What the BIOS leaves configured before jumping to a game.
    func writeCP15DefaultsAfterBoot() {
        dtcmRegister = 0x0080_000A   // DTCM at 0x00800000, 16 KB
        itcmRegister = 0x0000_0020   // ITCM at 0, 32 MB virtual
        cp15Control = 0x0005_2078    // DTCM and ITCM enabled, high vectors
        updateTCM()
    }

    private func updateTCM() {
        dtcmBase = dtcmRegister & 0xFFFF_F000
        let dtcmSize = UInt32(512) << ((dtcmRegister >> 1) & 0x1F)
        let itcmSize = UInt32(512) << ((itcmRegister >> 1) & 0x1F)
        dtcmLimit = cp15Control & (1 << 16) != 0 ? dtcmSize : 0
        itcmLimit = cp15Control & (1 << 18) != 0 ? itcmSize : 0
        s.arm9?.exceptionBase = cp15Control & (1 << 13) != 0 ? 0xFFFF_0000 : 0
    }

    func cp15Read(cn: Int, cm: Int, cp: Int) -> UInt32 {
        switch (cn, cm, cp) {
        case (0, 0, 0): return 0x4105_9461  // ARM946E-S ID
        case (0, 0, 1): return 0x0F0D_2112  // cache type
        case (1, 0, 0): return cp15Control
        case (9, 1, 0): return dtcmRegister
        case (9, 1, 1): return itcmRegister
        default: return 0
        }
    }

    func cp15Write(cn: Int, cm: Int, cp: Int, value: UInt32, cpu: ARMRegisterFile) {
        switch (cn, cm, cp) {
        case (1, 0, 0):
            cp15Control = (value & 0x000F_F085) | 0x0000_0078
            updateTCM()
        case (7, 0, 4), (7, 8, 2):
            cpu.halt()  // wait for interrupt
        case (9, 1, 0):
            dtcmRegister = value
            updateTCM()
        case (9, 1, 1):
            itcmRegister = value
            updateTCM()
        default:
            break  // caches and protection unit: no effect on emulation
        }
    }

    var irqHandlerPointer: UInt32 { dtcmBase &+ 0x3FFC }
    var irqCheckFlagsAddress: UInt32 { dtcmBase &+ 0x3FF8 }

    func hleSWI(_ number: UInt32, cpu: ARMRegisterFile) -> Bool {
        HLEBIOS.call(number, cpu: cpu, bus: self, isARM9: true)
    }

    // MARK: - Shared WRAM as the ARM9 sees it (WRAMCNT)

    @inline(__always) private func wramOffset(_ a: UInt32) -> UInt32? {
        switch s.wramcnt & 3 {
        case 0: return a & 0x7FFF
        case 1: return 0x4000 | (a & 0x3FFF)
        case 2: return a & 0x3FFF
        default: return nil
        }
    }

    // MARK: - Reads

    @inline(__always) func read32(_ a: UInt32) -> UInt32 {
        if a < itcmLimit { return s.itcm.read32(a) }
        if a &- dtcmBase < dtcmLimit { return s.dtcm.read32(a &- dtcmBase) }
        switch a >> 24 {
        case 0x02: return s.mainRAM.read32(a)
        case 0x03: return wramOffset(a).map { s.sharedWRAM.read32($0) } ?? 0
        case 0x04: return ioRead(a & ~3)
        case 0x05: return s.palette.read32(a)
        case 0x06: return isLCDC(a) ? s.vram.read32(a &- 0x0680_0000) : 0
        case 0x07: return s.oam.read32(a)
        case 0x08, 0x09, 0x0A: return 0xFFFF_FFFF  // empty GBA slot
        default: return 0
        }
    }

    @inline(__always) func read16(_ a: UInt32) -> UInt16 {
        if a < itcmLimit { return s.itcm.read16(a) }
        if a &- dtcmBase < dtcmLimit { return s.dtcm.read16(a &- dtcmBase) }
        switch a >> 24 {
        case 0x02: return s.mainRAM.read16(a)
        case 0x03: return wramOffset(a).map { s.sharedWRAM.read16($0) } ?? 0
        case 0x04: return UInt16(truncatingIfNeeded: ioRead(a & ~3) >> ((a & 2) * 8))
        case 0x05: return s.palette.read16(a)
        case 0x06: return isLCDC(a) ? s.vram.read16(a &- 0x0680_0000) : 0
        case 0x07: return s.oam.read16(a)
        case 0x08, 0x09, 0x0A: return 0xFFFF
        default: return 0
        }
    }

    @inline(__always) func read8(_ a: UInt32) -> UInt8 {
        if a < itcmLimit { return s.itcm.read8(a) }
        if a &- dtcmBase < dtcmLimit { return s.dtcm.read8(a &- dtcmBase) }
        switch a >> 24 {
        case 0x02: return s.mainRAM.read8(a)
        case 0x03: return wramOffset(a).map { s.sharedWRAM.read8($0) } ?? 0
        case 0x04: return UInt8(truncatingIfNeeded: ioRead(a & ~3) >> ((a & 3) * 8))
        case 0x05: return s.palette.read8(a)
        case 0x06: return isLCDC(a) ? s.vram.read8(a &- 0x0680_0000) : 0
        case 0x07: return s.oam.read8(a)
        case 0x08, 0x09, 0x0A: return 0xFF
        default: return 0
        }
    }

    @inline(__always) func fetch32(_ a: UInt32) -> UInt32 { read32(a) }
    @inline(__always) func fetch16(_ a: UInt32) -> UInt16 { read16(a) }

    /// The LCDC window onto all VRAM banks, 0x06800000-0x068A3FFF.
    @inline(__always) private func isLCDC(_ a: UInt32) -> Bool { a >= 0x0680_0000 && a < 0x068A_4000 }

    // MARK: - Writes

    @inline(__always) func write32(_ a: UInt32, _ v: UInt32) {
        if a < itcmLimit { s.itcm.write32(a, v); return }
        if a &- dtcmBase < dtcmLimit { s.dtcm.write32(a &- dtcmBase, v); return }
        switch a >> 24 {
        case 0x02: s.mainRAM.write32(a, v)
        case 0x03: if let o = wramOffset(a) { s.sharedWRAM.write32(o, v) }
        case 0x04: ioWrite(a & ~3, v, mask: 0xFFFF_FFFF)
        case 0x05: s.palette.write32(a, v)
        case 0x06: if isLCDC(a) { s.vram.write32(a &- 0x0680_0000, v) }
        case 0x07: s.oam.write32(a, v)
        default: break
        }
    }

    @inline(__always) func write16(_ a: UInt32, _ v: UInt16) {
        if a < itcmLimit { s.itcm.write16(a, v); return }
        if a &- dtcmBase < dtcmLimit { s.dtcm.write16(a &- dtcmBase, v); return }
        switch a >> 24 {
        case 0x02: s.mainRAM.write16(a, v)
        case 0x03: if let o = wramOffset(a) { s.sharedWRAM.write16(o, v) }
        case 0x04:
            let shift = (a & 2) * 8
            ioWrite(a & ~3, UInt32(v) << shift, mask: 0xFFFF << shift)
        case 0x05: s.palette.write16(a, v)
        case 0x06: if isLCDC(a) { s.vram.write16(a &- 0x0680_0000, v) }
        case 0x07: s.oam.write16(a, v)
        default: break
        }
    }

    @inline(__always) func write8(_ a: UInt32, _ v: UInt8) {
        if a < itcmLimit { s.itcm.write8(a, v); return }
        if a &- dtcmBase < dtcmLimit { s.dtcm.write8(a &- dtcmBase, v); return }
        switch a >> 24 {
        case 0x02: s.mainRAM.write8(a, v)
        case 0x03: if let o = wramOffset(a) { s.sharedWRAM.write8(o, v) }
        case 0x04:
            let shift = (a & 3) * 8
            ioWrite(a & ~3, UInt32(v) << shift, mask: 0xFF << shift)
        default: break  // the ARM9 ignores byte writes to palette, VRAM and OAM
        }
    }

    // MARK: - I/O registers

    func ioRead(_ a: UInt32) -> UInt32 {
        if let v = s.ioReadCommon(cpu: 0, a) { return v }
        switch a {
        case 0x0400_0000: return s.dispcntA
        case 0x0400_00E0...0x0400_00EC: return dmaFill[Int((a - 0x0400_00E0) / 4)]
        case 0x0400_0204: return exmemcnt
        case 0x0400_0240: return UInt32(s.vramcnt[0]) | UInt32(s.vramcnt[1]) << 8 | UInt32(s.vramcnt[2]) << 16 | UInt32(s.vramcnt[3]) << 24
        case 0x0400_0244: return UInt32(s.vramcnt[4]) | UInt32(s.vramcnt[5]) << 8 | UInt32(s.vramcnt[6]) << 16 | UInt32(s.wramcnt) << 24
        case 0x0400_0248: return UInt32(s.vramcnt[7]) | UInt32(s.vramcnt[8]) << 8
        case 0x0400_0280: return s.math.divControl
        case 0x0400_0290: return UInt32(truncatingIfNeeded: s.math.numerator)
        case 0x0400_0294: return UInt32(truncatingIfNeeded: s.math.numerator >> 32)
        case 0x0400_0298: return UInt32(truncatingIfNeeded: s.math.denominator)
        case 0x0400_029C: return UInt32(truncatingIfNeeded: s.math.denominator >> 32)
        case 0x0400_02A0: return UInt32(truncatingIfNeeded: s.math.quotient)
        case 0x0400_02A4: return UInt32(truncatingIfNeeded: s.math.quotient >> 32)
        case 0x0400_02A8: return UInt32(truncatingIfNeeded: s.math.remainder)
        case 0x0400_02AC: return UInt32(truncatingIfNeeded: s.math.remainder >> 32)
        case 0x0400_02B0: return s.math.sqrtControl
        case 0x0400_02B4: return s.math.sqrtResult
        case 0x0400_02B8: return UInt32(truncatingIfNeeded: s.math.sqrtParameter)
        case 0x0400_02BC: return UInt32(truncatingIfNeeded: s.math.sqrtParameter >> 32)
        case 0x0400_0300: return postflg
        case 0x0400_0304: return s.powcnt1
        case 0x0400_1000: return s.dispcntB
        default: return 0
        }
    }

    func ioWrite(_ a: UInt32, _ v: UInt32, mask: UInt32) {
        if s.ioWriteCommon(cpu: 0, a, v, mask: mask) { return }
        @inline(__always) func merge(_ old: UInt32) -> UInt32 { (old & ~mask) | (v & mask) }
        @inline(__always) func merge64(_ old: UInt64, high: Bool) -> UInt64 {
            let shift: UInt64 = high ? 32 : 0
            let part = UInt32(truncatingIfNeeded: old >> shift)
            return (old & ~(0xFFFF_FFFF << shift)) | UInt64(merge(part)) << shift
        }
        switch a {
        case 0x0400_0000: s.dispcntA = merge(s.dispcntA)
        case 0x0400_00E0...0x0400_00EC:
            let i = Int((a - 0x0400_00E0) / 4)
            dmaFill[i] = merge(dmaFill[i])
        case 0x0400_0204: exmemcnt = merge(exmemcnt)
        case 0x0400_0240...0x0400_0248:
            for byte in 0..<4 where mask & (0xFF << UInt32(byte * 8)) != 0 {
                let index = Int(a - 0x0400_0240) + byte
                let value = UInt8(truncatingIfNeeded: v >> UInt32(byte * 8))
                if index == 7 { s.wramcnt = value & 3 } else if index < 7 { s.vramcnt[index] = value } else if index < 10 { s.vramcnt[index - 1] = value }
            }
        case 0x0400_0280: s.math.divControl = merge(s.math.divControl) & 3; s.math.divide()
        case 0x0400_0290: s.math.numerator = merge64(s.math.numerator, high: false); s.math.divide()
        case 0x0400_0294: s.math.numerator = merge64(s.math.numerator, high: true); s.math.divide()
        case 0x0400_0298: s.math.denominator = merge64(s.math.denominator, high: false); s.math.divide()
        case 0x0400_029C: s.math.denominator = merge64(s.math.denominator, high: true); s.math.divide()
        case 0x0400_02B0: s.math.sqrtControl = merge(s.math.sqrtControl) & 1; s.math.squareRoot()
        case 0x0400_02B8: s.math.sqrtParameter = merge64(s.math.sqrtParameter, high: false); s.math.squareRoot()
        case 0x0400_02BC: s.math.sqrtParameter = merge64(s.math.sqrtParameter, high: true); s.math.squareRoot()
        case 0x0400_0300: postflg = merge(postflg) & 3
        case 0x0400_0304: s.powcnt1 = merge(s.powcnt1) & 0x820F
        case 0x0400_1000: s.dispcntB = merge(s.dispcntB)
        default: break
        }
    }
}
