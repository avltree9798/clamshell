// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The Seiko S-35199A real-time clock on the ARM7's serial port at 0x04000138
/// (GBATEK "DS Real-Time Clock"). The game bit-bangs it: select high, then a
/// command byte and data bytes, one bit per rising clock edge, LSB first.
final class RTC {
    private var port: UInt8 = 0
    private var input: UInt8 = 0
    private var inputBits = 0
    private var command: UInt8?
    private var output: [UInt8] = []
    private var outputBit = 0
    private var written: [UInt8] = []
    private var status1: UInt8 = 0x02  // 24-hour mode
    private var status2: UInt8 = 0

    /// Bits 0 data, 1 clock, 2 select; 4-6 their directions (1 = written by the CPU).
    func read() -> UInt32 { UInt32(port) }

    func write(_ value: UInt8) {
        let old = port
        // The data bit comes from the CPU when it drives it, otherwise from the clock.
        port = value & 0x76 | (value & 0x10 != 0 ? value & 1 : port & 1)
        if old & 4 == 0 && value & 4 != 0 {
            input = 0; inputBits = 0; command = nil; output = []; outputBit = 0; written = []
            return
        }
        guard value & 4 != 0, old & 2 == 0, value & 2 != 0 else {
            if value & 4 == 0, old & 4 != 0 { finishWrite() }
            return
        }
        if value & 0x10 != 0 {
            input |= (value & 1) << UInt8(inputBits)
            inputBits += 1
            if inputBits == 8 {
                byte(input)
                input = 0
                inputBits = 0
            }
        } else {
            let byteIndex = outputBit / 8
            let bit = byteIndex < output.count ? (output[byteIndex] >> UInt8(outputBit % 8)) & 1 : 0
            port = port & ~1 | bit
            outputBit += 1
        }
    }

    private func byte(_ b: UInt8) {
        guard let command else {
            // Accept the command byte in either bit order: 0110 CCC R.
            var c = b
            if c & 0xF0 != 0x60 { c = Self.reversed(b) }
            guard c & 0xF0 == 0x60 else { return }
            self.command = c
            if c & 1 != 0 { output = response((c >> 1) & 7) }
            return
        }
        if command & 1 == 0 { written.append(b) }
    }

    private func finishWrite() {
        guard let command, command & 1 == 0, let first = written.first else { return }
        switch (command >> 1) & 7 {
        case 0: status1 = (status1 & 0xF0) | (first & 0x0E)  // reset (bit 0) is not kept
        case 1: status2 = first
        default: break  // setting the clock or alarms: the host clock stays authoritative
        }
    }

    private func response(_ register: UInt8) -> [UInt8] {
        switch register {
        case 0:
            let s = status1
            status1 &= 0x0F  // power-on and interrupt flags clear when read
            return [s]
        case 1: return [status2]
        case 2: return Array(Self.dateTime().prefix(7))
        case 3: return Array(Self.dateTime().suffix(3))
        default: return [0, 0, 0]
        }
    }

    /// Year, month, day, weekday, hour, minute, second in BCD.
    static func dateTime(_ date: Date = Date()) -> [UInt8] {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
        func bcd(_ v: Int) -> UInt8 { UInt8((v / 10) << 4 | v % 10) }
        let hour = c.hour ?? 0
        return [bcd((c.year ?? 2000) % 100), bcd(c.month ?? 1), bcd(c.day ?? 1), UInt8(((c.weekday ?? 1) + 6) % 7),
                bcd(hour) | (hour >= 12 ? 0x40 : 0), bcd(c.minute ?? 0), bcd(c.second ?? 0)]
    }

    static func reversed(_ b: UInt8) -> UInt8 {
        var r: UInt8 = 0
        for i in 0..<8 where b & (1 << UInt8(i)) != 0 { r |= 0x80 >> UInt8(i) }
        return r
    }
}
