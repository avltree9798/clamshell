// SPDX-License-Identifier: GPL-3.0-or-later
//
// Guest self-test for the ARM11 interpreter. Built twice by generate.sh: for
// ARMv6K + VFPv2 (the guest image) and for the host (the expected results).
// Each check writes one 32-bit word to results[].

#include <stdint.h>

#define COUNT 64
uint32_t results[COUNT];
static int slot;
static void put(uint32_t v) { results[slot++] = v; }
static uint32_t f2u(float f) { union { float f; uint32_t u; } x = { f }; return x.u; }
static uint32_t d2lo(double d) { union { double d; uint64_t u; } x = { d }; return (uint32_t)x.u; }
static uint32_t d2hi(double d) { union { double d; uint64_t u; } x = { d }; return (uint32_t)(x.u >> 32); }

// Inputs come through volatile globals so the compiler cannot fold the work away.
volatile uint32_t vu[8] = { 0x12345678, 0xFFFFFFFF, 7, 0x80000000, 0xDEADBEEF, 3, 0x0000FFFF, 100 };
volatile float vf[4] = { 1.5f, -2.25f, 3.0e10f, 0.1f };
volatile double vd[3] = { 2.5, -1.0e-3, 1.0e100 };

#if defined(__thumb__) || defined(__arm__)
#define THUMB __attribute__((target("thumb")))
#else
#define THUMB
#endif

static THUMB uint32_t thumb_mix(uint32_t a, uint32_t b) {
    uint32_t s = 0;
    for (int i = 0; i < 16; i++) { s = (s << 3) ^ (s >> 5) ^ (a + i * b); }
    return s + (uint32_t)(int8_t)a + (uint32_t)(uint16_t)b + __builtin_bswap32(a);
}

static uint64_t mul64(uint64_t a, uint64_t b) { return a * b; }

static uint32_t udiv(uint32_t n, uint32_t d) {  // no hardware divide on ARMv6
    uint32_t q = 0, r = 0;
    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1);
        if (r >= d) { r -= d; q |= 1u << i; }
    }
    return q;
}

int main(void) {
    uint32_t a = vu[0], b = vu[1], c = vu[2], d = vu[3], e = vu[4];
    put(a + b * c);
    put(__builtin_bswap32(e));
    put((uint32_t)(int16_t)e);
    put((uint32_t)(uint8_t)(e >> 8));
    put(__builtin_clz(c));
    put((uint32_t)((int32_t)d >> 7));
    put(udiv(e, c));
    uint64_t m = mul64(((uint64_t)a << 32) | e, 0x9E3779B97F4A7C15ull);
    put((uint32_t)m); put((uint32_t)(m >> 32));
    int64_t sm = (int64_t)(int32_t)e * (int32_t)a;
    put((uint32_t)sm); put((uint32_t)(sm >> 32));
    put(thumb_mix(a, e));

    float x = vf[0], y = vf[1], z = vf[2], w = vf[3];
    put(f2u(x + y)); put(f2u(x * y)); put(f2u(x / w)); put(f2u(z * z));
    put(f2u(__builtin_sqrtf(x))); put(f2u(x * y + w)); put(f2u(-(x * w)));
    put((uint32_t)(int32_t)y); put((uint32_t)(int32_t)(z / 100.0f)); put((uint32_t)(z / 10.0f));
    put(f2u((float)(int32_t)e)); put(f2u((float)e));
    put(x < y); put(x > y); put(w == w); put(z >= z * 2.0f);

    double p = vd[0], q = vd[1], r = vd[2];
    double s1 = p * q + r / 3.0;
    put(d2lo(s1)); put(d2hi(s1));
    put(d2lo(p / q)); put(d2hi(p / q));
    put(d2lo(__builtin_sqrt(p))); put(d2hi(__builtin_sqrt(p)));
    put(f2u((float)q)); put((uint32_t)(int32_t)(p * 1000.0));
    put(p > q);

    // Exclusive access through the compiler's atomics (LDREX/STREX on ARMv6K).
    static uint32_t counter = 5;
    __atomic_fetch_add(&counter, 37, __ATOMIC_SEQ_CST);
    uint32_t expected = 42;
    put(__atomic_compare_exchange_n(&counter, &expected, 99, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST));
    put(counter);

    // Unaligned word and halfword loads (enabled on the 3DS).
    static uint8_t bytes[12] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    volatile uint8_t *bp = bytes;
    put(*(volatile uint32_t *)(bp + 1));
    put(*(volatile uint16_t *)(bp + 3));
    *(volatile uint32_t *)(bp + 5) = 0xA1B2C3D4;
    put(*(volatile uint32_t *)(bp + 4));
    put(*(volatile uint32_t *)(bp + 8));
    return slot;
}

#if defined(__arm__)
__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile("ldr sp, =0x000F0000\n"
                     "bl main\n"
                     "svc #0\n"
                     "b .\n");
}
#endif
