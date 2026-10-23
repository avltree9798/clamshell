// SPDX-License-Identifier: GPL-3.0-or-later

/// Which console a core emulates. Stored in every save state.
public enum SystemID: UInt32, Sendable, Codable {
    case nds = 0x4E44_5300  // "NDS\0"
    case ctr = 0x4354_5200  // "CTR\0"
}

/// What a screen is for, so layouts never depend on one console's dimensions.
public enum ScreenRole: Sendable, Hashable {
    case primary      // DS / 3DS top screen
    case touch        // DS / 3DS bottom screen
}

public struct ScreenDescriptor: Sendable, Hashable {
    public var role: ScreenRole
    public var width: Int
    public var height: Int
    public var acceptsTouch: Bool

    public init(role: ScreenRole, width: Int, height: Int, acceptsTouch: Bool) {
        self.role = role
        self.width = width
        self.height = height
        self.acceptsTouch = acceptsTouch
    }
}

/// Static facts the app needs before it starts a core.
public struct SystemDescriptor: Sendable {
    public var id: SystemID
    public var screens: [ScreenDescriptor]
    /// Video frames per second, e.g. 59.8261 for the DS.
    public var frameRate: Double
    /// Native audio output rate in Hz.
    public var audioSampleRate: Double
    public var hasAnalogStick: Bool
    public var hasMotionSensors: Bool
    public var hasCameras: Bool

    public init(
        id: SystemID, screens: [ScreenDescriptor], frameRate: Double, audioSampleRate: Double,
        hasAnalogStick: Bool, hasMotionSensors: Bool, hasCameras: Bool
    ) {
        self.id = id
        self.screens = screens
        self.frameRate = frameRate
        self.audioSampleRate = audioSampleRate
        self.hasAnalogStick = hasAnalogStick
        self.hasMotionSensors = hasMotionSensors
        self.hasCameras = hasCameras
    }
}

public enum CoreError: Error, Sendable {
    case unsupportedImage(String)
    case missingFile(String)
    case corruptSnapshot(String)
}

/// The contract every console core implements.
///
/// A core is owned by exactly one emulation thread and is never shared, so it is
/// not `Sendable`. The app talks to it only through the channels it is handed at
/// creation: `FrameSink`, `AudioRing` and `InputState`.
public protocol EmulatorCore: AnyObject {
    static var descriptor: SystemDescriptor { get }

    init(frames: FrameSink, audio: AudioRing, input: InputState)

    /// Loads a game image. `bytes` is the whole file, already read by the app.
    func load(image bytes: [UInt8]) throws(CoreError)

    func reset()

    /// Emulates exactly one video frame, then publishes it to the `FrameSink`.
    func runFrame()

    /// Battery-backed save memory, if the game has any.
    var batterySave: [UInt8]? { get set }

    func writeSnapshot(into writer: inout SnapshotWriter)
    func readSnapshot(from reader: inout SnapshotReader) throws(CoreError)

    /// Sets the console's lid switch. On iPhone Duo this follows the hinge.
    func setLidClosed(_ closed: Bool)

    /// A few lines of internal state for the on-screen diagnostics readout.
    var diagnostics: String { get }
}

public extension EmulatorCore {
    var diagnostics: String { "" }
}
