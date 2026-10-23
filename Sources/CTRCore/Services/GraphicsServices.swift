// SPDX-License-Identifier: GPL-3.0-or-later
//
// gsp::Gpu (display and GPU access) and hid:USER (buttons, circle pad, touch).
// Shared-memory layouts from 3dbrew.

import EmuKit

/// One screen's scan-out settings, as the LCD hardware would hold them.
struct ScreenFramebuffer {
    /// Virtual addresses of the two buffers; `select` picks the one shown.
    var addresses: (UInt32, UInt32) = (0, 0)
    var select: UInt32 = 0
    var stride: UInt32 = 0
    /// Low 3 bits: 0 RGBA8, 1 BGR8, 2 RGB565, 3 RGB5A1, 4 RGBA4.
    var format: UInt32 = 1

    var shownAddress: UInt32 { select & 1 == 0 ? addresses.0 : addresses.1 }
}

final class GSPService: Service {
    enum Interrupt: UInt8 { case psc0 = 0, psc1 = 1, vblankTop = 2, vblankBottom = 3, ppf = 4, p3d = 5, dma = 6 }

    let sharedMemory = KSharedMemory(size: 0x1000)
    private var interruptEvent: KEvent?
    private let threadIndex = 0
    private var registered = false

    /// What the top (0) and bottom (1) screens show.
    var screens = [ScreenFramebuffer(), ScreenFramebuffer()]

    override func handle(_ ipc: inout IPC) {
        switch ipc.command {
        case 0x0001, 0x0002:  // WriteHWRegs, WriteHWRegsWithMask
            ipc.reply([0])
        case 0x0004:  // ReadHWRegs: report zeros
            ipc.reply([0])
        case 0x0005:  // SetBufferSwap(screen, FramebufferInfo)
            let screen = Int(ipc[1] & 1)
            apply(screen: screen, select: ipc[2], first: ipc[3], second: ipc[4], stride: ipc[5], format: ipc[6])
            ipc.reply([0])
        case 0x0008, 0x0009:  // FlushDataCache, InvalidateDataCache
            ipc.reply([0])
        case 0x000B:  // SetLcdForceBlack
            ipc.reply([0])
        case 0x000C:  // TriggerCmdReqQueue
            processCommandQueue()
            ipc.reply([0])
        case 0x0013:  // RegisterInterruptRelayQueue(flags, handle descriptor, event)
            interruptEvent = kernel.object(ipc[3], as: KEvent.self)
            let first = !registered
            registered = true
            // 0x2A07 tells the first client it owns GPU initialisation.
            ipc.reply([first ? 0x2A07 : 0, UInt32(threadIndex)], translate: IPC.handles([kernel.makeHandle(sharedMemory)]))
        case 0x0014:  // UnregisterInterruptRelayQueue
            interruptEvent = nil
            ipc.reply([0])
        case 0x0016, 0x0017:  // AcquireRight, ReleaseRight
            ipc.reply([0])
        case 0x0018:  // ImportDisplayCaptureInfo
            let top = screens[0], bottom = screens[1]
            ipc.reply([0, top.addresses.0, top.addresses.1, top.format, top.stride,
                       bottom.addresses.0, bottom.addresses.1, bottom.format, bottom.stride])
        default:
            ipc.reply([0])
        }
    }

    private func apply(screen: Int, select: UInt32, first: UInt32, second: UInt32, stride: UInt32, format: UInt32) {
        screens[screen] = ScreenFramebuffer(addresses: (first, second), select: select, stride: stride, format: format)
    }

    /// Called at each VBlank: takes framebuffer updates the application posted in
    /// shared memory, then queues VBlank interrupts for it.
    func vblank() {
        for screen in 0..<2 {
            let header = 0x200 + threadIndex * 0x80 + screen * 0x40
            let index = Int(sharedMemory.load8(header) & 1)
            guard sharedMemory.load8(header + 1) != 0 else { continue }
            let info = header + 4 + index * 0x1C
            apply(screen: screen, select: sharedMemory.load32(info), first: sharedMemory.load32(info + 4),
                  second: sharedMemory.load32(info + 8), stride: sharedMemory.load32(info + 12),
                  format: sharedMemory.load32(info + 16))
            sharedMemory.store8(header + 1, 0)
        }
        raise(.vblankTop)
        raise(.vblankBottom)
    }

