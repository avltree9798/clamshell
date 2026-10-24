// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit

/// The ARM7's sound unit (GBATEK "DS Sound"): 16 channels that play PCM8, PCM16
/// or IMA-ADPCM from memory, channels 8-13 also as square waves and 14-15 as
/// noise, mixed with panning and a master volume.
///
/// Output is generated lazily: before every register access and at the end of
/// each frame the unit catches up to the scheduler's clock, so notes start and
/// stop where the game wrote them rather than at frame boundaries.
final class SPU {
    unowned(unsafe) let s: NDS

    /// 0x04000400-0x0400051F as 32-bit words.
    private(set) var regs = [UInt32](repeating: 0, count: 0x120 / 4)

    private struct Channel {
        var position = 0            // in samples (nibbles for ADPCM) from the source address
        var ticks = 0.0             // timer ticks towards the next sample
        var sample: Int32 = 0       // the current output, 16-bit
        // ADPCM state, and its copy at the loop start.
        var adpcmValue: Int32 = 0
        var adpcmIndex = 0
        var loopValue: Int32 = 0
        var loopIndex = 0
        var psgStep = 0
        var lfsr: UInt16 = 0x7FFF
    }
    private var channels = [Channel](repeating: Channel(), count: 16)
    private var samplesMade: UInt64 = 0

    /// Timer ticks (33.51 MHz / 2) per output sample.
    private static let ticksPerSample = 33_513_982.0 / 2 / NDSClock.audioRate

    init(system: NDS) { s = system }

    func reset() {
        regs = [UInt32](repeating: 0, count: regs.count)
        regs[0x104 / 4] = 0x200  // SOUNDBIAS
        channels = [Channel](repeating: Channel(), count: 16)
        samplesMade = 0
    }

    // MARK: - Registers

    func read(_ offset: Int) -> UInt32 {
        catchUp()
        return regs[offset / 4]
    }

    func write(_ offset: Int, _ value: UInt32, mask: UInt32) {
        catchUp()
        let i = offset / 4
        let old = regs[i]
        regs[i] = (old & ~mask) | (value & mask)
        if offset < 0x100 && offset & 0xF == 0 && old & 0x8000_0000 == 0 && regs[i] & 0x8000_0000 != 0 {
            start(offset >> 4)
        }
    }

    private func control(_ n: Int) -> UInt32 { regs[n * 4] }
    private func sourceAddress(_ n: Int) -> UInt32 { regs[n * 4 + 1] & 0x07FF_FFFC }
    private func timer(_ n: Int) -> Int { Int(regs[n * 4 + 2] & 0xFFFF) }
    /// Loop start and length, in words.
    private func loopStart(_ n: Int) -> Int { Int(regs[n * 4 + 2] >> 16) }
    private func length(_ n: Int) -> Int { Int(regs[n * 4 + 3] & 0x3F_FFFF) }

    private func start(_ n: Int) {
        var ch = Channel()
        let format = (control(n) >> 29) & 3
        if format == 2 {
            // The first word is the header: the starting value and step index.
            let header = s.bus7.read32(sourceAddress(n))
            ch.adpcmValue = Int32(Int16(truncatingIfNeeded: header))
            ch.adpcmIndex = min(Int((header >> 16) & 0x7F), 88)
            ch.position = 8
            ch.loopValue = ch.adpcmValue
            ch.loopIndex = ch.adpcmIndex
        }
        ch.sample = format == 2 ? ch.adpcmValue : 0
        channels[n] = ch
    }

    // MARK: - Generation

    /// Makes the samples due by the scheduler's current time.
    func catchUp() {
        let due = UInt64(Double(s.scheduler.now) * NDSClock.audioRate / NDSClock.hz)
        while samplesMade < due {
            let (l, r) = mix()
            s.audio.push(left: l, right: r)
            samplesMade += 1
        }
    }

    private func mix() -> (Int16, Int16) {
        let soundcnt = regs[0x100 / 4]
        guard soundcnt & 0x8000 != 0, s.bus7.powcnt2 & 1 != 0 else {
            for n in 0..<16 where control(n) & 0x8000_0000 != 0 { advance(n) }
            return (0, 0)
        }
        var left: Int64 = 0, right: Int64 = 0
        for n in 0..<16 where control(n) & 0x8000_0000 != 0 {
            advance(n)
            guard control(n) & 0x8000_0000 != 0 else { continue }
            let cnt = control(n)
            let volume = Int64(cnt & 0x7F)
            let shift = Int64([4, 3, 2, 0][Int((cnt >> 8) & 3)])
            let pan = Int64((cnt >> 16) & 0x7F)
            let value = (Int64(channels[n].sample) << shift) * volume
            left += (value * (128 - pan)) >> 10
            right += (value * pan) >> 10
        }
        let master = Int64(soundcnt & 0x7F)
        func output(_ v: Int64) -> Int16 { Int16(clamping: ((v * master) >> 7) >> 8) }
        return (output(left), output(right))
    }

