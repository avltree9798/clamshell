// SPDX-License-Identifier: GPL-3.0-or-later
//
// PICA200 rasteriser and fragment pipeline: clipping, perspective-correct
// interpolation, texture units 0-2, the six texture combiner stages, alpha,
// stencil and depth tests, blending or logic ops, and tiled colour and depth buffers.
// Behaviour follows Citra's software renderer, the reference most homebrew is tested on.

/// Fixed-function state, decoded from the registers once per draw call.
struct PICAFragmentConfig {
    struct TextureUnit {
        var enabled = false
        var address: UInt32 = 0
        var width = 0, height = 0
        var format = PICATextureFormat.rgba8
        var wrapS: UInt32 = 0, wrapT: UInt32 = 0
        var linear = false
        var border = PICAColor(0, 0, 0, 0)
    }

    struct Stage {
        var sources: [UInt32] = [0, 0, 0, 0, 0, 0]   // rgb 1-3, alpha 1-3
        var operands: [UInt32] = [0, 0, 0, 0, 0, 0]
        var rgbOp: UInt32 = 0, alphaOp: UInt32 = 0
        var constant = PICAColor(0, 0, 0, 0)
        var rgbScale: Int32 = 1, alphaScale: Int32 = 1
        /// A stage that passes the previous result through unchanged.
        var isPassThrough: Bool {
            rgbOp == 0 && alphaOp == 0 && sources[0] == 0xF && sources[3] == 0xF
                && operands[0] == 0 && operands[3] == 0 && rgbScale == 1 && alphaScale == 1
        }
    }

    var textures = [TextureUnit](repeating: TextureUnit(), count: 3)
    var texture2UsesCoordinate1 = false
    var stages = [Stage](repeating: Stage(), count: 6)
    var bufferUpdates: UInt32 = 0
    var bufferColor = PICAColor(0, 0, 0, 0)

    var alphaTest = false, alphaFunction: UInt32 = 1, alphaReference: Int32 = 0
    var stencilTest = false, stencilFunction: UInt32 = 1, stencilReference: UInt8 = 0
    var stencilWriteMask: UInt8 = 0, stencilInputMask: UInt8 = 0
    var stencilFail: UInt32 = 0, stencilDepthFail: UInt32 = 0, stencilPass: UInt32 = 0
    var depthTest = false, depthFunction: UInt32 = 1, depthWrite = false
    var colorMask: UInt32 = 0xF
    var blending = true
    var rgbEquation: UInt32 = 0, alphaEquation: UInt32 = 0
    var sourceRGB: UInt32 = 1, destinationRGB: UInt32 = 0, sourceAlpha: UInt32 = 1, destinationAlpha: UInt32 = 0
    var blendColor = PICAColor(0, 0, 0, 0)
    var logicOp: UInt32 = 3

    var colorAddress: UInt32 = 0, depthAddress: UInt32 = 0
    var width = 0, height = 0
    var colorFormat = PICATextureFormat.rgba8
    var depthFormat: UInt32 = 3
    var colorRead = true, colorWrite = true, depthRead = true, depthWrite_ = true

    var cull: UInt32 = 0
    var viewportHalfWidth: Float = 0, viewportHalfHeight: Float = 0
    var viewportX: Float = 0, viewportY: Float = 0
    var depthScale: Float = -1, depthOffset: Float = 0, zBuffering = true
    var scissorMode: UInt32 = 0
    var scissor = (x0: 0, y0: 0, x1: 0, y1: 0)

    init() {}

