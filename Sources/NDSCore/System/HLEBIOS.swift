// SPDX-License-Identifier: GPL-3.0-or-later
//
// BIOS calls reimplemented from their documented behaviour (GBATEK), so no
// Nintendo BIOS image is needed or distributed.

enum HLEBIOS {
    /// Runs SWI `number`. Returns false for calls not implemented yet, which then
    /// take the real exception path (and fail visibly in a debugger).
    static func call<B: ARMBus>(_ number: UInt32, cpu: ARMRegisterFile, bus: B, isARM9: Bool) -> Bool {
        let r0 = cpu.reg(0), r1 = cpu.reg(1), r2 = cpu.reg(2)
        switch number {
        case 0x00:  // SoftReset: not used by games after boot
            return true
        case 0x03:  // WaitByLoop: r0 iterations of a 4-cycle loop
            cpu.cycles &+= UInt64(r0) * 4
        case 0x04:  // IntrWait(discardOld, mask)
            cpu.waitForInterrupt(mask: r1, discardOld: r0 != 0)
        case 0x05:  // VBlankIntrWait
            cpu.waitForInterrupt(mask: 1, discardOld: true)
        case 0x06:  // Halt
            cpu.halt()
        case 0x07 where !isARM9:  // Sleep
            cpu.halt()
        case 0x08 where !isARM9:  // SoundBias: the SPU is not emulated yet
            break
        case 0x09:  // Div
            divide(cpu, numerator: Int32(bitPattern: r0), denominator: Int32(bitPattern: r1))
        case 0x0B:  // CpuSet
            cpuSet(bus, source: r0, destination: r1, control: r2, fast: false)
        case 0x0C:  // CpuFastSet
            cpuSet(bus, source: r0, destination: r1, control: r2, fast: true)
        case 0x0D:  // Sqrt
            cpu.setReg(0, UInt32(UInt64(r0).squareRootFloor))
        case 0x0E:  // GetCRC16(initial, address, length)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(Int(r2))
            for i in 0..<(r2 & ~1) { bytes.append(bus.read8(r1 &+ i)) }
            cpu.setReg(0, UInt32(Firmware.crc16(bytes, seed: UInt16(truncatingIfNeeded: r0))))
        case 0x0F:  // IsDebugger
            cpu.setReg(0, 0)
        case 0x10:  // BitUnPack
            bitUnpack(bus, source: r0, destination: r1, info: r2)
        case 0x11:  // LZ77UnCompReadNormalWrite8bit
            lz77(bus, source: r0, destination: r1, halfwords: false)
        case 0x12:  // LZ77UnCompReadNormalWrite16bit (for VRAM)
            lz77(bus, source: r0, destination: r1, halfwords: true)
        case 0x14:  // RLUnCompReadNormalWrite8bit
            runLength(bus, source: r0, destination: r1, halfwords: false)
        case 0x15:  // RLUnCompReadNormalWrite16bit
            runLength(bus, source: r0, destination: r1, halfwords: true)
        default:
            return false
        }
        return true
    }

    private static func divide(_ cpu: ARMRegisterFile, numerator: Int32, denominator: Int32) {
        guard denominator != 0 else { return }  // the real BIOS hangs; leave registers alone
        let (q, overflow) = numerator.dividedReportingOverflow(by: denominator)
        let quotient = overflow ? numerator : q
        let remainder = overflow ? 0 : numerator % denominator
        cpu.setReg(0, UInt32(bitPattern: quotient))
        cpu.setReg(1, UInt32(bitPattern: remainder))
        cpu.setReg(3, quotient.magnitude)
    }

    private static func cpuSet<B: ARMBus>(_ bus: B, source: UInt32, destination: UInt32, control: UInt32, fast: Bool) {
        var count = control & 0x1F_FFFF
        let fill = control & (1 << 24) != 0
        let words = fast || control & (1 << 26) != 0
        if fast { count = (count + 7) & ~7 }
        var s = source, d = destination
        if words {
            s &= ~3; d &= ~3
            let value = bus.read32(s)
            for _ in 0..<count {
                bus.write32(d, fill ? value : bus.read32(s))
                d &+= 4
                if !fill { s &+= 4 }
            }
        } else {
            s &= ~1; d &= ~1
            let value = bus.read16(s)
            for _ in 0..<count {
                bus.write16(d, fill ? value : bus.read16(s))
                d &+= 2
                if !fill { s &+= 2 }
            }
        }
    }

