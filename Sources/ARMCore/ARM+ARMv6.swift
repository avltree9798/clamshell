// SPDX-License-Identifier: GPL-3.0-or-later
//
// ARMv6K additions used by the 3DS ARM11: media instructions (parallel
// arithmetic, packing, saturation, extension, byte reversal, dual multiplies),
// exclusive loads and stores, UMAAL, CPS and CLREX, and the Thumb additions.
// Written from the ARM Architecture Reference Manual (ARMv6 edition).

extension ARM {
    /// CPSR GE[3:0], bits 19-16, set by parallel add/sub and read by SEL.
    @inline(__always) var greaterOrEqual: UInt32 { (cpsr >> 16) & 0xF }

    // MARK: - Unconditional space (cond = 1111)

    func unconditional(_ op: UInt32, address: UInt32) {
        if op & 0xFFF1_FE20 == 0xF100_0000 {  // CPS
            guard cpsr & PSR.modeMask != ARMMode.user.rawValue else { return }
            let bits = op & 0x1C0  // A, I, F
            switch (op >> 18) & 3 {
            case 2: cpsr &= ~bits
            case 3: cpsr |= bits
            default: break
            }
            if op & (1 << 17) != 0 { switchMode(op & 0x1F) }
            return
        }
        if op == 0xF57F_F01F { exclusiveAddress = nil; return }  // CLREX
        // PLD, SETEND (big-endian data is not supported), DSB/DMB/ISB: no effect here.
        if op & 0xFD70_F000 == 0xF550_F000 || op & 0xFFFF_FDFF == 0xF101_0000 || op & 0xFFFF_FF00 == 0xF57F_F000 {
            return
        }
        undefinedInstruction(address)
    }

    // MARK: - Multiplies

    /// UMAAL: RdHi:RdLo = Rn * Rm + RdHi + RdLo.
    func multiplyAccumulateAccumulate(_ op: UInt32) {
        let rdHi = Int((op >> 16) & 0xF), rdLo = Int((op >> 12) & 0xF)
        let result = UInt64(regs[Int(op & 0xF)]) &* UInt64(regs[Int((op >> 8) & 0xF)])
            &+ UInt64(regs[rdHi]) &+ UInt64(regs[rdLo])
        regs[rdLo] = UInt32(truncatingIfNeeded: result)
        regs[rdHi] = UInt32(truncatingIfNeeded: result >> 32)
    }

    // MARK: - Exclusive access

    /// LDREX, STREX and the byte, halfword and doubleword forms. One monitor per CPU;
    /// the 3DS kernel HLE clears it on every thread switch.
    func exclusiveTransfer(_ op: UInt32) {
        let rn = Int((op >> 16) & 0xF), rd = Int((op >> 12) & 0xF), rt = Int(op & 0xF)
        let address = regs[rn]
        let size = (op >> 21) & 3  // 0 word, 1 doubleword, 2 byte, 3 halfword
        if op & (1 << 20) != 0 {
            exclusiveAddress = address
            switch size {
            case 0: regs[rd] = bus.read32(address & ~3)
            case 1:
                regs[rd & ~1] = bus.read32(address & ~3)
                regs[(rd & ~1) + 1] = bus.read32((address & ~3) &+ 4)
            case 2: regs[rd] = UInt32(bus.read8(address))
            default: regs[rd] = UInt32(bus.read16(address & ~1))
            }
            return
        }
        guard exclusiveAddress == address else {
            regs[rd] = 1
            return
        }
        switch size {
        case 0: bus.write32(address & ~3, regs[rt])
        case 1:
            bus.write32(address & ~3, regs[rt & ~1])
            bus.write32((address & ~3) &+ 4, regs[(rt & ~1) + 1])
        case 2: bus.write8(address, UInt8(truncatingIfNeeded: regs[rt]))
        default: bus.write16(address & ~1, UInt16(truncatingIfNeeded: regs[rt]))
        }
        exclusiveAddress = nil
        regs[rd] = 0
    }

    // MARK: - Media instructions

