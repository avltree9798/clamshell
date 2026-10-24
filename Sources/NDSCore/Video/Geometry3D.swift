// SPDX-License-Identifier: GPL-3.0-or-later
//
// The DS 3D geometry engine: the command FIFO, matrix stacks, lighting,
// polygon assembly and clipping. Commands run as soon as they arrive, so the
// FIFO always reads as empty. Behaviour from GBATEK "DS 3D Video".

/// A 4 × 4 matrix of 20.12 fixed-point numbers. The DS multiplies row vectors
/// on the left, so translation sits in row 3.
struct Matrix4: Equatable {
    var m: [Int64] = [4096, 0, 0, 0, 0, 4096, 0, 0, 0, 0, 4096, 0, 0, 0, 0, 4096]

    static let identity = Matrix4()

    @inline(__always) subscript(_ row: Int, _ column: Int) -> Int64 {
        get { m[row * 4 + column] }
        set { m[row * 4 + column] = newValue }
    }

    /// `a * b`, as the DS computes it.
    static func * (a: Matrix4, b: Matrix4) -> Matrix4 {
        var r = Matrix4()
        for i in 0..<4 {
            for j in 0..<4 {
                var sum: Int64 = 0
                for k in 0..<4 { sum += a[i, k] * b[k, j] }
                r[i, j] = sum >> 12
            }
        }
        return r
    }
}

/// A vertex after transformation, in clip space, with its attributes.
struct ClipVertex {
    var x: Float, y: Float, z: Float, w: Float
    var r: Float, g: Float, b: Float   // 0...31
    var s: Float, t: Float             // texels

    static func lerp(_ a: ClipVertex, _ b: ClipVertex, _ f: Float) -> ClipVertex {
        ClipVertex(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, z: a.z + (b.z - a.z) * f, w: a.w + (b.w - a.w) * f,
                   r: a.r + (b.r - a.r) * f, g: a.g + (b.g - a.g) * f, b: a.b + (b.b - a.b) * f,
                   s: a.s + (b.s - a.s) * f, t: a.t + (b.t - a.t) * f)
    }
}

/// A clipped polygon ready for the rasteriser, vertices in screen space.
struct Polygon3D {
    struct Vertex {
        var x: Float, y: Float
        /// Depth for the depth buffer: z/w in 0...1, or w itself in W-buffer mode.
        var depth: Float
        var invW: Float
        var r: Float, g: Float, b: Float
        var s: Float, t: Float
    }
    var vertices: [Vertex]
    var attributes: UInt32
    var textureParameters: UInt32
    var paletteBase: UInt32
    var translucent: Bool
}

final class GPU3D {
    unowned(unsafe) let s: NDS

    // MARK: Geometry state

    var matrixMode = 0
    var projection = Matrix4.identity, position = Matrix4.identity, vector = Matrix4.identity, texture = Matrix4.identity
    var projectionStack = Matrix4.identity
    var positionStack = [Matrix4](repeating: .identity, count: 32)
    var vectorStack = [Matrix4](repeating: .identity, count: 32)
    var textureStack = Matrix4.identity
    var stackPointer = 0, projectionPointer = 0
    var stackError = false
    private var clip = Matrix4.identity
    private var clipDirty = false

    var vertexColor: (Float, Float, Float) = (31, 31, 31)
    var texCoord: (Int32, Int32) = (0, 0)
    var transformedTexCoord: (Float, Float) = (0, 0)
    var lastVertex: (Int64, Int64, Int64) = (0, 0, 0)
    var pendingAttributes: UInt32 = 0, polygonAttributes: UInt32 = 0
    var textureParameters: UInt32 = 0, paletteBase: UInt32 = 0
    var primitive = 0
    private var strip: [ClipVertex] = []
    private var stripCount = 0

    // Lighting
    var diffuse: UInt32 = 0, ambient: UInt32 = 0, specular: UInt32 = 0, emission: UInt32 = 0
    var useShininessTable = false
    var shininess = [UInt8](repeating: 0, count: 128)
    var lightVectors = [(Float, Float, Float)](repeating: (0, 0, -1), count: 4)
    var lightColors = [UInt32](repeating: 0, count: 4)

    var viewport: (x1: Int, y1: Int, x2: Int, y2: Int) = (0, 0, 255, 191)

