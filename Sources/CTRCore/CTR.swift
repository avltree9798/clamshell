// SPDX-License-Identifier: GPL-3.0-or-later

import ARMCore
import EmuKit

/// Nintendo 3DS core: the application ARM11 with a high-level emulated Horizon
/// kernel and system services, loading .3dsx homebrew.
///
/// What works: the CPU (ARMv6K + VFPv2), threads and synchronisation, memory
/// management, srv/APT/cfg/ptm/hid, and the framebuffer path of gsp::Gpu (2D
/// output, memory fills and DMA). Not yet: the PICA200 3D GPU, DSP audio, the
/// file system, and encrypted retail titles (which this project will never decrypt).
public final class CTR: EmulatorCore {
    public static let descriptor = SystemDescriptor(
        id: .ctr,
        screens: [
            ScreenDescriptor(role: .primary, width: 400, height: 240, acceptsTouch: false),
            ScreenDescriptor(role: .touch, width: 320, height: 240, acceptsTouch: true),
        ],
        frameRate: Double(Kernel.clockRate) / Double(CTR.cyclesPerFrame),
        audioSampleRate: 32_728,
        hasAnalogStick: true, hasMotionSensors: true, hasCameras: true)

    /// 268,111,856 Hz / 59.83 Hz.
    public static let cyclesPerFrame: UInt64 = 4_481_136
    /// Longest stretch one thread runs before the kernel looks at timers again.
    static let quantum: UInt64 = 33_000

    private let frames: FrameSink
    private let audio: AudioRing
    private let input: InputState
    private var audioPhase: Double = 0

    private(set) var memory: AddressSpace
    private var bus: Bus11
    private(set) var cpu: ARM<Bus11>
    private(set) var kernel: Kernel
    private var gsp: GSPService!
    private var hid: HIDService!
    private var image: [UInt8] = []
    private var frameStart: UInt64 = 0

    public init(frames: FrameSink, audio: AudioRing, input: InputState) {
        self.frames = frames
        self.audio = audio
        self.input = input
        (memory, bus, cpu, kernel) = Self.makeMachine()
    }

    private static func makeMachine() -> (AddressSpace, Bus11, ARM<Bus11>, Kernel) {
        let memory = AddressSpace()
        let bus = Bus11(memory: memory)
        let cpu = ARM(model: .arm11mpcore, bus: bus)
        cpu.haltConsumesTime = false
        let kernel = Kernel(memory: memory, cpu: cpu)
        bus.kernel = kernel
        return (memory, bus, cpu, kernel)
    }

    public func load(image bytes: [UInt8]) throws(CoreError) {
        guard ThreeDSX.looksLike(bytes) else {
            throw .unsupportedImage("Only .3dsx homebrew runs so far. Retail .3ds/.cia titles are not supported yet.")
        }
        _ = try ThreeDSX(bytes)
        image = bytes
        reset()
    }

    public func reset() {
        (memory, bus, cpu, kernel) = Self.makeMachine()
        frameStart = 0
        installServices()
        mapSystemPages()
        guard let executable = try? ThreeDSX(image) else { return }
        let entry = executable.load(into: memory)

        let stackSize: UInt32 = 0x4_0000
        memory.mapNew(0x1000_0000 - stackSize, size: stackSize, permission: .readWrite, state: .private)
        kernel.createThread(entry: entry, argument: 0, stackTop: 0x1000_0000, priority: 0x30)
        kernel.reschedule()
    }

    private func installServices() {
        func add(_ service: Service, as names: String...) { for n in names { kernel.services[n] = service } }
        add(ServiceManager(name: "srv:", kernel: kernel), as: "srv:")
        add(AppletService(name: "APT:U", kernel: kernel), as: "APT:U", "APT:A", "APT:S")
        add(ConfigService(name: "cfg:u", kernel: kernel), as: "cfg:u", "cfg:s", "cfg:i")
        add(PowerService(name: "ptm:u", kernel: kernel), as: "ptm:u", "ptm:sysm", "ptm:s")
        add(FileSystemService(name: "fs:USER", kernel: kernel), as: "fs:USER")
        let gsp = GSPService(name: "gsp::Gpu", kernel: kernel)
        add(gsp, as: "gsp::Gpu")
        let hid = HIDService(name: "hid:USER", kernel: kernel)
        add(hid, as: "hid:USER", "hid:SPVR")
        self.gsp = gsp
        self.hid = hid
        kernel.makeStubService = { [unowned kernel] name in StubService(name: name, kernel: kernel) }
    }

    /// Kernel configuration memory, the shared page and thread-local storage.
    private func mapSystemPages() {
        memory.mapNew(0x1FF8_0000, size: 0x1000, permission: .read, state: .static)
        memory.mapNew(0x1FF8_1000, size: 0x1000, permission: .read, state: .shared)
        memory.mapNew(0x1FF8_2000, size: 0x4000, permission: .readWrite, state: .private)
        memory.write32(0x1FF8_0000, 0x0239_0000)  // kernel 2.57.0 (system 11.x)
        memory.write32(0x1FF8_0060, 0x0239_0000)  // FIRM version
        memory.write32(0x1FF8_0030, 0)            // APPMEMTYPE: 64 MB layout
        memory.write32(0x1FF8_0040, Kernel.applicationMemory)
        memory.write32(0x1FF8_0044, 0x02C0_0000)  // SYSMEMALLOC
        memory.write32(0x1FF8_0048, 0x0140_0000)  // BASEMEMALLOC
        memory.write32(0x1FF8_1004, 1)            // RUNNING_HW: retail unit
    }

