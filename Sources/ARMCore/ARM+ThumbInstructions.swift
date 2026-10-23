// SPDX-License-Identifier: GPL-3.0-or-later
//
// 16-bit Thumb instruction set. `regs[15]` reads as the instruction address + 4.

extension ARM {
    @usableFromInline func executeThumb(_ op16: UInt16, address: UInt32) {
        let op = UInt32(op16)
        switch op >> 11 {
        case 0x00, 0x01, 0x02:  // LSL, LSR, ASR by immediate
            let rd = Int(op & 7)
            let (v, c) = shiftImmediate(op >> 11, regs[Int((op >> 3) & 7)], (op >> 6) & 0x1F)
            regs[rd] = v
            setNZC(v, c)

        case 0x03:  // ADD/SUB register or 3-bit immediate
            let rd = Int(op & 7)
            let a = regs[Int((op >> 3) & 7)]
            let b = op & (1 << 10) != 0 ? (op >> 6) & 7 : regs[Int((op >> 6) & 7)]
            regs[rd] = op & (1 << 9) != 0 ? addWithCarry(a, ~b, 1, setFlags: true) : addWithCarry(a, b, 0, setFlags: true)

        case 0x04:  // MOV imm8
            let rd = Int((op >> 8) & 7)
            regs[rd] = op & 0xFF
            setNZ(op & 0xFF)
        case 0x05:  // CMP imm8
            _ = addWithCarry(regs[Int((op >> 8) & 7)], ~(op & 0xFF), 1, setFlags: true)
        case 0x06:  // ADD imm8
            let rd = Int((op >> 8) & 7)
            regs[rd] = addWithCarry(regs[rd], op & 0xFF, 0, setFlags: true)
        case 0x07:  // SUB imm8
            let rd = Int((op >> 8) & 7)
            regs[rd] = addWithCarry(regs[rd], ~(op & 0xFF), 1, setFlags: true)

        case 0x08:
            if op & (1 << 10) == 0 { thumbALU(op) } else { thumbHighRegister(op, address: address) }

        case 0x09:  // LDR rd, [pc, #imm8*4]
            regs[Int((op >> 8) & 7)] = bus.read32((regs[15] & ~2) &+ (op & 0xFF) << 2)

        case 0x0A, 0x0B:  // load/store with register offset
            let address = regs[Int((op >> 3) & 7)] &+ regs[Int((op >> 6) & 7)]
            let rd = Int(op & 7)
            switch (op >> 9) & 7 {
            case 0: storeWord(address, regs[rd])
            case 1: storeHalf(address, regs[rd])
            case 2: bus.write8(address, UInt8(truncatingIfNeeded: regs[rd]))
            case 3: regs[rd] = loadSignedByte(address)
            case 4: regs[rd] = loadWord(address)
            case 5: regs[rd] = loadHalf(address)
            case 6: regs[rd] = UInt32(bus.read8(address))
            default: regs[rd] = loadSignedHalf(address)
            }

        case 0x0C:  // STR rd, [rb, #imm5*4]
            storeWord(regs[Int((op >> 3) & 7)] &+ ((op >> 6) & 0x1F) << 2, regs[Int(op & 7)])
        case 0x0D:  // LDR
            regs[Int(op & 7)] = loadWord(regs[Int((op >> 3) & 7)] &+ ((op >> 6) & 0x1F) << 2)
        case 0x0E:  // STRB
            bus.write8(regs[Int((op >> 3) & 7)] &+ ((op >> 6) & 0x1F), UInt8(truncatingIfNeeded: regs[Int(op & 7)]))
        case 0x0F:  // LDRB
            regs[Int(op & 7)] = UInt32(bus.read8(regs[Int((op >> 3) & 7)] &+ ((op >> 6) & 0x1F)))
        case 0x10:  // STRH
            let address = regs[Int((op >> 3) & 7)] &+ ((op >> 6) & 0x1F) << 1
            storeHalf(address, regs[Int(op & 7)])
        case 0x11:  // LDRH
            regs[Int(op & 7)] = loadHalf(regs[Int((op >> 3) & 7)] &+ ((op >> 6) & 0x1F) << 1)

        case 0x12:  // STR rd, [sp, #imm8*4]
            storeWord(regs[13] &+ (op & 0xFF) << 2, regs[Int((op >> 8) & 7)])
        case 0x13:  // LDR rd, [sp, #imm8*4]
            regs[Int((op >> 8) & 7)] = loadWord(regs[13] &+ (op & 0xFF) << 2)

        case 0x14:  // ADD rd, pc, #imm8*4
            regs[Int((op >> 8) & 7)] = (regs[15] & ~2) &+ (op & 0xFF) << 2
        case 0x15:  // ADD rd, sp, #imm8*4
            regs[Int((op >> 8) & 7)] = regs[13] &+ (op & 0xFF) << 2

        case 0x16, 0x17:
            thumbMisc(op, address: address)

        case 0x18:  // STMIA rb!, {rlist}
            let rb = Int((op >> 8) & 7)
            var address = regs[rb]
            let list = op & 0xFF
            for i in 0..<8 where list & (1 << UInt32(i)) != 0 {
                bus.write32(address & ~3, regs[i])
                address &+= 4
            }
            regs[rb] = address
        case 0x19:  // LDMIA rb!, {rlist}
            let rb = Int((op >> 8) & 7)
            var address = regs[rb]
            let list = op & 0xFF
            for i in 0..<8 where list & (1 << UInt32(i)) != 0 {
                regs[i] = bus.read32(address & ~3)
                address &+= 4
            }
            if list & (1 << UInt32(rb)) == 0 { regs[rb] = address }

        case 0x1A, 0x1B:  // conditional branch, SWI
            let cond = (op >> 8) & 0xF
            if cond == 0xF {
                softwareInterrupt(op & 0xFF, returnAddress: address &+ 2)
            } else if cond == 0xE {
                undefinedInstruction(address)
            } else if conditionPassed(cond) {
                branch(to: regs[15] &+ ((op & 0xFF).signExtended(bits: 8) << 1))
            }

        case 0x1C:  // B
            branch(to: regs[15] &+ ((op & 0x7FF).signExtended(bits: 11) << 1))

        case 0x1D:  // BLX suffix (ARMv5): switch to ARM
            guard isV5 else { undefinedInstruction(address); return }
            let target = (regs[14] &+ (op & 0x7FF) << 1) & ~3
            regs[14] = (address &+ 2) | 1
            branchExchange(to: target)

        case 0x1E:  // BL/BLX prefix
            regs[14] = regs[15] &+ ((op & 0x7FF).signExtended(bits: 11) << 12)

        default:  // 0x1F: BL suffix
            let target = regs[14] &+ (op & 0x7FF) << 1
            regs[14] = (address &+ 2) | 1
            branch(to: target)
        }
    }