    // Polygon lists: one being built, one being rendered.
    var building: [Polygon3D] = []
    var rendering: [Polygon3D] = []
    var vertexCount = 0
    var swapPending = false
    var swapParameters: UInt32 = 0
    var renderingWBuffer = false, renderingManualSort = false
    /// Commands that arrived while a swap waits for VBlank.
    private var deferred: [(UInt8, [UInt32])] = []

    // MARK: FIFO

    var gxstat: UInt32 = 0
    private var packedCommands: [UInt8] = []
    private var currentCommand: UInt8 = 0
    private var parameters: [UInt32] = []
    var positionResult: [Int32] = [0, 0, 0, 0]
    var vectorResult: [Int16] = [0, 0, 0]
    var boxTestResult = false

    // MARK: Rendering registers

    var edgeColors = [UInt16](repeating: 0, count: 8)
    var alphaTestRef: UInt32 = 0
    var clearColor: UInt32 = 0
    var clearDepth: UInt32 = 0x7FFF
    var clearOffset: UInt32 = 0
    var fogColor: UInt32 = 0, fogOffset: UInt32 = 0
    var fogTable = [UInt8](repeating: 0, count: 32)
    var toonTable = [UInt16](repeating: 0, count: 32)

    /// The rendered picture: BGR555 in bits 0-14, alpha 0-31 in bits 16-20, `Engine2D.opaque` when alpha > 0.
    let colorBuffer: UnsafeMutablePointer<UInt32>
    let depthBuffer: UnsafeMutablePointer<Float>
    let attributeBuffer: UnsafeMutablePointer<UInt32>

    init(system: NDS) {
        s = system
        colorBuffer = .allocate(capacity: 256 * 192)
        colorBuffer.initialize(repeating: 0, count: 256 * 192)
        depthBuffer = .allocate(capacity: 256 * 192)
        depthBuffer.initialize(repeating: 1, count: 256 * 192)
        attributeBuffer = .allocate(capacity: 256 * 192)
        attributeBuffer.initialize(repeating: 0, count: 256 * 192)
    }

    deinit {
        colorBuffer.deallocate()
        depthBuffer.deallocate()
        attributeBuffer.deallocate()
    }

    /// Parameter words each command takes.
    static let parameterCount: [UInt8: Int] = [
        0x00: 0, 0x10: 1, 0x11: 0, 0x12: 1, 0x13: 1, 0x14: 1, 0x15: 0, 0x16: 16, 0x17: 12, 0x18: 16, 0x19: 12,
        0x1A: 9, 0x1B: 3, 0x1C: 3, 0x20: 1, 0x21: 1, 0x22: 1, 0x23: 2, 0x24: 1, 0x25: 1, 0x26: 1, 0x27: 1,
        0x28: 1, 0x29: 1, 0x2A: 1, 0x2B: 1, 0x30: 1, 0x31: 1, 0x32: 1, 0x33: 1, 0x34: 32, 0x40: 1, 0x41: 0,
        0x50: 1, 0x60: 1, 0x70: 3, 0x71: 2, 0x72: 1,
    ]

    // MARK: - Register interface

    /// GXFIFO (0x04000400): packed commands, four per word, then their parameters.
    func writeFIFO(_ value: UInt32) {
        if packedCommands.isEmpty && parameters.isEmpty && currentCommand == 0 {
            packedCommands = (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }
            // Trailing zero commands are padding.
            while let last = packedCommands.last, last == 0 { packedCommands.removeLast() }
            nextPacked()
            return
        }
        parameters.append(value)
        if parameters.count >= Self.parameterCount[currentCommand] ?? 0 {
            submit(currentCommand, parameters)
            parameters.removeAll(keepingCapacity: true)
            currentCommand = 0
            nextPacked()
        }
    }

    /// Starts the next packed command, running any that take no parameters.
    private func nextPacked() {
        while !packedCommands.isEmpty {
            let command = packedCommands.removeFirst()
            if (Self.parameterCount[command] ?? 0) == 0 {
                submit(command, [])
            } else {
                currentCommand = command
                return
            }
        }
    }

    /// Direct command ports, 0x04000440-0x040005FC.
    func writeCommandPort(_ command: UInt8, _ value: UInt32) {
        let needed = Self.parameterCount[command] ?? 0
        if needed == 0 {
            submit(command, [])
            return
        }
        if currentCommand != command || !packedCommands.isEmpty {
            parameters.removeAll(keepingCapacity: true)
            packedCommands.removeAll()
            currentCommand = command
        }
        parameters.append(value)
        if parameters.count >= needed {
            submit(command, parameters)
            parameters.removeAll(keepingCapacity: true)
            currentCommand = 0
        }
    }