    /// Appends an interrupt to the relay queue and signals the application's event.
    func raise(_ interrupt: Interrupt) {
        guard let event = interruptEvent else { return }
        let queue = threadIndex * 0x40
        let start = Int(sharedMemory.load8(queue)), count = Int(sharedMemory.load8(queue + 1))
        if count >= 0x34 {
            sharedMemory.store8(queue + 2, 1)  // overflow
        } else {
            sharedMemory.store8(queue + 0xC + (start + count) % 0x34, interrupt.rawValue)
            sharedMemory.store8(queue + 1, UInt8(count + 1))
        }
        kernel.signal(event)
    }

    /// GX commands posted to shared memory (0x800 + thread * 0x200), run synchronously.
    private func processCommandQueue() {
        let queue = 0x800 + threadIndex * 0x200
        var count = Int(sharedMemory.load8(queue + 1))
        var index = Int(sharedMemory.load8(queue))
        while count > 0 {
            let command = queue + 0x20 + index * 0x20
            let id = sharedMemory.load32(command) & 0xFF
            let word = { (i: Int) in self.sharedMemory.load32(command + i * 4) }
            switch id {
            case 0x00:  // RequestDma(source, destination, size)
                copy(from: word(1), to: word(2), count: Int(word(3)))
                raise(.dma)
            case 0x01:  // ProcessCommandList: no PICA200 renderer yet
                raise(.p3d)
            case 0x02:  // MemoryFill(start0, value0, end0, start1, value1, end1, widths)
                fill(start: word(1), value: word(2), end: word(3), control: word(7) & 0xFFFF)
                if word(4) != 0 { fill(start: word(4), value: word(5), end: word(6), control: word(7) >> 16) }
                raise(.psc0)
            case 0x03, 0x04:  // DisplayTransfer, TextureCopy: no tiled conversion yet
                raise(.ppf)
            default:
                break
            }
            sharedMemory.store32(command, 0)
            index = (index + 1) % 15
            count -= 1
        }
        sharedMemory.store8(queue, UInt8(index))
        sharedMemory.store8(queue + 1, 0)
    }

    private func copy(from source: UInt32, to destination: UInt32, count: Int) {
        for i in 0..<count / 4 {
            memory.write32(destination &+ UInt32(i * 4), memory.read32(source &+ UInt32(i * 4)))
        }
    }

    private func fill(start: UInt32, value: UInt32, end: UInt32, control: UInt32) {
        // Addresses are physical, in 8-byte units.
        guard start != 0, end > start else { return }
        let width = (control >> 8) & 3  // 0: 16-bit, 1: 24-bit, 2/3: 32-bit
        guard let base = memory.host(physical: start << 3) else { return }
        let bytes = Int((end - start) << 3)
        switch width {
        case 0:
            for i in stride(from: 0, to: bytes - 1, by: 2) { base.storeBytes(of: UInt16(truncatingIfNeeded: value), toByteOffset: i, as: UInt16.self) }
        case 1:
            for i in stride(from: 0, to: bytes - 2, by: 3) {
                base.storeBytes(of: UInt8(truncatingIfNeeded: value), toByteOffset: i, as: UInt8.self)
                base.storeBytes(of: UInt8(truncatingIfNeeded: value >> 8), toByteOffset: i + 1, as: UInt8.self)
                base.storeBytes(of: UInt8(truncatingIfNeeded: value >> 16), toByteOffset: i + 2, as: UInt8.self)
            }
        default:
            for i in stride(from: 0, to: bytes - 3, by: 4) { base.storeBytes(of: value, toByteOffset: i, as: UInt32.self) }
        }
    }
}

