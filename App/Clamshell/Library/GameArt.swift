// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The icon and full title a game carries in its own file, for the library.
/// Nothing is fetched online: DS cartridges hold a 32 × 32 banner icon and the
/// title in several languages; .3dsx homebrew may append an SMDH with a 48 × 48 icon.
struct GameArt: Hashable {
    /// Icon pixels, RGBA8, row by row.
    var icon: [UInt8]
    var width: Int
    var height: Int
    /// The English title's lines, such as ["The Legend of Zelda", "Phantom Hourglass", "Nintendo"].
    var titleLines: [String]

    static func read(_ url: URL) -> GameArt? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        func bytes(_ offset: Int, _ count: Int) -> [UInt8]? {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return [UInt8](data)
        }
        if url.pathExtension.lowercased() == "3dsx" {
            guard let header = bytes(0, 0x28), header.prefix(4).elementsEqual("3DSX".utf8),
                  u16(header, 4) > 0x20 else { return nil }
            let offset = Int(u32(header, 0x20)), size = Int(u32(header, 0x24))
            guard size >= 0x36C0, let smdh = bytes(offset, 0x36C0) else { return nil }
            return smdhArt(smdh)
        }
        guard let header = bytes(0x68, 4), case let offset = Int(u32(header, 0)), offset != 0,
              let banner = bytes(offset, 0x440) else { return nil }
        return bannerArt(banner)
    }

    /// DS banner: a 4 × 4 grid of 8 × 8 tiles at 4 bits per pixel, a 16-colour
    /// BGR555 palette (colour 0 transparent), then 0x100-byte UTF-16 titles.
    static func bannerArt(_ b: [UInt8]) -> GameArt? {
        guard b.count >= 0x440 else { return nil }
        var icon = [UInt8](repeating: 0, count: 32 * 32 * 4)
        for y in 0..<32 {
            for x in 0..<32 {
                let tile = (y / 8) * 4 + x / 8
                let byte = b[0x20 + tile * 32 + (y % 8) * 4 + (x % 8) / 2]
                let index = Int(x & 1 == 0 ? byte & 0xF : byte >> 4)
                guard index != 0 else { continue }
                let c = u16(b, 0x220 + index * 2)
                let o = (y * 32 + x) * 4
                icon[o] = expand5(c); icon[o + 1] = expand5(c >> 5); icon[o + 2] = expand5(c >> 10); icon[o + 3] = 255
            }
        }
        let title = utf16(b, 0x340, 0x100)
        return GameArt(icon: icon, width: 32, height: 32, titleLines: lines(title))
    }

    /// SMDH: 0x200-byte title entries from 0x8 (English is the second), and the
    /// 48 × 48 RGB565 icon at 0x24C0 in 8 × 8 tiles with pixels in Morton order.
    static func smdhArt(_ b: [UInt8]) -> GameArt? {
        guard b.count >= 0x36C0, b.prefix(4).elementsEqual("SMDH".utf8) else { return nil }
        var icon = [UInt8](repeating: 0, count: 48 * 48 * 4)
        for i in 0..<(48 * 48) {
            let tile = i / 64, p = i % 64
            let tx = (p & 1) | (p >> 1 & 2) | (p >> 2 & 4), ty = (p >> 1 & 1) | (p >> 2 & 2) | (p >> 3 & 4)
            let x = (tile % 6) * 8 + tx, y = (tile / 6) * 8 + ty
            let c = u16(b, 0x24C0 + i * 2)
            let o = (y * 48 + x) * 4
            let r = UInt8(c >> 11), g = UInt8((c >> 5) & 0x3F), bl = UInt8(c & 0x1F)
            icon[o] = r << 3 | r >> 2; icon[o + 1] = g << 2 | g >> 4; icon[o + 2] = bl << 3 | bl >> 2; icon[o + 3] = 255
        }
        let entry = 0x8 + 0x200
        let name = utf16(b, entry + 0x80, 0x100), publisher = utf16(b, entry + 0x180, 0x80)
        return GameArt(icon: icon, width: 48, height: 48, titleLines: lines(name) + (publisher.isEmpty ? [] : [publisher]))
    }

    /// The icon's average opaque colour, for tinting the card behind it.
    var averageColor: (r: Double, g: Double, b: Double) {
        var r = 0, g = 0, b = 0, n = 0
        for o in stride(from: 0, to: icon.count, by: 4) where icon[o + 3] != 0 {
            r += Int(icon[o]); g += Int(icon[o + 1]); b += Int(icon[o + 2]); n += 1
        }
        guard n > 0 else { return (0.2, 0.25, 0.35) }
        return (Double(r) / Double(n) / 255, Double(g) / Double(n) / 255, Double(b) / Double(n) / 255)
    }

    private static func expand5(_ c: UInt16) -> UInt8 { let v = UInt8(c & 0x1F); return v << 3 | v >> 2 }
    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(u16(b, o)) | UInt32(u16(b, o + 2)) << 16 }

    private static func utf16(_ b: [UInt8], _ offset: Int, _ count: Int) -> String {
        var units: [UInt16] = []
        for o in stride(from: offset, to: offset + count, by: 2) {
            let u = u16(b, o)
            if u == 0 { break }
            units.append(u)
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
