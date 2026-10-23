// SPDX-License-Identifier: GPL-3.0-or-later
//
// The ARM fast path. Every handler either completes its instruction or returns
// CARMExitSlow before changing any state, so the Swift interpreter can run that
// instruction from scratch. Encodings from the ARM Architecture Reference Manual
// (ARMv6); instructions that ARMv4 or ARMv5 lack or run differently go back to
// the interpreter on those cores.

#include "carm.h"

#include <string.h>

#define N_FLAG 0x80000000u
#define Z_FLAG 0x40000000u
#define C_FLAG 0x20000000u
#define V_FLAG 0x10000000u
#define T_FLAG 0x00000020u

#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)

/// Bit `cond` of entry NZCV says whether condition `cond` passes.
static uint16_t condition_table[16];
static int condition_table_ready;

static void build_condition_table(void) {
    for (int flags = 0; flags < 16; flags++) {
        int n = (flags >> 3) & 1, z = (flags >> 2) & 1, c = (flags >> 1) & 1, v = flags & 1;
        int pass[16] = {
            z, !z, c, !c, n, !n, v, !v,
            c && !z, !c || z, n == v, n != v, !z && n == v, z || n != v, 1, 0,
        };
        uint16_t bits = 0;
        for (int cond = 0; cond < 16; cond++) if (pass[cond]) bits |= (uint16_t)(1u << cond);
        condition_table[flags] = bits;
    }
    condition_table_ready = 1;
}

static inline uint8_t *host(const CARMState *s, uint32_t address) {
    uint8_t *page = s->pages[address >> 12];
    return page ? page + (address & 0xFFF) : NULL;
}

/// A pointer to `size` bytes at `address` within one page, or NULL.
static inline uint8_t *span(const CARMState *s, uint32_t address, uint32_t size) {
    if (UNLIKELY((address & 0xFFF) + size > 0x1000)) return NULL;
    return host(s, address);
}

static inline uint32_t load32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static inline uint16_t load16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }
static inline void store32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static inline void store16(uint8_t *p, uint16_t v) { memcpy(p, &v, 2); }

static inline uint32_t ror32(uint32_t v, uint32_t r) { r &= 31; return r ? (v >> r) | (v << (32 - r)) : v; }

static inline uint32_t nz(uint32_t cpsr, uint32_t result) {
    cpsr &= ~(N_FLAG | Z_FLAG);
    cpsr |= result & N_FLAG;
    if (result == 0) cpsr |= Z_FLAG;
    return cpsr;
}

/// Shift by an immediate amount, as in data processing and LDR/STR register offsets.
static inline __attribute__((always_inline)) uint32_t shift_immediate(uint32_t value, uint32_t type, uint32_t amount, uint32_t cpsr, uint32_t *carry) {
    switch (type) {
    case 0:  // LSL
        if (amount == 0) { *carry = (cpsr >> 29) & 1; return value; }
        *carry = (value >> (32 - amount)) & 1;
        return value << amount;
    case 1:  // LSR, 0 means 32
        if (amount == 0) { *carry = value >> 31; return 0; }
        *carry = (value >> (amount - 1)) & 1;
        return value >> amount;
    case 2:  // ASR, 0 means 32
        if (amount == 0) { *carry = value >> 31; return (uint32_t)((int32_t)value >> 31); }
        *carry = (value >> (amount - 1)) & 1;
        return (uint32_t)((int32_t)value >> amount);
    default:  // ROR, 0 means RRX
        if (amount == 0) {
            *carry = value & 1;
            return (value >> 1) | (((cpsr >> 29) & 1) << 31);
        }
        *carry = (value >> (amount - 1)) & 1;
        return ror32(value, amount);
    }
}

