// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit
import Metal
import QuartzCore
import SwiftUI
import UIKit

/// Draws one console screen into a CAMetalLayer at integer or sharp-bilinear scale.
/// SwiftUI decides where the screen goes; this view only fills its bounds.
struct MetalScreen: UIViewRepresentable {
    let presenter: Presenter
    let screenIndex: Int
    var onTouch: ((CGPoint?) -> Void)?

    func makeUIView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.onTouch = onTouch
        presenter.attach(view.metalLayer, screen: screenIndex)
        return view
    }

    func updateUIView(_ view: ScreenView, context: Context) { view.onTouch = onTouch }

    final class ScreenView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
        var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
        var onTouch: ((CGPoint?) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            metalLayer.contentsScale = window?.screen.scale ?? 3
            metalLayer.drawableSize = CGSize(width: bounds.width * metalLayer.contentsScale,
                                             height: bounds.height * metalLayer.contentsScale)
        }

        /// Reports touches as a fraction of the screen (0...1), or nil on release.
        private func report(_ touches: Set<UITouch>) {
            guard let t = touches.first, bounds.width > 0, bounds.height > 0 else { return }
            let p = t.location(in: self)
            onTouch?(CGPoint(x: min(max(p.x / bounds.width, 0), 1), y: min(max(p.y / bounds.height, 0), 1)))
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { onTouch?(nil) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { onTouch?(nil) }
    }
}

/// Owns the Metal device and pipeline, and redraws every attached screen each
/// display refresh from the newest frame the core published.
final class Presenter {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let frames: FrameSink
    private var layers: [Int: CAMetalLayer] = [:]
    private var textures: [MTLTexture] = []
    private var displayLink: CADisplayLink?

    init?(frames: FrameSink) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "screenFragmentSharpBilinear")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.sampler = sampler
        self.frames = frames
        textures = frames.screens.compactMap { s in
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: s.width, height: s.height, mipmapped: false)
            d.usage = .shaderRead
            return device.makeTexture(descriptor: d)
        }
    }

    func attach(_ layer: CAMetalLayer, screen: Int) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layers[screen] = layer
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // The DS runs at 59.83 Hz; ask ProMotion for 60, not 120.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        if let pixels = frames.acquireNewest() {
            for (i, screen) in frames.screens.enumerated() where i < textures.count {
                textures[i].replace(region: MTLRegionMake2D(0, 0, screen.width, screen.height), mipmapLevel: 0,
                                    withBytes: pixels[i], bytesPerRow: screen.width * 4)
            }
        }
        guard let commands = queue.makeCommandBuffer() else { return }
        for (index, layer) in layers {
            guard index < textures.count, let drawable = layer.nextDrawable() else { continue }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { continue }
            var sizes = SIMD4<Float>(Float(textures[index].width), Float(textures[index].height),
                                     Float(drawable.texture.width), Float(drawable.texture.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(textures[index], index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&sizes, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            commands.present(drawable)
        }
        commands.commit()
    }
}
