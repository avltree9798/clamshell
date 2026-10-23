// SPDX-License-Identifier: GPL-3.0-or-later
//
// 32-bit ARM instruction set. `regs[15]` reads as the instruction address + 8.
//
// Decoding goes through a 4096-entry table indexed by bits 27-20 and 7-4, so
// each instruction costs one table load and one jump. Data-processing cases
// pass their opcode as a literal, which lets the compiler build a separate,
// branch-free body for each one.

/// Instruction classes in `ARM.armDecodeTable`. 0-47 are data processing:
/// opcode + 16 * form (0 immediate, 1 register shifted by immediate, 2 shifted by register).
@usableFromInline enum ARMKind {
    static let msrImmediate: UInt8 = 48
    static let misc: UInt8 = 49
    static let multiply: UInt8 = 50
    static let multiplyLong: UInt8 = 51
    static let swap: UInt8 = 52
    static let halfword: UInt8 = 53
    // 54-57: LDR/STR immediate offset (store word, store byte, load word, load byte).
    static let transferImmediate: UInt8 = 54
    // 58-61: the same with a shifted register offset.
    static let transferRegister: UInt8 = 58
    static let undefined: UInt8 = 62
    static let block: UInt8 = 63
    static let branch: UInt8 = 64
    static let branchLink: UInt8 = 65
    static let softwareInterrupt: UInt8 = 66
    static let coprocessor: UInt8 = 67
    static let none: UInt8 = 68

    /// Class of an instruction from bits 27-20 (index bits 11-4) and 7-4 (index bits 3-0).
    static func classify(_ index: Int) -> UInt8 {
        let op = UInt32(index >> 4) << 20 | UInt32(index & 0xF) << 4
        let opcode = UInt8((op >> 21) & 0xF)
        switch (op >> 25) & 7 {
        case 0:
            if op & 0x0FC0_00F0 == 0x0000_0090 { return multiply }
            if op & 0x0F80_00F0 == 0x0080_0090 { return multiplyLong }
            if op & 0x0FB0_00F0 == 0x0100_0090 { return swap }
            if op & 0x0E00_0090 == 0x0000_0090 { return halfword }
            if op & 0x0190_0000 == 0x0100_0000 { return misc }
            return op & 0x10 != 0 ? 32 + opcode : 16 + opcode
        case 1:
            if op & 0x0FB0_0000 == 0x0320_0000 { return msrImmediate }
            return opcode
        case 2:
            return transferImmediate + UInt8((op >> 20) & 1) * 2 + UInt8((op >> 22) & 1)
        case 3:
            if op & 0x10 != 0 { return undefined }
            return transferRegister + UInt8((op >> 20) & 1) * 2 + UInt8((op >> 22) & 1)
        case 4:
            return block
        case 5:
            return op & (1 << 24) != 0 ? branchLink : branch
        case 6:
            return none  // LDC/STC: no coprocessor on the DS uses them
        default:
            if op & (1 << 24) != 0 { return softwareInterrupt }
            return op & 0x10 != 0 ? coprocessor : none
        }
    }

    static func makeTable() -> UnsafeMutablePointer<UInt8> {
        let table = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        for i in 0..<4096 { table[i] = classify(i) }
        return table
    }
}

