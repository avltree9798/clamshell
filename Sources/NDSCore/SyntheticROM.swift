// SPDX-License-Identifier: GPL-3.0-or-later

/// Builds a tiny DS image in memory for benchmarks and tests, so CI never needs
/// a commercial game. Both CPUs run a loop that sums a table in main RAM.
public enum SyntheticROM {
    public static let arm9Address: UInt32 = 0x0200_4000
    public static let arm7Address: UInt32 = 0x0380_0000

    /// ARM code (little-endian words) for:
    ///
    ///         mov   r0, #0          ; sum
    ///         ldr   r1, =table
    ///     outer:
    ///         mov   r2, #64         ; count
    ///         mov   r3, r1
    ///     inner:
    ///         ldr   r4, [r3], #4
    ///         add   r0, r0, r4
    ///         eor   r5, r0, r4, lsl #3
    ///         subs  r2, r2, #1
    ///         bne   inner
    ///         str   r0, [r1, #-4]
    ///         b     outer
    static func loop(tableAddress: UInt32) -> [UInt32] {
        [
            0xE3A0_0000,  // mov r0, #0
            0xE59F_1020,  // ldr r1, [pc, #32]  -> literal below
            0xE3A0_2040,  // mov r2, #64
            0xE1A0_3001,  // mov r3, r1
            0xE493_4004,  // ldr r4, [r3], #4
            0xE080_0004,  // add r0, r0, r4
            0xE020_5184,  // eor r5, r0, r4, lsl #3
            0xE252_2001,  // subs r2, r2, #1
            0x1AFF_FFFA,  // bne inner (-6 words from pc+8)
            0xE501_0004,  // str r0, [r1, #-4]
            0xEAFF_FFF6,  // b outer (-10 words from pc+8)
            tableAddress, // literal pool
        ]
    }

    public static func make() -> [UInt8] {
        var rom = [UInt8](repeating: 0, count: 0x8000)
        func put32(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 { rom[offset + i] = UInt8(truncatingIfNeeded: value >> UInt32(i * 8)) }
        }
        for (i, c) in "CLAMSHELL".utf8.enumerated() { rom[i] = c }
        for (i, c) in "CLMS".utf8.enumerated() { rom[12 + i] = c }

        let arm9Code = loop(tableAddress: 0x0210_0000)
        let arm7Code = loop(tableAddress: 0x0380_8000)
        let arm9Offset = 0x4000, arm7Offset = 0x6000

        put32(0x20, UInt32(arm9Offset)); put32(0x24, arm9Address); put32(0x28, arm9Address)
        put32(0x2C, UInt32(arm9Code.count * 4))
        put32(0x30, UInt32(arm7Offset)); put32(0x34, arm7Address); put32(0x38, arm7Address)
        put32(0x3C, UInt32(arm7Code.count * 4))
        for (i, word) in arm9Code.enumerated() { put32(arm9Offset + i * 4, word) }
        for (i, word) in arm7Code.enumerated() { put32(arm7Offset + i * 4, word) }
        return rom
    }
}
