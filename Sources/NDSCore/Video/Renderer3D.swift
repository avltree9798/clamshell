// SPDX-License-Identifier: GPL-3.0-or-later
//
// The DS 3D rendering engine: rasterises the polygon list into a 256 × 192
// colour buffer that engine A shows as BG0. Texture formats and blending from
// GBATEK "DS 3D Texture Formats" and "DS 3D Polygon Attributes".

extension GPU3D {
    var disp3dcnt: UInt32 { s.engineA.regs[0x60 / 4] }

    func render() {
        let control = disp3dcnt
        // Clear: colour with alpha and polygon ID, depth from CLEAR_DEPTH.
        let clearRGB = clearColor & 0x7FFF
        let clearAlpha = (clearColor >> 16) & 0x1F
        let clearValue = clearRGB | clearAlpha << Engine2D.alphaShift | (clearAlpha != 0 ? Engine2D.opaque : 0)
        colorBuffer.update(repeating: clearValue, count: 256 * 192)
        let depth = Float((clearDepth & 0x7FFF) * 0x200 + 0x1FF)
        depthBuffer.update(repeating: renderingWBuffer ? depth / 4096 : depth / Float(0xFF_FFFF), count: 256 * 192)
        // Attribute buffer: polygon ID in bits 24-29, bit 31 marks a translucent pixel's ID.
        attributeBuffer.update(repeating: ((clearColor >> 24) & 0x3F) << 24 | (clearColor & 0x8000), count: 256 * 192)

        let texturesOn = control & 1 != 0
        for polygon in rendering where !polygon.translucent { rasterise(polygon, control: control, textures: texturesOn) }
        var translucent = rendering.filter { $0.translucent }
        if !renderingManualSort {
            // Automatic sorting: by bottom-most Y, then top-most Y.
            translucent.sort { a, b in
                let ay = a.vertices.map(\.y).max() ?? 0, by = b.vertices.map(\.y).max() ?? 0
                return ay < by
            }
        }
        for polygon in translucent { rasterise(polygon, control: control, textures: texturesOn) }
        if control & (1 << 7) != 0 { applyFog(control) }
    }

    // MARK: - Rasteriser

