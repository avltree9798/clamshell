// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit

/// Master clock: one tick per ARM9 cycle, 67.027964 MHz. The ARM7 and the
/// bus run at half that, so ARM7-side periods are doubled.
public enum NDSClock {
    public static let hz: Double = 67_027_964
    public static let cyclesPerLine: UInt64 = 4260     // 355 dots × 6 ARM7 cycles × 2
    public static let hblankStart: UInt64 = 3072       // 256 dots × 6 × 2
    public static let linesPerFrame: UInt64 = 263
    public static let visibleLines: UInt64 = 192
    public static let cyclesPerFrame: UInt64 = cyclesPerLine * linesPerFrame  // 1_120_380
    public static let audioRate: Double = 32_768
}

/// Interrupt sources, as bits of IE and IF.
public enum IRQ {
    public static let vblank: UInt32 = 1 << 0
    public static let hblank: UInt32 = 1 << 1
    public static let vcount: UInt32 = 1 << 2
    public static func timer(_ n: Int) -> UInt32 { 1 << UInt32(3 + n) }
    public static func dma(_ n: Int) -> UInt32 { 1 << UInt32(8 + n) }
    public static let keypad: UInt32 = 1 << 12
    public static let ipcSync: UInt32 = 1 << 16
    public static let ipcSendEmpty: UInt32 = 1 << 17
    public static let ipcRecvNotEmpty: UInt32 = 1 << 18
    public static let cardTransferDone: UInt32 = 1 << 19
    public static let geometryFIFO: UInt32 = 1 << 21
    public static let spi: UInt32 = 1 << 23
}

enum Event {
    static let hblank = 0
    static let lineEnd = 1
    /// Timers 0-3 of the ARM9 are 2...5, of the ARM7 6...9.
    static func timer(cpu: Int, _ n: Int) -> Int { 2 + cpu * 4 + n }
}

/// Per-CPU interrupt controller.
final class InterruptController {
    var ime: UInt32 = 0
    var ie: UInt32 = 0
    var iflags: UInt32 = 0
    weak var system: NDS?
    let cpuIndex: Int

    init(cpuIndex: Int) { self.cpuIndex = cpuIndex }

    func raise(_ bits: UInt32) {
        iflags |= bits
        system?.updateIRQLines()
    }

    var line: Bool { ime & 1 != 0 && ie & iflags != 0 }
    var wake: Bool { ie & iflags != 0 }
}

/// The Nintendo DS: two CPUs, shared memory, and the hardware between them.
public final class NDS: EmulatorCore {
    public static let descriptor = SystemDescriptor(
        id: .nds,
        screens: [
            ScreenDescriptor(role: .primary, width: 256, height: 192, acceptsTouch: false),
            ScreenDescriptor(role: .touch, width: 256, height: 192, acceptsTouch: true),
        ],
        frameRate: NDSClock.hz / Double(NDSClock.cyclesPerFrame),
        audioSampleRate: NDSClock.audioRate,
        hasAnalogStick: false, hasMotionSensors: false, hasCameras: false)

    let frames: FrameSink
    let audio: AudioRing
    let input: InputState

    // Memory
    let mainRAM = RAM(size: 4 * 1024 * 1024)
    let sharedWRAM = RAM(size: 32 * 1024)
    let arm7WRAM = RAM(size: 64 * 1024)
    let itcm = RAM(size: 32 * 1024)
    let dtcm = RAM(size: 16 * 1024)
    let palette = RAM(size: 2 * 1024)
    let oam = RAM(size: 2 * 1024)
    /// All VRAM banks back to back, as the LCDC region at 0x06800000 sees them.
    let vram = RAM(size: 1024 * 1024)

    var scheduler = Scheduler()
    var bus9: Bus9!
    var bus7: Bus7!
    var arm9: ARM<Bus9>!
    var arm7: ARM<Bus7>!

    /// Instructions executed by both CPUs since power-on, for benchmarks.
    public var instructionsRetired: UInt64 { arm9.instructionsRetired &+ arm7.instructionsRetired }

