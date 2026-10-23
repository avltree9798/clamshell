// SPDX-License-Identifier: GPL-3.0-or-later

import ARMCore
import EmuKit

/// The ARM7's view of memory: its own 64 KB WRAM, part of shared WRAM, and the
/// sound, SPI, RTC and wireless hardware.
final class Bus7: ARMBus {
    unowned(unsafe) let s: NDS

    var postflg: UInt32 = 0
    var powcnt2: UInt32 = 0
    var soundRegisters = [UInt32](repeating: 0, count: 0x120 / 4)

    /// RAM pages for the C fast path, rebuilt when WRAMCNT changes. The ARM7 fetches
    /// what it reads, so one table serves both.
    let pages = PageMap()

    init(system: NDS) {
        s = system
        rebuildPages()
    }

    /// Maps main RAM, shared WRAM and ARM7 WRAM as `wram(_:)` sees them.
    func rebuildPages() {
        pages.map(0x2000, count: 0x1000, s.mainRAM, in: pages.data)
        switch s.wramcnt & 3 {
        case 0: pages.map(0x3000, count: 0x800, s.arm7WRAM, in: pages.data)
        case 1: pages.map(0x3000, count: 0x800, s.sharedWRAM, size: 0x4000, in: pages.data)
        case 2: pages.map(0x3000, count: 0x800, s.sharedWRAM, offset: 0x4000, size: 0x4000, in: pages.data)
        default: pages.map(0x3000, count: 0x800, s.sharedWRAM, in: pages.data)
        }
        pages.map(0x3800, count: 0x800, s.arm7WRAM, in: pages.data)
    }

    var irqHandlerPointer: UInt32 { 0x0380_FFFC }
    var irqCheckFlagsAddress: UInt32 { 0x0380_FFF8 }

    func hleSWI(_ number: UInt32, cpu: ARMRegisterFile) -> Bool {
        // There is no BIOS behind the vector, so an unknown call is skipped and noted.
        if !HLEBIOS.call(number, cpu: cpu, bus: self, isARM9: false) { s.noteUnhandledSWI(cpu: 1, number) }
        return true
    }

    func cp15Read(cn: Int, cm: Int, cp: Int) -> UInt32 { 0 }
    func cp15Write(cn: Int, cm: Int, cp: Int, value: UInt32, cpu: ARMRegisterFile) {}

    /// 0x03000000-0x037FFFFF: shared WRAM per WRAMCNT; 0x03800000+: ARM7 WRAM.
    @inline(__always) private func wram(_ a: UInt32) -> (RAM, UInt32) {
        if a >= 0x0380_0000 { return (s.arm7WRAM, a) }
        switch s.wramcnt & 3 {
        case 0: return (s.arm7WRAM, a)  // no shared WRAM: mirrors ARM7 WRAM
        case 1: return (s.sharedWRAM, a & 0x3FFF)
        case 2: return (s.sharedWRAM, 0x4000 | (a & 0x3FFF))
        default: return (s.sharedWRAM, a & 0x7FFF)
        }
    }

    // MARK: - Reads

    @inline(__always) func read32(_ a: UInt32) -> UInt32 {
        switch a >> 24 {
        case 0x02: return s.mainRAM.read32(a)
        case 0x03: let (m, o) = wram(a); return m.read32(o)
        case 0x06: return s.vramOffset7(a).map { s.vram.read32(UInt32($0)) } ?? 0
        case 0x04: return ioRead(a & ~3)
        case 0x08, 0x09, 0x0A: return 0xFFFF_FFFF
        default: return 0
        }
    }

    @inline(__always) func read16(_ a: UInt32) -> UInt16 {
        switch a >> 24 {
        case 0x02: return s.mainRAM.read16(a)
        case 0x03: let (m, o) = wram(a); return m.read16(o)
        case 0x06: return s.vramOffset7(a).map { s.vram.read16(UInt32($0)) } ?? 0
        case 0x04: return UInt16(truncatingIfNeeded: ioRead(a & ~3) >> ((a & 2) * 8))
        case 0x08, 0x09, 0x0A: return 0xFFFF
        default: return 0
        }
    }

    @inline(__always) func read8(_ a: UInt32) -> UInt8 {
        switch a >> 24 {
        case 0x02: return s.mainRAM.read8(a)
        case 0x03: let (m, o) = wram(a); return m.read8(o)
        case 0x06: return s.vramOffset7(a).map { s.vram.read8(UInt32($0)) } ?? 0
        case 0x04: return UInt8(truncatingIfNeeded: ioRead(a & ~3) >> ((a & 3) * 8))
        case 0x08, 0x09, 0x0A: return 0xFF
        default: return 0
        }
    }

