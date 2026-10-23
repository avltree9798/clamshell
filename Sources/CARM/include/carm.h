// SPDX-License-Identifier: GPL-3.0-or-later
//
// A fast path in C for the ARM cores (the DS ARM7 and ARM9, the 3DS ARM11). It runs
// the common ARM-state instructions (data processing, multiplies, loads and
// stores, branches, sign and zero extension) straight from a page table of guest
// RAM, and hands every other instruction back to the Swift interpreter one at a time.

#ifndef CARM_H
#define CARM_H

#include <stdint.h>

typedef struct CARMState {
    /// The Swift interpreter's register storage: r0-r15 at [0, 16).
    uint32_t *regs;
    /// 4 KB pages covering the 4 GB address space: host pointers, or NULL when unmapped.
    uint8_t *const *pages;
    /// The same for instruction fetches, which can differ (the DS ARM9's DTCM is data only).
    uint8_t *const *code_pages;
    /// Instructions run so far, and the count to stop at.
    uint64_t cycles;
    uint64_t target;
    uint64_t retired;
    uint32_t cpsr;
    /// The architecture version: 4 (ARM7TDMI), 5 (ARM946E-S) or 6 (ARM11 MPCore).
    /// Instructions an older core lacks or runs differently go to the interpreter.
    uint32_t arch;
} CARMState;

typedef enum CARMExit {
    /// `cycles` reached `target`.
    CARMExitTarget = 0,
    /// The instruction at r15 needs the Swift interpreter; nothing of it has run.
    CARMExitSlow = 1,
    /// The CPU switched to Thumb state.
    CARMExitThumb = 2,
} CARMExit;

/// Runs ARM-state code from r15 until one of the exits. r15 holds the address of
/// the next instruction on return, and `cpsr` holds the updated flags and T bit.
CARMExit carm_run(CARMState *state);

#endif
