// SPDX-License-Identifier: GPL-3.0-or-later
//
// VFPv2 (the ARM11's floating-point unit): coprocessors 10 (single) and 11 (double).
// Written from the ARM Architecture Reference Manual, part C.
//
// Supported: all VFPv2 arithmetic, compares, conversions, loads, stores and
// register moves, FPSCR rounding modes for single precision, flush-to-zero and
// default NaN. Not supported: short vectors (FPSCR LEN/STRIDE) and FP exceptions,
// which 3DS games do not use.

extension ARM {
    @inline(__always) func single(_ i: Int) -> Float { Float(bitPattern: vfp[i]) }

    @inline(__always) func setSingle(_ i: Int, _ value: Float) { vfp[i] = finishSingle(value).bitPattern }

    @inline(__always) func double(_ i: Int) -> Double {
        Double(bitPattern: UInt64(vfp[2 * i + 1]) << 32 | UInt64(vfp[2 * i]))
    }

    @inline(__always) func setDouble(_ i: Int, _ value: Double) {
        var v = value
        if fpscr & (1 << 25) != 0 && v.isNaN { v = .nan }
        if fpscr & (1 << 24) != 0 && v.isSubnormal { v = v.sign == .minus ? -0.0 : 0 }
        let bits = v.bitPattern
        vfp[2 * i] = UInt32(truncatingIfNeeded: bits)
        vfp[2 * i + 1] = UInt32(truncatingIfNeeded: bits >> 32)
    }

    /// Applies default-NaN and flush-to-zero to a single-precision result.
    @inline(__always) func finishSingle(_ value: Float) -> Float {
        if fpscr & (1 << 25) != 0 && value.isNaN { return Float(bitPattern: 0x7FC0_0000) }
        if fpscr & (1 << 24) != 0 && value.isSubnormal { return value.sign == .minus ? -0.0 : 0 }
        return value
    }

    /// Single-precision input with flush-to-zero applied.
    @inline(__always) func singleOperand(_ i: Int) -> Float {
        let v = single(i)
        if fpscr & (1 << 24) != 0 && v.isSubnormal { return v.sign == .minus ? -0.0 : 0 }
        return v
    }

    /// Rounds an exact (or nearly exact) double result to single in the FPSCR rounding mode.
    /// The 3DS kernel starts threads with round-towards-zero, so this matters.
    @inline(__always) func roundToSingle(_ value: Double) -> Float {
        let nearest = Float(value)
        let mode = (fpscr >> 22) & 3
        if mode == 0 || !nearest.isFinite || Double(nearest) == value { return nearest }
        let tooBig = Double(nearest) > value
        switch mode {
        case 1: return tooBig ? nearest : nearest.nextUp                 // towards +infinity
        case 2: return tooBig ? nearest.nextDown : nearest               // towards -infinity
        default:                                                          // towards zero
            if value > 0 { return tooBig ? nearest.nextDown : nearest }
            return tooBig ? nearest : nearest.nextUp
        }
    }

    // MARK: - Data processing (CDP)

