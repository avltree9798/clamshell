// SPDX-License-Identifier: GPL-3.0-or-later

/// Event scheduler on a single 64-bit master clock.
///
/// Subsystems (timers, DMA, display, audio) register events at absolute
/// timestamps. The CPU runs until `nextEventTime`, then the core calls
/// `runDue` to fire everything that has come due. Events are few (under 32),
/// so a small sorted array beats a heap.
public struct Scheduler: ~Copyable {
    public struct Event {
        public var time: UInt64
        public var id: Int
    }

    public private(set) var now: UInt64 = 0
    private var events: [Event] = []

    public init() { events.reserveCapacity(32) }

    @inline(__always)
    public var nextEventTime: UInt64 { events.first?.time ?? .max }

    public mutating func advance(to time: UInt64) { now = time }
    public mutating func advance(by cycles: UInt64) { now &+= cycles }

    /// Schedules `id` at `time`, replacing any pending event with the same id.
    public mutating func schedule(_ id: Int, at time: UInt64) {
        cancel(id)
        var i = events.count
        while i > 0 && events[i - 1].time > time { i -= 1 }
        events.insert(Event(time: time, id: id), at: i)
    }

    public mutating func schedule(_ id: Int, in cycles: UInt64) {
        schedule(id, at: now &+ cycles)
    }

    public mutating func cancel(_ id: Int) {
        if let i = events.firstIndex(where: { $0.id == id }) { events.remove(at: i) }
    }

    public func isScheduled(_ id: Int) -> Bool { events.contains { $0.id == id } }

    /// Removes and returns the earliest due event, or nil if none are due.
    public mutating func popDue() -> Event? {
        guard let first = events.first, first.time <= now else { return nil }
        return events.removeFirst()
    }

    public func pending() -> [Event] { events }

    public mutating func restore(now: UInt64, events: [Event]) {
        self.now = now
        self.events = events.sorted { $0.time < $1.time }
    }
}
