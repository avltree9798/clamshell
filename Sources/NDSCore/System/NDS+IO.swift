// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit

/// I/O registers that exist on both CPUs, with per-CPU copies where the hardware has them.
/// Every access is a 32-bit word at an aligned address plus a byte-lane mask.
extension NDS {
    func ioReadCommon(cpu: Int, _ a: UInt32) -> UInt32? {
        let irq = cpu == 0 ? irq9 : irq7
        let timers = cpu == 0 ? timers9 : timers7
        let dma = cpu == 0 ? dma9 : dma7
        switch a {
        case 0x0400_0004:
            return (cpu == 0 ? dispstat9 : dispstat7) | vcount << 16
        case 0x0400_00B0...0x0400_00DC:
            let ch = Int((a - 0x0400_00B0) / 12)
            switch (a - 0x0400_00B0) % 12 {
            case 0: return dma.channels[ch].source
            case 4: return dma.channels[ch].destination
            default: return dma.channels[ch].control
            }
        case 0x0400_0100...0x0400_010C:
            let n = Int((a - 0x0400_0100) / 4)
            return UInt32(timers.counter(n)) | UInt32(timers.timers[n].control) << 16
        case 0x0400_0130:
            return ~input.buttons.rawValue & 0x3FF
        case 0x0400_0180:
            return ipc.readSync(cpu: cpu)
        case 0x0400_0184:
            return ipc.readControl(cpu: cpu)
        case 0x0400_01A0:
            return UInt32(cartridge.auxSPIControl) | UInt32(cartridge.auxSPIData) << 16
        case 0x0400_01A4:
            return cartridge.readControl()
        case 0x0400_01A8, 0x0400_01AC:
            let base = Int(a - 0x0400_01A8)
            return (0..<4).reduce(0) { $0 | UInt32(cartridge.command[base + $1]) << UInt32($1 * 8) }
        case 0x0400_0208:
            return irq.ime
        case 0x0400_0210:
            return irq.ie
        case 0x0400_0214:
            return irq.iflags
        case 0x0410_0000:
            return ipc.receive(cpu: cpu)
        case 0x0410_0010:
            return cartridge.readData()
        default:
            return nil
        }
    }

    /// Returns true if the register was handled here.
    func ioWriteCommon(cpu: Int, _ a: UInt32, _ v: UInt32, mask: UInt32) -> Bool {
        let irq = cpu == 0 ? irq9 : irq7
        let timers = cpu == 0 ? timers9 : timers7
        let dma = cpu == 0 ? dma9 : dma7
        @inline(__always) func merge(_ old: UInt32) -> UInt32 { (old & ~mask) | (v & mask) }

        switch a {
        case 0x0400_0004:
            // DISPSTAT: bits 0-2 are read-only status.
            let writable: UInt32 = 0xFFB8
            if cpu == 0 {
                dispstat9 = (dispstat9 & ~(writable & mask)) | (v & writable & mask)
            } else {
                dispstat7 = (dispstat7 & ~(writable & mask)) | (v & writable & mask)
            }
        case 0x0400_00B0...0x0400_00DC:
            let ch = Int((a - 0x0400_00B0) / 12)
            switch (a - 0x0400_00B0) % 12 {
            case 0: dma.channels[ch].source = merge(dma.channels[ch].source)
            case 4: dma.channels[ch].destination = merge(dma.channels[ch].destination)
            default: dma.writeControl(ch, merge(dma.channels[ch].control))
            }
        case 0x0400_0100...0x0400_010C:
            let n = Int((a - 0x0400_0100) / 4)
            if mask & 0xFFFF != 0 {
                let old = UInt32(timers.timers[n].reload)
                timers.writeReload(n, UInt16(truncatingIfNeeded: (old & ~mask) | (v & mask)))
            }
            if mask & 0xFFFF_0000 != 0 {
                let old = UInt32(timers.timers[n].control) << 16
                timers.writeControl(n, UInt16(truncatingIfNeeded: ((old & ~mask) | (v & mask)) >> 16))
            }
        case 0x0400_0130:
            break  // KEYINPUT is read-only; KEYCNT (keypad IRQ) comes later
        case 0x0400_0180:
            if mask & 0xFFFF != 0 { ipc.writeSync(cpu: cpu, v & mask) }
        case 0x0400_0184:
            if mask & 0xFFFF != 0 { ipc.writeControl(cpu: cpu, merge(ipc.readControl(cpu: cpu))) }
        case 0x0400_0188:
            ipc.send(cpu: cpu, v)
        case 0x0400_01A0:
            if mask & 0xFFFF != 0 {
                cartridge.writeAuxSPIControl(UInt16(truncatingIfNeeded: merge(UInt32(cartridge.auxSPIControl))))
            }
            if mask & 0x00FF_0000 != 0 { cartridge.writeAuxSPIData(UInt8(truncatingIfNeeded: v >> 16)) }
        case 0x0400_01A4:
            cartridge.writeControl(v, mask: mask)
        case 0x0400_01A8, 0x0400_01AC:
            let base = Int(a - 0x0400_01A8)
            for byte in 0..<4 where mask & (0xFF << UInt32(byte * 8)) != 0 {
                cartridge.command[base + byte] = UInt8(truncatingIfNeeded: v >> UInt32(byte * 8))
            }
        case 0x0400_0208:
            irq.ime = merge(irq.ime) & 1
            updateIRQLines()
        case 0x0400_0210:
            irq.ie = merge(irq.ie)
            updateIRQLines()
        case 0x0400_0214:
            // Writing 1 acknowledges an interrupt.
            irq.iflags &= ~(v & mask)
            updateIRQLines()
        default:
            return false
        }
        return true
    }
}