    func coprocessorDataOperation(_ op: UInt32, address: UInt32) {
        let coprocessor = (op >> 8) & 0xF
        guard coprocessor & 0xE == 0xA else { undefinedInstruction(address); return }
        let isDouble = coprocessor == 11
        let sd = Int((op >> 11) & 0x1E | (op >> 22) & 1)
        let sn = Int((op >> 15) & 0x1E | (op >> 7) & 1)
        let sm = Int((op << 1) & 0x1E | (op >> 5) & 1)
        let dd = Int((op >> 12) & 0xF), dn = Int((op >> 16) & 0xF), dm = Int(op & 0xF)
        let pqrs = (op >> 20) & 8 | (op >> 19) & 4 | (op >> 19) & 2 | (op >> 6) & 1

        if pqrs != 15 {
            if isDouble {
                let a = double(dn), b = double(dm), d = double(dd)
                switch pqrs {
                case 0: setDouble(dd, d + a * b)      // FMAC
                case 1: setDouble(dd, d - a * b)      // FNMAC
                case 2: setDouble(dd, -d + a * b)     // FMSC
                case 3: setDouble(dd, -d - a * b)     // FNMSC
                case 4: setDouble(dd, a * b)          // FMUL
                case 5: setDouble(dd, -(a * b))       // FNMUL
                case 6: setDouble(dd, a + b)          // FADD
                case 7: setDouble(dd, a - b)          // FSUB
                case 8: setDouble(dd, a / b)          // FDIV
                default: undefinedInstruction(address)
                }
            } else {
                // Products and sums of two singles are exact in double, so rounding
                // once afterwards gives the single-precision result in any mode.
                let a = Double(singleOperand(sn)), b = Double(singleOperand(sm))
                let d = Double(singleOperand(sd))
                let product = Double(roundToSingle(a * b))
                switch pqrs {
                case 0: setSingle(sd, roundToSingle(d + product))
                case 1: setSingle(sd, roundToSingle(d - product))
                case 2: setSingle(sd, roundToSingle(-d + product))
                case 3: setSingle(sd, roundToSingle(-d - product))
                case 4: setSingle(sd, roundToSingle(a * b))
                case 5: setSingle(sd, -roundToSingle(a * b))
                case 6: setSingle(sd, roundToSingle(a + b))
                case 7: setSingle(sd, roundToSingle(a - b))
                case 8: setSingle(sd, roundToSingle(a / b))
                default: undefinedInstruction(address)
                }
            }
            return
        }

        let ext = sn  // Fn:N selects the extension operation
        switch ext {
        case 0:  // FCPY
            if isDouble { vfp[2 * dd] = vfp[2 * dm]; vfp[2 * dd + 1] = vfp[2 * dm + 1] } else { vfp[sd] = vfp[sm] }
        case 1:  // FABS
            if isDouble { vfp[2 * dd] = vfp[2 * dm]; vfp[2 * dd + 1] = vfp[2 * dm + 1] & 0x7FFF_FFFF } else { vfp[sd] = vfp[sm] & 0x7FFF_FFFF }
        case 2:  // FNEG
            if isDouble { vfp[2 * dd] = vfp[2 * dm]; vfp[2 * dd + 1] = vfp[2 * dm + 1] ^ 0x8000_0000 } else { vfp[sd] = vfp[sm] ^ 0x8000_0000 }
        case 3:  // FSQRT
            if isDouble { setDouble(dd, double(dm).squareRoot()) } else { setSingle(sd, roundToSingle(Double(singleOperand(sm)).squareRoot())) }
        case 8, 9, 10, 11:  // FCMP, FCMPE, FCMPZ, FCMPEZ
            let a: Double = isDouble ? double(dd) : Double(singleOperand(sd))
            let b: Double = ext >= 10 ? 0 : (isDouble ? double(dm) : Double(singleOperand(sm)))
            let flags: UInt32
            if a.isNaN || b.isNaN { flags = 0x3 } else if a == b { flags = 0x6 } else if a < b { flags = 0x8 } else { flags = 0x2 }
            fpscr = (fpscr & 0x0FFF_FFFF) | flags << 28
        case 15:  // FCVTDS (single to double), FCVTSD (double to single)
            if isDouble { setSingle(sd, roundToSingle(double(dm))) } else { setDouble(dd, Double(singleOperand(sm))) }
        case 16, 17:  // FUITO, FSITO: the source is always an integer in a single register
            let raw = vfp[sm]
            let value = ext == 17 ? Double(Int32(bitPattern: raw)) : Double(raw)
            if isDouble { setDouble(dd, value) } else { setSingle(sd, roundToSingle(value)) }
        case 24, 25, 26, 27:  // FTOUI, FTOUIZ, FTOSI, FTOSIZ: the result is always in a single register
            let value = isDouble ? double(dm) : Double(singleOperand(sm))
            let towardZero = ext & 1 != 0 || (fpscr >> 22) & 3 == 3
            let rounded: Double
            if towardZero {
                rounded = value.rounded(.towardZero)
            } else {
                switch (fpscr >> 22) & 3 {
                case 1: rounded = value.rounded(.up)
                case 2: rounded = value.rounded(.down)
                default: rounded = value.rounded(.toNearestOrEven)
                }
            }
            if ext >= 26 {
                let clamped = rounded.isNaN ? 0 : min(max(rounded, Double(Int32.min)), Double(Int32.max))
                vfp[sd] = UInt32(bitPattern: Int32(clamped))
            } else {
                let clamped = rounded.isNaN ? 0 : min(max(rounded, 0), Double(UInt32.max))
                vfp[sd] = UInt32(clamped)
            }
        default:
            undefinedInstruction(address)
        }
    }

