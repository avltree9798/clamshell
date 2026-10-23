// SPDX-License-Identifier: GPL-3.0-or-later
//
// One of the DS's two 2D graphics engines. Engine A drives one screen and can
// show the 3D layer as BG0; engine B drives the other. Register layout and
// behaviour from GBATEK "DS Video".

/// Renders one scanline at a time, at HBlank, so mid-frame register changes
/// (raster effects) show the way they do on hardware.
final class Engine2D {
    let isA: Bool
    unowned(unsafe) let s: NDS

    /// The I/O registers at 0x04000000 (A) or 0x04001000 (B), as 32-bit words.
    private(set) var regs = [UInt32](repeating: 0, count: 0x70 / 4)
    /// BG2 and BG3 affine reference points as they advance down the screen (20.8 fixed point).
    private var affineX: (Int32, Int32) = (0, 0)
    private var affineY: (Int32, Int32) = (0, 0)

    /// The finished picture, 256 × 192, 0xAARRGGBB.
    let frame: UnsafeMutablePointer<UInt32>

    // Line buffers. BG and OBJ pixels hold BGR555 colour with `opaque` set when drawn.
    private let bgLine: UnsafeMutablePointer<UInt32>   // 4 × 256
    private let objLine: UnsafeMutablePointer<UInt32>
    private let objPriority: UnsafeMutablePointer<UInt8>
    /// Bit 0-3: alpha for bitmap OBJs; bit 4: semi-transparent; bit 5: bitmap OBJ.
    private let objMode: UnsafeMutablePointer<UInt8>
    private let objWindow: UnsafeMutablePointer<Bool>
    private let windowMasks: UnsafeMutablePointer<UInt8>

    static let opaque: UInt32 = 1 << 31
    /// 3D pixels also carry a 5-bit alpha in bits 16-20.
    static let alphaShift: UInt32 = 16

    init(isA: Bool, system: NDS) {
        self.isA = isA
        s = system
        frame = .allocate(capacity: 256 * 192)
        frame.initialize(repeating: 0xFF00_0000, count: 256 * 192)
        bgLine = .allocate(capacity: 4 * 256)
        bgLine.initialize(repeating: 0, count: 4 * 256)
        objLine = .allocate(capacity: 256)
        objLine.initialize(repeating: 0, count: 256)
        objPriority = .allocate(capacity: 256)
        objPriority.initialize(repeating: 4, count: 256)
        objMode = .allocate(capacity: 256)
        objMode.initialize(repeating: 0, count: 256)
        objWindow = .allocate(capacity: 256)
        objWindow.initialize(repeating: false, count: 256)
        windowMasks = .allocate(capacity: 256)
        windowMasks.initialize(repeating: 0x3F, count: 256)
    }

    deinit {
        frame.deallocate()
        bgLine.deallocate()
        objLine.deallocate()
        objPriority.deallocate()
        objMode.deallocate()
        objWindow.deallocate()
        windowMasks.deallocate()
    }

    func reset() {
        regs = [UInt32](repeating: 0, count: regs.count)
        affineX = (0, 0)
        affineY = (0, 0)
    }

    // MARK: - Registers

    var dispcnt: UInt32 { regs[0] }
    @inline(__always) private func bgcnt(_ i: Int) -> UInt32 { (regs[2 + i / 2] >> UInt32((i & 1) * 16)) & 0xFFFF }
    @inline(__always) private func hofs(_ i: Int) -> Int { Int(regs[4 + i] & 0x1FF) }
    @inline(__always) private func vofs(_ i: Int) -> Int { Int((regs[4 + i] >> 16) & 0x1FF) }
    /// PA, PB, PC, PD of BG2 (n = 0) or BG3 (n = 1), signed 8.8.
    @inline(__always) private func affine(_ n: Int) -> (Int32, Int32, Int32, Int32) {
        let w0 = regs[8 + n * 4], w1 = regs[9 + n * 4]
        return (Int32(Int16(truncatingIfNeeded: w0)), Int32(Int16(truncatingIfNeeded: w0 >> 16)),
                Int32(Int16(truncatingIfNeeded: w1)), Int32(Int16(truncatingIfNeeded: w1 >> 16)))
    }
    /// The 28-bit signed reference point register.
    @inline(__always) private func reference(_ word: Int) -> Int32 { Int32(bitPattern: regs[word] << 4) >> 4 }