extension ARM {
    @usableFromInline func executeARM(_ op: UInt32, address: UInt32) {
        let cond = op >> 28
        if cond != 0xE && !conditionPassed(cond) {
            // ARMv5 "never" space holds unconditional instructions: BLX imm, PLD.
            if cond == 0xF && isV5 && op & 0x0E00_0000 == 0x0A00_0000 {
                blxImmediate(op, address: address)
            }
            return
        }

        switch armDecodeTable[Int((op >> 16) & 0xFF0 | (op >> 4) & 0xF)] {
        case 0: dataProcessingImmediate(op, opcode: 0)  // AND
        case 1: dataProcessingImmediate(op, opcode: 1)  // EOR
        case 2: dataProcessingImmediate(op, opcode: 2)  // SUB
        case 3: dataProcessingImmediate(op, opcode: 3)  // RSB
        case 4: dataProcessingImmediate(op, opcode: 4)  // ADD
        case 5: dataProcessingImmediate(op, opcode: 5)  // ADC
        case 6: dataProcessingImmediate(op, opcode: 6)  // SBC
        case 7: dataProcessingImmediate(op, opcode: 7)  // RSC
        case 8: dataProcessingImmediate(op, opcode: 8)  // TST
        case 9: dataProcessingImmediate(op, opcode: 9)  // TEQ
        case 10: dataProcessingImmediate(op, opcode: 10)  // CMP
        case 11: dataProcessingImmediate(op, opcode: 11)  // CMN
        case 12: dataProcessingImmediate(op, opcode: 12)  // ORR
        case 13: dataProcessingImmediate(op, opcode: 13)  // MOV
        case 14: dataProcessingImmediate(op, opcode: 14)  // BIC
        case 15: dataProcessingImmediate(op, opcode: 15)  // MVN
        case 16: dataProcessingShiftImmediate(op, opcode: 0)
        case 17: dataProcessingShiftImmediate(op, opcode: 1)
        case 18: dataProcessingShiftImmediate(op, opcode: 2)
        case 19: dataProcessingShiftImmediate(op, opcode: 3)
        case 20: dataProcessingShiftImmediate(op, opcode: 4)
        case 21: dataProcessingShiftImmediate(op, opcode: 5)
        case 22: dataProcessingShiftImmediate(op, opcode: 6)
        case 23: dataProcessingShiftImmediate(op, opcode: 7)
        case 24: dataProcessingShiftImmediate(op, opcode: 8)
        case 25: dataProcessingShiftImmediate(op, opcode: 9)
        case 26: dataProcessingShiftImmediate(op, opcode: 10)
        case 27: dataProcessingShiftImmediate(op, opcode: 11)
        case 28: dataProcessingShiftImmediate(op, opcode: 12)
        case 29: dataProcessingShiftImmediate(op, opcode: 13)
        case 30: dataProcessingShiftImmediate(op, opcode: 14)
        case 31: dataProcessingShiftImmediate(op, opcode: 15)
        case 32: dataProcessingShiftRegister(op, opcode: 0)
        case 33: dataProcessingShiftRegister(op, opcode: 1)
        case 34: dataProcessingShiftRegister(op, opcode: 2)
        case 35: dataProcessingShiftRegister(op, opcode: 3)
        case 36: dataProcessingShiftRegister(op, opcode: 4)
        case 37: dataProcessingShiftRegister(op, opcode: 5)
        case 38: dataProcessingShiftRegister(op, opcode: 6)
        case 39: dataProcessingShiftRegister(op, opcode: 7)
        case 40: dataProcessingShiftRegister(op, opcode: 8)
        case 41: dataProcessingShiftRegister(op, opcode: 9)
        case 42: dataProcessingShiftRegister(op, opcode: 10)
        case 43: dataProcessingShiftRegister(op, opcode: 11)
        case 44: dataProcessingShiftRegister(op, opcode: 12)
        case 45: dataProcessingShiftRegister(op, opcode: 13)
        case 46: dataProcessingShiftRegister(op, opcode: 14)
        case 47: dataProcessingShiftRegister(op, opcode: 15)
        case 48:
            let rot = ((op >> 8) & 0xF) * 2
            msr(op, operand: (op & 0xFF).rotatedRight(rot))
        case 49: miscellaneous(op, address: address)
        case 50: multiply(op)
        case 51: multiplyLong(op)
        case 52:
            if op & 0xF00 == 0 { swap(op) } else { halfwordTransfer(op) }
        case 53: halfwordTransfer(op)
        case 54: singleDataTransfer(op, offset: op & 0xFFF, load: false, byte: false)
        case 55: singleDataTransfer(op, offset: op & 0xFFF, load: false, byte: true)
        case 56: singleDataTransfer(op, offset: op & 0xFFF, load: true, byte: false)
        case 57: singleDataTransfer(op, offset: op & 0xFFF, load: true, byte: true)
        case 58: singleDataTransfer(op, offset: registerOffset(op), load: false, byte: false)
        case 59: singleDataTransfer(op, offset: registerOffset(op), load: false, byte: true)
        case 60: singleDataTransfer(op, offset: registerOffset(op), load: true, byte: false)
        case 61: singleDataTransfer(op, offset: registerOffset(op), load: true, byte: true)
        case 62: undefinedInstruction(address)
        case 63: blockDataTransfer(op)
        case 64:
            branch(to: regs[15] &+ (op & 0x00FF_FFFF).signExtended(bits: 24) << 2)
        case 65:
            regs[14] = address &+ 4
            branch(to: regs[15] &+ (op & 0x00FF_FFFF).signExtended(bits: 24) << 2)
        case 66: softwareInterrupt((op >> 16) & 0xFF, returnAddress: address &+ 4)
        case 67: coprocessorRegisterTransfer(op)
        default: break
        }
    }