    func thumbALU(_ op: UInt32) {
        let rd = Int(op & 7)
        let a = regs[rd], b = regs[Int((op >> 3) & 7)]
        switch (op >> 6) & 0xF {
        case 0x0: regs[rd] = a & b; setNZ(regs[rd])
        case 0x1: regs[rd] = a ^ b; setNZ(regs[rd])
        case 0x2: let (v, c) = shiftRegister(0, a, b & 0xFF); regs[rd] = v; setNZC(v, c)
        case 0x3: let (v, c) = shiftRegister(1, a, b & 0xFF); regs[rd] = v; setNZC(v, c)
        case 0x4: let (v, c) = shiftRegister(2, a, b & 0xFF); regs[rd] = v; setNZC(v, c)
        case 0x5: regs[rd] = addWithCarry(a, b, carry, setFlags: true)
        case 0x6: regs[rd] = addWithCarry(a, ~b, carry, setFlags: true)
        case 0x7: let (v, c) = shiftRegister(3, a, b & 0xFF); regs[rd] = v; setNZC(v, c)
        case 0x8: setNZ(a & b)
        case 0x9: regs[rd] = addWithCarry(0, ~b, 1, setFlags: true)  // NEG
        case 0xA: _ = addWithCarry(a, ~b, 1, setFlags: true)
        case 0xB: _ = addWithCarry(a, b, 0, setFlags: true)
        case 0xC: regs[rd] = a | b; setNZ(regs[rd])
        case 0xD: regs[rd] = a &* b; setNZ(regs[rd])
        case 0xE: regs[rd] = a & ~b; setNZ(regs[rd])
        default: regs[rd] = ~b; setNZ(regs[rd])
        }
    }

    /// ADD, CMP, MOV on r8-r15, and BX/BLX.
    func thumbHighRegister(_ op: UInt32, address: UInt32) {
        let rd = Int((op & 7) | ((op >> 4) & 8))
        let rs = Int((op >> 3) & 0xF)
        switch (op >> 8) & 3 {
        case 0: setReg(rd, regs[rd] &+ regs[rs])
        case 1: _ = addWithCarry(regs[rd], ~regs[rs], 1, setFlags: true)
        case 2: setReg(rd, regs[rs])
        default:
            let target = regs[rs]
            if op & (1 << 7) != 0 && isV5 { regs[14] = (address &+ 2) | 1 }
            branchExchange(to: target)
        }
    }

    /// ADD SP, PUSH, POP, BKPT, and on ARMv6 extend, reverse and CPS.
    func thumbMisc(_ op: UInt32, address: UInt32) {
        switch (op >> 8) & 0xF {
        case 0x0:  // ADD SP, #±imm7*4
            let offset = (op & 0x7F) << 2
            regs[13] = op & (1 << 7) != 0 ? regs[13] &- offset : regs[13] &+ offset
        case 0x4, 0x5:  // PUSH {rlist, lr}
            let list = op & 0xFF
            let withLR = op & (1 << 8) != 0
            let count = UInt32(list.nonzeroBitCount) + (withLR ? 1 : 0)
            var sp = regs[13] &- count * 4
            regs[13] = sp
            for i in 0..<8 where list & (1 << UInt32(i)) != 0 {
                bus.write32(sp & ~3, regs[i])
                sp &+= 4
            }
            if withLR { bus.write32(sp & ~3, regs[14]) }
        case 0xC, 0xD:  // POP {rlist, pc}
            let list = op & 0xFF
            var sp = regs[13]
            for i in 0..<8 where list & (1 << UInt32(i)) != 0 {
                regs[i] = bus.read32(sp & ~3)
                sp &+= 4
            }
            if op & (1 << 8) != 0 {
                let value = bus.read32(sp & ~3)
                sp &+= 4
                regs[13] = sp
                loadPC(value)
            } else {
                regs[13] = sp
            }
        case 0x2 where isV6: thumbExtend(op)
        case 0x6 where isV6: thumbChangeState(op, address: address)
        case 0xA where isV6: thumbReverse(op, address: address)
        case 0xE:  // BKPT (ARMv5)
            if isV5 { prefetchAbort(address) } else { undefinedInstruction(address) }
        default:
            undefinedInstruction(address)
        }
    }
}