    init(_ regs: [UInt32]) {
        cull = regs[0x40] & 3
        viewportHalfWidth = Float24.float(regs[0x41] & 0xFF_FFFF)
        viewportHalfHeight = Float24.float(regs[0x43] & 0xFF_FFFF)
        viewportX = Float(Int32(regs[0x68] << 22) >> 22)
        viewportY = Float(Int32((regs[0x68] >> 16) << 22) >> 22)
        depthScale = Float24.float(regs[0x4D] & 0xFF_FFFF)
        depthOffset = Float24.float(regs[0x4E] & 0xFF_FFFF)
        zBuffering = regs[0x6D] & 1 != 0
        scissorMode = regs[0x65] & 3
        scissor = (Int(regs[0x66] & 0x3FF), Int((regs[0x66] >> 16) & 0x3FF), Int(regs[0x67] & 0x3FF), Int((regs[0x67] >> 16) & 0x3FF))

        let unitConfig = regs[0x80]
        texture2UsesCoordinate1 = unitConfig & (1 << 13) != 0
        let unitRegs = [(0x81, 0x82, 0x83, 0x85, 0x8E), (0x91, 0x92, 0x93, 0x95, 0x96), (0x99, 0x9A, 0x9B, 0x9D, 0x9E)]
        for (i, r) in unitRegs.enumerated() {
            var unit = TextureUnit()
            unit.enabled = unitConfig & (1 << UInt32(i)) != 0
            let border = regs[r.0]
            unit.border = PICAColor(Int32(border & 0xFF), Int32((border >> 8) & 0xFF), Int32((border >> 16) & 0xFF), Int32(border >> 24))
            unit.height = Int(regs[r.1] & 0x7FF)
            unit.width = Int((regs[r.1] >> 16) & 0x7FF)
            let parameters = regs[r.2]
            unit.linear = parameters & 2 != 0
            unit.wrapT = (parameters >> 8) & 7
            unit.wrapS = (parameters >> 12) & 7
            unit.address = regs[r.3] << 3
            unit.format = PICATextureFormat(rawValue: regs[r.4] & 0xF) ?? .rgba8
            if unit.width == 0 || unit.height == 0 { unit.enabled = false }
            textures[i] = unit
        }

        let stageBases = [0xC0, 0xC8, 0xD0, 0xD8, 0xF0, 0xF8]
        for (i, base) in stageBases.enumerated() {
            var stage = Stage()
            let source = regs[base], operand = regs[base + 1], combine = regs[base + 2]
            let constant = regs[base + 3], scale = regs[base + 4]
            stage.sources = [source & 0xF, (source >> 4) & 0xF, (source >> 8) & 0xF,
                             (source >> 16) & 0xF, (source >> 20) & 0xF, (source >> 24) & 0xF]
            stage.operands = [operand & 0xF, (operand >> 4) & 0xF, (operand >> 8) & 0xF,
                              (operand >> 12) & 7, (operand >> 16) & 7, (operand >> 20) & 7]
            stage.rgbOp = combine & 0xF
            stage.alphaOp = (combine >> 16) & 0xF
            stage.constant = PICAColor(Int32(constant & 0xFF), Int32((constant >> 8) & 0xFF),
                                       Int32((constant >> 16) & 0xFF), Int32(constant >> 24))
            stage.rgbScale = [1, 2, 4, 1][Int(scale & 3)]
            stage.alphaScale = [1, 2, 4, 1][Int((scale >> 16) & 3)]
            stages[i] = stage
        }
        bufferUpdates = (regs[0xE0] >> 8) & 0xFF
        let buffer = regs[0xFD]
        bufferColor = PICAColor(Int32(buffer & 0xFF), Int32((buffer >> 8) & 0xFF), Int32((buffer >> 16) & 0xFF), Int32(buffer >> 24))

        blending = regs[0x100] & 0x100 != 0
        let blend = regs[0x101]
        rgbEquation = blend & 7
        alphaEquation = (blend >> 8) & 7
        sourceRGB = (blend >> 16) & 0xF
        destinationRGB = (blend >> 20) & 0xF
        sourceAlpha = (blend >> 24) & 0xF
        destinationAlpha = (blend >> 28) & 0xF
        logicOp = regs[0x102] & 0xF
        let color = regs[0x103]
        blendColor = PICAColor(Int32(color & 0xFF), Int32((color >> 8) & 0xFF), Int32((color >> 16) & 0xFF), Int32(color >> 24))

        let alpha = regs[0x104]
        alphaTest = alpha & 1 != 0
        alphaFunction = (alpha >> 4) & 7
        alphaReference = Int32((alpha >> 8) & 0xFF)
        let stencil = regs[0x105]
        stencilTest = stencil & 1 != 0
        stencilFunction = (stencil >> 4) & 7
        stencilWriteMask = UInt8((stencil >> 8) & 0xFF)
        stencilReference = UInt8((stencil >> 16) & 0xFF)
        stencilInputMask = UInt8(stencil >> 24)
        let stencilOps = regs[0x106]
        stencilFail = stencilOps & 7
        stencilDepthFail = (stencilOps >> 4) & 7
        stencilPass = (stencilOps >> 8) & 7
        let depthColor = regs[0x107]
        depthTest = depthColor & 1 != 0
        depthFunction = (depthColor >> 4) & 7
        colorMask = (depthColor >> 8) & 0xF
        depthWrite = depthColor & 0x1000 != 0

        colorRead = regs[0x112] & 0xF != 0
        colorWrite = regs[0x113] & 0xF != 0
        depthRead = regs[0x114] & 3 != 0
        depthWrite_ = regs[0x115] & 3 != 0
        depthFormat = regs[0x116] & 3
        colorFormat = [PICATextureFormat.rgba8, .rgb8, .rgb5a1, .rgb565, .rgba4][Int(min((regs[0x117] >> 16) & 7, 4))]
        depthAddress = regs[0x11C] << 3
        colorAddress = regs[0x11D] << 3
        width = Int(regs[0x11E] & 0x7FF)
        height = Int((regs[0x11E] >> 12) & 0x3FF) + 1
    }
}