    /// Steps channel `n` by one output sample's worth of timer ticks.
    private func advance(_ n: Int) {
        let period = Double(0x10000 - timer(n))
        channels[n].ticks += Self.ticksPerSample
        while channels[n].ticks >= period {
            channels[n].ticks -= period
            step(n)
            if control(n) & 0x8000_0000 == 0 { return }
        }
    }

    /// Moves channel `n` to its next sample.
    private func step(_ n: Int) {
        let cnt = control(n)
        let format = (cnt >> 29) & 3
        var ch = channels[n]
        defer { channels[n] = ch }

        if format == 3 {
            if n >= 8 && n <= 13 {
                // Square wave: duty d is high for d + 1 of 8 steps; 7 is always low.
                let duty = Int((cnt >> 24) & 7)
                ch.psgStep = (ch.psgStep + 1) & 7
                ch.sample = duty != 7 && ch.psgStep <= duty ? 0x7FFF : -0x7FFF
            } else if n >= 14 {
                if ch.lfsr & 1 != 0 {
                    ch.lfsr = (ch.lfsr >> 1) ^ 0x6000
                    ch.sample = -0x7FFF
                } else {
                    ch.lfsr >>= 1
                    ch.sample = 0x7FFF
                }
            } else {
                ch.sample = 0
            }
            return
        }

        let perWord = format == 0 ? 4 : format == 1 ? 2 : 8
        let loopPoint = loopStart(n) * perWord
        let end = (loopStart(n) + length(n)) * perWord
        if ch.position >= end {
            if (cnt >> 27) & 3 == 1 {
                ch.position = max(loopPoint, format == 2 ? 8 : 0)
                if format == 2 { ch.adpcmValue = ch.loopValue; ch.adpcmIndex = ch.loopIndex }
            } else {
                regs[n * 4] &= ~0x8000_0000
                ch.sample = 0
                return
            }
        }
        let base = sourceAddress(n)
        switch format {
        case 0:
            ch.sample = Int32(Int8(bitPattern: s.bus7.read8(base &+ UInt32(ch.position)))) << 8
        case 1:
            ch.sample = Int32(Int16(bitPattern: s.bus7.read16(base &+ UInt32(ch.position * 2))))
        default:
            if ch.position == loopPoint { ch.loopValue = ch.adpcmValue; ch.loopIndex = ch.adpcmIndex }
            let byte = s.bus7.read8(base &+ UInt32(ch.position / 2))
            let nibble = Int32(ch.position & 1 == 0 ? byte & 0xF : byte >> 4)
            (ch.adpcmValue, ch.adpcmIndex) = Self.adpcm(ch.adpcmValue, ch.adpcmIndex, nibble)
            ch.sample = ch.adpcmValue
        }
        ch.position += 1
    }

    /// One IMA-ADPCM nibble applied to the running value and step index.
    static func adpcm(_ value: Int32, _ index: Int, _ nibble: Int32) -> (Int32, Int) {
        let step = Int32(adpcmSteps[index])
        var diff = step >> 3
        if nibble & 1 != 0 { diff += step >> 2 }
        if nibble & 2 != 0 { diff += step >> 1 }
        if nibble & 4 != 0 { diff += step }
        let next = nibble & 8 != 0 ? max(value - diff, -0x7FFF) : min(value + diff, 0x7FFF)
        return (next, min(max(index + adpcmIndexShift[Int(nibble & 7)], 0), 88))
    }

    static let adpcmIndexShift = [-1, -1, -1, -1, 2, 4, 6, 8]

    static let adpcmSteps: [UInt16] = [
        0x0007, 0x0008, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x000E, 0x0010, 0x0011, 0x0013, 0x0015,
        0x0017, 0x0019, 0x001C, 0x001F, 0x0022, 0x0025, 0x0029, 0x002D, 0x0032, 0x0037, 0x003C, 0x0042,
        0x0049, 0x0050, 0x0058, 0x0061, 0x006B, 0x0076, 0x0082, 0x008F, 0x009D, 0x00AD, 0x00BE, 0x00D1,
        0x00E6, 0x00FD, 0x0117, 0x0133, 0x0151, 0x0173, 0x0198, 0x01C1, 0x01EE, 0x0220, 0x0256, 0x0292,
        0x02D4, 0x031C, 0x036C, 0x03C3, 0x0424, 0x048E, 0x0502, 0x0583, 0x0610, 0x06AB, 0x0756, 0x0812,
        0x08E0, 0x09C3, 0x0ABD, 0x0BD0, 0x0CFF, 0x0E4C, 0x0FBA, 0x114C, 0x1307, 0x14EE, 0x1706, 0x1954,
        0x1BDC, 0x1EA5, 0x21B6, 0x2515, 0x28CA, 0x2CDF, 0x315B, 0x364B, 0x3BB9, 0x41B2, 0x4844, 0x4F7E,
        0x5771, 0x602F, 0x69CE, 0x7462, 0x7FFF,
    ]
}