    private static let readable: Set<Int> = [0x00, 0x08, 0x0C, 0x48, 0x50, 0x60, 0x64, 0x6C]

    func read(_ offset: UInt32) -> UInt32 {
        let o = Int(offset)
        guard o < 0x70, Self.readable.contains(o) else { return 0 }
        if o == 0x50 { return regs[o / 4] & 0x1F1F_3FFF }
        return regs[o / 4]
    }

    func write(_ offset: UInt32, _ value: UInt32, mask: UInt32) {
        let o = Int(offset)
        guard o < 0x70 else { return }
        regs[o / 4] = (regs[o / 4] & ~mask) | (value & mask)
        switch o {
        case 0x28: affineX.0 = reference(0x28 / 4)
        case 0x2C: affineY.0 = reference(0x2C / 4)
        case 0x38: affineX.1 = reference(0x38 / 4)
        case 0x3C: affineY.1 = reference(0x3C / 4)
        default: break
        }
    }

    // MARK: - Memory

    private var palette: UnsafeMutableRawPointer { s.palette.base + (isA ? 0 : 0x400) }
    private var oam: UnsafeMutableRawPointer { s.oam.base + (isA ? 0 : 0x400) }
    private var bgPages: VRAMMap.Table { isA ? s.vramMap.bgA : s.vramMap.bgB }
    private var objPages: VRAMMap.Table { isA ? s.vramMap.objA : s.vramMap.objB }

    @inline(__always) private static func vram8(_ pages: VRAMMap.Table, _ vram: UnsafeMutableRawPointer, _ a: Int) -> UInt8 {
        let page = pages[(a >> 14) & (pages.count - 1)]
        if page < 0 { return 0 }
        return vram.load(fromByteOffset: Int(page) + (a & 0x3FFF), as: UInt8.self)
    }

    @inline(__always) private static func vram16(_ pages: VRAMMap.Table, _ vram: UnsafeMutableRawPointer, _ a: Int) -> UInt16 {
        let page = pages[(a >> 14) & (pages.count - 1)]
        if page < 0 { return 0 }
        return vram.load(fromByteOffset: Int(page) + (a & 0x3FFE), as: UInt16.self)
    }

    /// An entry of extended palette slot `slot` of the given table, or 0 if unmapped.
    @inline(__always) private static func extPalette(_ table: VRAMMap.Table, slot: Int, _ index: Int, _ vram: UnsafeMutableRawPointer) -> UInt32 {
        let base = table[slot]
        if base < 0 { return 0 }
        return UInt32(vram.load(fromByteOffset: Int(base) + index * 2, as: UInt16.self))
    }

    // MARK: - Scanline

    func renderLine(_ y: Int) {
        let out = frame + y * 256
        if y == 0 {
            affineX = (reference(0x28 / 4), reference(0x38 / 4))
            affineY = (reference(0x2C / 4), reference(0x3C / 4))
        }
        let enabled = s.powcnt1 & (isA ? 1 << 1 : 1 << 9) != 0
        let mode = isA ? (dispcnt >> 16) & 3 : (dispcnt >> 16) & 1
        guard enabled else {
            out.update(repeating: 0xFF00_0000, count: 256)
            return
        }
        switch mode {
        case 0:
            out.update(repeating: 0xFFFF_FFFF, count: 256)
        case 2:
            // VRAM display: a whole bank (A-D) shown as RGB555.
            let bank = Int((dispcnt >> 18) & 3) * 0x20000 + y * 512
            let vram = s.vram.base
            for x in 0..<256 { out[x] = NDS.bgra(from: vram.load(fromByteOffset: bank + x * 2, as: UInt16.self)) }
        case 3:
            out.update(repeating: 0xFF00_0000, count: 256)  // main-memory display FIFO: not emulated
        default:
            if dispcnt & 0x80 != 0 {
                out.update(repeating: 0xFFFF_FFFF, count: 256)  // forced blank
            } else {
                renderNormal(y, into: out)
            }
        }
        applyMasterBrightness(out)
        advanceAffine()
    }