    func media(_ op: UInt32, address: UInt32) {
        let op1 = (op >> 20) & 0x1F
        let op2 = (op >> 5) & 7
        let rn = Int((op >> 16) & 0xF), rd = Int((op >> 12) & 0xF), rm = Int(op & 0xF)

        switch op1 {
        case 0x00...0x07:
            parallelAddSubtract(op)
        case 0x08:
            if op2 & 1 == 0 {  // PKHBT, PKHTB
                let amount = (op >> 7) & 0x1F
                if op & (1 << 6) == 0 {
                    regs[rd] = (regs[rn] & 0xFFFF) | ((regs[rm] << amount) & 0xFFFF_0000)
                } else {
                    let shifted = UInt32(bitPattern: Int32(bitPattern: regs[rm]) >> Int32(amount == 0 ? 31 : amount))
                    regs[rd] = (regs[rn] & 0xFFFF_0000) | (shifted & 0xFFFF)
                }
            } else if op2 == 5 {  // SEL
                let ge = greaterOrEqual
                var result: UInt32 = 0
                for lane in 0..<4 as Range<UInt32> {
                    let mask: UInt32 = 0xFF << (lane * 8)
                    result |= (ge >> lane) & 1 != 0 ? regs[rn] & mask : regs[rm] & mask
                }
                regs[rd] = result
            } else if op2 == 3 {  // SXTAB16, SXTB16
                extend16(op, signed: true)
            } else {
                undefinedInstruction(address)
            }
        case 0x0A, 0x0B, 0x0E, 0x0F:
            let unsigned = op1 >= 0x0E
            if op2 & 1 == 0 {
                saturate(op, unsigned: unsigned)
            } else if op2 == 1 && op1 & 1 == 0 {
                saturate16(op, unsigned: unsigned)
            } else if op2 == 3 {  // SXTAB, SXTAH, UXTAB, UXTAH and the forms without add (Rn = 15)
                let value = regs[rm].rotatedRight(((op >> 10) & 3) * 8)
                let extended: UInt32
                switch (op1 & 1, unsigned) {
                case (0, false): extended = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: value)))
                case (1, false): extended = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: value)))
                case (0, true): extended = value & 0xFF
                default: extended = value & 0xFFFF
                }
                regs[rd] = rn == 15 ? extended : regs[rn] &+ extended
            } else if op2 == 1 && op1 == 0x0B {  // REV
                regs[rd] = regs[rm].byteSwapped
            } else if op2 == 5 && op1 == 0x0B {  // REV16
                let v = regs[rm]
                regs[rd] = ((v & 0x00FF_00FF) << 8) | ((v >> 8) & 0x00FF_00FF)
            } else if op2 == 5 && op1 == 0x0F {  // REVSH
                let v = regs[rm]
                let half = UInt16(truncatingIfNeeded: ((v & 0xFF) << 8) | ((v >> 8) & 0xFF))
                regs[rd] = UInt32(bitPattern: Int32(Int16(bitPattern: half)))
            } else {
                undefinedInstruction(address)
            }
        case 0x0C:
            if op2 == 3 { extend16(op, signed: false) } else { undefinedInstruction(address) }
        case 0x10, 0x14:
            dualMultiply(op, long: op1 == 0x14)
        case 0x15:
            mostSignificantMultiply(op)
        case 0x18:
            guard op2 == 0 else { undefinedInstruction(address); return }
            // USAD8, USADA8: these use Rd = 19-16, Ra = 15-12, Rm = 11-8, Rn = 3-0.
            let a = regs[Int(op & 0xF)], b = regs[Int((op >> 8) & 0xF)]
            var sum: UInt32 = 0
            for lane in 0..<4 as Range<UInt32> {
                let x = Int32((a >> (lane * 8)) & 0xFF), y = Int32((b >> (lane * 8)) & 0xFF)
                sum &+= UInt32(abs(x - y))
            }
            let ra = Int((op >> 12) & 0xF)
            regs[Int((op >> 16) & 0xF)] = ra == 15 ? sum : sum &+ regs[ra]
        default:
            undefinedInstruction(address)
        }
    }

    /// SADD16, QADD8, UHSUB16 and the rest: lane-wise add/sub in six flavours.
    func parallelAddSubtract(_ op: UInt32) {
        let flavour = (op >> 20) & 7  // 1 S, 2 Q, 3 SH, 5 U, 6 UQ, 7 UH
        let form = (op >> 5) & 7      // 0 ADD16, 1 ASX, 2 SAX, 3 SUB16, 4 ADD8, 7 SUB8
        let a = regs[Int((op >> 16) & 0xF)], b = regs[Int(op & 0xF)]
        let signed = flavour < 4
        var result: UInt32 = 0, ge: UInt32 = 0

        func lane(width: UInt32, shiftA: UInt32, shiftB: UInt32, out: UInt32, add: Bool) {
            let mask: UInt32 = (1 << width) - 1
            var x = Int64((a >> shiftA) & mask), y = Int64((b >> shiftB) & mask)
            if signed {
                let sign = Int64(1) << (width - 1)
                x = (x ^ sign) - sign
                y = (y ^ sign) - sign
            }
            var r = add ? x + y : x - y
            let geLanes: UInt32 = width == 16 ? 3 : 1
            switch flavour {
            case 1: if r >= 0 { ge |= geLanes << (out / 8) }
            case 5: if add ? r >= Int64(1) << width : r >= 0 { ge |= geLanes << (out / 8) }
            case 2: r = min(max(r, -(Int64(1) << (width - 1))), (Int64(1) << (width - 1)) - 1)
            case 6: r = min(max(r, 0), (Int64(1) << width) - 1)
            case 3, 7: r >>= 1
            default: break
            }
            result |= (UInt32(truncatingIfNeeded: r) & mask) << out
        }

        switch form {
        case 0:
            lane(width: 16, shiftA: 0, shiftB: 0, out: 0, add: true)
            lane(width: 16, shiftA: 16, shiftB: 16, out: 16, add: true)
        case 1:  // ASX: high = a.hi + b.lo, low = a.lo - b.hi
            lane(width: 16, shiftA: 0, shiftB: 16, out: 0, add: false)
            lane(width: 16, shiftA: 16, shiftB: 0, out: 16, add: true)
        case 2:  // SAX: high = a.hi - b.lo, low = a.lo + b.hi
            lane(width: 16, shiftA: 0, shiftB: 16, out: 0, add: true)
            lane(width: 16, shiftA: 16, shiftB: 0, out: 16, add: false)
        case 3:
            lane(width: 16, shiftA: 0, shiftB: 0, out: 0, add: false)
            lane(width: 16, shiftA: 16, shiftB: 16, out: 16, add: false)
        case 4, 7:
            for i in 0..<4 as Range<UInt32> { lane(width: 8, shiftA: i * 8, shiftB: i * 8, out: i * 8, add: form == 4) }
        default:
            return
        }
        regs[Int((op >> 12) & 0xF)] = result
        if flavour == 1 || flavour == 5 { cpsr = (cpsr & ~0x000F_0000) | (ge << 16) }
    }

    /// SSAT, USAT: shift, then clamp to a signed or unsigned bit width; Q on clamp.
    func saturate(_ op: UInt32, unsigned: Bool) {
        let amount = (op >> 7) & 0x1F
        let value = regs[Int(op & 0xF)]
        let shifted: Int64
        if op & (1 << 6) != 0 {
            shifted = Int64(Int32(bitPattern: value) >> Int32(amount == 0 ? 31 : amount))
        } else {
            shifted = Int64(Int32(bitPattern: value << amount))
        }
        let bits = (op >> 16) & 0x1F
        let (low, high): (Int64, Int64) = unsigned
            ? (0, (Int64(1) << bits) - 1)
            : (-(Int64(1) << bits), (Int64(1) << bits) - 1)  // SSAT encodes width - 1
        let clamped = min(max(shifted, low), high)
        if clamped != shifted { cpsr |= PSR.q }
        regs[Int((op >> 12) & 0xF)] = UInt32(truncatingIfNeeded: clamped)
    }

    /// SSAT16, USAT16.
    func saturate16(_ op: UInt32, unsigned: Bool) {
        let bits = (op >> 16) & 0xF
        let (low, high): (Int32, Int32) = unsigned
            ? (0, (1 << bits) - 1)
            : (-(1 << bits), (1 << bits) - 1)
        let value = regs[Int(op & 0xF)]
        var result: UInt32 = 0
        for shift in [0, 16] as [UInt32] {
            let half = Int32(Int16(truncatingIfNeeded: value >> shift))
            let clamped = min(max(half, low), high)
            if clamped != half { cpsr |= PSR.q }
            result |= (UInt32(bitPattern: clamped) & 0xFFFF) << shift
        }
        regs[Int((op >> 12) & 0xF)] = result
    }

    /// SXTB16, SXTAB16, UXTB16, UXTAB16: extend bytes 0 and 2 into two halfwords.
    func extend16(_ op: UInt32, signed: Bool) {
        let rn = Int((op >> 16) & 0xF)
        let value = regs[Int(op & 0xF)].rotatedRight(((op >> 10) & 3) * 8)
        var result: UInt32 = 0
        for shift in [0, 16] as [UInt32] {
            let byte = (value >> shift) & 0xFF
            var half = signed ? UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: byte))) & 0xFFFF : byte
            if rn != 15 { half = half &+ (regs[rn] >> shift) }
            result |= (half & 0xFFFF) << shift
        }
        regs[Int((op >> 12) & 0xF)] = result
    }

    /// SMLAD, SMUAD, SMLSD, SMUSD, SMLALD, SMLSLD.
    func dualMultiply(_ op: UInt32, long: Bool) {
        let rn = regs[Int(op & 0xF)]
        var rm = regs[Int((op >> 8) & 0xF)]
        if op & (1 << 5) != 0 { rm = rm.rotatedRight(16) }
        let low = Int64(Int16(truncatingIfNeeded: rn)) * Int64(Int16(truncatingIfNeeded: rm))
        let high = Int64(Int16(truncatingIfNeeded: rn >> 16)) * Int64(Int16(truncatingIfNeeded: rm >> 16))
        let subtract = op & (1 << 6) != 0
        let product = subtract ? low - high : low + high
        let rd = Int((op >> 16) & 0xF), ra = Int((op >> 12) & 0xF)
        if long {
            let acc = Int64(bitPattern: UInt64(regs[rd]) << 32 | UInt64(regs[ra])) &+ product
            regs[ra] = UInt32(truncatingIfNeeded: acc)
            regs[rd] = UInt32(truncatingIfNeeded: acc >> 32)
            return
        }
        var sum = product
        if ra != 15 { sum += Int64(Int32(bitPattern: regs[ra])) }
        if sum != Int64(Int32(truncatingIfNeeded: sum)) { cpsr |= PSR.q }
        regs[rd] = UInt32(truncatingIfNeeded: sum)
    }

    /// SMMLA, SMMUL, SMMLS (with optional rounding): the top word of a 64-bit result.
    func mostSignificantMultiply(_ op: UInt32) {
        let product = Int64(Int32(bitPattern: regs[Int(op & 0xF)])) * Int64(Int32(bitPattern: regs[Int((op >> 8) & 0xF)]))
        let ra = Int((op >> 12) & 0xF)
        var value: Int64
        if op & (1 << 6) != 0 {
            value = (Int64(Int32(bitPattern: regs[ra])) << 32) &- product
        } else {
            value = ra == 15 ? product : (Int64(Int32(bitPattern: regs[ra])) << 32) &+ product
        }
        if op & (1 << 5) != 0 { value &+= 0x8000_0000 }
        regs[Int((op >> 16) & 0xF)] = UInt32(truncatingIfNeeded: value >> 32)
    }

    // MARK: - Thumb additions

    /// SXTH, SXTB, UXTH, UXTB (0xB2xx).
    func thumbExtend(_ op: UInt32) {
        let value = regs[Int((op >> 3) & 7)]
        let rd = Int(op & 7)
        switch (op >> 6) & 3 {
        case 0: regs[rd] = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: value)))
        case 1: regs[rd] = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: value)))
        case 2: regs[rd] = value & 0xFFFF
        default: regs[rd] = value & 0xFF
        }
    }

    /// REV, REV16, REVSH (0xBAxx).
    func thumbReverse(_ op: UInt32, address: UInt32) {
        let v = regs[Int((op >> 3) & 7)]
        let rd = Int(op & 7)
        switch (op >> 6) & 3 {
        case 0: regs[rd] = v.byteSwapped
        case 1: regs[rd] = ((v & 0x00FF_00FF) << 8) | ((v >> 8) & 0x00FF_00FF)
        case 3:
            let half = UInt16(truncatingIfNeeded: ((v & 0xFF) << 8) | ((v >> 8) & 0xFF))
            regs[rd] = UInt32(bitPattern: Int32(Int16(bitPattern: half)))
        default: undefinedInstruction(address)
        }
    }

    /// CPSIE, CPSID, SETEND (0xB65x-0xB67x).
    func thumbChangeState(_ op: UInt32, address: UInt32) {
        if op & 0xFFE8 == 0xB660 {
            guard cpsr & PSR.modeMask != ARMMode.user.rawValue else { return }
            let bits = (op & 7) << 6  // A, I, F
            if op & (1 << 4) != 0 { cpsr |= bits } else { cpsr &= ~bits }
        } else if op & 0xFFF7 != 0xB650 {  // SETEND is accepted and ignored
            undefinedInstruction(address)
        }
    }
}