    func readGXSTAT() -> UInt32 {
        var v = gxstat & 0xC000_0000
        if boxTestResult { v |= 1 << 1 }
        v |= UInt32(stackPointer & 31) << 8
        v |= UInt32(projectionPointer & 1) << 13
        if stackError { v |= 1 << 15 }
        v |= 1 << 25 | 1 << 26  // FIFO less than half full, and empty
        if swapPending { v |= 1 << 27 }
        return v
    }

    func writeGXSTAT(_ value: UInt32, mask: UInt32) {
        if mask & 0x8000 != 0 && value & 0x8000 != 0 {
            stackError = false
            projectionPointer = 0
        }
        gxstat = (gxstat & ~(mask & 0xC000_0000)) | (value & mask & 0xC000_0000)
        checkFIFOInterrupt()
    }

    /// The FIFO is always empty, so either FIFO IRQ condition is always true. The IRQ
    /// is level-triggered, so this runs again whenever the flag is acknowledged.
    func checkFIFOInterrupt() {
        let mode = (gxstat >> 30) & 3
        if (mode == 1 || mode == 2) && s.irq9.iflags & IRQ.geometryFIFO == 0 { s.irq9.raise(IRQ.geometryFIFO) }
    }

    var ramCount: UInt32 { UInt32(building.count & 0xFFF) | UInt32(vertexCount & 0x1FFF) << 16 }

    func clipMatrixResult(_ i: Int) -> UInt32 {
        updateClip()
        return UInt32(truncatingIfNeeded: clip.m[i])
    }

    func vectorMatrixResult(_ i: Int) -> UInt32 { UInt32(truncatingIfNeeded: vector[i / 3, i % 3]) }

    /// Rendering registers at 0x04000320-0x040003BF, as aligned words.
    func writeRenderRegister(_ a: UInt32, _ v: UInt32, mask: UInt32) {
        @inline(__always) func half(_ shift: UInt32) -> UInt16? {
            mask & (0xFFFF << shift) != 0 ? UInt16(truncatingIfNeeded: v >> shift) : nil
        }
        switch a {
        case 0x0400_0330...0x0400_033C:
            let i = Int(a - 0x0400_0330) / 2
            if let lo = half(0) { edgeColors[i] = lo & 0x7FFF }
            if let hi = half(16) { edgeColors[i + 1] = hi & 0x7FFF }
        case 0x0400_0340: if mask & 0xFF != 0 { alphaTestRef = v & 0x1F }
        case 0x0400_0350: clearColor = (clearColor & ~mask) | (v & mask)
        case 0x0400_0354:
            if let lo = half(0) { clearDepth = UInt32(lo & 0x7FFF) }
            if let hi = half(16) { clearOffset = UInt32(hi) }
        case 0x0400_0358: fogColor = (fogColor & ~mask) | (v & mask)
        case 0x0400_035C: if let lo = half(0) { fogOffset = UInt32(lo & 0x7FFF) }
        case 0x0400_0360...0x0400_037C:
            for b in 0..<4 where mask & (0xFF << UInt32(b * 8)) != 0 {
                fogTable[Int(a - 0x0400_0360) + b] = UInt8(truncatingIfNeeded: v >> UInt32(b * 8)) & 0x7F
            }
        case 0x0400_0380...0x0400_03BC:
            let i = Int(a - 0x0400_0380) / 2
            if let lo = half(0) { toonTable[i] = lo & 0x7FFF }
            if let hi = half(16) { toonTable[i + 1] = hi & 0x7FFF }
        default: break
        }
    }

    /// Geometry registers at 0x04000400-0x040006A3 the ARM9 can read.
    func readGeometryRegister(_ a: UInt32) -> UInt32 {
        switch a {
        case 0x0400_0600: return readGXSTAT()
        case 0x0400_0604: return ramCount
        case 0x0400_0620...0x0400_062C: return UInt32(bitPattern: positionResult[Int(a - 0x0400_0620) / 4])
        case 0x0400_0630: return UInt32(UInt16(bitPattern: vectorResult[0])) | UInt32(UInt16(bitPattern: vectorResult[1])) << 16
        case 0x0400_0634: return UInt32(UInt16(bitPattern: vectorResult[2]))
        case 0x0400_0640...0x0400_067C: return clipMatrixResult(Int(a - 0x0400_0640) / 4)
        case 0x0400_0680...0x0400_06A0: return vectorMatrixResult(Int(a - 0x0400_0680) / 4)
        default: return 0
        }
    }

