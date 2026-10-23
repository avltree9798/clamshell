// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit

/// ARM7 SPI bus: power management (device 0), firmware flash (1), touchscreen (2).
final class SPIBus {
    var control: UInt16 = 0
    private var data: UInt8 = 0

    // Touchscreen controller state.
    private var touchResult: UInt16 = 0
    private var touchByte = 0

    // Firmware flash state.
    private var flashCommand: UInt8 = 0
    private var flashAddress: UInt32 = 0
    private var flashAddressBytes = 0
    let firmware = Firmware.generate()

    var touchPoint: (x: Int, y: Int)?

    func readData() -> UInt8 { data }

    func writeData(_ value: UInt8) {
        guard control & 0x8000 != 0 else { return }
        let hold = control & (1 << 11) != 0
        switch (control >> 8) & 3 {
        case 1: data = flash(value, hold: hold)
        case 2: data = touch(value)
        default: data = 0
        }
    }

    private func flash(_ value: UInt8, hold: Bool) -> UInt8 {
        defer { if !hold { flashCommand = 0 } }
        if flashCommand == 0 {
            flashCommand = value
            flashAddress = 0
            flashAddressBytes = 0
            return 0
        }
        switch flashCommand {
        case 0x03:  // READ: 3 address bytes, then data
            if flashAddressBytes < 3 {
                flashAddress = flashAddress << 8 | UInt32(value)
                flashAddressBytes += 1
                return 0
            }
            let byte = firmware[Int(flashAddress) & (firmware.count - 1)]
            flashAddress &+= 1
            return byte
        case 0x05:  // read status: never busy
            return 0
        default:
            return 0
        }
    }

    /// TSC2046-style controller: a command byte starts a 12-bit conversion that
    /// the next two bytes shift out (high 7 bits, then low 5 bits).
    private func touch(_ value: UInt8) -> UInt8 {
        var out: UInt8 = 0
        switch touchByte {
        case 1: out = UInt8(truncatingIfNeeded: touchResult >> 5)
        case 2: out = UInt8(truncatingIfNeeded: touchResult << 3)
        default: break
        }
        if value & 0x80 != 0 {
            let channel = (value >> 4) & 7
            touchResult = convert(channel: channel)
            touchByte = 1
        } else if touchByte > 0 {
            touchByte = touchByte == 1 ? 2 : 0
        }
        return out
    }

    private func convert(channel: UInt8) -> UInt16 {
        guard let p = touchPoint else { return channel == 1 ? 0xFFF : 0 }
        // Inverse of the calibration the firmware user settings describe.
        let c = Firmware.calibration
        switch channel {
        case 5: return UInt16(clamping: c.adcX1 + (p.x - c.screenX1) * (c.adcX2 - c.adcX1) / (c.screenX2 - c.screenX1))
        case 1: return UInt16(clamping: c.adcY1 + (p.y - c.screenY1) * (c.adcY2 - c.adcY1) / (c.screenY2 - c.screenY1))
        default: return 0
        }
    }
}

/// A synthetic firmware image and user settings, so no Nintendo firmware is needed.
enum Firmware {
    struct Calibration {
        let adcX1 = 0x0200, adcY1 = 0x0200, screenX1 = 0x20, screenY1 = 0x20
        let adcX2 = 0x0E00, adcY2 = 0x0800, screenX2 = 0xE0, screenY2 = 0xA0
    }
    static let calibration = Calibration()

    /// 256 KB of flash with two copies of the user settings at the top.
    static func generate() -> [UInt8] {
        var image = [UInt8](repeating: 0xFF, count: 256 * 1024)
        let settings = userSettings()
        for base in [0x3FE00, 0x3FF00] {
            for (i, b) in settings.enumerated() { image[base + i] = b }
        }
        // Header: firmware size code at 0x20 points the user settings offset to 0x3FE00.
        image[0x20] = 0xC0
        image[0x21] = 0x7F
        return image
    }

    /// The user settings block: 0x70 bytes of settings, an update counter at 0x70
    /// and a CRC-16 of the settings at 0x72. The first 0x70 bytes are also copied
    /// to RAM at 0x027FFC80 on boot.
    static func userSettings() -> [UInt8] {
        var s = [UInt8](repeating: 0, count: 0x74)
        s[0x00] = 5                       // version
        s[0x02] = 0                       // favourite colour
        s[0x03] = 1; s[0x04] = 1          // birthday month, day
        let name = Array("Player".utf16)
        for (i, ch) in name.enumerated() {
            s[0x06 + i * 2] = UInt8(ch & 0xFF)
            s[0x07 + i * 2] = UInt8(ch >> 8)
        }
        s[0x1A] = UInt8(name.count)
        let c = calibration
        func put16(_ o: Int, _ v: Int) { s[o] = UInt8(v & 0xFF); s[o + 1] = UInt8(v >> 8) }
        put16(0x58, c.adcX1); put16(0x5A, c.adcY1); s[0x5C] = UInt8(c.screenX1); s[0x5D] = UInt8(c.screenY1)
        put16(0x5E, c.adcX2); put16(0x60, c.adcY2); s[0x62] = UInt8(c.screenX2); s[0x63] = UInt8(c.screenY2)
        s[0x64] = 1                       // language: English
        put16(0x70, 0)                    // update counter
        put16(0x72, Int(crc16(s[0..<0x70], seed: 0xFFFF)))
        return s
    }

    static func writeUserSettings(to ram: RAM, at address: UInt32) {
        for (i, b) in userSettings().prefix(0x70).enumerated() { ram.write8(address + UInt32(i), b) }
    }

    /// The BIOS CRC-16 (polynomial 0xA001), used for firmware blocks and SWI 0x0E.
    static func crc16<C: Collection>(_ bytes: C, seed: UInt16) -> UInt16 where C.Element == UInt8 {
        var crc = seed
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }
}
