// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit
import GameController
import NDSCore
import SwiftUI

/// Plays one game: two Metal screens placed by `LayoutResolver`, with
/// on-screen controls unless a controller is connected.
struct GameView: View {
    let game: GameLibrary.Game

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var runtime: Runtime?
    @State private var hinge: HingeState = .none
    @State private var fold: CGRect?
    @State private var controllerConnected = GCController.controllers().isEmpty == false

    /// Session, presenter and audio for the lifetime of this view.
    @MainActor final class Runtime {
        let session: EmulationSession
        let presenter: Presenter?
        let audio: AudioOutput
        let controllers: ControllerInput

        init(game: GameLibrary.Game) {
            session = EmulationSession(romURL: game.url, saveURL: game.saveURL)
            presenter = Presenter(frames: session.frames)
            audio = AudioOutput(ring: session.audio, sampleRate: session.coreType.descriptor.audioSampleRate)
            controllers = ControllerInput(input: session.input)
        }

        func start() {
            session.start()
            presenter?.start()
            audio.start()
        }

        func stop() {
            session.stop()
            presenter?.stop()
            audio.stop()
        }
    }

    /// Native size of screen 0 (top) or 1 (bottom) for this game's console.
    private func screenSize(_ index: Int) -> CGSize {
        let screens = EmulationSession.coreType(for: game.url).descriptor.screens
        return CGSize(width: screens[index].width, height: screens[index].height)
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = LayoutResolver.resolve(LayoutInput(
                size: proxy.size, hinge: hinge, fold: fold, controllerConnected: controllerConnected,
                topScreenSize: screenSize(0), bottomScreenSize: screenSize(1)))
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                if let runtime, let presenter = runtime.presenter {
                    ScreenFrame(rect: layout.topScreen)
                    ScreenFrame(rect: layout.bottomScreen)
                    MetalScreen(presenter: presenter, screenIndex: 0)
                        .frame(width: layout.topScreen.width, height: layout.topScreen.height)
                        .offset(x: layout.topScreen.minX, y: layout.topScreen.minY)
                    MetalScreen(presenter: presenter, screenIndex: 1) { point in
                        if let point {
                            let touch = screenSize(1)
                            runtime.session.input.setTouch(x: Int(point.x * (touch.width - 1)), y: Int(point.y * (touch.height - 1)))
                        } else {
                            runtime.session.input.clearTouch()
                        }
                    }
                    .frame(width: layout.bottomScreen.width, height: layout.bottomScreen.height)
                    .offset(x: layout.bottomScreen.minX, y: layout.bottomScreen.minY)

                    if !controllerConnected {
                        ControlsOverlay(layout: layout, input: runtime.session.input)
                    }
                }
                Button("Close", systemImage: "xmark.circle.fill") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .readPosture(hinge: $hinge, fold: $fold)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            let r = Runtime(game: game)
            runtime = r
            r.start()
        }
        .onDisappear { runtime?.stop() }
        .onChange(of: hinge) { _, newValue in
            // The DS lid follows the hinge.
            runtime?.session.setLidClosed(newValue == .closed)
            if newValue == .closed { runtime?.session.flushSave() }
        }
        .onChange(of: scenePhase) { _, phase in
            runtime?.session.setPaused(phase != .active)
            if phase != .active { runtime?.session.flushSave() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in controllerConnected = true }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            controllerConnected = !GCController.controllers().isEmpty
        }
    }
}

/// A faint outline just outside a screen, so a dark game screen does not vanish into the background.
private struct ScreenFrame: View {
    let rect: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            .frame(width: rect.width + 6, height: rect.height + 6)
            .offset(x: rect.minX - 3, y: rect.minY - 3)
            .allowsHitTesting(false)
    }
}