    private func advanceAffine() {
        let (_, pb2, _, pd2) = affine(0), (_, pb3, _, pd3) = affine(1)
        affineX.0 &+= pb2; affineY.0 &+= pd2
        affineX.1 &+= pb3; affineY.1 &+= pd3
    }

    private enum Kind { case none, text, affine, extended, large, threeD }

    private func kind(of bg: Int) -> Kind {
        let mode = Int(dispcnt & 7)
        if bg == 0 && isA && dispcnt & 8 != 0 { return .threeD }
        switch (mode, bg) {
        case (_, 0), (_, 1): return mode == 6 ? (bg == 0 ? .threeD : .none) : .text
        case (0, _), (1, 2), (3, 2): return .text
        case (1, 3), (2, _), (4, 2): return .affine
        case (3, 3), (4, 3), (5, _): return .extended
        case (6, 2): return isA ? .large : .none
        default: return .none
        }
    }

    private func renderNormal(_ y: Int, into out: UnsafeMutablePointer<UInt32>) {
        // Backgrounds, in drawing order: lowest priority value first, then lowest BG number.
        var order: [Int] = []
        for bg in 0..<4 where dispcnt & (1 << UInt32(8 + bg)) != 0 {
            let line = bgLine + bg * 256
            switch kind(of: bg) {
            case .none: continue
            case .text: renderText(bg, y, line)
            case .affine: renderAffine(bg, line, extended: false)
            case .extended: renderAffine(bg, line, extended: true)
            case .large: renderLarge(bg, line)
            case .threeD: render3DLayer(y, line)
            }
            order.append(bg)
        }
        order.sort { (bgcnt($0) & 3, $0) < (bgcnt($1) & 3, $1) }

        objPriority.update(repeating: 4, count: 256)
        objWindow.update(repeating: false, count: 256)
        if dispcnt & (1 << 12) != 0 { renderObjects(y) }

        compose(y, order: order, into: out)
    }

    /// BG0 showing the 3D picture, scrolled horizontally by BG0HOFS.
    private func render3DLayer(_ y: Int, _ line: UnsafeMutablePointer<UInt32>) {
        let source = s.gpu3D.colorBuffer + y * 256
        let scroll = Int(Int16(truncatingIfNeeded: UInt16(hofs(0)) << 7) >> 7)
        for x in 0..<256 {
            let sx = x + scroll
            line[x] = sx >= 0 && sx < 256 ? source[sx] : 0
        }
    }

    // MARK: - Text backgrounds