    public func runFrame() {
        let frameEnd = frameStart + Self.cyclesPerFrame
        while cpu.cycles < frameEnd && !kernel.exited {
            kernel.processTimedEvents()
            kernel.reschedule()
            var target = min(frameEnd, cpu.cycles + Self.quantum)
            if let wake = kernel.nextWakeTime { target = min(target, max(wake, cpu.cycles + 1)) }
            if kernel.currentThread == nil {
                cpu.cycles = target  // every thread is waiting: skip ahead
            } else {
                cpu.run(until: target)
            }
        }
        if cpu.cycles < frameEnd { cpu.cycles = frameEnd }
        frameStart = frameEnd
        hid.update(input: input, now: cpu.cycles)
        gsp.vblank()
        present()
        // No DSP yet: silence keeps the app's audio-driven pacing at the right rate.
        audioPhase += Self.descriptor.audioSampleRate / Self.descriptor.frameRate
        let count = Int(audioPhase)
        audioPhase -= Double(count)
        for _ in 0..<count { audio.push(left: 0, right: 0) }
    }

    // MARK: - Display

    /// Copies both framebuffers to the frame sink. 3DS framebuffers are stored
    /// rotated: each 240-pixel column of the screen is one row in memory.
    private func present() {
        for screen in 0..<2 {
            let width = screen == 0 ? 400 : 320
            let out = frames.backBuffer(screen: screen)
            let fb = gsp.screens[screen]
            let format = fb.format & 7
            let bpp: Int = format == 0 ? 4 : format == 1 ? 3 : 2
            let stride = fb.stride != 0 ? Int(fb.stride) : 240 * bpp
            guard fb.shownAddress != 0, let base = memory.pointer(fb.shownAddress),
                  memory.isMapped(fb.shownAddress, size: UInt32(stride * width)) else {
                out.update(repeating: 0xFF00_0000, count: width * 240)
                continue
            }
            for x in 0..<width {
                let column = base + x * stride
                for y in 0..<240 {
                    let p = column + (239 - y) * bpp
                    out[y * width + x] = Self.pixel(p, format: format)
                }
            }
        }
        frames.publish()
    }

    /// Converts one framebuffer pixel to 0xAARRGGBB.
    @inline(__always) static func pixel(_ p: UnsafeMutableRawPointer, format: UInt32) -> UInt32 {
        switch format {
        case 0:  // RGBA8: bytes A, B, G, R
            let r = UInt32(p.load(fromByteOffset: 3, as: UInt8.self)), g = UInt32(p.load(fromByteOffset: 2, as: UInt8.self))
            let b = UInt32(p.load(fromByteOffset: 1, as: UInt8.self))
            return 0xFF00_0000 | r << 16 | g << 8 | b  // the LCD ignores alpha
        case 1:  // BGR8: bytes B, G, R
            let b = UInt32(p.load(as: UInt8.self)), g = UInt32(p.load(fromByteOffset: 1, as: UInt8.self))
            let r = UInt32(p.load(fromByteOffset: 2, as: UInt8.self))
            return 0xFF00_0000 | r << 16 | g << 8 | b
        case 2:  // RGB565
            let v = UInt32(p.loadUnaligned(as: UInt16.self))
            let r = (v >> 11) & 0x1F, g = (v >> 5) & 0x3F, b = v & 0x1F
            return 0xFF00_0000 | (r << 3 | r >> 2) << 16 | (g << 2 | g >> 4) << 8 | (b << 3 | b >> 2)
        case 3:  // RGB5A1
            let v = UInt32(p.loadUnaligned(as: UInt16.self))
            let r = (v >> 11) & 0x1F, g = (v >> 6) & 0x1F, b = (v >> 1) & 0x1F
            return 0xFF00_0000 | (r << 3 | r >> 2) << 16 | (g << 3 | g >> 2) << 8 | (b << 3 | b >> 2)
        default:  // RGBA4
            let v = UInt32(p.loadUnaligned(as: UInt16.self))
            let r = (v >> 12) & 0xF, g = (v >> 8) & 0xF, b = (v >> 4) & 0xF
            return 0xFF00_0000 | (r * 17) << 16 | (g * 17) << 8 | b * 17
        }
    }

    // MARK: - State

    public var batterySave: [UInt8]? { get { nil } set {} }
    public func writeSnapshot(into writer: inout SnapshotWriter) {}
    public func readSnapshot(from reader: inout SnapshotReader) throws(CoreError) {}
    public func setLidClosed(_ closed: Bool) {}

    // MARK: - Diagnostics

    /// Kernel log: debug strings, unimplemented SVCs and service commands.
    public var log: [String] { kernel.log }
    public var hasExited: Bool { kernel.exited }
    public var instructionsRetired: UInt64 { cpu.instructionsRetired }
    public var memoryFaults: Int { memory.faults }
}