    @inline(__always) func fetch32(_ a: UInt32) -> UInt32 {
        if a >= 0x0380_0000 && a < 0x0400_0000 { return s.arm7WRAM.read32(a) }
        return read32(a)
    }
    @inline(__always) func fetch16(_ a: UInt32) -> UInt16 {
        if a >= 0x0380_0000 && a < 0x0400_0000 { return s.arm7WRAM.read16(a) }
        return read16(a)
    }

    // MARK: - Writes

    @inline(__always) func write32(_ a: UInt32, _ v: UInt32) {
        switch a >> 24 {
        case 0x02: s.mainRAM.write32(a, v)
        case 0x03: let (m, o) = wram(a); m.write32(o, v)
        case 0x06: if let o = s.vramOffset7(a) { s.vram.write32(UInt32(o), v) }
        case 0x04: ioWrite(a & ~3, v, mask: 0xFFFF_FFFF)
        default: break
        }
    }

    @inline(__always) func write16(_ a: UInt32, _ v: UInt16) {
        switch a >> 24 {
        case 0x02: s.mainRAM.write16(a, v)
        case 0x03: let (m, o) = wram(a); m.write16(o, v)
        case 0x06: if let o = s.vramOffset7(a) { s.vram.write16(UInt32(o), v) }
        case 0x04:
            let shift = (a & 2) * 8
            ioWrite(a & ~3, UInt32(v) << shift, mask: 0xFFFF << shift)
        default: break
        }
    }

    @inline(__always) func write8(_ a: UInt32, _ v: UInt8) {
        switch a >> 24 {
        case 0x02: s.mainRAM.write8(a, v)
        case 0x03: let (m, o) = wram(a); m.write8(o, v)
        case 0x04:
            let shift = (a & 3) * 8
            ioWrite(a & ~3, UInt32(v) << shift, mask: 0xFF << shift)
        default: break
        }
    }

    // MARK: - I/O registers

    func ioRead(_ a: UInt32) -> UInt32 {
        if let v = s.ioReadCommon(cpu: 1, a) { return v }
        switch a {
        case 0x0400_0134: return extKeyIn << 16  // RCNT reads as 0
        case 0x0400_0138: return s.rtc.read()
        case 0x0400_01C0: return UInt32(s.spi.control) | UInt32(s.spi.readData()) << 16
        case 0x0400_0240:
            // VRAMSTAT: banks C and D mapped to the ARM7.
            let c: UInt32 = s.vramcnt[2] & 0x87 == 0x82 ? 1 : 0, d: UInt32 = s.vramcnt[3] & 0x87 == 0x82 ? 2 : 0
            return c | d | UInt32(s.wramcnt) << 8
        case 0x0400_0300: return postflg
        case 0x0400_0304: return powcnt2
        case 0x0400_0400..<0x0400_0520: return soundRegisters[Int((a - 0x0400_0400) / 4)]
        default:
            s.noteUnhandledIO(cpu: 1, a)
            return 0
        }
    }

    /// X, Y, pen down and hinge, active low except the hinge bit.
    private var extKeyIn: UInt32 {
        var v: UInt32 = 0x7F
        let buttons = s.input.buttons
        if buttons.contains(.x) { v &= ~1 }
        if buttons.contains(.y) { v &= ~2 }
        if s.input.touch != nil { v &= ~0x40 }
        if s.lidClosed { v |= 0x80 }
        return v
    }

    func ioWrite(_ a: UInt32, _ v: UInt32, mask: UInt32) {
        if s.ioWriteCommon(cpu: 1, a, v, mask: mask) { return }
        switch a {
        case 0x0400_0134:
            break  // RCNT: the serial port is unused
        case 0x0400_0138:
            if mask & 0xFF != 0 { s.rtc.write(UInt8(truncatingIfNeeded: v)) }
        case 0x0400_01C0:
            if mask & 0xFFFF != 0 { s.spi.control = UInt16(truncatingIfNeeded: (UInt32(s.spi.control) & ~mask) | (v & mask)) }
            if mask & 0x00FF_0000 != 0 { s.spi.writeData(UInt8(truncatingIfNeeded: v >> 16)) }
        case 0x0400_0300:
            postflg = (postflg & ~mask & 0xFF) | (v & mask & 1)
            if mask & 0xFF00 != 0 && (v >> 14) & 3 == 2 { s.arm7.halt() }  // HALTCNT
        case 0x0400_0304: powcnt2 = (powcnt2 & ~mask) | (v & mask & 3)
        case 0x0400_0400..<0x0400_0520:
            let i = Int((a - 0x0400_0400) / 4)
            soundRegisters[i] = (soundRegisters[i] & ~mask) | (v & mask)
        default: s.noteUnhandledIO(cpu: 1, a)
        }
    }
}
