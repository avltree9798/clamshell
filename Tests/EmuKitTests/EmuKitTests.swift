// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import EmuKit

@Suite struct SnapshotFormatTests {
    @Test func roundTrip() throws {
        var w = SnapshotWriter(system: .nds)
        w.beginSection(0xAAAA_0001)
        w.put(UInt32(0xDEAD_BEEF))
        w.put(true)
        w.endSection()
        w.beginSection(0xBBBB_0002)  // a section this reader does not know
        w.put(UInt64(7))
        w.endSection()

        var r = try SnapshotReader(bytes: w.bytes)
        #expect(r.system == .nds)
        let firstSection = try r.nextSection()
        let first = try #require(firstSection)
        #expect(first.tag == 0xAAAA_0001)
        let word: UInt32 = try r.get()
        let flag: Bool = try r.get()
        #expect(word == 0xDEAD_BEEF)
        #expect(flag)
        let secondSection = try r.nextSection()
        let second = try #require(secondSection)
        r.skip(second.length)
        let end = try r.nextSection()
        #expect(end == nil)
    }

    @Test func rejectsGarbage() {
        #expect(throws: CoreError.self) { _ = try SnapshotReader(bytes: [1, 2, 3]) }
    }
}

@Suite struct AudioRingTests {
    @Test func pushPullAndUnderrun() {
        let ring = AudioRing(frames: 8)
        ring.push(left: 1, right: 2)
        ring.push(left: 3, right: 4)
        var out = [Int16](repeating: -1, count: 6)
        let got = out.withUnsafeMutableBufferPointer { ring.pull(into: $0.baseAddress!, frames: 3) }
        #expect(got == 2)
        #expect(out == [1, 2, 3, 4, 0, 0])
    }
}

@Suite struct SchedulerTests {
    @Test func firesInOrder() {
        var s = Scheduler()
        s.schedule(2, at: 30)
        s.schedule(1, at: 10)
        s.schedule(3, at: 20)
        #expect(s.nextEventTime == 10)
        s.advance(to: 25)
        #expect(s.popDue()?.id == 1)
        #expect(s.popDue()?.id == 3)
        #expect(s.popDue() == nil)
    }

    @Test func rescheduleReplaces() {
        var s = Scheduler()
        s.schedule(1, at: 10)
        s.schedule(1, at: 50)
        #expect(s.pending().count == 1)
        #expect(s.nextEventTime == 50)
    }
}

@Suite struct FrameSinkTests {
    @Test func newestFrameWins() {
        let sink = FrameSink(screens: [ScreenDescriptor(role: .primary, width: 2, height: 1, acceptsTouch: false)])
        sink.backBuffer(screen: 0)[0] = 1
        sink.publish()
        sink.backBuffer(screen: 0)[0] = 2
        sink.publish()
        let frame = sink.acquireNewest()
        #expect(frame?[0][0] == 2)
        #expect(sink.acquireNewest() == nil)
    }
}
