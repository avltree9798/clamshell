// SPDX-License-Identifier: GPL-3.0-or-later
//
// The PICA200 vertex shader unit: program memory, operand descriptors, uniforms and
// an interpreter for its instruction set. Encodings from 3dbrew ("Shader
// Instruction Set") and the behaviour Citra documents. Arithmetic runs in Float;
// the hardware's 24-bit floats only differ in the last bits.

import Foundation

/// PICA 24-bit float: 1 sign bit, 7 exponent bits (bias 63), 16 mantissa bits.
enum Float24 {
    static func float(_ raw: UInt32) -> Float {
        let mantissa = raw & 0xFFFF, exponent = (raw >> 16) & 0x7F, sign = (raw >> 23) & 1
        if exponent == 0 { return sign != 0 ? -0.0 : 0 }  // no denormals
        if exponent == 0x7F {
            return Float(bitPattern: sign << 31 | 0xFF << 23 | mantissa << 7)
        }
        return Float(bitPattern: sign << 31 | (exponent + 64) << 23 | mantissa << 7)
    }

    /// Four float24 values packed into three words, w first, as uniform and attribute
    /// uploads send them.
    static func vector(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> SIMD4<Float> {
        SIMD4(float(c & 0xFF_FFFF),
              float((b & 0xFFFF) << 8 | c >> 24),
              float((a & 0xFF) << 16 | b >> 16),
              float(a >> 8))
    }

    /// Converts a 31-bit float (1.7.23 with bias 63), as some rasteriser registers hold.
    static func float31(_ raw: UInt32) -> Float {
        let mantissa = raw & 0x7F_FFFF, exponent = (raw >> 23) & 0x7F, sign = (raw >> 30) & 1
        if exponent == 0 { return 0 }
        return Float(bitPattern: sign << 31 | (exponent + 64) << 23 | mantissa)
    }
}

/// The program, swizzle patterns and uniforms of one shader unit.
struct PICAShaderSetup {
    var program = [UInt32](repeating: 0, count: 4096)
    var swizzles = [UInt32](repeating: 0, count: 128)
    var floatUniforms = [SIMD4<Float>](repeating: .zero, count: 96)
    var intUniforms = [SIMD4<Int32>](repeating: .zero, count: 4)
    var boolUniforms: UInt16 = 0
    var entryPoint = 0
}

/// Runs a shader program for one vertex.
struct PICAShaderUnit {
    var inputs = [SIMD4<Float>](repeating: .zero, count: 16)
    var outputs = [SIMD4<Float>](repeating: .zero, count: 16)
    private var temps = [SIMD4<Float>](repeating: .zero, count: 16)
    private var address = SIMD2<Int32>(0, 0)
    private var loopCounter: Int32 = 0
    private var conditions = (x: false, y: false)

    /// Control flow the program is inside: when `pc` reaches `end`, continue at
    /// `resume`, possibly repeating a loop.
    private struct Frame {
        var end: Int
        var resume: Int
        var kind: Kind
        var loopsLeft = 0
        var loopStart = 0
        var increment: Int32 = 0
        enum Kind { case call, ifElse, loop }
    }

    init() {}

    mutating func run(_ setup: PICAShaderSetup) {
        for i in 0..<16 { outputs[i] = .zero }
        for i in 0..<16 { temps[i] = .zero }
        address = .zero
        loopCounter = 0
        conditions = (false, false)
        var stack: [Frame] = []
        var pc = setup.entryPoint
        var steps = 0
        let program = setup.program

        while pc < 4096 && steps < 100_000 {
            steps += 1
            // Leave a block that ends here, or go round its loop again.
            if let top = stack.last, top.end == pc {
                stack.removeLast()
                if top.kind == .loop && top.loopsLeft > 0 {
                    loopCounter &+= top.increment
                    var again = top
                    again.loopsLeft -= 1
                    stack.append(again)
                    pc = top.loopStart
                } else {
                    pc = top.resume
                }
                continue
            }

            let instruction = program[pc]
            let opcode = instruction >> 26
            pc += 1
            switch opcode {
            case 0x00...0x0F, 0x12, 0x13, 0x18...0x1B:
                arithmetic(instruction, opcode: opcode, setup)
            case 0x20:  // BREAK
                if let i = stack.lastIndex(where: { $0.kind == .loop }) {
                    pc = stack[i].resume
                    stack.removeSubrange(i...)
                }
            case 0x21, 0x2A, 0x2B:  // NOP, EMIT, SETEMIT (geometry shaders only)
                break
            case 0x22:  // END
                return
            case 0x23:  // BREAKC
                if condition(instruction), let i = stack.lastIndex(where: { $0.kind == .loop }) {
                    pc = stack[i].resume
                    stack.removeSubrange(i...)
                }
            case 0x24, 0x25, 0x26:  // CALL, CALLC, CALLU
                let taken = opcode == 0x24 || (opcode == 0x25 ? condition(instruction) : boolUniform(instruction, setup))
                if taken {
                    let destination = Int((instruction >> 10) & 0xFFF), count = Int(instruction & 0xFF)
                    stack.append(Frame(end: destination + count, resume: pc, kind: .call))
                    pc = destination
                }
            case 0x27, 0x28:  // IFU, IFC
                let taken = opcode == 0x28 ? condition(instruction) : boolUniform(instruction, setup)
                let destination = Int((instruction >> 10) & 0xFFF), count = Int(instruction & 0xFF)
                if taken {
                    // Run the "then" block up to the else part, then skip it.
                    stack.append(Frame(end: destination, resume: destination + count, kind: .ifElse))
                } else {
                    pc = destination
                    stack.append(Frame(end: destination + count, resume: destination + count, kind: .ifElse))
                }
            case 0x29:  // LOOP
                let i = setup.intUniforms[Int((instruction >> 22) & 3)]
                let destination = Int((instruction >> 10) & 0xFFF)
                loopCounter = i.y & 0xFF
                stack.append(Frame(end: destination + 1, resume: destination + 1, kind: .loop,
                                   loopsLeft: Int(i.x & 0xFF), loopStart: pc, increment: Int32(Int8(truncatingIfNeeded: i.z))))
            case 0x2C, 0x2D:  // JMPC, JMPU
                let taken = opcode == 0x2C ? condition(instruction)
                    : boolUniform(instruction, setup) == (instruction & 1 == 0)
                if taken { pc = Int((instruction >> 10) & 0xFFF) }
            case 0x2E, 0x2F:  // CMP
                compare(instruction, setup)
            case 0x30...0x3F:  // MADI, MAD
                multiplyAdd(instruction, inverted: opcode < 0x38, setup)
            default:
                break
            }
        }
    }