    private func renderText(_ bg: Int, _ y: Int, _ line: UnsafeMutablePointer<UInt32>) {
        let cnt = bgcnt(bg)
        let extraBase = isA ? Int((dispcnt >> 24) & 7) * 0x10000 : 0
        let charBase = Int((cnt >> 2) & 0xF) * 0x4000 + extraBase
        let screenBase = Int((cnt >> 8) & 0x1F) * 0x800 + (isA ? Int((dispcnt >> 27) & 7) * 0x10000 : 0)
        let wide = cnt & 0x4000 != 0, tall = cnt & 0x8000 != 0
        let widthMask = wide ? 511 : 255, heightMask = tall ? 511 : 255
        let yy = (y + vofs(bg)) & heightMask
        let color256 = cnt & 0x80 != 0
        let useExt = color256 && dispcnt & (1 << 30) != 0
        let extSlot = bg < 2 && cnt & 0x2000 != 0 ? bg + 2 : bg
        let extTable = isA ? s.vramMap.bgExtA : s.vramMap.bgExtB
        let pages = bgPages, vram = s.vram.base, pal = palette
        let rowBase = screenBase + (yy >= 256 ? (wide ? 0x1000 : 0x800) : 0) + ((yy & 255) >> 3) * 64
        let hofs = hofs(bg)

        var x = 0
        while x < 256 {
            let xx = (x + hofs) & widthMask
            let entry = Int(Self.vram16(pages, vram, rowBase + (xx >= 256 ? 0x800 : 0) + ((xx & 255) >> 3) * 2))
            let tile = entry & 0x3FF, palNum = entry >> 12
            let py = (yy & 7) ^ (entry & 0x800 != 0 ? 7 : 0)
            let hflip = entry & 0x400 != 0 ? 7 : 0
            // Draw to the end of this tile.
            var px = xx & 7
            while px < 8 && x < 256 {
                let tx = px ^ hflip
                var color: UInt32 = 0
                if color256 {
                    let index = Int(Self.vram8(pages, vram, charBase + tile * 64 + py * 8 + tx))
                    if index != 0 {
                        color = Self.opaque | (useExt ? Self.extPalette(extTable, slot: extSlot, palNum * 256 + index, vram)
                                                      : UInt32(pal.load(fromByteOffset: index * 2, as: UInt16.self)))
                    }
                } else {
                    let byte = Self.vram8(pages, vram, charBase + tile * 32 + py * 4 + tx / 2)
                    let index = Int(tx & 1 != 0 ? byte >> 4 : byte & 0xF)
                    if index != 0 { color = Self.opaque | UInt32(pal.load(fromByteOffset: (palNum * 16 + index) * 2, as: UInt16.self)) }
                }
                line[x] = color
                px += 1
                x += 1
            }
        }
    }

    // MARK: - Affine and extended backgrounds

    private func renderAffine(_ bg: Int, _ line: UnsafeMutablePointer<UInt32>, extended: Bool) {
        let n = bg - 2
        let cnt = bgcnt(bg)
        let (pa, _, pc, _) = affine(n)
        var ax = n == 0 ? affineX.0 : affineX.1
        var ay = n == 0 ? affineY.0 : affineY.1
        let wrap = cnt & 0x2000 != 0
        let pages = bgPages, vram = s.vram.base, pal = palette
        let sizeBits = Int((cnt >> 14) & 3)

        if extended && cnt & 0x80 != 0 {
            // Bitmap: 256-colour or direct colour.
            let sizes = [(128, 128), (256, 256), (512, 256), (512, 512)]
            let (w, h) = sizes[sizeBits]
            let base = Int((cnt >> 8) & 0x1F) * 0x4000
            let direct = cnt & 0x4 != 0
            for x in 0..<256 {
                var tx = Int(ax >> 8), ty = Int(ay >> 8)
                ax &+= pa; ay &+= pc
                if wrap { tx &= w - 1; ty &= h - 1 } else if tx < 0 || tx >= w || ty < 0 || ty >= h { line[x] = 0; continue }
                if direct {
                    let c = UInt32(Self.vram16(pages, vram, base + (ty * w + tx) * 2))
                    line[x] = c & 0x8000 != 0 ? Self.opaque | (c & 0x7FFF) : 0
                } else {
                    let index = Int(Self.vram8(pages, vram, base + ty * w + tx))
                    line[x] = index == 0 ? 0 : Self.opaque | UInt32(pal.load(fromByteOffset: index * 2, as: UInt16.self))
                }
            }
            return
        }

        let size = 128 << sizeBits
        let charBase = Int((cnt >> 2) & 0xF) * 0x4000 + (isA ? Int((dispcnt >> 24) & 7) * 0x10000 : 0)
        let screenBase = Int((cnt >> 8) & 0x1F) * 0x800 + (isA ? Int((dispcnt >> 27) & 7) * 0x10000 : 0)
        let useExt = dispcnt & (1 << 30) != 0
        let extTable = isA ? s.vramMap.bgExtA : s.vramMap.bgExtB
        let tilesPerRow = size / 8
        for x in 0..<256 {
            var tx = Int(ax >> 8), ty = Int(ay >> 8)
            ax &+= pa; ay &+= pc
            if wrap { tx &= size - 1; ty &= size - 1 } else if tx < 0 || tx >= size || ty < 0 || ty >= size { line[x] = 0; continue }
            let index: Int
            var palNum = 0
            if extended {
                // 16-bit map entries with flips and (extended) palettes.
                let entry = Int(Self.vram16(pages, vram, screenBase + ((ty >> 3) * tilesPerRow + (tx >> 3)) * 2))
                let px = (tx & 7) ^ (entry & 0x400 != 0 ? 7 : 0), py = (ty & 7) ^ (entry & 0x800 != 0 ? 7 : 0)
                index = Int(Self.vram8(pages, vram, charBase + (entry & 0x3FF) * 64 + py * 8 + px))
                palNum = entry >> 12
            } else {
                let tile = Int(Self.vram8(pages, vram, screenBase + (ty >> 3) * tilesPerRow + (tx >> 3)))
                index = Int(Self.vram8(pages, vram, charBase + tile * 64 + (ty & 7) * 8 + (tx & 7)))
            }
            if index == 0 { line[x] = 0; continue }
            if extended && useExt {
                line[x] = Self.opaque | Self.extPalette(extTable, slot: bg, palNum * 256 + index, vram)
            } else {
                line[x] = Self.opaque | UInt32(pal.load(fromByteOffset: index * 2, as: UInt16.self))
            }
        }
    }

