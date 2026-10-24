// SPDX-License-Identifier: GPL-3.0-or-later

/// The save chip on the card's auxiliary SPI bus (GBATEK "DS Cartridge Backup"):
/// EEPROM or flash, which differ mainly in how many address bytes follow a command.
///
/// Nothing in the ROM says which chip a game has. A save file's size decides it when
/// there is one; otherwise the first read does, the way DeSmuME detects it: games
/// start by reading a single byte, so the bytes after the command are the address
/// plus one.
final class BackupMemory {
    enum Kind {
        case eeprom512   // 1 address byte, the 9th address bit in the command
        case eeprom      // 2 address bytes (8 KB, 64 KB, and FRAM 32 KB)
        case flash       // 3 address bytes (256 KB and up)

        var addressBytes: Int { self == .eeprom512 ? 1 : self == .eeprom ? 2 : 3 }
        var defaultSize: Int { self == .eeprom512 ? 512 : self == .eeprom ? 64 << 10 : 512 << 10 }
    }

    private(set) var data: [UInt8] = []
    private(set) var kind: Kind?
    /// Bumped on every write, so the app knows when to save.
    private(set) var writes = 0

    private var command: UInt8 = 0
    private var position = 0          // bytes received in the current command
    private var address = 0
    private var writeEnabled = false
    private var detecting: [UInt8] = []

    /// Restores a save; its size picks the chip.
    func load(_ bytes: [UInt8]) {
        data = bytes
        switch bytes.count {
        case 0: kind = nil
        case ...512: kind = .eeprom512
        case ...(128 << 10): kind = .eeprom
        default: kind = .flash
        }
    }

    /// Releases chip select: the command ends.
    func deselect() {
        if command == 0x03, kind == nil, detecting.count >= 2 {
            // Command byte excluded: address bytes + the one data byte read.
            switch detecting.count - 1 {
            case 1: setKind(.eeprom512)
            case 2: setKind(.eeprom)
            default: setKind(.flash)
            }
        }
        if [0x02, 0x0A, 0xDB, 0xD8].contains(command) && position > 0 { writeEnabled = false }
        command = 0
        position = 0
        detecting = []
    }

    private func setKind(_ k: Kind) {
        kind = k
        if data.isEmpty { data = [UInt8](repeating: 0xFF, count: k.defaultSize) }
    }

    /// Exchanges one byte with the chip.
    func transfer(_ value: UInt8) -> UInt8 {
        if position == 0 {
            command = value
            position = 1
            address = 0
            switch value {
            case 0x06: writeEnabled = true
            case 0x04: writeEnabled = false
            default: break
            }
            return 0xFF
        }
        position += 1
        let index = position - 2  // bytes after the command
        switch command {
        case 0x05:  // read status: bit 1 write enable, bit 0 busy (never)
            return writeEnabled ? 0x02 : 0x00
        case 0x9F:  // flash ID
            return kind == .flash ? 0xC2 : 0xFF
        case 0x03, 0x0B:
            guard let kind else {
                detecting.append(value)
                return 0xFF
            }
            // 0x0B is the upper half on a 512-byte EEPROM, fast read (one dummy byte) on flash.
            let dummy = command == 0x0B && kind == .flash ? 1 : 0
            if index < kind.addressBytes + dummy {
                if index < kind.addressBytes { address = address << 8 | Int(value) }
                if index == kind.addressBytes - 1 && kind == .eeprom512 && command == 0x0B { address |= 0x100 }
                return 0xFF
            }
            let byte = data.isEmpty ? 0xFF : data[address % data.count]
            address += 1
            return byte
        case 0x02, 0x0A:  // write (EEPROM; flash page write and program)
            guard let kind else { return 0xFF }
            if index < kind.addressBytes {
                address = address << 8 | Int(value)
                if index == kind.addressBytes - 1 && kind == .eeprom512 && command == 0x0A { address |= 0x100 }
                return 0xFF
            }
            guard writeEnabled, !data.isEmpty else { return 0xFF }
            data[address % data.count] = value
            address += 1
            writes += 1
            return 0xFF
        case 0xDB, 0xD8:  // flash page (256 B) and sector (64 KB) erase
            guard kind == .flash, !data.isEmpty, index < 3 else { return 0xFF }
            address = address << 8 | Int(value)
            if index == 2 && writeEnabled {
                let size = command == 0xDB ? 0x100 : 0x10000
                let start = (address & ~(size - 1)) % data.count
                for i in start..<min(start + size, data.count) { data[i] = 0xFF }
                writes += 1
            }
            return 0xFF
        default:
            return 0xFF
        }
    }
}
