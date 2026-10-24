// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit

// MARK: - Timers

/// Four 16-bit timers per CPU. Counters are computed from the clock on read,
/// and only overflows are scheduled, so a running timer costs nothing per cycle.
final class TimerUnit {
    struct Timer {
        var reload: UInt16 = 0
        var control: UInt16 = 0
        var counter: UInt16 = 0
        var startTime: UInt64 = 0
        var running: Bool { control & 0x80 != 0 }
        var cascade: Bool { control & 0x04 != 0 }
        /// Master-clock cycles per tick: prescaler 1, 64, 256 or 1024 on the 33 MHz bus.
        var period: UInt64 { [1, 64, 256, 1024][Int(control & 3)] * 2 }
    }

    var timers = [Timer](repeating: Timer(), count: 4)
    let cpuIndex: Int
    let irq: InterruptController
    weak var system: NDS?

    init(cpuIndex: Int, irq: InterruptController) {
        self.cpuIndex = cpuIndex
        self.irq = irq
    }

    private var now: UInt64 { system?.scheduler.now ?? 0 }

    func counter(_ n: Int) -> UInt16 {
        let t = timers[n]
        guard t.running && !(t.cascade && n > 0) else { return t.counter }
        let ticks = (now &- t.startTime) / t.period
        return t.counter &+ UInt16(truncatingIfNeeded: ticks)
    }

    func writeReload(_ n: Int, _ value: UInt16) { timers[n].reload = value }

    func writeControl(_ n: Int, _ value: UInt16) {
        let wasRunning = timers[n].running
        timers[n].counter = counter(n)
        timers[n].control = value & 0xC7
        if !wasRunning && timers[n].running { timers[n].counter = timers[n].reload }
        timers[n].startTime = now
        schedule(n)
    }

    private func schedule(_ n: Int) {
        let id = Event.timer(cpu: cpuIndex, n)
        let t = timers[n]
        guard let system else { return }
        if t.running && !(t.cascade && n > 0) {
            system.scheduler.schedule(id, at: t.startTime + UInt64(0x10000 - Int(t.counter)) * t.period)
        } else {
            system.scheduler.cancel(id)
        }
    }

    func overflow(_ n: Int, at time: UInt64) {
        timers[n].counter = timers[n].reload
        timers[n].startTime = time
        if timers[n].control & 0x40 != 0 { irq.raise(IRQ.timer(n)) }
        schedule(n)
        cascadeInto(n + 1, at: time)
    }

    private func cascadeInto(_ n: Int, at time: UInt64) {
        guard n < 4, timers[n].running, timers[n].cascade else { return }
        timers[n].counter &+= 1
        if timers[n].counter == 0 {
            timers[n].counter = timers[n].reload
            if timers[n].control & 0x40 != 0 { irq.raise(IRQ.timer(n)) }
            cascadeInto(n + 1, at: time)
        }
    }
}

// MARK: - DMA

/// Four DMA channels per CPU. Transfers complete instantly when triggered.
final class DMAUnit {
    enum Trigger { case immediate, vblank, hblank, cartridge }

    struct Channel {
        var source: UInt32 = 0
        var destination: UInt32 = 0
        var control: UInt32 = 0  // word count in the low bits, control in the high half
        var internalSource: UInt32 = 0
        var internalDestination: UInt32 = 0
        var enabled: Bool { control & 0x8000_0000 != 0 }
    }

    var channels = [Channel](repeating: Channel(), count: 4)
    let cpuIndex: Int
    let irq: InterruptController
    weak var system: NDS?

    init(cpuIndex: Int, irq: InterruptController) {
        self.cpuIndex = cpuIndex
        self.irq = irq
    }

    private func trigger(of control: UInt32) -> Trigger? {
        if cpuIndex == 0 {
            switch (control >> 27) & 7 {
            case 0: return .immediate
            case 1: return .vblank
            case 2: return .hblank
            case 5: return .cartridge
            case 7: return .immediate  // geometry FIFO: commands run at once, so the FIFO always has room
            default: return nil  // display, main-memory display, GBA slot: later milestones
            }
        }
        switch (control >> 28) & 3 {
        case 0: return .immediate
        case 1: return .vblank
        case 2: return .cartridge
        default: return nil
        }
    }