    /// Mode 6 BG2: one 512 × 1024 or 1024 × 512 256-colour bitmap filling engine A's BG VRAM.
    private func renderLarge(_ bg: Int, _ line: UnsafeMutablePointer<UInt32>) {
        let cnt = bgcnt(bg)
        let (pa, _, pc, _) = affine(0)
        var ax = affineX.0, ay = affineY.0
        let (w, h) = cnt & 0x4000 != 0 ? (1024, 512) : (512, 1024)
        let wrap = cnt & 0x2000 != 0
        let pages = bgPages, vram = s.vram.base, pal = palette
        for x in 0..<256 {
            var tx = Int(ax >> 8), ty = Int(ay >> 8)
            ax &+= pa; ay &+= pc
            if wrap { tx &= w - 1; ty &= h - 1 } else if tx < 0 || tx >= w || ty < 0 || ty >= h { line[x] = 0; continue }
            let index = Int(Self.vram8(pages, vram, ty * w + tx))
            line[x] = index == 0 ? 0 : Self.opaque | UInt32(pal.load(fromByteOffset: index * 2, as: UInt16.self))
        }
    }

    // MARK: - Objects

    private static let objSizes: [(Int, Int)] = [
        (8, 8), (16, 16), (32, 32), (64, 64),     // square
        (16, 8), (32, 8), (32, 16), (64, 32),     // wide
        (8, 16), (8, 32), (16, 32), (32, 64),     // tall
        (8, 8), (8, 8), (8, 8), (8, 8),           // prohibited
    ]