    @inline(__always) func registerOffset(_ op: UInt32) -> UInt32 {
        shiftImmediate((op >> 5) & 3, regs[Int(op & 0xF)], (op >> 7) & 0x1F).0
    }

    // MARK: - Data processing operand forms

    @inline(__always) func dataProcessingImmediate(_ op: UInt32, opcode: UInt32) {
        let rot = ((op >> 8) & 0xF) * 2
        let imm = (op & 0xFF).rotatedRight(rot)
        let c = rot == 0 ? cpsr & PSR.c != 0 : imm >> 31 != 0
        dataProcessing(op, opcode: opcode, operand2: imm, shifterCarry: c)
    }

    @inline(__always) func dataProcessingShiftImmediate(_ op: UInt32, opcode: UInt32) {
        let (v, c) = shiftImmediate((op >> 5) & 3, regs[Int(op & 0xF)], (op >> 7) & 0x1F)
        dataProcessing(op, opcode: opcode, operand2: v, shifterCarry: c)
    }

    @inline(__always) func dataProcessingShiftRegister(_ op: UInt32, opcode: UInt32) {
        // Shift by register: the PC reads one word further ahead.
        let rm = Int(op & 0xF)
        var value = regs[rm]
        if rm == 15 { value &+= 4 }
        let (v, c) = shiftRegister((op >> 5) & 3, value, regs[Int((op >> 8) & 0xF)] & 0xFF)
        dataProcessing(op, opcode: opcode, operand2: v, shifterCarry: c, registerShift: true)
    }

    // MARK: - Miscellaneous: BX, BLX, CLZ, QADD, SMLAxy, BKPT, MRS, MSR

    // These live where TST/TEQ/CMP/CMN would have S clear.
    func miscellaneous(_ op: UInt32, address: UInt32) {
        if op & 0x0FFF_FFF0 == 0x012F_FF10 { branchExchange(to: regs[Int(op & 0xF)]); return }
        if isV5 {
            if op & 0x0FFF_FFF0 == 0x012F_FF30 {
                let target = regs[Int(op & 0xF)]
                regs[14] = address &+ 4
                branchExchange(to: target)
                return
            }
            if op & 0x0FFF_0FF0 == 0x016F_0F10 {
                regs[Int((op >> 12) & 0xF)] = UInt32(regs[Int(op & 0xF)].leadingZeroBitCount)
                return
            }
            if op & 0x0F90_0FF0 == 0x0100_0050 { saturatingArithmetic(op); return }
            if op & 0x0F90_0090 == 0x0100_0080 { signedHalfwordMultiply(op); return }
            if op & 0x0FF0_00F0 == 0x0120_0070 { prefetchAbort(address); return }  // BKPT
        }
        if op & 0x0FBF_0FFF == 0x010F_0000 {
            regs[Int((op >> 12) & 0xF)] = op & (1 << 22) != 0 ? spsr : cpsr
            return
        }
        if op & 0x0FB0_FFF0 == 0x0120_F000 { msr(op, operand: regs[Int(op & 0xF)]); return }
        undefinedInstruction(address)
    }

    // MARK: - Data processing