    func writeControl(_ n: Int, _ value: UInt32) {
        let wasEnabled = channels[n].enabled
        channels[n].control = value
        if !wasEnabled && channels[n].enabled {
            channels[n].internalSource = channels[n].source
            channels[n].internalDestination = channels[n].destination
            switch trigger(of: value) {
            case .immediate: run(n)
            case .cartridge: system?.cartridge.pumpDMA()  // the card may already have data waiting
            default: break
            }
        }
    }

    func trigger(_ kind: Trigger) {
        for n in 0..<4 where channels[n].enabled && trigger(of: channels[n].control) == kind { run(n) }
    }

    private func run(_ n: Int) {
        guard let system else { return }
        var ch = channels[n]
        let wordSize: UInt32 = ch.control & (1 << 26) != 0 ? 4 : 2
        let countMask: UInt32 = cpuIndex == 0 ? 0x1F_FFFF : (n == 3 ? 0xFFFF : 0x3FFF)
        var count = ch.control & countMask
        if count == 0 { count = countMask + 1 }

        func step(_ mode: UInt32) -> UInt32 {
            switch mode {
            case 0, 3: return wordSize
            case 1: return 0 &- wordSize
            default: return 0
            }
        }
        let destinationStep = step((ch.control >> 21) & 3)
        let sourceStep = step((ch.control >> 23) & 3)

        for _ in 0..<count {
            if wordSize == 4 {
                let v = cpuIndex == 0 ? system.bus9.read32(ch.internalSource) : system.bus7.read32(ch.internalSource)
                if cpuIndex == 0 { system.bus9.write32(ch.internalDestination, v) } else { system.bus7.write32(ch.internalDestination, v) }
            } else {
                let v = cpuIndex == 0 ? system.bus9.read16(ch.internalSource) : system.bus7.read16(ch.internalSource)
                if cpuIndex == 0 { system.bus9.write16(ch.internalDestination, v) } else { system.bus7.write16(ch.internalDestination, v) }
            }
            ch.internalSource &+= sourceStep
            ch.internalDestination &+= destinationStep
        }

        let repeating = ch.control & (1 << 25) != 0 && trigger(of: ch.control) != .immediate
        if repeating {
            if (ch.control >> 21) & 3 == 3 { ch.internalDestination = ch.destination }
        } else {
            ch.control &= ~0x8000_0000
        }
        // A transfer may have written this channel's own registers; keep their effect.
        ch.control = (channels[n].control & ~0x8000_0000) | (ch.control & 0x8000_0000)
        channels[n].internalSource = ch.internalSource
        channels[n].internalDestination = ch.internalDestination
        channels[n].control = ch.control
        if ch.control & (1 << 30) != 0 { irq.raise(IRQ.dma(n)) }
    }
}

// MARK: - IPC

/// IPCSYNC and the two 16-word FIFOs between the CPUs.
final class IPC {
    var sync = [UInt32](repeating: 0, count: 2)       // per CPU: output nibble and IRQ enable
    var fifoControl = [UInt32](repeating: 0, count: 2)
    var fifo: [[UInt32]] = [[], []]                    // fifo[n] holds words sent by CPU n
    var lastReceived = [UInt32](repeating: 0, count: 2)
    weak var system: NDS?

    private func irq(_ cpu: Int) -> InterruptController? { cpu == 0 ? system?.irq9 : system?.irq7 }

    func readSync(cpu: Int) -> UInt32 {
        let other = 1 - cpu
        return (sync[cpu] & 0x4F00) | ((sync[other] >> 8) & 0xF)
    }

    func writeSync(cpu: Int, _ value: UInt32) {
        sync[cpu] = value & 0x4F00
        let other = 1 - cpu
        if value & (1 << 13) != 0 && sync[other] & (1 << 14) != 0 { irq(other)?.raise(IRQ.ipcSync) }
    }

    func readControl(cpu: Int) -> UInt32 {
        let other = 1 - cpu
        var v = fifoControl[cpu] & 0xC404
        if fifo[cpu].isEmpty { v |= 1 }
        if fifo[cpu].count == 16 { v |= 2 }
        if fifo[other].isEmpty { v |= 1 << 8 }
        if fifo[other].count == 16 { v |= 1 << 9 }
        return v
    }