    private func renderObjects(_ y: Int) {
        let oam = oam, pages = objPages, vram = s.vram.base
        let objPalette = palette + 0x200
        let useExt = dispcnt & (1 << 31) != 0
        let extTable = isA ? s.vramMap.objExtA : s.vramMap.objExtB
        let oneD = dispcnt & 0x10 != 0
        let boundary = 32 << Int((dispcnt >> 20) & 3)
        let bitmap1D = dispcnt & 0x40 != 0
        let bitmapBoundary = 128 << Int((dispcnt >> 22) & 1)
        let bitmapWide = dispcnt & 0x20 != 0

        for n in 0..<128 {
            let a0 = Int(oam.load(fromByteOffset: n * 8, as: UInt16.self))
            let a1 = Int(oam.load(fromByteOffset: n * 8 + 2, as: UInt16.self))
            let a2 = Int(oam.load(fromByteOffset: n * 8 + 4, as: UInt16.self))
            let isAffine = a0 & 0x100 != 0
            if !isAffine && a0 & 0x200 != 0 { continue }  // hidden
            let mode = (a0 >> 10) & 3
            let (w, h) = Self.objSizes[((a0 >> 14) & 3) * 4 + ((a1 >> 14) & 3)]
            let double = isAffine && a0 & 0x200 != 0
            let bw = double ? w * 2 : w, bh = double ? h * 2 : h
            let row = (y - (a0 & 0xFF)) & 0xFF
            if row >= bh { continue }
            var ox = a1 & 0x1FF
            if ox >= 256 { ox -= 512 }
            let priority = UInt8((a2 >> 10) & 3)
            let tileNumber = a2 & 0x3FF
            let color256 = a0 & 0x2000 != 0
            let palNum = a2 >> 12

            var pa = 256, pb = 0, pc = 0, pd = 256
            if isAffine {
                let group = ((a1 >> 9) & 31) * 32
                pa = Int(oam.load(fromByteOffset: group + 6, as: Int16.self))
                pb = Int(oam.load(fromByteOffset: group + 14, as: Int16.self))
                pc = Int(oam.load(fromByteOffset: group + 22, as: Int16.self))
                pd = Int(oam.load(fromByteOffset: group + 30, as: Int16.self))
            }
            let hflip = !isAffine && a1 & 0x1000 != 0, vflip = !isAffine && a1 & 0x2000 != 0

            for sx in 0..<bw {
                let x = ox + sx
                if x < 0 { continue }
                if x >= 256 { break }
                var tx: Int, ty: Int
                if isAffine {
                    let cx = sx - bw / 2, cy = row - bh / 2
                    tx = ((pa * cx + pb * cy) >> 8) + w / 2
                    ty = ((pc * cx + pd * cy) >> 8) + h / 2
                    if tx < 0 || tx >= w || ty < 0 || ty >= h { continue }
                } else {
                    tx = hflip ? w - 1 - sx : sx
                    ty = vflip ? h - 1 - row : row
                }

                var color: UInt32 = 0
                if mode == 3 {
                    let address: Int
                    if bitmap1D {
                        address = tileNumber * bitmapBoundary + (ty * w + tx) * 2
                    } else if bitmapWide {
                        address = (tileNumber & 0x1F) * 0x10 + (tileNumber & 0x3E0) * 0x80 + ty * 512 + tx * 2
                    } else {
                        address = (tileNumber & 0xF) * 0x10 + (tileNumber & 0x3F0) * 0x80 + ty * 256 + tx * 2
                    }
                    let c = UInt32(Self.vram16(pages, vram, address))
                    if c & 0x8000 == 0 { continue }
                    color = Self.opaque | (c & 0x7FFF)
                } else {
                    let tileIndex: Int, base: Int
                    if oneD {
                        base = tileNumber * boundary
                        tileIndex = (ty >> 3) * (w >> 3) + (tx >> 3)
                    } else {
                        base = tileNumber * 32
                        tileIndex = (ty >> 3) * (color256 ? 16 : 32) + (tx >> 3)
                    }
                    let index: Int
                    if color256 {
                        index = Int(Self.vram8(pages, vram, base + tileIndex * 64 + (ty & 7) * 8 + (tx & 7)))
                    } else {
                        let byte = Self.vram8(pages, vram, base + tileIndex * 32 + (ty & 7) * 4 + (tx & 7) / 2)
                        index = Int(tx & 1 != 0 ? byte >> 4 : byte & 0xF)
                    }
                    if index == 0 { continue }
                    if mode == 2 {
                        objWindow[x] = true
                        continue
                    }
                    if color256 {
                        color = Self.opaque | (useExt ? Self.extPalette(extTable, slot: 0, palNum * 256 + index, vram)
                                                      : UInt32(objPalette.load(fromByteOffset: index * 2, as: UInt16.self)))
                    } else {
                        color = Self.opaque | UInt32(objPalette.load(fromByteOffset: (palNum * 16 + index) * 2, as: UInt16.self))
                    }
                }
                // Lower OAM entries win ties, so only a strictly better priority replaces a pixel.
                if priority < objPriority[x] {
                    objLine[x] = color
                    objPriority[x] = priority
                    objMode[x] = mode == 1 ? 0x10 : mode == 3 ? 0x20 | UInt8(palNum) : 0
                }
            }
        }
    }