    @inline(__always)
    func dataProcessing(_ op: UInt32, opcode: UInt32, operand2 b: UInt32, shifterCarry: Bool, registerShift: Bool = false) {
        let s = op & (1 << 20) != 0
        let rn = Int((op >> 16) & 0xF)
        let rd = Int((op >> 12) & 0xF)
        var a = regs[rn]
        if rn == 15 && registerShift { a &+= 4 }
        // Writing r15 with S set returns from an exception: flags come from SPSR instead.
        let flags = s && rd != 15

        let result: UInt32
        switch opcode {
        case 0x0: result = a & b; if flags { setNZC(result, shifterCarry) }
        case 0x1: result = a ^ b; if flags { setNZC(result, shifterCarry) }
        case 0x2: result = addWithCarry(a, ~b, 1, setFlags: flags)
        case 0x3: result = addWithCarry(b, ~a, 1, setFlags: flags)
        case 0x4: result = addWithCarry(a, b, 0, setFlags: flags)
        case 0x5: result = addWithCarry(a, b, carry, setFlags: flags)
        case 0x6: result = addWithCarry(a, ~b, carry, setFlags: flags)
        case 0x7: result = addWithCarry(b, ~a, carry, setFlags: flags)
        case 0x8: setNZC(a & b, shifterCarry); return
        case 0x9: setNZC(a ^ b, shifterCarry); return
        case 0xA: _ = addWithCarry(a, ~b, 1, setFlags: true); return
        case 0xB: _ = addWithCarry(a, b, 0, setFlags: true); return
        case 0xC: result = a | b; if flags { setNZC(result, shifterCarry) }
        case 0xD: result = b; if flags { setNZC(result, shifterCarry) }
        case 0xE: result = a & ~b; if flags { setNZC(result, shifterCarry) }
        default: result = ~b; if flags { setNZC(result, shifterCarry) }
        }

        if rd == 15 {
            if s {
                setCPSR(spsr)
                branch(to: result)
            } else {
                branch(to: result)
            }
        } else {
            regs[rd] = result
        }
    }

    // MARK: - PSR transfer

    func msr(_ op: UInt32, operand: UInt32) {
        var mask: UInt32 = 0
        if op & (1 << 16) != 0 { mask |= 0x0000_00FF }
        if op & (1 << 17) != 0 { mask |= 0x0000_FF00 }
        if op & (1 << 18) != 0 { mask |= 0x00FF_0000 }
        if op & (1 << 19) != 0 { mask |= 0xFF00_0000 }

        if op & (1 << 22) != 0 {
            if hasSPSR { spsr = (spsr & ~mask) | (operand & mask) }
            return
        }
        // User mode may only change flags. MSR never changes the T bit.
        if cpsr & PSR.modeMask == ARMMode.user.rawValue { mask &= 0xFF00_0000 }
        mask &= ~PSR.t
        let value = (cpsr & ~mask) | (operand & mask)
        setCPSR(value | 0x10)  // bit 4 of the mode is always set
    }

    // MARK: - Multiply

    func multiply(_ op: UInt32) {
        let rd = Int((op >> 16) & 0xF)
        var result = regs[Int(op & 0xF)] &* regs[Int((op >> 8) & 0xF)]
        if op & (1 << 21) != 0 { result &+= regs[Int((op >> 12) & 0xF)] }
        regs[rd] = result
        if op & (1 << 20) != 0 { setNZ(result) }
    }

    func multiplyLong(_ op: UInt32) {
        let rdHi = Int((op >> 16) & 0xF), rdLo = Int((op >> 12) & 0xF)
        let rs = regs[Int((op >> 8) & 0xF)], rm = regs[Int(op & 0xF)]
        var result: UInt64
        if op & (1 << 22) != 0 {
            result = UInt64(bitPattern: Int64(Int32(bitPattern: rm)) &* Int64(Int32(bitPattern: rs)))
        } else {
            result = UInt64(rm) &* UInt64(rs)
        }
        if op & (1 << 21) != 0 { result &+= UInt64(regs[rdHi]) << 32 | UInt64(regs[rdLo]) }
        regs[rdLo] = UInt32(truncatingIfNeeded: result)
        regs[rdHi] = UInt32(truncatingIfNeeded: result >> 32)
        if op & (1 << 20) != 0 {
            cpsr = (cpsr & ~(PSR.n | PSR.z)) | (result >> 63 != 0 ? PSR.n : 0) | (result == 0 ? PSR.z : 0)
        }
    }