    func writeGeometryRegister(_ a: UInt32, _ v: UInt32, mask: UInt32) {
        switch a {
        case 0x0400_0400...0x0400_043C: writeFIFO(v)
        case 0x0400_0440...0x0400_05FC: writeCommandPort(UInt8((a - 0x0400_0400) / 4), v)
        case 0x0400_0600: writeGXSTAT(v, mask: mask)
        default: break
        }
    }

    // MARK: - Commands

    private func submit(_ command: UInt8, _ p: [UInt32]) {
        if swapPending {
            deferred.append((command, p))
            return
        }
        execute(command, p)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func execute(_ command: UInt8, _ p: [UInt32]) {
        switch command {
        case 0x10: matrixMode = Int(p[0] & 3)
        case 0x11: push()
        case 0x12: pop(Int(Int8(truncatingIfNeeded: UInt8(p[0] & 0x3F) << 2) >> 2))
        case 0x13: store(Int(p[0] & 31))
        case 0x14: restore(Int(p[0] & 31))
        case 0x15: load(.identity)
        case 0x16: load(Self.matrix(p, rows: 4, columns: 4))
        case 0x17: load(Self.matrix(p, rows: 4, columns: 3))
        case 0x18: multiply(Self.matrix(p, rows: 4, columns: 4))
        case 0x19: multiply(Self.matrix(p, rows: 4, columns: 3))
        case 0x1A: multiply(Self.matrix(p, rows: 3, columns: 3))
        case 0x1B: scale(Int64(Int32(bitPattern: p[0])), Int64(Int32(bitPattern: p[1])), Int64(Int32(bitPattern: p[2])))
        case 0x1C: translate(Int64(Int32(bitPattern: p[0])), Int64(Int32(bitPattern: p[1])), Int64(Int32(bitPattern: p[2])))
        case 0x20:
            vertexColor = (Float(p[0] & 0x1F), Float((p[0] >> 5) & 0x1F), Float((p[0] >> 10) & 0x1F))
        case 0x21: normal(p[0])
        case 0x22:
            texCoord = (Int32(Int16(truncatingIfNeeded: p[0])), Int32(Int16(truncatingIfNeeded: p[0] >> 16)))
            transformTexCoord(source: 1)
        case 0x23:
            vertex(Int64(Int16(truncatingIfNeeded: p[0])), Int64(Int16(truncatingIfNeeded: p[0] >> 16)), Int64(Int16(truncatingIfNeeded: p[1])))
        case 0x24:
            vertex(Self.signed10(p[0]) << 6, Self.signed10(p[0] >> 10) << 6, Self.signed10(p[0] >> 20) << 6)
        case 0x25: vertex(Int64(Int16(truncatingIfNeeded: p[0])), Int64(Int16(truncatingIfNeeded: p[0] >> 16)), lastVertex.2)
        case 0x26: vertex(Int64(Int16(truncatingIfNeeded: p[0])), lastVertex.1, Int64(Int16(truncatingIfNeeded: p[0] >> 16)))
        case 0x27: vertex(lastVertex.0, Int64(Int16(truncatingIfNeeded: p[0])), Int64(Int16(truncatingIfNeeded: p[0] >> 16)))
        case 0x28:  // VTX_DIFF: 1.0.9 offsets, which are whole steps of the 1.3.12 coordinates
            vertex(Int64(Int16(truncatingIfNeeded: lastVertex.0 + Self.signed10(p[0]))),
                   Int64(Int16(truncatingIfNeeded: lastVertex.1 + Self.signed10(p[0] >> 10))),
                   Int64(Int16(truncatingIfNeeded: lastVertex.2 + Self.signed10(p[0] >> 20))))
        case 0x29: pendingAttributes = p[0]
        case 0x2A: textureParameters = p[0]
        case 0x2B: paletteBase = p[0] & 0x1FFF
        case 0x30:
            diffuse = p[0] & 0x7FFF
            ambient = (p[0] >> 16) & 0x7FFF
            if p[0] & 0x8000 != 0 { vertexColor = (Float(diffuse & 0x1F), Float((diffuse >> 5) & 0x1F), Float((diffuse >> 10) & 0x1F)) }
        case 0x31:
            specular = p[0] & 0x7FFF
            useShininessTable = p[0] & 0x8000 != 0
            emission = (p[0] >> 16) & 0x7FFF
        case 0x32:
            let light = Int(p[0] >> 30)
            let x = Self.signed10(p[0]), y = Self.signed10(p[0] >> 10), z = Self.signed10(p[0] >> 20)
            // Light vectors are kept in the same space as transformed normals.
            let tx = (x * vector[0, 0] + y * vector[1, 0] + z * vector[2, 0]) >> 12
            let ty = (x * vector[0, 1] + y * vector[1, 1] + z * vector[2, 1]) >> 12
            let tz = (x * vector[0, 2] + y * vector[1, 2] + z * vector[2, 2]) >> 12
            lightVectors[light] = (Float(tx) / 512, Float(ty) / 512, Float(tz) / 512)
        case 0x33: lightColors[Int(p[0] >> 30)] = p[0] & 0x7FFF
        case 0x34:
            for (i, word) in p.enumerated() {
                for b in 0..<4 { shininess[i * 4 + b] = UInt8(truncatingIfNeeded: word >> UInt32(b * 8)) }
            }
        case 0x40:
            primitive = Int(p[0] & 3)
            polygonAttributes = pendingAttributes
            strip.removeAll(keepingCapacity: true)
            stripCount = 0
        case 0x41: break
        case 0x50:
            swapPending = true
            swapParameters = p[0]
        case 0x60:
            viewport = (Int(p[0] & 0xFF), Int((p[0] >> 8) & 0xFF), Int((p[0] >> 16) & 0xFF), Int((p[0] >> 24) & 0xFF))
        case 0x70: boxTest(p)
        case 0x71:
            texCoordLessVertexTest(Int64(Int16(truncatingIfNeeded: p[0])), Int64(Int16(truncatingIfNeeded: p[0] >> 16)),
                                   Int64(Int16(truncatingIfNeeded: p[1])))
        case 0x72:
            let x = Self.signed10(p[0]), y = Self.signed10(p[0] >> 10), z = Self.signed10(p[0] >> 20)
            for i in 0..<3 {
                let v = (x * vector[0, i] + y * vector[1, i] + z * vector[2, i]) >> 9
                vectorResult[i] = Int16(truncatingIfNeeded: v)
            }
        default: break
        }
    }

    @inline(__always) static func signed10(_ v: UInt32) -> Int64 { Int64(Int32(bitPattern: (v & 0x3FF) << 22) >> 22) }

    static func matrix(_ p: [UInt32], rows: Int, columns: Int) -> Matrix4 {
        var m = Matrix4.identity
        for r in 0..<rows {
            for c in 0..<columns { m[r, c] = Int64(Int32(bitPattern: p[r * columns + c])) }
        }
        return m
    }

    // MARK: - Matrices

    private func load(_ m: Matrix4) {
        switch matrixMode {
        case 0: projection = m
        case 1: position = m
        case 2: position = m; vector = m
        default: texture = m
        }
        clipDirty = true
    }

    private func multiply(_ m: Matrix4) {
        switch matrixMode {
        case 0: projection = m * projection
        case 1: position = m * position
        case 2: position = m * position; vector = m * vector
        default: texture = m * texture
        }
        clipDirty = true
    }

    private func scale(_ x: Int64, _ y: Int64, _ z: Int64) {
        var m = Matrix4.identity
        m[0, 0] = x; m[1, 1] = y; m[2, 2] = z
        switch matrixMode {
        case 0: projection = m * projection
        case 1, 2: position = m * position  // never the vector matrix
        default: texture = m * texture
        }
        clipDirty = true
    }

    private func translate(_ x: Int64, _ y: Int64, _ z: Int64) {
        var m = Matrix4.identity
        m[3, 0] = x; m[3, 1] = y; m[3, 2] = z
        multiply(m)
    }

    private func push() {
        switch matrixMode {
        case 0:
            if projectionPointer > 0 { stackError = true }
            projectionStack = projection
            projectionPointer = 1
        case 1, 2:
            if stackPointer >= 31 { stackError = true }
            positionStack[stackPointer & 31] = position
            vectorStack[stackPointer & 31] = vector
            stackPointer = (stackPointer + 1) & 63
        default:
            textureStack = texture
        }
    }

    private func pop(_ offset: Int) {
        switch matrixMode {
        case 0:
            if projectionPointer == 0 { stackError = true }
            projectionPointer = 0
            projection = projectionStack
        case 1, 2:
            stackPointer = (stackPointer - offset) & 63
            if stackPointer >= 31 { stackError = true }
            position = positionStack[stackPointer & 31]
            vector = vectorStack[stackPointer & 31]
        default:
            texture = textureStack
        }
        clipDirty = true
    }

    private func store(_ index: Int) {
        switch matrixMode {
        case 0: projectionStack = projection
        case 1, 2:
            if index == 31 { stackError = true }
            positionStack[index] = position
            vectorStack[index] = vector
        default: textureStack = texture
        }
    }

    private func restore(_ index: Int) {
        switch matrixMode {
        case 0: projection = projectionStack
        case 1, 2:
            if index == 31 { stackError = true }
            position = positionStack[index]
            vector = vectorStack[index]
        default: texture = textureStack
        }
        clipDirty = true
    }

    private func updateClip() {
        if clipDirty {
            clip = position * projection
            clipDirty = false
        }
    }

    // MARK: - Texture coordinates and lighting

    /// Applies the texture matrix per TEXIMAGE_PARAM bits 30-31; `source` is the command that triggered it.
    private func transformTexCoord(source: Int, normal: (Int64, Int64, Int64)? = nil, vertex: (Int64, Int64, Int64)? = nil) {
        let mode = Int(textureParameters >> 30)
        let s0 = Int64(texCoord.0), t0 = Int64(texCoord.1)
        switch (mode, source) {
        case (0, 1):
            transformedTexCoord = (Float(s0) / 16, Float(t0) / 16)
        case (1, 1):
            let s = (s0 * texture[0, 0] + t0 * texture[1, 0] + texture[2, 0] + texture[3, 0]) >> 12
            let t = (s0 * texture[0, 1] + t0 * texture[1, 1] + texture[2, 1] + texture[3, 1]) >> 12
            transformedTexCoord = (Float(s) / 16, Float(t) / 16)
        case (2, 2):
            guard let n = normal else { return }
            let s = ((n.0 * texture[0, 0] + n.1 * texture[1, 0] + n.2 * texture[2, 0]) >> 21) + s0
            let t = ((n.0 * texture[0, 1] + n.1 * texture[1, 1] + n.2 * texture[2, 1]) >> 21) + t0
            transformedTexCoord = (Float(s) / 16, Float(t) / 16)
        case (3, 3):
            guard let v = vertex else { return }
            let s = ((v.0 * texture[0, 0] + v.1 * texture[1, 0] + v.2 * texture[2, 0]) >> 24) + s0
            let t = ((v.0 * texture[0, 1] + v.1 * texture[1, 1] + v.2 * texture[2, 1]) >> 24) + t0
            transformedTexCoord = (Float(s) / 16, Float(t) / 16)
        case (0, _), (1, _):
            break
        default:
            break
        }
    }

    private func normal(_ word: UInt32) {
        let nx = Self.signed10(word), ny = Self.signed10(word >> 10), nz = Self.signed10(word >> 20)
        transformTexCoord(source: 2, normal: (nx, ny, nz))
        let x = Float((nx * vector[0, 0] + ny * vector[1, 0] + nz * vector[2, 0]) >> 12) / 512
        let y = Float((nx * vector[0, 1] + ny * vector[1, 1] + nz * vector[2, 1]) >> 12) / 512
        let z = Float((nx * vector[0, 2] + ny * vector[1, 2] + nz * vector[2, 2]) >> 12) / 512

        func channel(_ c: UInt32, _ shift: UInt32) -> Float { Float((c >> shift) & 0x1F) }
        var r = channel(emission, 0), g = channel(emission, 5), b = channel(emission, 10)
        for i in 0..<4 where polygonAttributesForLighting & (1 << UInt32(i)) != 0 {
            let l = lightVectors[i]
            let diffuseLevel = max(0, -(l.0 * x + l.1 * y + l.2 * z))
            // Half-way vector between the light and the line of sight (0, 0, -1).
            let h = (l.0 / 2, l.1 / 2, (l.2 - 1) / 2)
            var shine = max(0, -(h.0 * x + h.1 * y + h.2 * z))
            shine = min(shine * shine, 1)
            if useShininessTable { shine = Float(shininess[min(Int(shine * 127), 127)]) / 256 }
            let lc = lightColors[i]
            for (index, shift) in [(0, UInt32(0)), (1, 5), (2, 10)] {
                let light = channel(lc, shift) / 31
                let add = channel(specular, shift) * light * shine + channel(diffuse, shift) * light * diffuseLevel
                    + channel(ambient, shift) * light
                switch index {
                case 0: r += add
                case 1: g += add
                default: b += add
                }
            }
        }
        vertexColor = (min(r, 31), min(g, 31), min(b, 31))
    }

    /// Lights enabled for the polygon being drawn: the attributes latched at BEGIN_VTXS.
    private var polygonAttributesForLighting: UInt32 { pendingAttributes & 0xF }

    // MARK: - Vertices and polygons

    private func vertex(_ x: Int64, _ y: Int64, _ z: Int64) {
        lastVertex = (x, y, z)
        updateClip()
        transformTexCoord(source: 3, vertex: (x, y, z))
        let cx = (x * clip[0, 0] + y * clip[1, 0] + z * clip[2, 0] + 4096 * clip[3, 0]) >> 12
        let cy = (x * clip[0, 1] + y * clip[1, 1] + z * clip[2, 1] + 4096 * clip[3, 1]) >> 12
        let cz = (x * clip[0, 2] + y * clip[1, 2] + z * clip[2, 2] + 4096 * clip[3, 2]) >> 12
        let cw = (x * clip[0, 3] + y * clip[1, 3] + z * clip[2, 3] + 4096 * clip[3, 3]) >> 12
        let v = ClipVertex(x: Float(cx), y: Float(cy), z: Float(cz), w: Float(cw),
                           r: vertexColor.0, g: vertexColor.1, b: vertexColor.2,
                           s: transformedTexCoord.0, t: transformedTexCoord.1)
        vertexCount += 1
        strip.append(v)
        stripCount += 1

        switch primitive {
        case 0:  // separate triangles
            if strip.count == 3 { addPolygon(strip); strip.removeAll(keepingCapacity: true) }
        case 1:  // separate quads
            if strip.count == 4 { addPolygon(strip); strip.removeAll(keepingCapacity: true) }
        case 2:  // triangle strip: every other triangle is reversed to keep its winding
            if strip.count == 3 {
                addPolygon(stripCount % 2 == 0 ? [strip[1], strip[0], strip[2]] : strip)
                strip.removeFirst()
            }
        default:  // quad strip: vertices arrive 0 1 2 3, the quad is 0 1 3 2
            if strip.count == 4 {
                addPolygon([strip[0], strip[1], strip[3], strip[2]])
                strip.removeFirst(2)
            }
        }
    }

    private func addPolygon(_ input: [ClipVertex]) {
        guard building.count < 2048 else { return }
        let attributes = polygonAttributes
        // Culling: the winding in homogeneous (x, y, w) space, before clipping, as the hardware does.
        let front = Self.facesViewer(input)
        if front ? attributes & 0x80 == 0 : attributes & 0x40 == 0 { return }

        // Clip against the six planes of the view volume.
        var poly = input
        let farClip = attributes & (1 << 12) != 0
        for plane in 0..<6 {
            if plane == 5 && !farClip && poly.contains(where: { $0.z > $0.w }) { return }
            poly = Self.clip(poly, plane: plane)
            if poly.count < 3 { return }
        }

        let wBuffer = swapParameters & 2 != 0
        let x1 = Float(viewport.x1), width = Float(viewport.x2 - viewport.x1 + 1)
        let y1 = Float(viewport.y1), height = Float(viewport.y2 - viewport.y1 + 1)
        let vertices = poly.map { v -> Polygon3D.Vertex in
            let w = v.w == 0 ? 1 : v.w
            let invW = 1 / w
            let sx = (v.x * invW + 1) * width / 2 + x1
            let sy = 192 - ((v.y * invW + 1) * height / 2 + y1)
            let depth = wBuffer ? w / 4096 : (v.z * invW + 1) / 2
            return Polygon3D.Vertex(x: sx, y: sy, depth: depth, invW: invW,
                                    r: v.r, g: v.g, b: v.b, s: v.s, t: v.t)
        }
        let alpha = (attributes >> 16) & 0x1F
        let format = (textureParameters >> 26) & 7
        let translucent = (alpha != 0 && alpha < 31) || format == 1 || format == 6
        building.append(Polygon3D(vertices: vertices, attributes: attributes, textureParameters: textureParameters,
                                  paletteBase: paletteBase, translucent: translucent))
    }

    /// Whether the first three vertices wind towards the viewer, from the sign of the
    /// polygon normal's dot product with a vertex in (x, y, w) space.
    private static func facesViewer(_ p: [ClipVertex]) -> Bool {
        let v0 = p[0], v1 = p[1], v2 = p[2]
        let ax = Double(v0.x - v1.x), ay = Double(v0.y - v1.y), aw = Double(v0.w - v1.w)
        let bx = Double(v2.x - v1.x), by = Double(v2.y - v1.y), bw = Double(v2.w - v1.w)
        let nx = ay * bw - aw * by, ny = aw * bx - ax * bw, nw = ax * by - ay * bx
        return Double(v1.x) * nx + Double(v1.y) * ny + Double(v1.w) * nw <= 0
    }

    /// Sutherland-Hodgman against one plane: 0 x ≥ -w, 1 x ≤ w, 2 y ≥ -w, 3 y ≤ w, 4 z ≥ -w, 5 z ≤ w.
    private static func clip(_ poly: [ClipVertex], plane: Int) -> [ClipVertex] {
        func distance(_ v: ClipVertex) -> Float {
            switch plane {
            case 0: v.w + v.x
            case 1: v.w - v.x
            case 2: v.w + v.y
            case 3: v.w - v.y
            case 4: v.w + v.z
            default: v.w - v.z
            }
        }
        var out: [ClipVertex] = []
        out.reserveCapacity(poly.count + 2)
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let da = distance(a), db = distance(b)
            if da >= 0 { out.append(a) }
            if (da >= 0) != (db >= 0) {
                out.append(ClipVertex.lerp(a, b, da / (da - db)))
            }
        }
        return out
    }