    // MARK: - Windows, blending, output

    /// Bits 0-3 BG0-3, 4 OBJ, 5 colour effects: what each pixel's window allows.
    private func windowMask(_ y: Int, _ masks: UnsafeMutablePointer<UInt8>) {
        let winEnable = (dispcnt >> 13) & 7
        if winEnable == 0 {
            masks.update(repeating: 0x3F, count: 256)
            return
        }
        let winin = regs[0x48 / 4] & 0xFFFF, winout = regs[0x48 / 4] >> 16
        masks.update(repeating: UInt8(winout & 0x3F), count: 256)
        if winEnable & 4 != 0 {
            for x in 0..<256 where objWindow[x] { masks[x] = UInt8((winout >> 8) & 0x3F) }
        }
        for win in [1, 0] where winEnable & (1 << UInt32(win)) != 0 {
            let hreg = (regs[0x40 / 4] >> UInt32(win * 16)) & 0xFFFF
            let vreg = (regs[0x44 / 4] >> UInt32(win * 16)) & 0xFFFF
            let x1 = Int(hreg >> 8), x2 = Int(hreg & 0xFF), y1 = Int(vreg >> 8), y2 = Int(vreg & 0xFF)
            let insideY = y1 <= y2 ? (y >= y1 && y < y2) : (y >= y1 || y < y2)
            guard insideY else { continue }
            let allow = UInt8((winin >> UInt32(win * 8)) & 0x3F)
            for x in 0..<256 {
                let inside = x1 <= x2 ? (x >= x1 && x < x2) : (x >= x1 || x < x2)
                if inside { masks[x] = allow }
            }
        }
    }

    private func compose(_ y: Int, order: [Int], into out: UnsafeMutablePointer<UInt32>) {
        let masks = windowMasks
        windowMask(y, masks)

        let backdrop = UInt32(palette.load(as: UInt16.self)) & 0x7FFF
        let bldcnt = regs[0x50 / 4] & 0xFFFF
        let effect = (bldcnt >> 6) & 3
        let first = bldcnt & 0x3F, second = (bldcnt >> 8) & 0x3F
        let alpha = regs[0x50 / 4] >> 16
        let eva = min(alpha & 0x1F, 16), evb = min((alpha >> 8) & 0x1F, 16)
        let evy = min(regs[0x54 / 4] & 0x1F, 16)
        let priorities = order.map { UInt8(bgcnt($0) & 3) }
        let bg0Is3D = kind(of: 0) == .threeD

        for x in 0..<256 {
            let mask = masks[x]
            // The two frontmost layers: (colour, layer bit). Layer bits: 0-3 BG, 4 OBJ, 5 backdrop.
            var topColor = backdrop, topLayer: UInt32 = 5
            var underColor = backdrop, underLayer: UInt32 = 5
            var found = 0
            let objOn = mask & 0x10 != 0 && objLine[x] & Self.opaque != 0 && objPriority[x] < 4
            var objDone = !objOn
            var i = 0
            while found < 2 {
                // Next candidate: OBJ wins over a BG of the same priority.
                let bgPriority: UInt8 = i < order.count ? priorities[i] : 4
                var color: UInt32, layer: UInt32
                if !objDone && objPriority[x] <= bgPriority {
                    color = objLine[x]; layer = 4; objDone = true
                } else if i < order.count {
                    let bg = order[i]
                    i += 1
                    guard mask & (1 << UInt8(bg)) != 0 else { continue }
                    color = bgLine[bg * 256 + x]
                    guard color & Self.opaque != 0 else { continue }
                    layer = UInt32(bg)
                } else {
                    break
                }
                if found == 0 { topColor = color; topLayer = layer } else { underColor = color; underLayer = layer }
                found += 1
            }

            var result = topColor & 0x7FFF
            let effectsOn = mask & 0x20 != 0
            let underIsSecond = second & (1 << underLayer) != 0
            if topLayer == 4 && objMode[x] & 0x30 != 0 && underIsSecond {
                // Semi-transparent and bitmap objects always blend with a second-target layer below.
                if objMode[x] & 0x20 != 0 {
                    let a = UInt32(objMode[x] & 0xF) + 1
                    result = Self.blend(result, underColor, a, 16 - a)
                } else {
                    result = Self.blend(result, underColor, eva, evb)
                }
            } else if topLayer == 0 && bg0Is3D && underIsSecond {
                // The 3D layer blends by its own per-pixel alpha (0-31).
                let a = (topColor >> Self.alphaShift) & 0x1F
                if a < 31 { result = Self.blend32(result, underColor, a + 1) }
            } else if effectsOn && first & (1 << topLayer) != 0 {
                switch effect {
                case 1: if underIsSecond { result = Self.blend(result, underColor, eva, evb) }
                case 2: result = Self.brighten(result, evy)
                case 3: result = Self.darken(result, evy)
                default: break
                }
            }
            out[x] = NDS.bgra(from: UInt16(truncatingIfNeeded: result))
        }
    }

