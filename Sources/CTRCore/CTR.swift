// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit

/// Nintendo 3DS core. Empty until milestone M6.
///
/// It exists from day one so CI proves the app builds with two cores and the
/// `EmulatorCore` contract keeps fitting a second system: two screens of
/// different sizes, an analog stick, motion sensors and cameras.
public final class CTR: EmulatorCore {
    public static let descriptor = SystemDescriptor(
        id: .ctr,
        screens: [
            ScreenDescriptor(role: .primary, width: 400, height: 240, acceptsTouch: false),
            ScreenDescriptor(role: .touch, width: 320, height: 240, acceptsTouch: true),
        ],
        frameRate: 59.8261,
        audioSampleRate: 32_728,
        hasAnalogStick: true, hasMotionSensors: true, hasCameras: true)

    private let frames: FrameSink

    public init(frames: FrameSink, audio: AudioRing, input: InputState) {
        self.frames = frames
    }

    public func load(image bytes: [UInt8]) throws(CoreError) {
        throw .unsupportedImage("3DS emulation is not available yet")
    }

    public func reset() {}
    public func runFrame() { frames.publish() }
    public var batterySave: [UInt8]? { get { nil } set {} }
    public func writeSnapshot(into writer: inout SnapshotWriter) {}
    public func readSnapshot(from reader: inout SnapshotReader) throws(CoreError) {}
    public func setLidClosed(_ closed: Bool) {}
}