final class PICARasterizer {
    let memory: AddressSpace
    private var config = PICAFragmentConfig()
    private var colorBuffer: UnsafeMutableRawPointer?
    private var depthBuffer: UnsafeMutableRawPointer?
    private var textureBases: [UnsafeRawPointer?] = [nil, nil, nil]

    /// Fragments drawn since start, for tests and diagnostics.
    private(set) var fragments = 0

    init(memory: AddressSpace) { self.memory = memory }

    func configure(_ regs: [UInt32]) {
        config = PICAFragmentConfig(regs)
        colorBuffer = config.colorAddress != 0 ? memory.host(physical: config.colorAddress) : nil
        depthBuffer = config.depthAddress != 0 ? memory.host(physical: config.depthAddress) : nil
        for i in 0..<3 {
            textureBases[i] = config.textures[i].enabled ? memory.host(physical: config.textures[i].address).map { UnsafeRawPointer($0) } : nil
        }
    }

    // MARK: - Clipping

    private struct ClipVertex {
        var position: SIMD4<Float>
        var values: [Float]
    }

    /// Plane tests: keep points where dot(plane, position) + bias >= 0.
    private static let planes: [(SIMD4<Float>, Float)] = [
        (SIMD4(-1, 0, 0, 1), 0), (SIMD4(1, 0, 0, 1), 0),
        (SIMD4(0, -1, 0, 1), 0), (SIMD4(0, 1, 0, 1), 0),
        (SIMD4(0, 0, -1, 0), 0), (SIMD4(0, 0, 1, 1), 0),
        (SIMD4(0, 0, 0, 1), -1e-5),
    ]

    func triangle(_ a: PICAVertex, _ b: PICAVertex, _ c: PICAVertex) {
        guard colorBuffer != nil, config.width > 0 else { return }
        var polygon = [a, b, c].map { ClipVertex(position: $0.position, values: $0.values) }
        // Skip the clipper when every vertex is inside.
        let inside = polygon.allSatisfy { v in Self.planes.allSatisfy { (v.position * $0.0).sum() + $0.1 >= 0 } }
        if !inside {
            for (plane, bias) in Self.planes {
                var output: [ClipVertex] = []
                for i in 0..<polygon.count {
                    let p = polygon[i], q = polygon[(i + 1) % polygon.count]
                    let dp = (p.position * plane).sum() + bias, dq = (q.position * plane).sum() + bias
                    if dp >= 0 { output.append(p) }
                    if (dp >= 0) != (dq >= 0) {
                        let t = dp / (dp - dq)
                        output.append(ClipVertex(position: p.position + (q.position - p.position) * t,
                                                 values: zip(p.values, q.values).map { $0 + ($1 - $0) * t }))
                    }
                }
                polygon = output
                if polygon.count < 3 { return }
            }
        }
        let screen = polygon.map(project)
        for i in 1..<(screen.count - 1) {
            rasterize(screen[0], screen[i], screen[i + 1])
        }
    }