    // MARK: - Tests

    private func boxTest(_ p: [UInt32]) {
        let x = Int64(Int16(truncatingIfNeeded: p[0])), y = Int64(Int16(truncatingIfNeeded: p[0] >> 16))
        let z = Int64(Int16(truncatingIfNeeded: p[1]))
        let w = Int64(Int16(truncatingIfNeeded: p[1] >> 16)), h = Int64(Int16(truncatingIfNeeded: p[2]))
        let d = Int64(Int16(truncatingIfNeeded: p[2] >> 16))
        updateClip()
        var outside = [Bool](repeating: true, count: 6)
        for corner in 0..<8 {
            let vx = x + (corner & 1 != 0 ? w : 0), vy = y + (corner & 2 != 0 ? h : 0), vz = z + (corner & 4 != 0 ? d : 0)
            let c = (0..<4).map { (vx * clip[0, $0] + vy * clip[1, $0] + vz * clip[2, $0] + 4096 * clip[3, $0]) >> 12 }
            let tests = [c[0] < -c[3], c[0] > c[3], c[1] < -c[3], c[1] > c[3], c[2] < -c[3], c[2] > c[3]]
            for i in 0..<6 where !tests[i] { outside[i] = false }
        }
        // Visible unless every corner is outside the same plane.
        boxTestResult = !outside.contains(true)
    }