    /// Writes bytes either directly or paired into halfwords (VRAM ignores byte writes).
    private struct Writer<B: ARMBus> {
        let bus: B
        let halfwords: Bool
        var address: UInt32
        var pending: UInt8?

        mutating func put(_ byte: UInt8) {
            if !halfwords {
                bus.write8(address, byte)
                address &+= 1
                return
            }
            if let low = pending {
                bus.write16(address, UInt16(low) | UInt16(byte) << 8)
                address &+= 2
                pending = nil
            } else {
                pending = byte
            }
        }

        /// Reads back a byte already written, for LZ77 back-references.
        func peek(back distance: UInt32) -> UInt8 {
            let written = address &+ (pending == nil ? 0 : 1)
            let target = written &- distance
            if halfwords, let low = pending, target == address { return low }
            return bus.read8(target)
        }
    }

    private static func lz77<B: ARMBus>(_ bus: B, source: UInt32, destination: UInt32, halfwords: Bool) {
        let header = bus.read32(source)
        let size = header >> 8
        var s = source &+ 4
        var out = Writer(bus: bus, halfwords: halfwords, address: destination, pending: nil)
        var written: UInt32 = 0
        while written < size {
            let flags = bus.read8(s); s &+= 1
            for bit in (0..<8).reversed() where written < size {
                if flags & (1 << UInt8(bit)) == 0 {
                    out.put(bus.read8(s)); s &+= 1
                    written += 1
                } else {
                    let b0 = UInt32(bus.read8(s)), b1 = UInt32(bus.read8(s &+ 1)); s &+= 2
                    let length = (b0 >> 4) + 3
                    let distance = ((b0 & 0xF) << 8 | b1) + 1
                    for _ in 0..<length where written < size {
                        out.put(out.peek(back: distance))
                        written += 1
                    }
                }
            }
        }
    }

    private static func runLength<B: ARMBus>(_ bus: B, source: UInt32, destination: UInt32, halfwords: Bool) {
        let size = bus.read32(source) >> 8
        var s = source &+ 4
        var out = Writer(bus: bus, halfwords: halfwords, address: destination, pending: nil)
        var written: UInt32 = 0
        while written < size {
            let flag = bus.read8(s); s &+= 1
            if flag & 0x80 != 0 {
                let length = UInt32(flag & 0x7F) + 3
                let byte = bus.read8(s); s &+= 1
                for _ in 0..<length where written < size { out.put(byte); written += 1 }
            } else {
                let length = UInt32(flag & 0x7F) + 1
                for _ in 0..<length where written < size {
                    out.put(bus.read8(s)); s &+= 1
                    written += 1
                }
            }
        }
    }

    private static func bitUnpack<B: ARMBus>(_ bus: B, source: UInt32, destination: UInt32, info: UInt32) {
        let length = UInt32(bus.read16(info))
        let sourceWidth = UInt32(bus.read8(info &+ 2))
        let destinationWidth = UInt32(bus.read8(info &+ 3))
        let offsetWord = bus.read32(info &+ 4)
        let dataOffset = offsetWord & 0x7FFF_FFFF
        let zeroFlag = offsetWord >> 31 != 0
        guard [1, 2, 4, 8].contains(sourceWidth), [1, 2, 4, 8, 16, 32].contains(destinationWidth) else { return }

        var d = destination & ~3
        var outWord: UInt32 = 0, outBits: UInt32 = 0
        for i in 0..<length {
            let byte = UInt32(bus.read8(source &+ i))
            var bit: UInt32 = 0
            while bit < 8 {
                var value = (byte >> bit) & ((1 << sourceWidth) - 1)
                if value != 0 || zeroFlag { value &+= dataOffset }
                outWord |= (value & (destinationWidth == 32 ? 0xFFFF_FFFF : (1 << destinationWidth) - 1)) << outBits
                outBits += destinationWidth
                if outBits >= 32 {
                    bus.write32(d, outWord)
                    d &+= 4
                    outWord = 0
                    outBits = 0
                }
                bit += sourceWidth
            }
        }
    }
}

extension UInt64 {
    /// Integer square root, rounded down.
    var squareRootFloor: UInt64 {
        if self < 2 { return self }
        var x = Swift.min(UInt64(Double(self).squareRoot()), 0xFFFF_FFFF)
        while x > self / x { x -= 1 }
        while x < 0xFFFF_FFFF && x + 1 <= self / (x + 1) { x += 1 }
        return x
    }
}
