// SPDX-License-Identifier: GPL-3.0-or-later
//
// A fast path for the 3DS ARM11 in C. It runs the common ARM-state instructions
// (data processing, multiplies, loads and stores, branches, sign and zero
// extension) straight from the address space's page table, and hands every
// other instruction back to the Swift interpreter one at a time.

#ifndef CARM11_H
#define CARM11_H

#include <stdint.h>

typedef struct CARM11State {
    /// The Swift interpreter's register storage: r0-r15 at [0, 16).
    uint32_t *regs;
    /// 4 KB pages covering the 4 GB address space: host pointers, or NULL when unmapped.
    uint8_t *const *pages;
    uint64_t cycles;
    uint64_t target;
    uint64_t retired;
    uint32_t cpsr;
} CARM11State;

typedef enum CARM11Exit {
    /// `cycles` reached `target`.
    CARM11ExitTarget = 0,
    /// The instruction at r15 needs the Swift interpreter; nothing of it has run.
    CARM11ExitSlow = 1,
    /// The CPU switched to Thumb state.
    CARM11ExitThumb = 2,
} CARM11Exit;

/// Runs ARM-state code from r15 until one of the exits. r15 holds the address of
/// the next instruction on return, and `cpsr` holds the updated flags and T bit.
CARM11Exit carm11_run(CARM11State *state);

#endif