final class HIDService: Service {
    let sharedMemory = KSharedMemory(size: 0x1000)
    let padEvent0 = KEvent(resetType: .oneShot, name: "HID pad 0")
    let padEvent1 = KEvent(resetType: .oneShot, name: "HID pad 1")
    let accelerometerEvent = KEvent(resetType: .oneShot, name: "HID accelerometer")
    let gyroscopeEvent = KEvent(resetType: .oneShot, name: "HID gyroscope")
    let debugPadEvent = KEvent(resetType: .oneShot, name: "HID debug pad")

    private var padIndex = 0, touchIndex = 0
    private var lastTick: UInt64 = 0
    private var previousButtons: UInt32 = 0

    override func handle(_ ipc: inout IPC) {
        switch ipc.command {
        case 0x000A:  // GetIPCHandles
            let handles = [sharedMemory, padEvent0, padEvent1, accelerometerEvent, gyroscopeEvent, debugPadEvent]
                .map { kernel.makeHandle($0) }
            ipc.reply([0], translate: IPC.handles(handles))
        case 0x0011, 0x0012, 0x0013, 0x0014:  // enable/disable accelerometer, gyroscope
            ipc.reply([0])
        case 0x0015:  // GetGyroscopeLowRawToDpsCoefficient
            ipc.reply([0, Float(14.375).bitPattern])
        case 0x0017:  // GetSoundVolume
            ipc.reply([0, 0x3F])
        default:
            unimplemented(ipc)
        }
    }

    /// Writes one new pad and touch sample, as the HID module does every few milliseconds.
    func update(input: InputState, now: UInt64) {
        let pressed = input.buttons
        // Bits 0-11 of Buttons match the 3DS pad layout; ZL and ZR sit at 14 and 15 there.
        var buttons = pressed.rawValue & 0xFFF
        if pressed.contains(.zl) { buttons |= 1 << 14 }
        if pressed.contains(.zr) { buttons |= 1 << 15 }
        let stick = input.stick
        let x = Int32(stick.x) * 156 / 32767, y = Int32(stick.y) * 156 / 32767
        if x > 40 { buttons |= 1 << 28 }
        if x < -40 { buttons |= 1 << 29 }
        if y > 40 { buttons |= 1 << 30 }
        if y < -40 { buttons |= 1 << 31 }

        padIndex = (padIndex + 1) % 8
        sharedMemory.store32(0x08, UInt32(truncatingIfNeeded: lastTick))
        sharedMemory.store32(0x0C, UInt32(truncatingIfNeeded: lastTick >> 32))
        sharedMemory.store32(0x00, UInt32(truncatingIfNeeded: now))
        sharedMemory.store32(0x04, UInt32(truncatingIfNeeded: now >> 32))
        sharedMemory.store32(0x10, UInt32(padIndex))
        let entry = 0x28 + padIndex * 0x10
        sharedMemory.store32(entry, buttons)
        sharedMemory.store32(entry + 4, buttons & ~previousButtons)
        sharedMemory.store32(entry + 8, previousButtons & ~buttons)
        sharedMemory.store32(entry + 12, UInt32(UInt16(bitPattern: Int16(x))) | UInt32(UInt16(bitPattern: Int16(y))) << 16)
        previousButtons = buttons

        touchIndex = (touchIndex + 1) % 8
        let touch = 0xA8
        sharedMemory.store32(touch + 8, UInt32(truncatingIfNeeded: lastTick))
        sharedMemory.store32(touch + 12, UInt32(truncatingIfNeeded: lastTick >> 32))
        sharedMemory.store32(touch, UInt32(truncatingIfNeeded: now))
        sharedMemory.store32(touch + 4, UInt32(truncatingIfNeeded: now >> 32))
        sharedMemory.store32(touch + 0x10, UInt32(touchIndex))
        let point = touch + 0x20 + touchIndex * 8
        if let t = input.touch {
            sharedMemory.store32(point, UInt32(min(max(t.x, 0), 319)) | UInt32(min(max(t.y, 0), 239)) << 16)
            sharedMemory.store32(point + 4, 1)
        } else {
            sharedMemory.store32(point, 0)
            sharedMemory.store32(point + 4, 0)
        }
        lastTick = now
        kernel.signal(padEvent0)
        kernel.signal(padEvent1)
    }
}
