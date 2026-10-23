// SPDX-License-Identifier: GPL-3.0-or-later

/// A generated .3dsx that never waits: one thread sums a table forever. The
/// benchmark uses it to measure the ARM11 interpreter without the GPU or idle time.
public enum SyntheticHomebrew {
    public static func make() -> [UInt8] {
        // The same loop as the DS benchmark: load, add, shifted eor, count down, branch.
        let tableAddress: UInt32 = 0x0010_2000
        let code: [UInt32] = [
            0xE3A0_0000,  // mov r0, #0
            0xE59F_1020,  // ldr r1, [pc, #32]
            0xE3A0_2040,  // mov r2, #64
            0xE1A0_3001,  // mov r3, r1
            0xE493_4004,  // ldr r4, [r3], #4
            0xE080_0004,  // add r0, r0, r4
            0xE020_5184,  // eor r5, r0, r4, lsl #3
            0xE252_2001,  // subs r2, r2, #1
            0x1AFF_FFFA,  // bne inner
            0xE501_0004,  // str r0, [r1, #-4]
            0xEAFF_FFF6,  // b outer
            tableAddress,
        ]
        var codeBytes = code.flatMap { w in (0..<4).map { UInt8(truncatingIfNeeded: w >> UInt32($0 * 8)) } }
        codeBytes += [UInt8](repeating: 0, count: 0x1000 - codeBytes.count)
        let rodata = [UInt8](repeating: 0, count: 0x1000)
        let data = (0..<0x400).map { UInt8(truncatingIfNeeded: $0 &* 37) }

        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { u16(v & 0xFFFF) + u16(v >> 16) }
        var file = Array("3DSX".utf8) + u16(0x20) + u16(8) + u32(0) + u32(0)
        file += u32(codeBytes.count) + u32(rodata.count) + u32(data.count) + u32(0)
        file += [UInt8](repeating: 0, count: 24)  // three empty relocation headers
        return file + codeBytes + rodata + data
    }
}