    private func texCoordLessVertexTest(_ x: Int64, _ y: Int64, _ z: Int64) {
        lastVertex = (x, y, z)
        updateClip()
        for i in 0..<4 {
            positionResult[i] = Int32(truncatingIfNeeded: (x * clip[0, i] + y * clip[1, i] + z * clip[2, i] + 4096 * clip[3, i]) >> 12)
        }
    }

    // MARK: - Frame

    /// At VBlank: a pending SWAP_BUFFERS hands the polygon list to the rasteriser and renders it.
    func vblank() {
        guard swapPending else { return }
        rendering = building
        building.removeAll(keepingCapacity: true)
        vertexCount = 0
        renderingManualSort = swapParameters & 1 != 0
        renderingWBuffer = swapParameters & 2 != 0
        swapPending = false
        render()
        let queued = deferred
        deferred.removeAll()
        for (command, p) in queued { submit(command, p) }
        checkFIFOInterrupt()
    }

    func reset() {
        matrixMode = 0
        projection = .identity; position = .identity; vector = .identity; texture = .identity
        stackPointer = 0; projectionPointer = 0; stackError = false
        clipDirty = true
        building.removeAll(); rendering.removeAll(); deferred.removeAll()
        packedCommands.removeAll(); parameters.removeAll(); currentCommand = 0
        swapPending = false
        gxstat = 0
        vertexCount = 0
        colorBuffer.update(repeating: 0, count: 256 * 192)
    }
}
