// SPDX-License-Identifier: GPL-3.0-or-later

import Synchronization

/// Console buttons, as a bit set. Covers DS and 3DS.
public struct Buttons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let a      = Buttons(rawValue: 1 << 0)
    public static let b      = Buttons(rawValue: 1 << 1)
    public static let select = Buttons(rawValue: 1 << 2)
    public static let start  = Buttons(rawValue: 1 << 3)
    public static let right  = Buttons(rawValue: 1 << 4)
    public static let left   = Buttons(rawValue: 1 << 5)
    public static let up     = Buttons(rawValue: 1 << 6)
    public static let down   = Buttons(rawValue: 1 << 7)
    public static let r      = Buttons(rawValue: 1 << 8)
    public static let l      = Buttons(rawValue: 1 << 9)
    public static let x      = Buttons(rawValue: 1 << 10)
    public static let y      = Buttons(rawValue: 1 << 11)
    public static let zl     = Buttons(rawValue: 1 << 12)
    public static let zr     = Buttons(rawValue: 1 << 13)
    public static let home   = Buttons(rawValue: 1 << 14)
}

/// Latest input, written by the main actor and read once per frame by the core.
///
/// Every field is a single atomic word, so a reader may see a press from one
/// frame and a touch from the next; at 60 Hz that is invisible to players.
public final class InputState: Sendable {
    private let buttonBits = Atomic<UInt32>(0)
    /// Touch packed as x << 16 | y in screen pixels, or `UInt32.max` when not touching.
    private let touchBits = Atomic<UInt32>(.max)
    /// Circle pad packed as two Int16 values, x << 16 | y, range -32768...32767.
    private let stickBits = Atomic<UInt32>(0)

    public init() {}

    public var buttons: Buttons {
        get { Buttons(rawValue: buttonBits.load(ordering: .relaxed)) }
    }

    public func set(_ buttons: Buttons) {
        buttonBits.store(buttons.rawValue, ordering: .relaxed)
    }

    public func press(_ b: Buttons) { buttonBits.bitwiseOr(b.rawValue, ordering: .relaxed) }
    public func release(_ b: Buttons) { buttonBits.bitwiseAnd(~b.rawValue, ordering: .relaxed) }

    public var touch: (x: Int, y: Int)? {
        let v = touchBits.load(ordering: .relaxed)
        if v == .max { return nil }
        return (Int(v >> 16), Int(v & 0xFFFF))
    }

    public func setTouch(x: Int, y: Int) {
        touchBits.store(UInt32(clamping: x) << 16 | UInt32(clamping: y) & 0xFFFF, ordering: .relaxed)
    }

    public func clearTouch() { touchBits.store(.max, ordering: .relaxed) }

    public var stick: (x: Int16, y: Int16) {
        let v = stickBits.load(ordering: .relaxed)
        return (Int16(truncatingIfNeeded: v >> 16), Int16(truncatingIfNeeded: v))
    }

    public func setStick(x: Int16, y: Int16) {
        let packed = UInt32(UInt16(bitPattern: x)) << 16 | UInt32(UInt16(bitPattern: y))
        stickBits.store(packed, ordering: .relaxed)
    }
}

/// Triple-buffered frames: the core writes one, the renderer reads the newest.
///
/// Pixels are 32-bit BGRA, one buffer per screen, sized from the system descriptor.
public final class FrameSink: @unchecked Sendable {
    public let screens: [ScreenDescriptor]
    private let buffers: [[UnsafeMutablePointer<UInt32>]]  // [slot][screen]
    /// Low 2 bits: slot ready for the reader. Bit 2: a new frame is waiting.
    private let state = Atomic<UInt8>(0)
    private var writeSlot = 1
    private var readSlot = 2

    public init(screens: [ScreenDescriptor]) {
        self.screens = screens
        buffers = (0..<3).map { _ in
            screens.map { s in
                let p = UnsafeMutablePointer<UInt32>.allocate(capacity: s.width * s.height)
                p.initialize(repeating: 0xFF00_0000, count: s.width * s.height)
                return p
            }
        }
    }

    deinit { buffers.joined().forEach { $0.deallocate() } }

    /// Core side: the buffer for `screen` in the slot being drawn.
    @inline(__always)
    public func backBuffer(screen: Int) -> UnsafeMutablePointer<UInt32> {
        buffers[writeSlot][screen]
    }

    /// Core side: publishes the slot just drawn and takes the old ready slot to draw into.
    public func publish() {
        let new = UInt8(writeSlot) | 0b100
        let old = state.exchange(new, ordering: .acquiringAndReleasing)
        writeSlot = Int(old & 0b11)
    }

    /// Render side: takes the newest frame, or nil if none arrived since the last call.
    public func acquireNewest() -> [UnsafePointer<UInt32>]? {
        if state.load(ordering: .relaxed) & 0b100 == 0 { return nil }
        let old = state.exchange(UInt8(readSlot), ordering: .acquiringAndReleasing)
        readSlot = Int(old & 0b11)
        return buffers[readSlot].map { UnsafePointer($0) }
    }
}

/// Single-producer, single-consumer ring of interleaved stereo Int16 samples.
public final class AudioRing: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Int16>
    private let head = Atomic<Int>(0)  // next write index, owned by the core
    private let tail = Atomic<Int>(0)  // next read index, owned by the audio callback

    /// - Parameter frames: capacity in stereo frames; rounded up to a power of two.
    public init(frames: Int) {
        var c = 1
        while c < frames * 2 { c <<= 1 }
        capacity = c
        storage = .allocate(capacity: c)
        storage.initialize(repeating: 0, count: c)
    }

    deinit { storage.deallocate() }

    /// Stereo frames waiting to be played.
    public var fill: Int {
        (head.load(ordering: .acquiring) &- tail.load(ordering: .acquiring)) / 2
    }

    public var fillRatio: Double { Double(fill * 2) / Double(capacity) }

    /// Core side. Drops the frame if the ring is full.
    @inline(__always)
    public func push(left: Int16, right: Int16) {
        let h = head.load(ordering: .relaxed)
        if h &- tail.load(ordering: .acquiring) >= capacity { return }
        storage[h & (capacity - 1)] = left
        storage[(h + 1) & (capacity - 1)] = right
        head.store(h &+ 2, ordering: .releasing)
    }

    /// Audio side. Fills `out` with up to `count` stereo frames, padding silence on underrun.
    public func pull(into out: UnsafeMutablePointer<Int16>, frames count: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let available = min((head.load(ordering: .acquiring) &- t) / 2, count)
        for i in 0..<(available * 2) { out[i] = storage[(t + i) & (capacity - 1)] }
        for i in (available * 2)..<(count * 2) { out[i] = 0 }
        tail.store(t &+ available * 2, ordering: .releasing)
        return available
    }
}
