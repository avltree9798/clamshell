// SPDX-License-Identifier: GPL-3.0-or-later

import CTRCore
import EmuKit
import Foundation
import NDSCore
import Synchronization

/// Runs one game on a dedicated emulation thread.
///
/// The core is created on that thread and never leaves it. The UI talks to it
/// through `input`, reads pictures from `frames`, and the audio callback drains
/// `audio`. Pacing is audio-driven: the thread runs a frame whenever the audio
/// ring drops below half full, so sound never starves and video follows it.
final class EmulationSession: Sendable {
    /// The core for a file: .3dsx homebrew runs on the 3DS core, everything else on the DS core.
    static func system(for url: URL) -> SystemID {
        url.pathExtension.lowercased() == "3dsx" ? .ctr : .nds
    }

    static func coreType(for url: URL) -> any EmulatorCore.Type {
        system(for: url) == .ctr ? CTR.self : NDS.self
    }

    let system: SystemID
    var coreType: any EmulatorCore.Type { system == .ctr ? CTR.self : NDS.self }
    let frames: FrameSink
    let audio = AudioRing(frames: 4096)
    let input = InputState()

    private let romURL: URL
    private let saveURL: URL
    private let paused = Atomic<Bool>(false)
    private let stopped = Atomic<Bool>(false)
    private let lidClosed = Atomic<Bool>(false)
    private let fastForward = Atomic<Bool>(false)
    private let saveRequested = Atomic<Bool>(false)
    private let lastError = Mutex<String?>(nil)
    private let diagnosticsText = Mutex<String>("")
    private let reportRequest = Mutex<(@Sendable (String) -> Void)?>(nil)
    private let reportDelivered = Mutex<Date?>(nil)

    init(romURL: URL, saveURL: URL) {
        self.romURL = romURL
        self.saveURL = saveURL
        system = Self.system(for: romURL)
        frames = FrameSink(screens: Self.coreType(for: romURL).descriptor.screens)
    }

    var errorMessage: String? { lastError.withLock { $0 } }
    /// The core's state and the measured frame rate, refreshed twice a second.
    var diagnostics: String {
        let text = diagnosticsText.withLock { $0 }
        let delivered = reportDelivered.withLock { $0 }
        guard let delivered, Date().timeIntervalSince(delivered) < 4 else { return text }
        return text + "\nDebug report copied"
    }

    /// Builds a debug report after the next frame and hands it to `completion` on the
    /// emulation thread.
    func requestDebugReport(_ completion: @escaping @Sendable (String) -> Void) {
        reportRequest.withLock { $0 = completion }
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "Clamshell emulation"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { stopped.store(true, ordering: .relaxed) }
    func setPaused(_ value: Bool) { paused.store(value, ordering: .relaxed) }
    func setLidClosed(_ value: Bool) { lidClosed.store(value, ordering: .relaxed) }
    func setFastForward(_ value: Bool) { fastForward.store(value, ordering: .relaxed) }
    /// Writes the battery save at the next frame boundary (backgrounding, fold close).
    func flushSave() { saveRequested.store(true, ordering: .relaxed) }

    private func run() {
        let core = coreType.init(frames: frames, audio: audio, input: input)
        do {
            let rom = try Data(contentsOf: romURL)
            try core.load(image: [UInt8](rom))
            if let save = try? Data(contentsOf: saveURL) { core.batterySave = [UInt8](save) }
        } catch {
            lastError.withLock { $0 = "\(error)" }
            return
        }

        let frameDuration = 1 / coreType.descriptor.frameRate
        var lastSaved = core.batterySave
        var framesSinceReport = 0
        var reportStart = Date()
        while !stopped.load(ordering: .relaxed) {
            core.setLidClosed(lidClosed.load(ordering: .relaxed))
            // A closed lid keeps running: the game sees the hinge bit and sleeps itself.
            if paused.load(ordering: .relaxed) {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if !fastForward.load(ordering: .relaxed) && audio.fillRatio > 0.5 {
                Thread.sleep(forTimeInterval: frameDuration / 4)
                continue
            }
            core.runFrame()
            if let completion = reportRequest.withLock({ request -> (@Sendable (String) -> Void)? in
                let pending = request
                request = nil
                return pending
            }) {
                completion(core.debugReport)
                reportDelivered.withLock { $0 = Date() }
            }
            framesSinceReport += 1
            let elapsed = Date().timeIntervalSince(reportStart)
            if elapsed >= 0.5 {
                let fps = Double(framesSinceReport) / elapsed
                let text = String(format: "%.1f fps\n", fps) + core.diagnostics
                diagnosticsText.withLock { $0 = text }
                framesSinceReport = 0
                reportStart = Date()
            }

            if saveRequested.exchange(false, ordering: .relaxed), let save = core.batterySave, save != lastSaved {
                writeSave(save)
                lastSaved = save
            }
        }
        if let save = core.batterySave, save != lastSaved { writeSave(save) }
    }

    /// Writes to a temporary file and renames it, so a crash never leaves half a save.
    private func writeSave(_ bytes: [UInt8]) {
        let temporary = saveURL.appendingPathExtension("tmp")
        do {
            try Data(bytes).write(to: temporary)
            if FileManager.default.fileExists(atPath: saveURL.path) {
                _ = try FileManager.default.replaceItemAt(saveURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: saveURL)
            }
        } catch {
            lastError.withLock { $0 = "Could not write save: \(error.localizedDescription)" }
        }
    }
}