    @inline(__always) static func blend(_ a: UInt32, _ b: UInt32, _ eva: UInt32, _ evb: UInt32) -> UInt32 {
        let r = min(((a & 0x1F) * eva + (b & 0x1F) * evb) >> 4, 31)
        let g = min((((a >> 5) & 0x1F) * eva + ((b >> 5) & 0x1F) * evb) >> 4, 31)
        let bl = min((((a >> 10) & 0x1F) * eva + ((b >> 10) & 0x1F) * evb) >> 4, 31)
        return r | g << 5 | bl << 10
    }

    /// Blends with weights out of 32, as the 3D layer's alpha does.
    @inline(__always) static func blend32(_ a: UInt32, _ b: UInt32, _ weight: UInt32) -> UInt32 {
        let inverse = 32 - weight
        let r = ((a & 0x1F) * weight + (b & 0x1F) * inverse) >> 5
        let g = (((a >> 5) & 0x1F) * weight + ((b >> 5) & 0x1F) * inverse) >> 5
        let bl = (((a >> 10) & 0x1F) * weight + ((b >> 10) & 0x1F) * inverse) >> 5
        return r | g << 5 | bl << 10
    }

    @inline(__always) static func brighten(_ c: UInt32, _ evy: UInt32) -> UInt32 {
        let r = c & 0x1F, g = (c >> 5) & 0x1F, b = (c >> 10) & 0x1F
        return (r + ((31 - r) * evy >> 4)) | (g + ((31 - g) * evy >> 4)) << 5 | (b + ((31 - b) * evy >> 4)) << 10
    }

    @inline(__always) static func darken(_ c: UInt32, _ evy: UInt32) -> UInt32 {
        let r = c & 0x1F, g = (c >> 5) & 0x1F, b = (c >> 10) & 0x1F
        return (r - (r * evy >> 4)) | (g - (g * evy >> 4)) << 5 | (b - (b * evy >> 4)) << 10
    }

    /// MASTER_BRIGHT: fades the whole screen to white or black, on the final 8-bit colour.
    private func applyMasterBrightness(_ out: UnsafeMutablePointer<UInt32>) {
        let reg = regs[0x6C / 4]
        let mode = (reg >> 14) & 3, factor = min(reg & 0x1F, 16)
        guard factor != 0, mode == 1 || mode == 2 else { return }
        for x in 0..<256 {
            let c = out[x]
            var r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF
            if mode == 1 {
                r += (255 - r) * factor / 16; g += (255 - g) * factor / 16; b += (255 - b) * factor / 16
            } else {
                r -= r * factor / 16; g -= g * factor / 16; b -= b * factor / 16
            }
            out[x] = 0xFF00_0000 | r << 16 | g << 8 | b
        }
    }
}