    private func rasterise(_ polygon: Polygon3D, control: UInt32, textures: Bool) {
        let v = polygon.vertices
        guard v.count >= 3 else { return }
        for i in 1..<(v.count - 1) {
            triangle(v[0], v[i], v[i + 1], polygon, control: control, textures: textures,
                     wireframeEdges: (i == 1, true, i == v.count - 2))
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func triangle(_ a: Polygon3D.Vertex, _ b: Polygon3D.Vertex, _ c: Polygon3D.Vertex, _ polygon: Polygon3D,
                          control: UInt32, textures: Bool, wireframeEdges: (Bool, Bool, Bool)) {
        let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        if area == 0 { return }
        let minX = max(0, Int(min(a.x, b.x, c.x).rounded(.down)))
        let maxX = min(255, Int(max(a.x, b.x, c.x).rounded(.up)))
        let minY = max(0, Int(min(a.y, b.y, c.y).rounded(.down)))
        let maxY = min(191, Int(max(a.y, b.y, c.y).rounded(.up)))
        if minX > maxX || minY > maxY { return }

        let attributes = polygon.attributes
        let polyAlpha = (attributes >> 16) & 0x1F
        let wireframe = polyAlpha == 0
        let alpha = wireframe ? 31 : polyAlpha
        let mode = (attributes >> 4) & 3
        if mode == 3 { return }  // shadow polygons: not emulated yet
        let polygonID = (attributes >> 24) & 0x3F
        let depthEqual = attributes & (1 << 14) != 0
        let updateDepthTranslucent = attributes & (1 << 11) != 0
        let alphaTest = control & (1 << 2) != 0
        let alphaRef = alphaTestRef & 0x1F
        let blending = control & (1 << 3) != 0
        let highlight = control & (1 << 1) != 0
        let fogBit = attributes & (1 << 15) != 0 ? UInt32(1) << 15 : 0
        let texParam = polygon.textureParameters
        let format = textures ? (texParam >> 26) & 7 : 0
        let texWidth = 8 << Int((texParam >> 20) & 7), texHeight = 8 << Int((texParam >> 23) & 7)
        let invArea = 1 / area
        let sign: Float = area > 0 ? 1 : -1
        let len0 = (c.x - b.x).magnitude + (c.y - b.y).magnitude
        let len1 = (a.x - c.x).magnitude + (a.y - c.y).magnitude
        let len2 = (b.x - a.x).magnitude + (b.y - a.y).magnitude

        for y in minY...maxY {
            let py = Float(y) + 0.5
            for x in minX...maxX {
                let px = Float(x) + 0.5
                // Edge functions, positive inside for either winding.
                var w0 = ((c.x - b.x) * (py - b.y) - (c.y - b.y) * (px - b.x)) * sign
                var w1 = ((a.x - c.x) * (py - c.y) - (a.y - c.y) * (px - c.x)) * sign
                var w2 = ((b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x)) * sign
                if w0 < 0 || w1 < 0 || w2 < 0 { continue }
                if wireframe {
                    let near0 = wireframeEdges.1 && w0 / max(len0, 1) < 1
                    let near1 = wireframeEdges.2 && w1 / max(len1, 1) < 1
                    let near2 = wireframeEdges.0 && w2 / max(len2, 1) < 1
                    if !(near0 || near1 || near2) { continue }
                }
                w0 *= invArea * sign; w1 *= invArea * sign; w2 *= invArea * sign
                let index = y * 256 + x

                // Depth: Z interpolates linearly in screen space, W perspective-correctly.
                let invW = w0 * a.invW + w1 * b.invW + w2 * c.invW
                let depth = renderingWBuffer ? 1 / max(invW, 1e-12) / 4096 : w0 * a.depth + w1 * b.depth + w2 * c.depth
                let stored = depthBuffer[index]
                if depthEqual {
                    if abs(depth - stored) > (renderingWBuffer ? 0.01 : 0.0002) { continue }
                } else if depth >= stored {
                    continue
                }

                let p0 = w0 * a.invW / invW, p1 = w1 * b.invW / invW, p2 = w2 * c.invW / invW
                var r = p0 * a.r + p1 * b.r + p2 * c.r
                var g = p0 * a.g + p1 * b.g + p2 * c.g
                var bl = p0 * a.b + p1 * b.b + p2 * c.b
                var pixelAlpha = alpha

                if format != 0 {
                    let s = Int((p0 * a.s + p1 * b.s + p2 * c.s).rounded(.down))
                    let t = Int((p0 * a.t + p1 * b.t + p2 * c.t).rounded(.down))
                    guard let texel = sampleTexture(texParam, palette: polygon.paletteBase, s: s, t: t,
                                                    width: texWidth, height: texHeight, format: format) else { continue }
                    let tr = Float(texel.color & 0x1F), tg = Float((texel.color >> 5) & 0x1F), tb = Float((texel.color >> 10) & 0x1F)
                    switch mode {
                    case 1:  // decal
                        let ta = Float(texel.alpha)
                        r = (tr * ta + r * (31 - ta)) / 31
                        g = (tg * ta + g * (31 - ta)) / 31
                        bl = (tb * ta + bl * (31 - ta)) / 31
                    default:  // modulate (and toon/highlight, which modulate a shaded colour)
                        if mode == 2 { (r, g, bl) = toonShade(r, g, bl, highlight: highlight) }
                        r = ((tr * 2 + 1) * (r * 2 + 1) - 1) / 128
                        g = ((tg * 2 + 1) * (g * 2 + 1) - 1) / 128
                        bl = ((tb * 2 + 1) * (bl * 2 + 1) - 1) / 128
                        pixelAlpha = ((texel.alpha + 1) * (alpha + 1) - 1) / 32
                    }
                    if mode == 2 && highlight { (r, g, bl) = addHighlight(r, g, bl, original: (p0 * a.r + p1 * b.r + p2 * c.r)) }
                } else if mode == 2 {
                    (r, g, bl) = toonShade(r, g, bl, highlight: highlight)
                    if highlight { (r, g, bl) = addHighlight(r, g, bl, original: p0 * a.r + p1 * b.r + p2 * c.r) }
                }

                if pixelAlpha == 0 { continue }
                if alphaTest && pixelAlpha <= alphaRef { continue }
                let color = UInt32(min(max(r, 0), 31)) | UInt32(min(max(g, 0), 31)) << 5 | UInt32(min(max(bl, 0), 31)) << 10

                if pixelAlpha == 31 {
                    colorBuffer[index] = color | 31 << Engine2D.alphaShift | Engine2D.opaque
                    depthBuffer[index] = depth
                    attributeBuffer[index] = polygonID << 24 | fogBit
                    continue
                }
                // Translucent: a polygon ID never overdraws its own translucent pixels.
                let attr = attributeBuffer[index]
                if attr & (1 << 31) != 0 && (attr >> 24) & 0x3F == polygonID { continue }
                let dst = colorBuffer[index]
                let dstAlpha = (dst >> Engine2D.alphaShift) & 0x1F
                var out = color, outAlpha = pixelAlpha
                if blending && dstAlpha != 0 {
                    out = Engine2D.blend32(color, dst, pixelAlpha + 1)
                    outAlpha = max(pixelAlpha, dstAlpha)
                }
                colorBuffer[index] = out | outAlpha << Engine2D.alphaShift | Engine2D.opaque
                if updateDepthTranslucent { depthBuffer[index] = depth }
                attributeBuffer[index] = 1 << 31 | polygonID << 24 | (attr & fogBit)
            }
        }
    }

    private func toonShade(_ r: Float, _ g: Float, _ b: Float, highlight: Bool) -> (Float, Float, Float) {
        let entry = toonTable[min(max(Int(r), 0), 31)]
        let tr = Float(entry & 0x1F), tg = Float((entry >> 5) & 0x1F), tb = Float((entry >> 10) & 0x1F)
        // Highlight shading uses the red channel as grey; toon replaces the colour.
        return highlight ? (r, r, r) : (tr, tg, tb)
    }

    private func addHighlight(_ r: Float, _ g: Float, _ b: Float, original red: Float) -> (Float, Float, Float) {
        let entry = toonTable[min(max(Int(red), 0), 31)]
        return (min(r + Float(entry & 0x1F), 31), min(g + Float((entry >> 5) & 0x1F), 31), min(b + Float((entry >> 10) & 0x1F), 31))
    }

    private func applyFog(_ control: UInt32) {
        let shift = (control >> 8) & 0xF
        let fogR = Float(fogColor & 0x1F), fogG = Float((fogColor >> 5) & 0x1F), fogB = Float((fogColor >> 10) & 0x1F)
        let fogA = (fogColor >> 16) & 0x1F
        let alphaOnly = control & (1 << 6) != 0
        let offset = Int(fogOffset & 0x7FFF)
        for i in 0..<(256 * 192) where attributeBuffer[i] & (1 << 15) != 0 {
            // Depth back to the hardware's 15-bit scale.
            let z = renderingWBuffer ? Int(depthBuffer[i] * 4096) >> 9 : Int(depthBuffer[i] * Float(0xFF_FFFF)) >> 9
            let step = 0x400 >> Int(shift)
            let position = step == 0 ? 0 : (z - offset) / max(step, 1)
            let density: Float
            if position < 0 {
                density = Float(fogTable[0] & 0x7F) / 128
            } else if position >= 31 {
                density = Float(fogTable[31] & 0x7F) / 128
            } else {
                density = Float(fogTable[position] & 0x7F) / 128
            }
            let c = colorBuffer[i]
            let a = (c >> Engine2D.alphaShift) & 0x1F
            var r = Float(c & 0x1F), g = Float((c >> 5) & 0x1F), b = Float((c >> 10) & 0x1F)
            if !alphaOnly {
                r += (fogR - r) * density; g += (fogG - g) * density; b += (fogB - b) * density
            }
            let newA = UInt32(Float(a) + (Float(fogA) - Float(a)) * density)
            colorBuffer[i] = UInt32(r) | UInt32(g) << 5 | UInt32(b) << 10 | newA << Engine2D.alphaShift | (newA != 0 ? Engine2D.opaque : 0)
        }
    }

    // MARK: - Textures

    @inline(__always) private func textureByte(_ address: Int) -> UInt8 {
        let slot = s.vramMap.texture[(address >> 17) & 3]
        if slot < 0 { return 0 }
        return s.vram.base.load(fromByteOffset: Int(slot) + (address & 0x1FFFF), as: UInt8.self)
    }

    @inline(__always) private func textureHalf(_ address: Int) -> UInt16 {
        UInt16(textureByte(address)) | UInt16(textureByte(address + 1)) << 8
    }

    @inline(__always) private func paletteColor(_ address: Int) -> UInt32 {
        let slot = s.vramMap.texturePalette[(address >> 14) % 6]
        if slot < 0 { return 0 }
        return UInt32(s.vram.base.load(fromByteOffset: Int(slot) + (address & 0x3FFE), as: UInt16.self)) & 0x7FFF
    }

    /// One texel as (BGR555, alpha 0-31), or nil where it is transparent.
    private func sampleTexture(_ param: UInt32, palette: UInt32, s inS: Int, t inT: Int,
                               width: Int, height: Int, format: UInt32) -> (color: UInt32, alpha: UInt32)? {
        let u = Self.wrap(inS, size: width, repeats: param & (1 << 16) != 0, flips: param & (1 << 18) != 0)
        let v = Self.wrap(inT, size: height, repeats: param & (1 << 17) != 0, flips: param & (1 << 19) != 0)
        let base = Int(param & 0xFFFF) * 8
        let texel = v * width + u
        let color0Transparent = param & (1 << 29) != 0
        let paletteBase = Int(palette) * 16

        switch format {
        case 1:  // A3I5
            let byte = textureByte(base + texel)
            let a3 = UInt32(byte >> 5)
            return (paletteColor(paletteBase + Int(byte & 0x1F) * 2), a3 * 4 + a3 / 2)
        case 2:  // 4 colours
            let index = Int(textureByte(base + texel / 4) >> UInt8((texel & 3) * 2)) & 3
            if index == 0 && color0Transparent { return nil }
            return (paletteColor(Int(palette) * 8 + index * 2), 31)
        case 3:  // 16 colours
            let index = Int(textureByte(base + texel / 2) >> UInt8((texel & 1) * 4)) & 0xF
            if index == 0 && color0Transparent { return nil }
            return (paletteColor(paletteBase + index * 2), 31)
        case 4:  // 256 colours
            let index = Int(textureByte(base + texel))
            if index == 0 && color0Transparent { return nil }
            return (paletteColor(paletteBase + index * 2), 31)
        case 5:  // 4 × 4 compressed
            return compressedTexel(base: base, u: u, v: v, width: width, paletteBase: paletteBase)
        case 6:  // A5I3
            let byte = textureByte(base + texel)
            return (paletteColor(paletteBase + Int(byte & 7) * 2), UInt32(byte >> 3))
        default:  // direct colour
            let c = UInt32(textureHalf(base + texel * 2))
            if c & 0x8000 == 0 { return nil }
            return (c & 0x7FFF, 31)
        }
    }

    private func compressedTexel(base: Int, u: Int, v: Int, width: Int, paletteBase: Int) -> (color: UInt32, alpha: UInt32)? {
        let block = (v >> 2) * (width >> 2) + (u >> 2)
        let blockAddress = base + block * 4
        let byte = textureByte(blockAddress + (v & 3))
        let code = Int(byte >> UInt8((u & 3) * 2)) & 3
        // Palette index data: slot 1 holds it for slot 0's blocks (first half) and slot 2's (second half).
        let infoAddress = 0x20000 + (blockAddress & 0x1FFFF) / 2 + (blockAddress >= 0x40000 ? 0x10000 : 0)
        let info = Int(textureHalf(infoAddress))
        let palette = paletteBase + (info & 0x3FFF) * 4
        let mode = info >> 14
        func color(_ i: Int) -> UInt32 { paletteColor(palette + i * 2) }
        func mix(_ a: UInt32, _ b: UInt32, _ wa: UInt32, _ wb: UInt32) -> UInt32 {
            let total = wa + wb
            let r = ((a & 0x1F) * wa + (b & 0x1F) * wb) / total
            let g = (((a >> 5) & 0x1F) * wa + ((b >> 5) & 0x1F) * wb) / total
            let bl = (((a >> 10) & 0x1F) * wa + ((b >> 10) & 0x1F) * wb) / total
            return r | g << 5 | bl << 10
        }
        switch (mode, code) {
        case (0, 3), (1, 3): return nil
        case (1, 2): return (mix(color(0), color(1), 1, 1), 31)
        case (3, 2): return (mix(color(0), color(1), 5, 3), 31)
        case (3, 3): return (mix(color(0), color(1), 3, 5), 31)
        default: return (color(code), 31)
        }
    }

    @inline(__always) private static func wrap(_ c: Int, size: Int, repeats: Bool, flips: Bool) -> Int {
        if !repeats { return min(max(c, 0), size - 1) }
        let period = c >= 0 ? c / size : (c - size + 1) / size
        let inside = c - period * size
        return flips && period & 1 != 0 ? size - 1 - inside : inside
    }
}