/// Shift by a register amount (bottom byte).
static inline uint32_t shift_register(uint32_t value, uint32_t type, uint32_t amount, uint32_t cpsr, uint32_t *carry) {
    uint32_t c = (cpsr >> 29) & 1;
    if (amount == 0) { *carry = c; return value; }
    switch (type) {
    case 0:
        if (amount < 32) { *carry = (value >> (32 - amount)) & 1; return value << amount; }
        *carry = amount == 32 ? (value & 1) : 0;
        return 0;
    case 1:
        if (amount < 32) { *carry = (value >> (amount - 1)) & 1; return value >> amount; }
        *carry = amount == 32 ? (value >> 31) : 0;
        return 0;
    case 2:
        if (amount < 32) { *carry = (value >> (amount - 1)) & 1; return (uint32_t)((int32_t)value >> amount); }
        *carry = value >> 31;
        return (uint32_t)((int32_t)value >> 31);
    default:
        amount &= 31;
        if (amount == 0) { *carry = value >> 31; return value; }
        *carry = (value >> (amount - 1)) & 1;
        return ror32(value, amount);
    }
}

/// Data processing. Returns 0 when it needs the slow path (S with Rd = PC).
static inline __attribute__((always_inline)) int data_processing(uint32_t *cpsr_io, uint32_t *regs, uint32_t op, uint32_t pc, uint32_t *next_pc,
                                                                  const uint32_t opcode, const int form) {
    uint32_t setFlags = (op >> 20) & 1;
    uint32_t rd = (op >> 12) & 0xF, rn = (op >> 16) & 0xF;
    uint32_t cpsr = *cpsr_io;
    if (UNLIKELY(rd == 15 && setFlags)) return 0;

    uint32_t operand2, carry;
    uint32_t rnValue;
    if (form == 0) {
        uint32_t rotate = ((op >> 8) & 0xF) * 2;
        operand2 = ror32(op & 0xFF, rotate);
        carry = rotate ? operand2 >> 31 : (cpsr >> 29) & 1;
        rnValue = rn == 15 ? pc + 8 : regs[rn];
    } else if (form == 2) {
        uint32_t rm = op & 0xF, rs = (op >> 8) & 0xF;
        uint32_t rmValue = rm == 15 ? pc + 12 : regs[rm];
        uint32_t amount = (rs == 15 ? pc + 8 : regs[rs]) & 0xFF;
        operand2 = shift_register(rmValue, (op >> 5) & 3, amount, cpsr, &carry);
        rnValue = rn == 15 ? pc + 12 : regs[rn];
    } else {
        uint32_t rm = op & 0xF;
        uint32_t rmValue = rm == 15 ? pc + 8 : regs[rm];
        operand2 = shift_immediate(rmValue, (op >> 5) & 3, (op >> 7) & 0x1F, cpsr, &carry);
        rnValue = rn == 15 ? pc + 8 : regs[rn];
    }

    uint32_t result;
    uint64_t wide;
    int writes = 1, arithmetic = 0;
    uint32_t c = carry, v = (cpsr >> 28) & 1;
    switch (opcode) {
    case 0x0: result = rnValue & operand2; break;
    case 0x1: result = rnValue ^ operand2; break;
    case 0x2:
        result = rnValue - operand2;
        c = rnValue >= operand2;
        v = ((rnValue ^ operand2) & (rnValue ^ result)) >> 31;
        arithmetic = 1;
        break;
    case 0x3:
        result = operand2 - rnValue;
        c = operand2 >= rnValue;
        v = ((operand2 ^ rnValue) & (operand2 ^ result)) >> 31;
        arithmetic = 1;
        break;
    case 0x4:
        wide = (uint64_t)rnValue + operand2;
        result = (uint32_t)wide;
        c = (uint32_t)(wide >> 32);
        v = (~(rnValue ^ operand2) & (rnValue ^ result)) >> 31;
        arithmetic = 1;
        break;
    case 0x5:
        wide = (uint64_t)rnValue + operand2 + ((cpsr >> 29) & 1);
        result = (uint32_t)wide;
        c = (uint32_t)(wide >> 32);
        v = (~(rnValue ^ operand2) & (rnValue ^ result)) >> 31;
        arithmetic = 1;
        break;
    case 0x6: {
        uint32_t borrowIn = 1 - ((cpsr >> 29) & 1);
        wide = (uint64_t)rnValue - operand2 - borrowIn;
        result = (uint32_t)wide;
        c = (uint64_t)rnValue >= (uint64_t)operand2 + borrowIn;
        v = ((rnValue ^ operand2) & (rnValue ^ result)) >> 31;
        arithmetic = 1;
        break;
    }
    case 0x7: {
        uint32_t borrowIn = 1 - ((cpsr >> 29) & 1);
        wide = (uint64_t)operand2 - rnValue - borrowIn;
        result = (uint32_t)wide;
        c = (uint64_t)operand2 >= (uint64_t)rnValue + borrowIn;
        v = ((operand2 ^ rnValue) & (operand2 ^ result)) >> 31;
        arithmetic = 1;
        break;
    }
    case 0x8: result = rnValue & operand2; writes = 0; break;
    case 0x9: result = rnValue ^ operand2; writes = 0; break;
    case 0xA:
        result = rnValue - operand2;
        c = rnValue >= operand2;
        v = ((rnValue ^ operand2) & (rnValue ^ result)) >> 31;
        arithmetic = 1; writes = 0;
        break;
    case 0xB:
        wide = (uint64_t)rnValue + operand2;
        result = (uint32_t)wide;
        c = (uint32_t)(wide >> 32);
        v = (~(rnValue ^ operand2) & (rnValue ^ result)) >> 31;
        arithmetic = 1; writes = 0;
        break;
    case 0xC: result = rnValue | operand2; break;
    case 0xD: result = operand2; break;
    case 0xE: result = rnValue & ~operand2; break;
    default: result = ~operand2; break;
    }

    if (setFlags) {
        cpsr = nz(cpsr, result);
        cpsr = (cpsr & ~C_FLAG) | (c << 29);
        if (arithmetic) cpsr = (cpsr & ~V_FLAG) | (v << 28);
        *cpsr_io = cpsr;
    }
    if (writes) {
        if (rd == 15) *next_pc = result & ~3u;
        else regs[rd] = result;
    }
    return 1;
}


