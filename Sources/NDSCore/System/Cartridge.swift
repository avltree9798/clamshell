// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit

/// The game card as seen after the BIOS has unlocked it (KEY2 mode, data already
/// decrypted). Supports the commands games use after boot: data read and chip ID.
final class Cartridge {
    private(set) var rom: [UInt8] = []
    var backup: [UInt8] = []
    weak var system: NDS?

    var romControl: UInt32 = 0
    var auxSPIControl: UInt16 = 0
    var command = [UInt8](repeating: 0, count: 8)
    private var buffer: [UInt32] = []
    private var bufferIndex = 0

    static let chipID: UInt32 = 0x0000_1FC2

    func load(_ bytes: [UInt8]) throws(CoreError) {
        guard bytes.count >= 0x200 else { throw .unsupportedImage("file is too small to be a DS game") }
        // Round up to a power of two so reads can wrap with a mask.
        var size = 1
        while size < bytes.count { size <<= 1 }
        rom = bytes + [UInt8](repeating: 0xFF, count: size - bytes.count)
        romControl = 0
        buffer = []
        bufferIndex = 0
    }

    var title: String {
        guard rom.count >= 12 else { return "" }
        return String(decoding: rom[0..<12].prefix { $0 != 0 }, as: UTF8.self)
    }

    var gameCode: String {
        guard rom.count >= 16 else { return "" }
        return String(decoding: rom[12..<16], as: UTF8.self)
    }

    /// Bit 23 = a data word is ready, bit 31 = a transfer is in progress.
    func readControl() -> UInt32 { romControl }

    func writeControl(_ value: UInt32, mask: UInt32) {
        romControl = (romControl & ~mask) | (value & mask & ~0x0080_0000)
        if mask & 0x8000_0000 != 0 && value & 0x8000_0000 != 0 { startTransfer() }
    }

    private func startTransfer() {
        let blockCode = (romControl >> 24) & 7
        let length: Int
        switch blockCode {
        case 0: length = 0
        case 7: length = 4
        default: length = 0x100 << Int(blockCode)
        }

        buffer = []
        bufferIndex = 0
        switch command[0] {
        case 0xB7:
            var address = Int(UInt32(command[1]) << 24 | UInt32(command[2]) << 16 | UInt32(command[3]) << 8 | UInt32(command[4]))
            if !rom.isEmpty { address &= rom.count - 1 }
            // The secure area cannot be read in KEY2 mode; the card redirects it.
            if address < 0x8000 { address = 0x8000 + (address & 0x1FF) }
            buffer.reserveCapacity(length / 4)
            for i in stride(from: 0, to: length, by: 4) {
                let a = (address + i) & max(rom.count - 1, 0)
                if rom.count >= a + 4 {
                    buffer.append(UInt32(rom[a]) | UInt32(rom[a + 1]) << 8 | UInt32(rom[a + 2]) << 16 | UInt32(rom[a + 3]) << 24)
                } else {
                    buffer.append(0xFFFF_FFFF)
                }
            }
        case 0xB8, 0x90:
            buffer = [UInt32](repeating: Self.chipID, count: length / 4)
        default:
            buffer = [UInt32](repeating: 0xFFFF_FFFF, count: length / 4)
        }

        if buffer.isEmpty {
            finishTransfer()
        } else {
            romControl |= 0x0080_0000
            pumpDMA()
        }
    }

    /// Card DMA moves one word (or a few) per "data ready" request, so keep asking
    /// while the card has data and a card DMA channel is taking it.
    func pumpDMA() {
        guard let system else { return }
        while hasData {
            let before = bufferIndex
            system.dma9.trigger(.cartridge)
            system.dma7.trigger(.cartridge)
            if bufferIndex == before { break }  // no channel is reading the card
        }
    }

    /// 0x04100010: the next data word of the current transfer.
    func readData() -> UInt32 {
        guard bufferIndex < buffer.count else { return 0xFFFF_FFFF }
        let word = buffer[bufferIndex]
        bufferIndex += 1
        if bufferIndex == buffer.count { finishTransfer() }
        return word
    }

    var hasData: Bool { bufferIndex < buffer.count }

    private func finishTransfer() {
        romControl &= ~0x8080_0000
        if auxSPIControl & (1 << 14) != 0 {
            system?.irq9.raise(IRQ.cardTransferDone)
            system?.irq7.raise(IRQ.cardTransferDone)
        }
    }
}