    let irq9 = InterruptController(cpuIndex: 0)
    let irq7 = InterruptController(cpuIndex: 1)
    let timers9: TimerUnit
    let timers7: TimerUnit
    let dma9: DMAUnit
    let dma7: DMAUnit
    let ipc = IPC()
    let math = MathUnit()
    let cartridge = Cartridge()
    let spi = SPIBus()

    // Display state shared by both CPUs.
    var vcount: UInt32 = 0
    var dispstat9: UInt32 = 0
    var dispstat7: UInt32 = 0
    var dispcntA: UInt32 = 0
    var dispcntB: UInt32 = 0
    var powcnt1: UInt32 = 0
    var vramcnt = [UInt8](repeating: 0, count: 10)
    var wramcnt: UInt8 = 3
    var lidClosed = false
    var frameStart: UInt64 = 0
    private var audioPhase: Double = 0

    public var batterySave: [UInt8]? {
        get { cartridge.backup.isEmpty ? nil : cartridge.backup }
        set { if let v = newValue { cartridge.backup = v } }
    }

    public init(frames: FrameSink, audio: AudioRing, input: InputState) {
        self.frames = frames
        self.audio = audio
        self.input = input
        timers9 = TimerUnit(cpuIndex: 0, irq: irq9)
        timers7 = TimerUnit(cpuIndex: 1, irq: irq7)
        dma9 = DMAUnit(cpuIndex: 0, irq: irq9)
        dma7 = DMAUnit(cpuIndex: 1, irq: irq7)
        bus9 = Bus9(system: self)
        bus7 = Bus7(system: self)
        arm9 = ARM(model: .arm946es, bus: bus9)
        arm7 = ARM(model: .arm7tdmi, bus: bus7)
        irq9.system = self
        irq7.system = self
        timers9.system = self
        timers7.system = self
        dma9.system = self
        dma7.system = self
        ipc.system = self
        cartridge.system = self
        reset()
    }

    /// Convenience for tests and tools that do not need the app's channels.
    public convenience init() {
        self.init(frames: FrameSink(screens: NDS.descriptor.screens), audio: AudioRing(frames: 4096), input: InputState())
    }

    deinit {
        [mainRAM, sharedWRAM, arm7WRAM, itcm, dtcm, palette, oam, vram].forEach { $0.free() }
    }

    // MARK: - EmulatorCore

    public func load(image bytes: [UInt8]) throws(CoreError) {
        try cartridge.load(bytes)
        reset()
        try directBoot()
    }

    public func reset() {
        [mainRAM, sharedWRAM, arm7WRAM, itcm, dtcm, palette, oam, vram].forEach { $0.clear() }
        scheduler = Scheduler()
        scheduler.schedule(Event.hblank, at: NDSClock.hblankStart)
        scheduler.schedule(Event.lineEnd, at: NDSClock.cyclesPerLine)
        vcount = 0
        frameStart = 0
        arm9.cycles = 0
        arm7.cycles = 0
        bus9.resetCP15()
        wramcnt = 3
    }

    public func setLidClosed(_ closed: Bool) { lidClosed = closed }

    /// Runs the CPUs in short interleaved slices so IPC handshakes stay in step.
    public func runFrame() {
        let target = frameStart + NDSClock.cyclesPerFrame
        let maxSlice: UInt64 = 64
        spi.touchPoint = input.touch
        while scheduler.now < target {
            let next = min(scheduler.nextEventTime, target, scheduler.now + maxSlice)
            arm9.run(until: next)
            arm7.run(until: next)
            scheduler.advance(to: next)
            while let event = scheduler.popDue() { handle(event) }
        }
        frameStart = target
        generateSilence()
    }

    // MARK: - Events