    /// SMLAxy, SMLAWy, SMULWy, SMLALxy, SMULxy (ARMv5TE).
    func signedHalfwordMultiply(_ op: UInt32) {
        let rd = Int((op >> 16) & 0xF), rn = Int((op >> 12) & 0xF)
        let rm = regs[Int(op & 0xF)], rs = regs[Int((op >> 8) & 0xF)]
        let x = op & (1 << 5) != 0, y = op & (1 << 6) != 0
        switch (op >> 21) & 3 {
        case 0:  // SMLAxy
            let product = UInt32(bitPattern: halfword(rm, top: x) &* halfword(rs, top: y))
            let (sum, o) = Int32(bitPattern: product).addingReportingOverflow(Int32(bitPattern: regs[rn]))
            if o { cpsr |= PSR.q }
            regs[rd] = UInt32(bitPattern: sum)
        case 1:  // SMLAWy / SMULWy
            let product = Int64(Int32(bitPattern: rm)) &* Int64(halfword(rs, top: y))
            let high = UInt32(truncatingIfNeeded: product >> 16)
            if x {
                regs[rd] = high
            } else {
                let (sum, o) = Int32(bitPattern: high).addingReportingOverflow(Int32(bitPattern: regs[rn]))
                if o { cpsr |= PSR.q }
                regs[rd] = UInt32(bitPattern: sum)
            }
        case 2:  // SMLALxy: RdHi = rd, RdLo = rn
            let product = Int64(halfword(rm, top: x) &* halfword(rs, top: y))
            let acc = Int64(bitPattern: UInt64(regs[rd]) << 32 | UInt64(regs[rn])) &+ product
            regs[rn] = UInt32(truncatingIfNeeded: acc)
            regs[rd] = UInt32(truncatingIfNeeded: acc >> 32)
        default:  // SMULxy
            regs[rd] = UInt32(bitPattern: halfword(rm, top: x) &* halfword(rs, top: y))
        }
    }

    /// QADD, QSUB, QDADD, QDSUB (ARMv5TE).
    func saturatingArithmetic(_ op: UInt32) {
        let rd = Int((op >> 12) & 0xF)
        let rm = regs[Int(op & 0xF)]
        var rn = regs[Int((op >> 16) & 0xF)]
        let opcode = (op >> 21) & 3
        if opcode & 2 != 0 { rn = saturatingAdd(rn, rn) }
        regs[rd] = opcode & 1 != 0 ? saturatingSub(rm, rn) : saturatingAdd(rm, rn)
    }

    // MARK: - Loads and stores

    /// `load` and `byte` come from bits 20 and 22, passed as literals by the dispatcher.
    @inline(__always) func singleDataTransfer(_ op: UInt32, offset: UInt32, load: Bool, byte: Bool) {
        let pre = op & (1 << 24) != 0
        let up = op & (1 << 23) != 0
        let writeBack = op & (1 << 21) != 0 || !pre
        let rn = Int((op >> 16) & 0xF), rd = Int((op >> 12) & 0xF)

        let base = regs[rn]
        let offsetAddress = up ? base &+ offset : base &- offset
        let address = pre ? offsetAddress : base

        if load {
            let value = byte ? UInt32(bus.read8(address)) : loadWord(address)
            if writeBack { regs[rn] = offsetAddress }
            if rd == 15 { loadPC(value) } else { regs[rd] = value }
        } else {
            var value = regs[rd]
            if rd == 15 { value &+= 4 }
            if byte { bus.write8(address, UInt8(truncatingIfNeeded: value)) } else { bus.write32(address & ~3, value) }
            if writeBack { setReg(rn, offsetAddress) }
        }
    }

    func halfwordTransfer(_ op: UInt32) {
        let pre = op & (1 << 24) != 0
        let up = op & (1 << 23) != 0
        let immediate = op & (1 << 22) != 0
        let writeBack = op & (1 << 21) != 0 || !pre
        let load = op & (1 << 20) != 0
        let rn = Int((op >> 16) & 0xF), rd = Int((op >> 12) & 0xF)
        let kind = (op >> 5) & 3

        let offset = immediate ? ((op >> 4) & 0xF0) | (op & 0xF) : regs[Int(op & 0xF)]
        let base = regs[rn]
        let offsetAddress = up ? base &+ offset : base &- offset
        let address = pre ? offsetAddress : base

        if load {
            let value: UInt32
            switch kind {
            case 1: value = loadHalf(address)
            case 2: value = loadSignedByte(address)
            default: value = loadSignedHalf(address)
            }
            if writeBack { regs[rn] = offsetAddress }
            setReg(rd, value)
            return
        }

        switch kind {
        case 1:  // STRH
            bus.write16(address & ~1, UInt16(truncatingIfNeeded: regs[rd]))
            if writeBack { setReg(rn, offsetAddress) }
        case 2:  // LDRD (ARMv5TE)
            guard isV5 else { return }
            let low = bus.read32(address & ~3), high = bus.read32((address & ~3) &+ 4)
            if writeBack { regs[rn] = offsetAddress }
            regs[rd & ~1] = low
            setReg((rd & ~1) + 1, high)
        default:  // STRD (ARMv5TE)
            guard isV5 else { return }
            bus.write32(address & ~3, regs[rd & ~1])
            bus.write32((address & ~3) &+ 4, regs[(rd & ~1) + 1])
            if writeBack { setReg(rn, offsetAddress) }
        }
    }

