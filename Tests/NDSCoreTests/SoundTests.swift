// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import NDSCore

/// Plays channels through the ARM7's sound registers and reads the mixed output.
@Suite struct SoundTests {
    static let samples: UInt32 = 0x0230_0000

    func system() throws -> NDS {
        let nds = NDS()
        try nds.load(image: SyntheticROM.make())
        nds.bus7.write32(0x0400_0304, 1)          // POWCNT2: sound on
        nds.bus7.write32(0x0400_0500, 0x807F)     // SOUNDCNT: enabled, full master volume
        return nds
    }

    func drain(_ nds: NDS) -> [(Int16, Int16)] {
        var out = [Int16](repeating: 0, count: 8192)
        let n = out.withUnsafeMutableBufferPointer { nds.audio.pull(into: $0.baseAddress!, frames: 4096) }
        return (0..<n).map { (out[$0 * 2], out[$0 * 2 + 1]) }
    }

    @Test func oneShotPCM16PlaysThenStops() throws {
        let nds = try system()
        for i in 0..<64 { nds.bus7.write16(Self.samples + UInt32(i * 2), 0x4000) }
        _ = drain(nds)
        nds.bus7.write32(0x0400_0404, Self.samples)
        nds.bus7.write32(0x0400_0408, 0x10000 - 512)  // about one sample per output sample, loop start 0
        nds.bus7.write32(0x0400_040C, 32)             // 64 samples
        nds.bus7.write32(0x0400_0400, 1 << 31 | 1 << 29 | 2 << 27 | 64 << 16 | 127)
        nds.runFrame()
        let out = drain(nds)
        let loud = out.filter { $0.0 > 7000 && $0.1 > 7000 && abs(Int($0.0) - Int($0.1)) < 200 }
        #expect((60...66).contains(loud.count))
        #expect(nds.bus7.read32(0x0400_0400) & 1 << 31 == 0)
        #expect(out.last! == (0, 0))
    }

    @Test func pannedHardLeft() throws {
        let nds = try system()
        for i in 0..<64 { nds.bus7.write16(Self.samples + UInt32(i * 2), 0x4000) }
        _ = drain(nds)
        nds.bus7.write32(0x0400_0404, Self.samples)
        nds.bus7.write32(0x0400_0408, 0x10000 - 512)
        nds.bus7.write32(0x0400_040C, 32)
        nds.bus7.write32(0x0400_0400, 1 << 31 | 1 << 29 | 1 << 27 | 0 << 16 | 127)  // looping, pan 0
        nds.runFrame()
        let out = drain(nds)
        #expect(out.dropFirst(10).allSatisfy { $0.0 > 10000 && $0.1 == 0 })
    }

    @Test func squareWaveDuty() throws {
        let nds = try system()
        _ = drain(nds)
        // Channel 8, 50% duty (3 → 4 of 8 high), one step per output sample.
        nds.bus7.write32(0x0400_0488, 0x10000 - 512)
        nds.bus7.write32(0x0400_0480, 1 << 31 | 3 << 29 | 3 << 24 | 64 << 16 | 127)
        nds.runFrame()
        let out = drain(nds).map(\.0)
        let high = out.filter { $0 > 0 }.count, low = out.filter { $0 < 0 }.count
        #expect(abs(high - low) < out.count / 10)
    }

    @Test func adpcmDecodesIMASteps() {
        var (v, i) = SPU.adpcm(0, 0, 7)
        #expect(v == 11 && i == 8)
        (v, i) = SPU.adpcm(v, i, 7)
        #expect(v == 41 && i == 16)
        (v, i) = SPU.adpcm(v, i, 0xF)
        #expect(v < 41 && i == 24)
        #expect(SPU.adpcm(0x7FF0, 88, 7).0 == 0x7FFF)
    }
}