    func handle(_ event: Scheduler.Event) {
        switch event.id {
        case Event.hblank:
            dispstat9 |= 2
            dispstat7 |= 2
            if dispstat9 & (1 << 4) != 0 { irq9.raise(IRQ.hblank) }
            if dispstat7 & (1 << 4) != 0 { irq7.raise(IRQ.hblank) }
            if vcount < NDSClock.visibleLines { dma9.trigger(.hblank) }
        case Event.lineEnd:
            endLine(at: event.time)
        default:
            let id = event.id - 2
            (id < 4 ? timers9 : timers7).overflow(id & 3, at: event.time)
        }
    }

    private func endLine(at time: UInt64) {
        dispstat9 &= ~2
        dispstat7 &= ~2
        vcount += 1
        if vcount == NDSClock.linesPerFrame { vcount = 0 }

        if vcount == NDSClock.visibleLines {
            dispstat9 |= 1
            dispstat7 |= 1
            if dispstat9 & (1 << 3) != 0 { irq9.raise(IRQ.vblank) }
            if dispstat7 & (1 << 3) != 0 { irq7.raise(IRQ.vblank) }
            dma9.trigger(.vblank)
            dma7.trigger(.vblank)
            presentFrame()
        } else if vcount == NDSClock.linesPerFrame - 1 {
            dispstat9 &= ~1
            dispstat7 &= ~1
        }

        for (stat, ctrl) in [(0, irq9), (1, irq7)] {
            let value = stat == 0 ? dispstat9 : dispstat7
            let match = (value >> 8) | ((value & 0x80) << 1)
            if vcount == match {
                if stat == 0 { dispstat9 |= 4 } else { dispstat7 |= 4 }
                if value & (1 << 5) != 0 { ctrl.raise(IRQ.vcount) }
            } else {
                if stat == 0 { dispstat9 &= ~4 } else { dispstat7 &= ~4 }
            }
        }

        let lineStart = time
        scheduler.schedule(Event.hblank, at: lineStart + NDSClock.hblankStart)
        scheduler.schedule(Event.lineEnd, at: lineStart + NDSClock.cyclesPerLine)
    }

    func updateIRQLines() {
        arm9.irqLine = irq9.line
        arm9.wakeLine = irq9.wake
        arm7.irqLine = irq7.line
        arm7.wakeLine = irq7.wake
    }

    // MARK: - Video output (framebuffer modes until the 2D engines land)

    private func presentFrame() {
        let topIsA = powcnt1 & (1 << 15) != 0
        let a = frames.backBuffer(screen: topIsA ? 0 : 1)
        let b = frames.backBuffer(screen: topIsA ? 1 : 0)
        renderEngine(dispcnt: dispcntA, paletteBase: 0, into: a, isEngineA: true)
        renderEngine(dispcnt: dispcntB, paletteBase: 0x400, into: b, isEngineA: false)
        frames.publish()
    }

    private func renderEngine(dispcnt: UInt32, paletteBase: UInt32, into out: UnsafeMutablePointer<UInt32>, isEngineA: Bool) {
        let mode = (dispcnt >> 16) & 3
        if isEngineA && mode == 2 {
            // VRAM display: a whole 128 KB bank (A-D) shown as 256 × 192 RGB555.
            let bankBase = ((dispcnt >> 18) & 3) * 0x20000
            for i in 0..<(256 * 192) {
                out[i] = Self.bgra(from: vram.read16(bankBase + UInt32(i) * 2))
            }
            return
        }
        let color: UInt32 = mode == 0 ? 0xFFFF_FFFF : Self.bgra(from: palette.read16(paletteBase))
        out.update(repeating: color, count: 256 * 192)
    }

    @inline(__always) static func bgra(from rgb555: UInt16) -> UInt32 {
        let r = UInt32(rgb555 & 0x1F), g = UInt32((rgb555 >> 5) & 0x1F), b = UInt32((rgb555 >> 10) & 0x1F)
        let r8 = (r << 3) | (r >> 2), g8 = (g << 3) | (g >> 2), b8 = (b << 3) | (b >> 2)
        return 0xFF00_0000 | r8 << 16 | g8 << 8 | b8
    }