    // MARK: - Register transfers (MCR/MRC on coprocessors 10 and 11)

    func vfpRegisterTransfer(_ op: UInt32, address: UInt32) {
        let load = op & (1 << 20) != 0  // to an ARM register
        let rt = Int((op >> 12) & 0xF)
        let opc1 = (op >> 21) & 7
        if (op >> 8) & 0xF == 10 {
            if opc1 == 0 {  // FMSR, FMRS
                let sn = Int((op >> 15) & 0x1E | (op >> 7) & 1)
                if load { regs[rt] = vfp[sn] } else { vfp[sn] = regs[rt] }
                return
            }
            if opc1 == 7 {  // FMXR, FMRX, FMSTAT
                let system = (op >> 16) & 0xF
                if load {
                    let value: UInt32
                    switch system {
                    case 0: value = 0x4100_20B4   // FPSID: ARM VFP11, VFPv2
                    case 1: value = fpscr
                    case 8: value = fpexc
                    default: value = 0
                    }
                    if rt == 15 { cpsr = (cpsr & 0x0FFF_FFFF) | (value & 0xF000_0000) } else { regs[rt] = value }
                } else {
                    switch system {
                    case 1: fpscr = regs[rt]
                    case 8: fpexc = regs[rt]
                    default: break
                    }
                }
                return
            }
        } else if opc1 <= 1 {  // FMDLR, FMRDL (opc1 0), FMDHR, FMRDH (opc1 1)
            let index = 2 * Int((op >> 16) & 0xF) + Int(opc1)
            if load { regs[rt] = vfp[index] } else { vfp[index] = regs[rt] }
            return
        }
        undefinedInstruction(address)
    }

    // MARK: - Loads, stores and two-register moves (LDC/STC/MCRR/MRRC)

    func coprocessorTransfer(_ op: UInt32, address: UInt32) {
        let coprocessor = (op >> 8) & 0xF
        guard coprocessor & 0xE == 0xA else { return }
        let isDouble = coprocessor == 11
        let load = op & (1 << 20) != 0
        let rn = Int((op >> 16) & 0xF)

        if op & 0x0FE0_0000 == 0x0C40_0000 {  // FMDRR, FMRRD, FMSRR, FMRRS
            let rt = Int((op >> 12) & 0xF), rt2 = rn
            let first = isDouble ? 2 * Int(op & 0xF) : Int((op << 1) & 0x1E | (op >> 5) & 1)
            if load {
                regs[rt] = vfp[first]
                regs[rt2] = vfp[first + 1]
            } else {
                vfp[first] = regs[rt]
                vfp[first + 1] = regs[rt2]
            }
            return
        }

        let pre = op & (1 << 24) != 0, up = op & (1 << 23) != 0, writeBack = op & (1 << 21) != 0
        let first = isDouble ? 2 * Int((op >> 12) & 0xF) : Int((op >> 11) & 0x1E | (op >> 22) & 1)
        let offset = (op & 0xFF) << 2
        var base = regs[rn]
        if rn == 15 { base &= ~3 }

        if pre && !writeBack {  // FLDS, FSTS, FLDD, FSTD
            let address = up ? base &+ offset : base &- offset
            let words = isDouble ? 2 : 1
            for i in 0..<words { transferVFPWord(first + i, address &+ UInt32(i * 4), load: load) }
            return
        }

        // FLDM, FSTM: increment after (P=0, U=1) or decrement before (P=1, U=0, W=1).
        var words = Int(op & 0xFF)
        if isDouble { words &= ~1 }  // FLDMX/FSTMX transfer one extra, unused word
        let start = pre ? base &- offset : base
        for i in 0..<min(words, 32 - first) { transferVFPWord(first + i, start &+ UInt32(i * 4), load: load) }
        if writeBack { regs[rn] = up ? base &+ offset : base &- offset }
    }

    @inline(__always) func transferVFPWord(_ index: Int, _ address: UInt32, load: Bool) {
        if load { vfp[index] = bus.read32(address & ~3) } else { bus.write32(address & ~3, vfp[index]) }
    }
}