// Instruction kinds, from bits 27-20 and 7-4 of the opcode.
enum {
    K_SLOW = 0,
    K_DPI = 1,    // + opcode: immediate operand
    K_DPS = 17,   // + opcode: register shifted by an immediate
    K_DPR = 33,   // + opcode: register shifted by a register
    K_MUL = 49, K_MULL, K_HALF, K_BX, K_CLZ, K_LDR_IMM, K_LDR_REG, K_MEDIA, K_BLOCK, K_B, K_BL,
    K_COUNT
};

static uint8_t decode_table[4096];

static uint8_t classify(uint32_t hi, uint32_t lo) {
    uint32_t op = hi << 20 | lo << 4;
    switch ((hi >> 5) & 7) {
    case 0:
        if ((lo & 9) == 9) {
            if ((lo & 6) == 0) {
                if (hi & 0x10) return K_SLOW;           // SWP, LDREX, STREX
                return (hi & 8) ? K_MULL : ((hi & 6) == 0 ? K_MUL : K_SLOW);
            }
            return K_HALF;
        }
        if ((hi & 0x19) == 0x10) {
            if (hi == 0x12 && lo == 1) return K_BX;
            if (hi == 0x12 && lo == 3) return K_BX;
            if (hi == 0x16 && lo == 1) return K_CLZ;
            return K_SLOW;
        }
        return (lo & 1) ? K_DPR + ((hi >> 1) & 0xF) : K_DPS + ((hi >> 1) & 0xF);
    case 1:
        if ((hi & 0x19) == 0x10) return K_SLOW;          // MSR immediate, hints
        return K_DPI + ((hi >> 1) & 0xF);
    case 2: return K_LDR_IMM;
    case 3: return (lo & 1) ? K_MEDIA : K_LDR_REG;
    case 4: return (hi & 4) ? K_SLOW : K_BLOCK;           // S bit: user registers or mode change
    case 5: return (hi & 0x10) ? K_BL : K_B;
    default: (void)op; return K_SLOW;
    }
}

static int decode_ready;

static void build_tables(void) {
    build_condition_table();
    for (uint32_t i = 0; i < 4096; i++) decode_table[i] = classify(i >> 4, i & 0xF);
    decode_ready = 1;
}