    /// Keeps audio pacing alive until the SPU is implemented.
    private func generateSilence() {
        audioPhase += NDSClock.audioRate * Double(NDSClock.cyclesPerFrame) / NDSClock.hz
        let count = Int(audioPhase)
        audioPhase -= Double(count)
        for _ in 0..<count { audio.push(left: 0, right: 0) }
    }

    // MARK: - Direct boot

    /// Loads the game the way the BIOS and firmware would, without needing either.
    func directBoot() throws(CoreError) {
        let rom = cartridge.rom
        guard rom.count >= 0x200 else { throw .unsupportedImage("ROM smaller than its header") }
        func header32(_ o: Int) -> UInt32 {
            UInt32(rom[o]) | UInt32(rom[o + 1]) << 8 | UInt32(rom[o + 2]) << 16 | UInt32(rom[o + 3]) << 24
        }
        let arm9Offset = Int(header32(0x20)), arm9Entry = header32(0x24)
        let arm9Address = header32(0x28), arm9Size = Int(header32(0x2C))
        let arm7Offset = Int(header32(0x30)), arm7Entry = header32(0x34)
        let arm7Address = header32(0x38), arm7Size = Int(header32(0x3C))
        guard arm9Offset + arm9Size <= rom.count, arm7Offset + arm7Size <= rom.count else {
            throw .unsupportedImage("binary extends past end of ROM")
        }

        for i in 0..<arm9Size { bus9.write8(arm9Address &+ UInt32(i), rom[arm9Offset + i]) }
        for i in 0..<arm7Size { bus7.write8(arm7Address &+ UInt32(i), rom[arm7Offset + i]) }

        // What the firmware leaves in main RAM: the cart header, chip IDs and user settings.
        mainRAM.copy(from: rom[0..<0x170], to: 0x027F_FE00)
        let chipID: UInt32 = 0x0000_1FC2
        for address: UInt32 in [0x027F_F800, 0x027F_F804, 0x027F_FC00, 0x027F_FC04] {
            mainRAM.write32(address, chipID)
        }
        mainRAM.write16(0x027F_F850, 0x5835)   // ARM7 BIOS CRC
        mainRAM.write16(0x027F_FC10, 0x5835)
        mainRAM.write16(0x027F_FC40, 1)        // boot indicator: normal cart boot
        Firmware.writeUserSettings(to: mainRAM, at: 0x027F_FC80)

        wramcnt = 3
        powcnt1 = 1 << 15 | 0x0F  // both engines on, engine A on top
        bus9.writeCP15DefaultsAfterBoot()
        arm9.directBoot(entry: arm9Entry, stackSVC: 0x0300_3FC0, stackIRQ: 0x0300_3F80, stackSYS: 0x0300_2F7C)
        arm7.directBoot(entry: arm7Entry, stackSVC: 0x0380_FFDC, stackIRQ: 0x0380_FFB0, stackSYS: 0x0380_FF00)
        bus9.postflg = 1
        bus7.postflg = 1
    }

    // MARK: - Snapshots

    static let snapshotTag: UInt32 = 0x4E44_5331  // "NDS1"

    public func writeSnapshot(into writer: inout SnapshotWriter) {
        writer.beginSection(Self.snapshotTag)
        for block in [mainRAM, sharedWRAM, arm7WRAM, itcm, dtcm, palette, oam, vram] { block.snapshot(into: &writer) }
        // CPU, IO and scheduler state follow in M2, when the formats settle.
        writer.endSection()
    }

    public func readSnapshot(from reader: inout SnapshotReader) throws(CoreError) {
        guard reader.system == .nds else { throw .corruptSnapshot("not a DS snapshot") }
        while let section = try reader.nextSection() {
            if section.tag == Self.snapshotTag {
                for block in [mainRAM, sharedWRAM, arm7WRAM, itcm, dtcm, palette, oam, vram] { try block.restore(from: &reader) }
            } else {
                reader.skip(section.length)
            }
        }
    }
}
