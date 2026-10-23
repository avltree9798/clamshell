// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import ARMCore
@testable import NDSCore

/// The fast path's page tables must show exactly what the buses read and fetch.
@Suite struct PageMapTests {
    /// Writes a distinct word through the bus at each sampled address, then checks
    /// that every mapped page holds the word the bus reads back there.
    func check<B: ARMBus>(_ bus: B, _ pages: PageMap, fetch: Bool, label: String) {
        let table = fetch ? pages.code : pages.data
        var addresses: [UInt32] = []
        for page in stride(from: 0, to: 0x4000, by: 7) { addresses.append(UInt32(page) << 12 | 0x124) }
        for page in 0x2_7C0..<0x2_7C8 { addresses.append(UInt32(page) << 12 | 0x10) }
        for page in 0x0B00_0..<0x0B00_8 { addresses.append(UInt32(page) << 12 | 0x10) }
        for (i, a) in addresses.enumerated() { bus.write32(a, 0x5A00_0000 | UInt32(i)) }
        for a in addresses {
            guard let host = table[Int(a >> 12)] else { continue }
            let mapped = UnsafeRawPointer(host + Int(a & 0xFFF)).loadUnaligned(as: UInt32.self)
            let expected = fetch ? bus.fetch32(a) : bus.read32(a)
            if mapped != expected {
                Issue.record("\(label) \(fetch ? "fetch" : "read") at \(String(a, radix: 16)): page \(String(mapped, radix: 16)) bus \(String(expected, radix: 16))")
                return
            }
        }
    }

    @Test(arguments: [UInt8(0), 1, 2, 3])
    func matchBuses(wramcnt: UInt8) throws {
        let nds = NDS()
        try nds.load(image: SyntheticROM.make())
        nds.wramcnt = wramcnt
        let file = nds.arm9!
        // Boot layout, then DTCM over main RAM with a 16 KB ITCM, then DTCM up high.
        for (control, dtcm, itcm): (UInt32, UInt32, UInt32) in [(0x0005_2078, 0x0080_000A, 0x20),
                                                                 (0x0005_2078, 0x027C_000A, 0x1C),
                                                                 (0x0001_2078, 0x0B00_0008, 0x20)] {
            nds.bus9.cp15Write(cn: 9, cm: 1, cp: 0, value: dtcm, cpu: file)
            nds.bus9.cp15Write(cn: 9, cm: 1, cp: 1, value: itcm, cpu: file)
            nds.bus9.cp15Write(cn: 1, cm: 0, cp: 0, value: control, cpu: file)
            for fetch in [false, true] {
                check(nds.bus9, nds.bus9.pages, fetch: fetch, label: "ARM9 \(String(dtcm, radix: 16))")
            }
        }
        check(nds.bus7, nds.bus7.pages, fetch: false, label: "ARM7")
        check(nds.bus7, nds.bus7.pages, fetch: true, label: "ARM7")
    }
}