    func swap(_ op: UInt32) {
        let rn = Int((op >> 16) & 0xF), rd = Int((op >> 12) & 0xF), rm = Int(op & 0xF)
        let address = regs[rn]
        if op & (1 << 22) != 0 {
            let old = bus.read8(address)
            bus.write8(address, UInt8(truncatingIfNeeded: regs[rm]))
            regs[rd] = UInt32(old)
        } else {
            let old = loadWord(address)
            bus.write32(address & ~3, regs[rm])
            regs[rd] = old
        }
    }

    func blockDataTransfer(_ op: UInt32) {
        let pre = op & (1 << 24) != 0
        let up = op & (1 << 23) != 0
        let psrOrUser = op & (1 << 22) != 0
        let writeBack = op & (1 << 21) != 0
        let load = op & (1 << 20) != 0
        let rn = Int((op >> 16) & 0xF)
        var list = op & 0xFFFF

        // An empty list transfers r15 and moves the base by 64 bytes (ARMv4/v5 behaviour).
        let emptyList = list == 0
        if emptyList { list = 1 << 15 }
        let count = UInt32(emptyList ? 16 : list.nonzeroBitCount)

        let base = regs[rn]
        let low: UInt32 = up ? base : base &- count * 4
        let finalBase: UInt32 = up ? base &+ count * 4 : base &- count * 4
        var address = (pre == up) ? low &+ 4 : low

        // S bit without a PC load means "use the user-mode registers".
        let loadsPC = list & (1 << 15) != 0
        let userBank = psrOrUser && !(load && loadsPC)
        let savedMode = cpsr & PSR.modeMask
        if userBank { switchMode(ARMMode.user.rawValue) }

        let firstRegister = list.trailingZeroBitCount
        var baseInList = false
        for i in 0..<16 where list & (1 << UInt32(i)) != 0 {
            if load {
                let value = bus.read32(address & ~3)
                if i == rn { baseInList = true }
                if i == 15 {
                    loadPC(value)
                } else {
                    regs[i] = value
                }
            } else {
                var value = regs[i]
                if i == 15 { value &+= 4 }
                // Storing the base after it was written back stores the new value on ARMv4.
                if i == rn && i != firstRegister && writeBack && !isV5 { value = finalBase }
                bus.write32(address & ~3, value)
            }
            address &+= 4
        }

        if userBank { switchMode(savedMode) }
        if writeBack && !(load && baseInList) { regs[rn] = finalBase }
        if load && loadsPC && psrOrUser {
            let target = regs[15]
            setCPSR(spsr)
            branch(to: target)
        }
    }

    // MARK: - Branches and exceptions

    func blxImmediate(_ op: UInt32, address: UInt32) {
        let offset = (op & 0x00FF_FFFF).signExtended(bits: 24) << 2 | ((op >> 23) & 2)
        regs[14] = address &+ 4
        branchExchange(to: (regs[15] &+ offset) | 1)
    }

    func softwareInterrupt(_ number: UInt32, returnAddress: UInt32) {
        if hleBIOS && bus.hleSWI(number, cpu: self) { return }
        enterException(vector: 0x08, mode: .supervisor, returnAddress: returnAddress)
    }

    func undefinedInstruction(_ address: UInt32) {
        enterException(vector: 0x04, mode: .undefined, returnAddress: address &+ (thumb ? 2 : 4))
    }

    func prefetchAbort(_ address: UInt32) {
        enterException(vector: 0x0C, mode: .abort, returnAddress: address &+ 4)
    }

    func coprocessorRegisterTransfer(_ op: UInt32) {
        guard isV5, (op >> 8) & 0xF == 15 else { return }
        let cn = Int((op >> 16) & 0xF), cm = Int(op & 0xF), cp = Int((op >> 5) & 7)
        let rd = Int((op >> 12) & 0xF)
        if op & (1 << 20) != 0 {
            let value = bus.cp15Read(cn: cn, cm: cm, cp: cp)
            if rd == 15 {
                cpsr = (cpsr & 0x0FFF_FFFF) | (value & 0xF000_0000)
            } else {
                regs[rd] = value
            }
        } else {
            bus.cp15Write(cn: cn, cm: cm, cp: cp, value: regs[rd], cpu: self)
        }
    }
}