    // MARK: - Conditions

    private func condition(_ instruction: UInt32) -> Bool {
        let refX = (instruction >> 25) & 1 != 0, refY = (instruction >> 24) & 1 != 0
        let x = conditions.x == refX, y = conditions.y == refY
        switch (instruction >> 22) & 3 {
        case 0: return x || y
        case 1: return x && y
        case 2: return x
        default: return y
        }
    }

    private func boolUniform(_ instruction: UInt32, _ setup: PICAShaderSetup) -> Bool {
        setup.boolUniforms & (1 << UInt16((instruction >> 22) & 0xF)) != 0
    }

    // MARK: - Operands

    /// Reads source register `index` (0x00-0x0F inputs, 0x10-0x1F temporaries,
    /// 0x20-0x7F float uniforms), offset by an address register for uniforms.
    private func source(_ index: UInt32, offset: Int32, _ setup: PICAShaderSetup) -> SIMD4<Float> {
        switch index {
        case 0x00..<0x10: return inputs[Int(index)]
        case 0x10..<0x20: return temps[Int(index - 0x10)]
        default:
            let uniform = Int32(index) - 0x20 + offset
            guard uniform >= 0 && uniform < 96 else { return SIMD4(repeating: 1) }
            return setup.floatUniforms[Int(uniform)]
        }
    }

    private func offset(_ selector: UInt32) -> Int32 {
        switch selector {
        case 1: return address.x
        case 2: return address.y
        case 3: return loopCounter
        default: return 0
        }
    }

    /// Applies a swizzle selector (8 bits, x first) and optional negation.
    @inline(__always) private func swizzle(_ v: SIMD4<Float>, _ selector: UInt32, negate: Bool) -> SIMD4<Float> {
        let r = SIMD4(v[Int((selector >> 6) & 3)], v[Int((selector >> 4) & 3)], v[Int((selector >> 2) & 3)], v[Int(selector & 3)])
        return negate ? -r : r
    }

    private mutating func write(_ destination: UInt32, _ value: SIMD4<Float>, mask: UInt32) {
        for i in 0..<4 where mask & (8 >> UInt32(i)) != 0 {
            if destination < 0x10 { outputs[Int(destination)][i] = value[i] } else if destination < 0x20 {
                temps[Int(destination - 0x10)][i] = value[i]
            }
        }
    }

    /// The PICA multiplies 0 × infinity to 0.
    @inline(__always) private static func mul(_ a: Float, _ b: Float) -> Float {
        a == 0 || b == 0 ? 0 : a * b
    }

    private static func dot(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ count: Int) -> Float {
        var sum: Float = 0
        for i in 0..<count { sum += mul(a[i], b[i]) }
        return sum
    }

    // MARK: - Instructions