#define RETIRE() do { cycles++; } while (0)
// `stop` is the earlier of the cycle target and the end of the current code page, so
// sequential code needs one check per instruction. Each handler ends in its own copy
// of the common dispatch path, so the host predicts each indirect jump from the
// handler it leaves.
#define STOP_FOR_PAGE() do { \
    uint64_t page_end = cycles + ((0x1000u - (pc & 0xFFFu)) >> 2); \
    stop = page_end < target ? page_end : target; \
} while (0)
#define DISPATCH_SAME_PAGE() do { \
    op = load32(code_base + (pc & 0xFFF)); \
    if (UNLIKELY(op >> 28 != 0xE)) goto conditional; \
    next = pc + 4; \
    goto *handlers[((op >> 16) & 0xFF0) | ((op >> 4) & 0xF)]; \
} while (0)
#define NEXT_SEQ() do { \
    pc += 4; cycles++; \
    if (UNLIKELY(cycles >= stop)) goto dispatch; \
    DISPATCH_SAME_PAGE(); \
} while (0)
#define NEXT(address) do { \
    pc = (address); cycles++; \
    if (UNLIKELY(cycles >= target || (pc >> 12) != code_tag)) goto dispatch; \
    STOP_FOR_PAGE(); \
    DISPATCH_SAME_PAGE(); \
} while (0)