    func writeControl(cpu: Int, _ value: UInt32) {
        let wasSendIRQ = fifoControl[cpu] & 4 != 0, wasRecvIRQ = fifoControl[cpu] & (1 << 10) != 0
        if value & 8 != 0 { fifo[cpu].removeAll() }
        if value & (1 << 14) != 0 { fifoControl[cpu] &= ~(1 << 14) }
        fifoControl[cpu] = (fifoControl[cpu] & (1 << 14)) | (value & 0x8404)
        if !wasSendIRQ && value & 4 != 0 && fifo[cpu].isEmpty { irq(cpu)?.raise(IRQ.ipcSendEmpty) }
        if !wasRecvIRQ && value & (1 << 10) != 0 && !fifo[1 - cpu].isEmpty { irq(cpu)?.raise(IRQ.ipcRecvNotEmpty) }
    }

    func send(cpu: Int, _ value: UInt32) {
        guard fifoControl[cpu] & 0x8000 != 0 else { return }
        if fifo[cpu].count == 16 { fifoControl[cpu] |= 1 << 14; return }
        let wasEmpty = fifo[cpu].isEmpty
        fifo[cpu].append(value)
        let other = 1 - cpu
        if wasEmpty && fifoControl[other] & (1 << 10) != 0 { irq(other)?.raise(IRQ.ipcRecvNotEmpty) }
    }

    func receive(cpu: Int) -> UInt32 {
        let other = 1 - cpu
        guard fifoControl[cpu] & 0x8000 != 0 else { return fifo[other].first ?? lastReceived[cpu] }
        if fifo[other].isEmpty { fifoControl[cpu] |= 1 << 14; return lastReceived[cpu] }
        lastReceived[cpu] = fifo[other].removeFirst()
        if fifo[other].isEmpty && fifoControl[other] & 4 != 0 { irq(other)?.raise(IRQ.ipcSendEmpty) }
        return lastReceived[cpu]
    }
}

// MARK: - Math unit (ARM9)

/// Hardware divider and square root. Results are ready immediately.
final class MathUnit {
    var divControl: UInt32 = 0
    var numerator: UInt64 = 0
    var denominator: UInt64 = 0
    var quotient: UInt64 = 0
    var remainder: UInt64 = 0
    var sqrtControl: UInt32 = 0
    var sqrtParameter: UInt64 = 0
    var sqrtResult: UInt32 = 0

    func divide() {
        let mode = divControl & 3
        var num = Int64(bitPattern: numerator), den = Int64(bitPattern: denominator)
        if mode == 0 {
            num = Int64(Int32(truncatingIfNeeded: num))
            den = Int64(Int32(truncatingIfNeeded: den))
        } else if mode == 1 {
            den = Int64(Int32(truncatingIfNeeded: den))
        }
        divControl = (divControl & ~0x4000) | (den == 0 ? 0x4000 : 0)
        if den == 0 {
            // Hardware result for division by zero.
            quotient = num < 0 ? 1 : UInt64.max
            if mode == 0 { quotient ^= 0xFFFF_FFFF_0000_0000 }
            remainder = UInt64(bitPattern: num)
            return
        }
        if num == .min && den == -1 {
            quotient = UInt64(bitPattern: num)
            remainder = 0
            return
        }
        quotient = UInt64(bitPattern: num / den)
        remainder = UInt64(bitPattern: num % den)
    }

    func squareRoot() {
        let value = sqrtControl & 1 != 0 ? sqrtParameter : sqrtParameter & 0xFFFF_FFFF
        // Floating-point estimate, then corrected to the exact integer root.
        // Comparisons divide instead of squaring so they cannot overflow.
        if value == 0 { sqrtResult = 0; return }
        var x = min(UInt64(Double(value).squareRoot()), 0xFFFF_FFFF)
        while x > value / x { x -= 1 }
        while x < 0xFFFF_FFFF && x + 1 <= value / (x + 1) { x += 1 }
        sqrtResult = UInt32(truncatingIfNeeded: x)
    }
}