    private mutating func arithmetic(_ instruction: UInt32, opcode: UInt32, _ setup: PICAShaderSetup) {
        let descriptor = setup.swizzles[Int(instruction & 0x7F)]
        let inverted = opcode >= 0x18
        let index = (instruction >> 19) & 3
        let src1Index = inverted ? (instruction >> 14) & 0x1F : (instruction >> 12) & 0x7F
        let src2Index = inverted ? (instruction >> 7) & 0x7F : (instruction >> 7) & 0x1F
        let a = swizzle(source(src1Index, offset: inverted ? 0 : offset(index), setup), (descriptor >> 5) & 0xFF,
                        negate: descriptor & 0x10 != 0)
        let b = swizzle(source(src2Index, offset: inverted ? offset(index) : 0, setup), (descriptor >> 14) & 0xFF,
                        negate: descriptor & 0x2000 != 0)
        let destination = (instruction >> 21) & 0x1F
        let mask = descriptor & 0xF
        var result = SIMD4<Float>.zero
        switch opcode {
        case 0x00: result = a + b                                                  // ADD
        case 0x01: result = SIMD4(repeating: Self.dot(a, b, 3))                    // DP3
        case 0x02: result = SIMD4(repeating: Self.dot(a, b, 4))                    // DP4
        case 0x03, 0x18:                                                           // DPH, DPHI
            var h = a; h.w = 1
            result = SIMD4(repeating: Self.dot(h, b, 4))
        case 0x04, 0x19: result = SIMD4(1, Self.mul(a.y, b.y), a.z, b.w)          // DST, DSTI
        case 0x05: result = SIMD4(repeating: exp2(a.x))                            // EX2
        case 0x06: result = SIMD4(repeating: log2(a.x))                            // LG2
        case 0x07: result = Self.lightingPower(a, setup: &conditions)              // LITP
        case 0x08: result = SIMD4(Self.mul(a.x, b.x), Self.mul(a.y, b.y), Self.mul(a.z, b.z), Self.mul(a.w, b.w))  // MUL
        case 0x09, 0x1A: result = SIMD4((0..<4).map { a[$0] >= b[$0] ? Float(1) : 0 })  // SGE, SGEI
        case 0x0A, 0x1B: result = SIMD4((0..<4).map { a[$0] < b[$0] ? Float(1) : 0 })   // SLT, SLTI
        case 0x0B: result = a.rounded(.down)                                       // FLR
        case 0x0C: result = SIMD4((0..<4).map { a[$0] > b[$0] ? a[$0] : b[$0] })    // MAX
        case 0x0D: result = SIMD4((0..<4).map { a[$0] < b[$0] ? a[$0] : b[$0] })    // MIN
        case 0x0E: result = SIMD4(repeating: 1 / a.x)                              // RCP
        case 0x0F: result = SIMD4(repeating: 1 / a.x.squareRoot())                 // RSQ
        case 0x12:                                                                 // MOVA
            if mask & 8 != 0 { address.x = Int32(clamping: Int(a.x.isFinite ? a.x : 0)) }
            if mask & 4 != 0 { address.y = Int32(clamping: Int(a.y.isFinite ? a.y : 0)) }
            return
        case 0x13: result = a                                                      // MOV
        default: return
        }
        write(destination, result, mask: mask)
    }

    /// LITP: clamps lighting inputs and sets the condition flags from the signs.
    private static func lightingPower(_ a: SIMD4<Float>, setup conditions: inout (x: Bool, y: Bool)) -> SIMD4<Float> {
        conditions = (a.x < 0, a.w < 0)
        return SIMD4(max(a.x, 0), min(max(a.y, -127.9961), 127.9961), max(a.z, 0), max(a.w, 0))
    }

    private mutating func compare(_ instruction: UInt32, _ setup: PICAShaderSetup) {
        let descriptor = setup.swizzles[Int(instruction & 0x7F)]
        let index = (instruction >> 19) & 3
        let a = swizzle(source((instruction >> 12) & 0x7F, offset: offset(index), setup), (descriptor >> 5) & 0xFF,
                        negate: descriptor & 0x10 != 0)
        let b = swizzle(source((instruction >> 7) & 0x1F, offset: 0, setup), (descriptor >> 14) & 0xFF,
                        negate: descriptor & 0x2000 != 0)
        func test(_ op: UInt32, _ x: Float, _ y: Float) -> Bool {
            switch op {
            case 0: return x == y
            case 1: return x != y
            case 2: return x < y
            case 3: return x <= y
            case 4: return x > y
            case 5: return x >= y
            default: return true
            }
        }
        conditions = (test((instruction >> 24) & 7, a.x, b.x), test((instruction >> 21) & 7, a.y, b.y))
    }

    private mutating func multiplyAdd(_ instruction: UInt32, inverted: Bool, _ setup: PICAShaderSetup) {
        let descriptor = setup.swizzles[Int(instruction & 0x1F)]
        let index = (instruction >> 22) & 3
        let src1 = (instruction >> 17) & 0x1F
        let src2 = inverted ? (instruction >> 12) & 0x1F : (instruction >> 10) & 0x7F
        let src3 = inverted ? (instruction >> 5) & 0x7F : (instruction >> 5) & 0x1F
        let a = swizzle(source(src1, offset: 0, setup), (descriptor >> 5) & 0xFF, negate: descriptor & 0x10 != 0)
        let b = swizzle(source(src2, offset: inverted ? 0 : offset(index), setup), (descriptor >> 14) & 0xFF,
                        negate: descriptor & 0x2000 != 0)
        let c = swizzle(source(src3, offset: inverted ? offset(index) : 0, setup), (descriptor >> 23) & 0xFF,
                        negate: descriptor & 0x40_0000 != 0)
        let result = SIMD4((0..<4).map { Self.mul(a[$0], b[$0]) + c[$0] })
        write((instruction >> 24) & 0x1F, result, mask: descriptor & 0xF)
    }
}