CARMExit carm_run(CARMState *s) {
    if (UNLIKELY(!decode_ready)) build_tables();
    uint32_t *regs = s->regs;
    uint32_t pc = regs[15];
    uint64_t cycles = s->cycles;
    const uint64_t target = s->target;
    const uint64_t start = cycles;
    uint64_t stop = 0;
    uint32_t cpsr = s->cpsr;
    const uint32_t arch = s->arch;
    // STR and STM of r15 store the instruction's address plus 8 on ARMv6, plus 12 before.
    const uint32_t pc_stored = arch >= 6 ? 8 : 12;
    CARMExit exit_reason = CARMExitTarget;
    uint32_t op = 0;
    uint32_t next = 0;
    uint32_t code_tag = 0xFFFFFFFFu;
    const uint8_t *code_base = NULL;

#define DP(n) &&dpi_##n, 
    static void *const labels[K_COUNT] = {
        &&slow,
        &&dpi_0, &&dpi_1, &&dpi_2, &&dpi_3, &&dpi_4, &&dpi_5, &&dpi_6, &&dpi_7,
        &&dpi_8, &&dpi_9, &&dpi_10, &&dpi_11, &&dpi_12, &&dpi_13, &&dpi_14, &&dpi_15,
        &&dps_0, &&dps_1, &&dps_2, &&dps_3, &&dps_4, &&dps_5, &&dps_6, &&dps_7,
        &&dps_8, &&dps_9, &&dps_10, &&dps_11, &&dps_12, &&dps_13, &&dps_14, &&dps_15,
        &&dpr_0, &&dpr_1, &&dpr_2, &&dpr_3, &&dpr_4, &&dpr_5, &&dpr_6, &&dpr_7,
        &&dpr_8, &&dpr_9, &&dpr_10, &&dpr_11, &&dpr_12, &&dpr_13, &&dpr_14, &&dpr_15,
        &&k_mul, &&k_mull, &&k_half, &&k_bx, &&k_clz, &&k_ldr_imm, &&k_ldr_reg, &&k_media, &&k_block, &&k_b, &&k_bl,
    };
#undef DP
    // Handler addresses by decode index, so dispatch is one load and one jump.
    static void *handlers[4096];
    if (UNLIKELY(handlers[0] == NULL)) {
        for (int i = 0; i < 4096; i++) handlers[i] = labels[decode_table[i]];
    }

dispatch:
    if (UNLIKELY(cycles >= target)) goto out;
    {
        // The current code page is cached: most instructions follow one in the same page.
        if (UNLIKELY((pc >> 12) != code_tag)) {
            code_base = s->code_pages[pc >> 12];
            if (code_base == NULL || (pc & 3)) goto slow;
            code_tag = pc >> 12;
        }
        STOP_FOR_PAGE();
        op = load32(code_base + (pc & 0xFFF));
    }
conditional: {
        uint32_t cond = op >> 28;
        if (cond != 0xE) {
            if (UNLIKELY(cond == 0xF)) {
                // Unconditional space: only BLX immediate here.
                if ((op & 0x0E000000u) != 0x0A000000u || arch < 5) goto slow;
                int32_t offset = ((int32_t)(op << 8) >> 6) | (int32_t)((op >> 23) & 2);
                regs[14] = pc + 4;
                pc = pc + 8 + (uint32_t)offset;
                cpsr |= T_FLAG;
                RETIRE();
                exit_reason = CARMExitThumb;
                goto out;
            }
            if (!((condition_table[cpsr >> 28] >> cond) & 1)) NEXT_SEQ();
        }
        next = pc + 4;
        goto *handlers[((op >> 16) & 0xFF0) | ((op >> 4) & 0xF)];
    }

#define DP_HANDLERS(n) \
    dpi_##n: if (!data_processing(&cpsr, regs, op, pc, &next, n, 0)) goto slow; if (next == pc + 4) NEXT_SEQ(); NEXT(next); \
    dps_##n: if (!data_processing(&cpsr, regs, op, pc, &next, n, 1)) goto slow; if (next == pc + 4) NEXT_SEQ(); NEXT(next); \
    dpr_##n: if (!data_processing(&cpsr, regs, op, pc, &next, n, 2)) goto slow; if (next == pc + 4) NEXT_SEQ(); NEXT(next);
    DP_HANDLERS(0) DP_HANDLERS(1) DP_HANDLERS(2) DP_HANDLERS(3) DP_HANDLERS(4) DP_HANDLERS(5) DP_HANDLERS(6) DP_HANDLERS(7)
    DP_HANDLERS(8) DP_HANDLERS(9) DP_HANDLERS(10) DP_HANDLERS(11) DP_HANDLERS(12) DP_HANDLERS(13) DP_HANDLERS(14) DP_HANDLERS(15)
#undef DP_HANDLERS

k_mul: {
    uint32_t rd = (op >> 16) & 0xF, rn = (op >> 12) & 0xF, rs = (op >> 8) & 0xF, rm = op & 0xF;
    if (rd == 15 || rm == 15 || rs == 15) goto slow;
    uint32_t result = regs[rm] * regs[rs];
    if (op & (1u << 21)) { if (rn == 15) goto slow; result += regs[rn]; }
    regs[rd] = result;
    if (op & (1u << 20)) cpsr = nz(cpsr, result);
    NEXT_SEQ();
}

k_mull: {
    // Long multiplies: rd is RdHi, rn is RdLo.
    uint32_t rd = (op >> 16) & 0xF, rn = (op >> 12) & 0xF, rs = (op >> 8) & 0xF, rm = op & 0xF;
    if (rd == 15 || rm == 15 || rs == 15 || rn == 15 || rn == rd) goto slow;
    uint64_t result;
    if (op & (1u << 22)) result = (uint64_t)((int64_t)(int32_t)regs[rm] * (int64_t)(int32_t)regs[rs]);
    else result = (uint64_t)regs[rm] * regs[rs];
    if (op & (1u << 21)) result += ((uint64_t)regs[rd] << 32) | regs[rn];
    regs[rn] = (uint32_t)result;
    regs[rd] = (uint32_t)(result >> 32);
    if (op & (1u << 20)) {
        cpsr &= ~(N_FLAG | Z_FLAG);
        if (result >> 63) cpsr |= N_FLAG;
        if (result == 0) cpsr |= Z_FLAG;
    }
    NEXT_SEQ();
}

k_half: {
    // LDRH, STRH, LDRSB, LDRSH, LDRD, STRD.
    uint32_t rn = (op >> 16) & 0xF, rd = (op >> 12) & 0xF;
    uint32_t pre = (op >> 24) & 1, up = (op >> 23) & 1, writeback = (op >> 21) & 1, load = (op >> 20) & 1;
    uint32_t kind = (op >> 5) & 3;
    if (rn == 15 || rd == 15) goto slow;
    if (!(op & (1u << 22)) && (op & 0xF) == 15) goto slow;
    uint32_t offset = (op & (1u << 22)) ? (((op >> 4) & 0xF0) | (op & 0xF)) : regs[op & 0xF];
    uint32_t base = regs[rn];
    uint32_t offsetAddress = up ? base + offset : base - offset;
    uint32_t address = pre ? offsetAddress : base;
    int writesBack = !pre || writeback;
    // Unaligned halfword and doubleword accesses take the interpreter's rules.
    if (address & ((load && kind == 2) ? 0 : (load || kind == 1) ? 1 : 3)) goto slow;
    if (load) {
        uint8_t *p = span(s, address, kind == 2 ? 1 : 2);
        if (!p) goto slow;
        uint32_t value = kind == 1 ? load16(p) : kind == 2 ? (uint32_t)(int32_t)(int8_t)*p : (uint32_t)(int32_t)(int16_t)load16(p);
        if (writesBack) regs[rn] = offsetAddress;
        regs[rd] = value;
    } else if (kind == 1) {
        uint8_t *p = span(s, address, 2);
        if (!p) goto slow;
        store16(p, (uint16_t)regs[rd]);
        if (writesBack) regs[rn] = offsetAddress;
    } else {
        // LDRD (2) and STRD (3), from ARMv5, need an even register pair.
        if ((rd & 1) || rd == 14 || arch < 5) goto slow;
        uint8_t *p = span(s, address, 8);
        if (!p) goto slow;
        if (kind == 2) {
            uint32_t lo = load32(p), hi = load32(p + 4);
            if (writesBack) regs[rn] = offsetAddress;
            regs[rd] = lo;
            regs[rd + 1] = hi;
        } else {
            store32(p, regs[rd]);
            store32(p + 4, regs[rd + 1]);
            if (writesBack) regs[rn] = offsetAddress;
        }
    }
    NEXT_SEQ();
}

k_bx: {
    if ((op & 0x000FFF00u) != 0x000FFF00u || ((op & 0x20) && arch < 5)) goto slow;
    uint32_t rm = op & 0xF;
    uint32_t destination = rm == 15 ? pc + 8 : regs[rm];
    if (op & 0x20) regs[14] = pc + 4;
    if (destination & 1) {
        pc = destination & ~1u;
        cpsr |= T_FLAG;
        RETIRE();
        exit_reason = CARMExitThumb;
        goto out;
    }
    NEXT(destination & ~3u);
}

k_clz: {
    uint32_t rd = (op >> 12) & 0xF, rm = op & 0xF;
    if (rd == 15 || rm == 15 || (op & 0x000F0F00u) != 0x000F0F00u || arch < 5) goto slow;
    regs[rd] = regs[rm] ? (uint32_t)__builtin_clz(regs[rm]) : 32;
    NEXT_SEQ();
}

k_ldr_imm:
k_ldr_reg: {
    // LDR, STR, LDRB, STRB.
    uint32_t rn = (op >> 16) & 0xF, rd = (op >> 12) & 0xF;
    uint32_t pre = (op >> 24) & 1, up = (op >> 23) & 1, byte = (op >> 22) & 1;
    uint32_t writeback = (op >> 21) & 1, load = (op >> 20) & 1;
    uint32_t offset;
    if (op & (1u << 25)) {
        uint32_t rm = op & 0xF, carry;
        if (rm == 15) goto slow;
        offset = shift_immediate(regs[rm], (op >> 5) & 3, (op >> 7) & 0x1F, cpsr, &carry);
    } else {
        offset = op & 0xFFF;
    }
    int writesBack = !pre || writeback;
    // Before ARMv5 a load to r15 never enters Thumb state; the interpreter handles it.
    if ((writesBack && rn == 15) || (load && rd == 15 && (byte || arch < 5))) goto slow;
    uint32_t base = rn == 15 ? pc + 8 : regs[rn];
    uint32_t offsetAddress = up ? base + offset : base - offset;
    uint32_t address = pre ? offsetAddress : base;
    if (!byte && (address & 3)) goto slow;
    uint8_t *p = byte ? host(s, address) : span(s, address, 4);
    if (!p) goto slow;
    if (load) {
        uint32_t value = byte ? *p : load32(p);
        if (writesBack) regs[rn] = offsetAddress;
        if (rd == 15) {
            if (value & 1) {
                pc = value & ~1u;
                cpsr |= T_FLAG;
                RETIRE();
                exit_reason = CARMExitThumb;
                goto out;
            }
            NEXT(value & ~3u);
        }
        regs[rd] = value;
    } else {
        uint32_t value = rd == 15 ? pc + pc_stored : regs[rd];
        if (byte) *p = (uint8_t)value; else store32(p, value);
        if (writesBack) regs[rn] = offsetAddress;
    }
    NEXT_SEQ();
}

k_media: {
    // Sign and zero extension and byte reversal; the rest in Swift.
    uint32_t rd = (op >> 12) & 0xF, rn = (op >> 16) & 0xF, rm = op & 0xF;
    if (rd == 15 || rm == 15 || arch < 6) goto slow;
    if ((op & 0x0F8003F0u) == 0x06800070u) {
        uint32_t value = ror32(regs[rm], ((op >> 10) & 3) * 8);
        uint32_t extended;
        switch ((op >> 20) & 7) {
        case 2: extended = (uint32_t)(int32_t)(int8_t)value; break;
        case 3: extended = (uint32_t)(int32_t)(int16_t)value; break;
        case 6: extended = value & 0xFF; break;
        case 7: extended = value & 0xFFFF; break;
        default: goto slow;  // the 16-bit pair forms
        }
        regs[rd] = rn == 15 ? extended : regs[rn] + extended;
        NEXT_SEQ();
    }
    if ((op & 0x0FFF0FF0u) == 0x06BF0F30u) { regs[rd] = __builtin_bswap32(regs[rm]); NEXT_SEQ(); }
    if ((op & 0x0FFF0FF0u) == 0x06BF0FB0u) {
        uint32_t v = regs[rm];
        regs[rd] = ((v & 0x00FF00FFu) << 8) | ((v >> 8) & 0x00FF00FFu);
        NEXT_SEQ();
    }
    if ((op & 0x0FFF0FF0u) == 0x06FF0FB0u) {
        uint32_t v = regs[rm];
        regs[rd] = (uint32_t)(int32_t)(int16_t)(((v & 0xFF) << 8) | ((v >> 8) & 0xFF));
        NEXT_SEQ();
    }
    goto slow;
}

k_block: {
    // LDM and STM without the S bit.
    uint32_t rn = (op >> 16) & 0xF;
    uint32_t list = op & 0xFFFF;
    if (rn == 15 || list == 0) goto slow;
    // Older cores differ on loading r15 and on writing back a base that is in the list.
    if (arch < 6 && (((op >> 20) & 1 && (list & 0x8000) && arch < 5) || ((op >> 21) & 1 && (list >> rn) & 1))) goto slow;
    uint32_t count = (uint32_t)__builtin_popcount(list);
    uint32_t pre = (op >> 24) & 1, up = (op >> 23) & 1, writeback = (op >> 21) & 1, load = (op >> 20) & 1;
    uint32_t base = regs[rn];
    uint32_t start;
    if (up) start = pre ? base + 4 : base;
    else start = pre ? base - count * 4 : base - count * 4 + 4;
    start &= ~3u;
    uint8_t *p = span(s, start, count * 4);
    if (!p) goto slow;  // crosses a page or unmapped
    uint32_t newBase = up ? base + count * 4 : base - count * 4;
    if (load) {
        if (writeback && !((list >> rn) & 1)) regs[rn] = newBase;
        uint32_t i = 0;
        for (uint32_t r = 0; r < 15; r++) {
            if ((list >> r) & 1) { regs[r] = load32(p + i * 4); i++; }
        }
        if (list & 0x8000) {
            uint32_t value = load32(p + i * 4);
            if (value & 1) {
                pc = value & ~1u;
                cpsr |= T_FLAG;
                RETIRE();
                exit_reason = CARMExitThumb;
                goto out;
            }
            NEXT(value & ~3u);
        }
    } else {
        uint32_t i = 0;
        for (uint32_t r = 0; r < 16; r++) {
            if ((list >> r) & 1) { store32(p + i * 4, r == 15 ? pc + pc_stored : regs[r]); i++; }
        }
        if (writeback) regs[rn] = newBase;
    }
    NEXT_SEQ();
}

k_bl:
    regs[14] = pc + 4;
k_b: {
    int32_t offset = (int32_t)(op << 8) >> 6;
    NEXT(pc + 8 + (uint32_t)offset);
}

slow:
    exit_reason = CARMExitSlow;
out:
    regs[15] = pc;
    s->cpsr = cpsr;
    s->cycles = cycles;
    s->retired += cycles - start;
    return exit_reason;
}
