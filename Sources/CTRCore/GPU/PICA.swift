// SPDX-License-Identifier: GPL-3.0-or-later
//
// The PICA200 GPU front end: command lists, the register file, vertex attribute
// loading, the vertex shader and primitive assembly. Rasterisation and per-fragment
// work are in PICARasterizer. Register numbers from 3dbrew ("GPU/Internal Registers").

/// One vertex after the shader, indexed by output semantic (0-3 position, 4-7
/// quaternion, 8-11 colour, 12-13 texcoord 0, 14-15 texcoord 1, 16 texcoord 0 w,
/// 18-20 view vector, 22-23 texcoord 2).
struct PICAVertex {
    var values = [Float](repeating: 0, count: 24)

    var position: SIMD4<Float> { SIMD4(values[0], values[1], values[2], values[3]) }
}

final class PICA {
    let memory: AddressSpace
    let rasterizer: PICARasterizer
    var regs = [UInt32](repeating: 0, count: 0x300)
    var vertexShader = PICAShaderSetup()
    private var shaderUnit = PICAShaderUnit()

    /// Attribute values for attributes marked fixed, and the immediate-mode vertex.
    private var fixedAttributes = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: 16)
    private var immediateAttributes: [SIMD4<Float>] = []
    private var attributeWords: [UInt32] = []
    private var uniformWords: [UInt32] = []

    // Primitive assembly
    private var assembled: [PICAVertex] = []
    private var stripCount = 0

    /// Draw calls and triangles since the last frame, for diagnostics.
    private(set) var drawCalls = 0

    init(memory: AddressSpace) {
        self.memory = memory
        rasterizer = PICARasterizer(memory: memory)
    }

    // MARK: - Command lists

    /// Runs a command list at a virtual address (GX command 1).
    func run(commandList address: UInt32, size: Int) {
        guard size > 0, let host = memory.pointer(address), memory.isMapped(address, size: UInt32(size)) else { return }
        run(host.assumingMemoryBound(to: UInt32.self), words: size / 4)
    }

    private func run(_ start: UnsafePointer<UInt32>, words: Int) {
        var p = start
        var end = start + words
        while p + 1 < end {
            let parameter = p[0], header = p[1]
            p += 2
            let id = Int(header & 0xFFFF)
            let mask = Self.byteMask(header >> 16)
            let extra = Int((header >> 20) & 0xFF)
            let consecutive = header & 0x8000_0000 != 0
            if let jump = write(id, parameter, mask: mask) { p = jump.start; end = jump.start + jump.words; continue }
            var redirected = false
            for i in 0..<extra where p < end {
                let value = p[0]
                p += 1
                if let jump = write(consecutive ? id + 1 + i : id, value, mask: mask) {
                    p = jump.start
                    end = jump.start + jump.words
                    redirected = true
                    break
                }
            }
            if redirected { continue }
            // Commands are 8-byte aligned: an odd number of extra words leaves a pad word.
            if extra & 1 != 0 { p += 1 }
        }
    }

    static func byteMask(_ bits: UInt32) -> UInt32 {
        (bits & 1 != 0 ? 0xFF : 0) | (bits & 2 != 0 ? 0xFF00 : 0) | (bits & 4 != 0 ? 0xFF_0000 : 0) | (bits & 8 != 0 ? 0xFF00_0000 : 0)
    }

    // MARK: - Registers

    /// Writes a register and runs its side effect. Returns a new command buffer when the
    /// write is a jump (CMDBUF_JUMP).
    @discardableResult
    func write(_ id: Int, _ value: UInt32, mask: UInt32 = 0xFFFF_FFFF) -> (start: UnsafePointer<UInt32>, words: Int)? {
        guard id < regs.count else { return nil }
        let new = (regs[id] & ~mask) | (value & mask)
        regs[id] = new
        switch id {
        case 0x22E: draw(indexed: false)
        case 0x22F: draw(indexed: true)
        case 0x232:  // FIXEDATTRIB_INDEX
            attributeWords.removeAll(keepingCapacity: true)
            if new & 0xF == 0xF { immediateAttributes.removeAll(keepingCapacity: true); resetAssembly() }
        case 0x233...0x235:
            attributeWords.append(new)
            if attributeWords.count == 3 {
                let v = Float24.vector(attributeWords[0], attributeWords[1], attributeWords[2])
                attributeWords.removeAll(keepingCapacity: true)
                let index = Int(regs[0x232] & 0xF)
                if index == 0xF {
                    immediate(v)
                } else if index < 12 {
                    fixedAttributes[index] = v
                    regs[0x232] = (regs[0x232] & ~0xF) | UInt32(index + 1)
                }
            }
        case 0x23C, 0x23D:  // CMDBUF_JUMP0/1
            let n = id - 0x23C
            let size = Int(regs[0x238 + n] & 0xF_FFFF) * 8
            let address = regs[0x23A + n] << 3
            guard let host = memory.host(physical: address) else { return nil }
            return (UnsafePointer(host.assumingMemoryBound(to: UInt32.self)), size / 4)
        case 0x25F: resetAssembly()
        case 0x2B0: vertexShader.boolUniforms = UInt16(truncatingIfNeeded: new)
        case 0x2B1...0x2B4:
            vertexShader.intUniforms[id - 0x2B1] = SIMD4(Int32(new & 0xFF), Int32((new >> 8) & 0xFF),
                                                         Int32((new >> 16) & 0xFF), Int32(new >> 24))
        case 0x2BA: vertexShader.entryPoint = Int(new & 0xFFFF)
        case 0x2C0: uniformWords.removeAll(keepingCapacity: true)
        case 0x2C1...0x2C8: uniform(new)
        case 0x2CC...0x2D3:  // VSH_CODETRANSFER_DATA
            let offset = Int(regs[0x2CB] & 0xFFF)
            vertexShader.program[offset] = new
            regs[0x2CB] = UInt32((offset + 1) & 0xFFF)
        case 0x2D6...0x2DD:  // VSH_OPDESCS_DATA
            let offset = Int(regs[0x2D5] & 0x7F)
            vertexShader.swizzles[offset] = new
            regs[0x2D5] = UInt32((offset + 1) & 0x7F)
        default:
            break
        }
        return nil
    }

    /// Float uniform upload: four float32 words or three packed float24 words per vector.
    private func uniform(_ word: UInt32) {
        uniformWords.append(word)
        let setup = regs[0x2C0]
        let float32 = setup & 0x8000_0000 != 0
        guard uniformWords.count == (float32 ? 4 : 3) else { return }
        let index = Int(setup & 0xFF)
        if index < 96 {
            vertexShader.floatUniforms[index] = float32
                ? SIMD4(Float(bitPattern: uniformWords[3]), Float(bitPattern: uniformWords[2]),
                        Float(bitPattern: uniformWords[1]), Float(bitPattern: uniformWords[0]))
                : Float24.vector(uniformWords[0], uniformWords[1], uniformWords[2])
        }
        regs[0x2C0] = (setup & ~0xFF) | UInt32((index + 1) & 0xFF)
        uniformWords.removeAll(keepingCapacity: true)
    }

    // MARK: - Vertices

    private var attributeCount: Int { Int(regs[0x242] & 0xF) + 1 }

    /// Puts attribute `i` into the shader input register the permutation names.
    private func loadInputs(_ attributes: [SIMD4<Float>]) {
        let permutation = UInt64(regs[0x2BB]) | UInt64(regs[0x2BC]) << 32
        for i in 0..<min(attributeCount, attributes.count) {
            shaderUnit.inputs[Int((permutation >> UInt64(i * 4)) & 0xF)] = attributes[i]
        }
    }

    private func immediate(_ v: SIMD4<Float>) {
        immediateAttributes.append(v)
        guard immediateAttributes.count == attributeCount else { return }
        loadInputs(immediateAttributes)
        immediateAttributes.removeAll(keepingCapacity: true)
        assemble(shade())
    }

    /// Reads vertex `index`'s attributes from the attribute buffers.
    private func attributes(of index: Int) -> [SIMD4<Float>] {
        var result = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: 12)
        let base = regs[0x200] << 3
        let format = UInt64(regs[0x201]) | UInt64(regs[0x202] & 0xFFFF) << 32
        let fixed = (regs[0x202] >> 16) & 0xFFF
        for buffer in 0..<12 {
            let offset = regs[0x203 + buffer * 3] & 0x0FFF_FFFF
            let components = regs[0x204 + buffer * 3]
            let config = regs[0x205 + buffer * 3]
            let stride = Int((config >> 16) & 0xFF), count = Int(config >> 28)
            guard count > 0 else { continue }
            guard let start = memory.host(physical: base &+ offset &+ UInt32(index * stride)) else { continue }
            var o = 0
            for c in 0..<count {
                let attribute = Int(c < 8 ? (components >> UInt32(c * 4)) & 0xF : (config >> UInt32((c - 8) * 4)) & 0xF)
                if attribute >= 12 {
                    // Padding of 4, 8, 12 or 16 bytes.
                    o = (o + 3) & ~3
                    o += (attribute - 11) * 4
                    continue
                }
                let type = Int((format >> UInt64(attribute * 4)) & 3)
                let elements = Int((format >> UInt64(attribute * 4 + 2)) & 3) + 1
                let size = [1, 1, 2, 4][type]
                o = (o + size - 1) & ~(size - 1)
                var value = SIMD4<Float>(0, 0, 0, 1)
                for e in 0..<elements {
                    let p = start + o + e * size
                    switch type {
                    case 0: value[e] = Float(p.load(as: Int8.self))
                    case 1: value[e] = Float(p.load(as: UInt8.self))
                    case 2: value[e] = Float(p.loadUnaligned(as: Int16.self))
                    default: value[e] = p.loadUnaligned(as: Float.self)
                    }
                }
                result[attribute] = value
                o += elements * size
            }
        }
        for a in 0..<12 where fixed & (1 << UInt32(a)) != 0 { result[a] = fixedAttributes[a] }
        return result
    }

    /// Runs the vertex shader on the loaded inputs and maps its outputs by semantic.
    private func shade() -> PICAVertex {
        shaderUnit.run(vertexShader)
        var vertex = PICAVertex()
        let enabled = regs[0x2BD] & 0xFFFF
        var slot = 0
        for register in 0..<16 where enabled & (1 << UInt32(register)) != 0 {
            guard slot < 7 else { break }
            let map = regs[0x50 + slot]
            let output = shaderUnit.outputs[register]
            for component in 0..<4 {
                let semantic = Int((map >> UInt32(component * 8)) & 0x1F)
                if semantic < 24 { vertex.values[semantic] = output[component] }
            }
            slot += 1
        }
        // Colours are clamped to 0...1 before interpolation.
        for i in 8..<12 { vertex.values[i] = min(max(vertex.values[i], 0), 1) }
        return vertex
    }

    private func draw(indexed: Bool) {
        drawCalls += 1
        rasterizer.configure(regs)
        resetAssembly()
        let count = Int(regs[0x228])
        let first = Int(regs[0x22A])
        let indexConfig = regs[0x227]
        let indexBase = (regs[0x200] << 3) &+ (indexConfig & 0x0FFF_FFFF)
        let wide = indexConfig & 0x8000_0000 != 0
        let indices = indexed ? memory.host(physical: indexBase) : nil
        // Indexed draws reuse vertices a lot: keep the shaded ones.
        var cache: [Int: PICAVertex] = [:]
        for i in 0..<count {
            let index: Int
            if indexed {
                guard let indices else { return }
                index = wide ? Int(indices.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                    : Int(indices.load(fromByteOffset: i, as: UInt8.self))
            } else {
                index = first + i
            }
            if let vertex = cache[index] {
                assemble(vertex)
                continue
            }
            loadInputs(attributes(of: index))
            let vertex = shade()
            if indexed { cache[index] = vertex }
            assemble(vertex)
        }
    }

    // MARK: - Primitive assembly

    private func resetAssembly() {
        assembled.removeAll(keepingCapacity: true)
        stripCount = 0
    }

    private func assemble(_ vertex: PICAVertex) {
        let topology = (regs[0x25E] >> 8) & 3
        switch topology {
        case 1, 2:  // strip, fan
            if assembled.count < 2 {
                assembled.append(vertex)
                return
            }
            rasterizer.triangle(assembled[0], assembled[1], vertex)
            if topology == 1 {
                // Alternate which old vertex is replaced so every triangle keeps the winding.
                assembled[stripCount & 1] = vertex
                stripCount += 1
            } else {
                assembled[1] = vertex
            }
        default:  // triangle list (and geometry-shader primitives, drawn as triangles)
            assembled.append(vertex)
            if assembled.count == 3 {
                rasterizer.triangle(assembled[0], assembled[1], assembled[2])
                assembled.removeAll(keepingCapacity: true)
            }
        }
    }
}