    private struct ScreenVertex {
        var x: Float, y: Float, zOverW: Float, inverseW: Float
        /// Attribute values divided by w, for perspective-correct interpolation.
        var values: [Float]
    }

    private func project(_ v: ClipVertex) -> ScreenVertex {
        let inverseW = 1 / v.position.w
        return ScreenVertex(x: (v.position.x * inverseW + 1) * config.viewportHalfWidth + config.viewportX,
                            y: (v.position.y * inverseW + 1) * config.viewportHalfHeight + config.viewportY,
                            zOverW: v.position.z * inverseW, inverseW: inverseW,
                            values: v.values.map { $0 * inverseW })
    }

    // MARK: - Rasterisation

    private func rasterize(_ v0: ScreenVertex, _ v1In: ScreenVertex, _ v2In: ScreenVertex) {
        var v1 = v1In, v2 = v2In
        func area(_ a: ScreenVertex, _ b: ScreenVertex, _ c: ScreenVertex) -> Float {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        if config.cull == 2 { swap(&v1, &v2) }
        if config.cull != 0 {
            if area(v0, v1, v2) <= 0 { return }
        } else if area(v0, v1, v2) <= 0 {
            swap(&v1, &v2)
        }
        let total = area(v0, v1, v2)
        guard total > 0 else { return }

        var minX = Int(min(v0.x, v1.x, v2.x).rounded(.down)), maxX = Int(max(v0.x, v1.x, v2.x).rounded(.up))
        var minY = Int(min(v0.y, v1.y, v2.y).rounded(.down)), maxY = Int(max(v0.y, v1.y, v2.y).rounded(.up))
        minX = max(minX, 0); minY = max(minY, 0)
        maxX = min(maxX, config.width - 1); maxY = min(maxY, config.height - 1)
        if config.scissorMode == 3 {
            minX = max(minX, config.scissor.x0); minY = max(minY, config.scissor.y0)
            maxX = min(maxX, config.scissor.x1); maxY = min(maxY, config.scissor.y1)
        }
        guard minX <= maxX, minY <= maxY else { return }

        // Edge functions; an edge owns the pixels exactly on it only if it is a top or left edge.
        func bias(_ a: ScreenVertex, _ b: ScreenVertex) -> Float {
            let topLeft = (a.y == b.y && b.x < a.x) || b.y < a.y
            return topLeft ? 0 : -1e-6
        }
        let bias0 = bias(v1, v2), bias1 = bias(v2, v0), bias2 = bias(v0, v1)
        let count = v0.values.count
        var values = [Float](repeating: 0, count: count)
        for y in minY...maxY {
            let py = Float(y) + 0.5
            for x in minX...maxX {
                let px = Float(x) + 0.5
                let w0 = (v2.x - v1.x) * (py - v1.y) - (v2.y - v1.y) * (px - v1.x)
                let w1 = (v0.x - v2.x) * (py - v2.y) - (v0.y - v2.y) * (px - v2.x)
                let w2 = (v1.x - v0.x) * (py - v0.y) - (v1.y - v0.y) * (px - v0.x)
                if w0 + bias0 < 0 || w1 + bias1 < 0 || w2 + bias2 < 0 { continue }
                if config.scissorMode == 1 && x >= config.scissor.x0 && x <= config.scissor.x1
                    && y >= config.scissor.y0 && y <= config.scissor.y1 { continue }
                let b0 = w0 / total, b1 = w1 / total, b2 = w2 / total
                let inverseW = b0 * v0.inverseW + b1 * v1.inverseW + b2 * v2.inverseW
                let w = 1 / inverseW
                for i in 0..<count { values[i] = (b0 * v0.values[i] + b1 * v1.values[i] + b2 * v2.values[i]) * w }
                let zOverW = b0 * v0.zOverW + b1 * v1.zOverW + b2 * v2.zOverW
                let z = config.zBuffering ? zOverW : zOverW * w
                let depth = min(max(z * config.depthScale + config.depthOffset, 0), 1)
                shade(x: x, y: y, depth: depth, values)
            }
        }
    }

    // MARK: - Fragments

    private func shade(x: Int, y: Int, depth: Float, _ values: [Float]) {
        fragments += 1
        let primary = PICAColor(Int32(values[8] * 255 + 0.5), Int32(values[9] * 255 + 0.5),
                                Int32(values[10] * 255 + 0.5), Int32(values[11] * 255 + 0.5))
        var textures = [PICAColor](repeating: PICAColor(0, 0, 0, 0), count: 4)
        for i in 0..<3 where config.textures[i].enabled {
            let (u, v): (Float, Float) = switch i {
            case 0: (values[12], values[13])
            case 1: (values[14], values[15])
            default: config.texture2UsesCoordinate1 ? (values[14], values[15]) : (values[22], values[23])
            }
            textures[i] = sample(i, u, v)
        }

        // Texture combiners.
        var previous = PICAColor(0, 0, 0, 0)
        var buffer = PICAColor(0, 0, 0, 0)
        var nextBuffer = config.bufferColor
        for (index, stage) in config.stages.enumerated() {
            buffer = nextBuffer
            if !stage.isPassThrough {
                func source(_ s: UInt32) -> PICAColor {
                    switch s {
                    case 0: return primary
                    case 3, 4, 5, 6: return textures[Int(s - 3)]
                    case 0xD: return buffer
                    case 0xE: return stage.constant
                    case 0xF: return previous
                    default: return PICAColor(0, 0, 0, 0)  // fragment lighting: not yet
                    }
                }
                let rgb = (0..<3).map { Self.rgbOperand(stage.operands[$0], source(stage.sources[$0])) }
                let alpha = (3..<6).map { Self.alphaOperand(stage.operands[$0], source(stage.sources[$0])) }
                var out = Self.combineRGB(stage.rgbOp, rgb[0], rgb[1], rgb[2])
                out = PICAColor(min(out.x * stage.rgbScale, 255), min(out.y * stage.rgbScale, 255), min(out.z * stage.rgbScale, 255), 0)
                var a = stage.rgbOp == 7 ? out.x : Self.combineAlpha(stage.alphaOp, alpha[0], alpha[1], alpha[2])
                a = min(a * stage.alphaScale, 255)
                previous = PICAColor(out.x, out.y, out.z, a)
            }
            if index < 4 {
                if config.bufferUpdates & (1 << UInt32(index)) != 0 {
                    nextBuffer.x = previous.x; nextBuffer.y = previous.y; nextBuffer.z = previous.z
                }
                if config.bufferUpdates & (16 << UInt32(index)) != 0 { nextBuffer.w = previous.w }
            }
        }
        let color = previous

        if config.alphaTest && !Self.compare(config.alphaFunction, color.w, config.alphaReference) { return }

        // Depth and stencil.
        let memoryY = config.height - 1 - y
        var depthPointer: UnsafeMutableRawPointer?
        var stencil: UInt8 = 0
        if let depthBuffer {
            let bpp = config.depthFormat == 0 ? 2 : config.depthFormat == 2 ? 3 : 4
            depthPointer = depthBuffer + PICAMemoryLayout.tiledOffset(x, memoryY, width: config.width, bytesPerPixel: bpp)
        }
        let maxDepth: Float = config.depthFormat == 0 ? 0xFFFF : 0xFF_FFFF
        let fragmentDepth = UInt32(depth * maxDepth)
        if let p = depthPointer {
            if config.depthFormat == 3 { stencil = p.load(fromByteOffset: 3, as: UInt8.self) }
            if config.stencilTest && config.depthFormat == 3 {
                let reference = config.stencilReference & config.stencilInputMask
                let value = stencil & config.stencilInputMask
                if !Self.compare(config.stencilFunction, Int32(value), Int32(reference)) {
                    updateStencil(p, stencil, config.stencilFail)
                    return
                }
            }
            if config.depthTest {
                let stored = config.depthFormat == 0 ? UInt32(p.loadUnaligned(as: UInt16.self))
                    : UInt32(p.load(as: UInt8.self)) | UInt32(p.load(fromByteOffset: 1, as: UInt8.self)) << 8
                        | UInt32(p.load(fromByteOffset: 2, as: UInt8.self)) << 16
                if !Self.compare(config.depthFunction, Int32(bitPattern: fragmentDepth), Int32(bitPattern: stored)) {
                    if config.stencilTest && config.depthFormat == 3 { updateStencil(p, stencil, config.stencilDepthFail) }
                    return
                }
            }
            if config.depthWrite && config.depthWrite_ {
                if config.depthFormat == 0 {
                    p.storeBytes(of: UInt16(truncatingIfNeeded: fragmentDepth), as: UInt16.self)
                } else {
                    p.storeBytes(of: UInt8(truncatingIfNeeded: fragmentDepth), as: UInt8.self)
                    p.storeBytes(of: UInt8(truncatingIfNeeded: fragmentDepth >> 8), toByteOffset: 1, as: UInt8.self)
                    p.storeBytes(of: UInt8(truncatingIfNeeded: fragmentDepth >> 16), toByteOffset: 2, as: UInt8.self)
                }
            }
            if config.stencilTest && config.depthFormat == 3 { updateStencil(p, stencil, config.stencilPass) }
        }

        // Blend and write.
        guard let colorBuffer, config.colorWrite, config.colorMask != 0 else { return }
        let bpp = config.colorFormat.bits / 8
        let p = colorBuffer + PICAMemoryLayout.tiledOffset(x, memoryY, width: config.width, bytesPerPixel: bpp)
        let destination = config.colorRead ? PICATexture.decode(config.colorFormat, p) : PICAColor(0, 0, 0, 0)
        var result = config.blending ? blend(color, destination) : Self.logic(config.logicOp, color, destination)
        for i in 0..<4 where config.colorMask & (1 << UInt32(i)) == 0 { result[i] = destination[i] }
        Self.encode(config.colorFormat, result, p)
    }

    private func updateStencil(_ p: UnsafeMutableRawPointer, _ old: UInt8, _ op: UInt32) {
        let reference = config.stencilReference
        let new: UInt8 = switch op {
        case 1: 0
        case 2: reference
        case 3: old == 255 ? 255 : old + 1
        case 4: old == 0 ? 0 : old - 1
        case 5: ~old
        case 6: old &+ 1
        case 7: old &- 1
        default: old
        }
        let mask = config.stencilWriteMask
        p.storeBytes(of: (old & ~mask) | (new & mask), toByteOffset: 3, as: UInt8.self)
    }

    // MARK: - Textures

    private func sample(_ unit: Int, _ u: Float, _ v: Float) -> PICAColor {
        let t = config.textures[unit]
        guard let base = textureBases[unit] else { return PICAColor(0, 0, 0, 0) }
        func texel(_ s: Int, _ tt: Int) -> PICAColor {
            guard let x = Self.wrap(s, t.width, t.wrapS), let y = Self.wrap(tt, t.height, t.wrapT) else { return t.border }
            return PICATexture.texel(t.format, base: base, width: t.width, x: x, y: t.height - 1 - y)
        }
        let fu = u * Float(t.width), fv = v * Float(t.height)
        guard fu.isFinite, fv.isFinite else { return t.border }
        if !t.linear {
            return texel(Int(fu.rounded(.down)), Int(fv.rounded(.down)))
        }
        let su = fu - 0.5, sv = fv - 0.5
        let x0 = Int(su.rounded(.down)), y0 = Int(sv.rounded(.down))
        let fx = Int32((su - Float(x0)) * 256), fy = Int32((sv - Float(y0)) * 256)
        let c00 = texel(x0, y0), c10 = texel(x0 + 1, y0), c01 = texel(x0, y0 + 1), c11 = texel(x0 + 1, y0 + 1)
        let top = (c00 &* (256 - fx) &+ c10 &* fx) / 256
        let bottom = (c01 &* (256 - fx) &+ c11 &* fx) / 256
        return (top &* (256 - fy) &+ bottom &* fy) / 256
    }

    /// Applies a wrap mode; nil means the border colour.
    static func wrap(_ c: Int, _ size: Int, _ mode: UInt32) -> Int? {
        switch mode {
        case 1:  // clamp to border
            return c < 0 || c >= size ? nil : c
        case 2:  // repeat
            return ((c % size) + size) % size
        case 3:  // mirrored repeat
            let period = size * 2
            let m = ((c % period) + period) % period
            return m < size ? m : period - 1 - m
        default:  // clamp to edge
            return min(max(c, 0), size - 1)
        }
    }

    // MARK: - Combiner arithmetic

    static func rgbOperand(_ op: UInt32, _ c: PICAColor) -> PICAColor {
        switch op {
        case 0: return c
        case 1: return 255 &- c
        case 2: return PICAColor(repeating: c.w)
        case 3: return PICAColor(repeating: 255 - c.w)
        case 4: return PICAColor(repeating: c.x)
        case 5: return PICAColor(repeating: 255 - c.x)
        case 8: return PICAColor(repeating: c.y)
        case 9: return PICAColor(repeating: 255 - c.y)
        case 12: return PICAColor(repeating: c.z)
        case 13: return PICAColor(repeating: 255 - c.z)
        default: return c
        }
    }

    static func alphaOperand(_ op: UInt32, _ c: PICAColor) -> Int32 {
        switch op {
        case 0: return c.w
        case 1: return 255 - c.w
        case 2: return c.x
        case 3: return 255 - c.x
        case 4: return c.y
        case 5: return 255 - c.y
        case 6: return c.z
        case 7: return 255 - c.z
        default: return c.w
        }
    }

    static func combineRGB(_ op: UInt32, _ a: PICAColor, _ b: PICAColor, _ c: PICAColor) -> PICAColor {
        func clamp(_ v: PICAColor) -> PICAColor { v.clamped(lowerBound: PICAColor(repeating: 0), upperBound: PICAColor(repeating: 255)) }
        switch op {
        case 0: return a
        case 1: return a &* b / 255
        case 2: return clamp(a &+ b)
        case 3: return clamp(a &+ b &- 128)
        case 4: return (a &* c &+ b &* (255 &- c)) / 255
        case 5: return clamp(a &- b)
        case 6, 7:
            let d = ((a.x - 128) * (b.x - 128) + (a.y - 128) * (b.y - 128) + (a.z - 128) * (b.z - 128)) / 64
            return PICAColor(repeating: min(max(d, 0), 255))
        case 8: return clamp(a &* b / 255 &+ c)
        case 9: return clamp(a &+ b) &* c / 255
        default: return a
        }
    }

    static func combineAlpha(_ op: UInt32, _ a: Int32, _ b: Int32, _ c: Int32) -> Int32 {
        switch op {
        case 0: return a
        case 1: return a * b / 255
        case 2: return min(a + b, 255)
        case 3: return min(max(a + b - 128, 0), 255)
        case 4: return (a * c + b * (255 - c)) / 255
        case 5: return max(a - b, 0)
        case 8: return min(a * b / 255 + c, 255)
        case 9: return min(a + b, 255) * c / 255
        default: return a
        }
    }

    static func compare(_ function: UInt32, _ a: Int32, _ b: Int32) -> Bool {
        switch function {
        case 0: return false
        case 1: return true
        case 2: return a == b
        case 3: return a != b
        case 4: return a < b
        case 5: return a <= b
        case 6: return a > b
        default: return a >= b
        }
    }

    // MARK: - Blending

    private func factor(_ f: UInt32, _ source: PICAColor, _ destination: PICAColor) -> PICAColor {
        let c = config.blendColor
        switch f {
        case 0: return PICAColor(repeating: 0)
        case 1: return PICAColor(repeating: 255)
        case 2: return source
        case 3: return 255 &- source
        case 4: return destination
        case 5: return 255 &- destination
        case 6: return PICAColor(repeating: source.w)
        case 7: return PICAColor(repeating: 255 - source.w)
        case 8: return PICAColor(repeating: destination.w)
        case 9: return PICAColor(repeating: 255 - destination.w)
        case 10: return c
        case 11: return 255 &- c
        case 12: return PICAColor(repeating: c.w)
        case 13: return PICAColor(repeating: 255 - c.w)
        case 14:
            let s = min(source.w, 255 - destination.w)
            return PICAColor(s, s, s, 255)
        default: return PICAColor(repeating: 255)
        }
    }

    private func blend(_ source: PICAColor, _ destination: PICAColor) -> PICAColor {
        let sRGB = factor(config.sourceRGB, source, destination), dRGB = factor(config.destinationRGB, source, destination)
        let sA = factor(config.sourceAlpha, source, destination), dA = factor(config.destinationAlpha, source, destination)
        func apply(_ equation: UInt32, _ s: Int32, _ sf: Int32, _ d: Int32, _ df: Int32) -> Int32 {
            let a = s * sf / 255, b = d * df / 255
            let r: Int32 = switch equation {
            case 1: a - b
            case 2: b - a
            case 3: min(s, d)
            case 4: max(s, d)
            default: a + b
            }
            return min(max(r, 0), 255)
        }
        return PICAColor(apply(config.rgbEquation, source.x, sRGB.x, destination.x, dRGB.x),
                         apply(config.rgbEquation, source.y, sRGB.y, destination.y, dRGB.y),
                         apply(config.rgbEquation, source.z, sRGB.z, destination.z, dRGB.z),
                         apply(config.alphaEquation, source.w, sA.w, destination.w, dA.w))
    }

    static func logic(_ op: UInt32, _ s: PICAColor, _ d: PICAColor) -> PICAColor {
        switch op {
        case 0: return PICAColor(repeating: 0)
        case 1: return s & d
        case 2: return s & ~d & 255
        case 3: return s
        case 4: return ~s & d & 255
        case 5: return d
        case 6: return s ^ d
        case 7: return s | d
        case 8: return ~(s | d) & 255
        case 9: return ~(s ^ d) & 255
        case 10: return ~d & 255
        case 11: return (s | ~d) & 255
        case 12: return ~s & 255
        case 13: return (~s | d) & 255
        case 14: return ~(s & d) & 255
        default: return PICAColor(repeating: 255)
        }
    }

    static func encode(_ format: PICATextureFormat, _ c: PICAColor, _ p: UnsafeMutableRawPointer) {
        let r = UInt32(c.x), g = UInt32(c.y), b = UInt32(c.z), a = UInt32(c.w)
        switch format {
        case .rgba8: p.storeBytes(of: r << 24 | g << 16 | b << 8 | a, as: UInt32.self)
        case .rgb8:
            p.storeBytes(of: UInt8(b), as: UInt8.self)
            p.storeBytes(of: UInt8(g), toByteOffset: 1, as: UInt8.self)
            p.storeBytes(of: UInt8(r), toByteOffset: 2, as: UInt8.self)
        case .rgb5a1: p.storeBytes(of: UInt16((r >> 3) << 11 | (g >> 3) << 6 | (b >> 3) << 1 | a >> 7), as: UInt16.self)
        case .rgb565: p.storeBytes(of: UInt16((r >> 3) << 11 | (g >> 2) << 5 | b >> 3), as: UInt16.self)
        default: p.storeBytes(of: UInt16((r >> 4) << 12 | (g >> 4) << 8 | (b >> 4) << 4 | a >> 4), as: UInt16.self)
        }
    }
}
