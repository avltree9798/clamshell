// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import EmuKit

/// Plays the core's audio ring through AVAudioEngine.
///
/// The source node runs at the console's native rate and AVAudioEngine
/// resamples to the device's rate, so the core never deals with 48 kHz.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?

    init(ring: AudioRing, sampleRate: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        // Only the audio render thread touches this buffer.
        nonisolated(unsafe) let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: 8192 * 2)
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let frames = min(Int(frameCount), 8192)
            _ = ring.pull(into: scratch, frames: frames)
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            for i in 0..<frames {
                left[i] = Float(scratch[i * 2]) / 32768
                right[i] = Float(scratch[i * 2 + 1]) / 32768
            }
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        try? engine.start()
    }

    func stop() { engine.stop() }
}
