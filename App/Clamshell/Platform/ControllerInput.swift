// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit
import GameController

/// Maps any connected game controller to DS buttons.
/// Uses physical positions: the right face button is A, the bottom is B, as on a DS.
@MainActor
final class ControllerInput {
    private let input: InputState
    private var observers: [NSObjectProtocol] = []

    init(input: InputState) {
        self.input = input
        GCController.controllers().forEach(attach)
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.attach(controller) }
        })
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let input = self.input
        pad.valueChangedHandler = { pad, _ in
            var b: Buttons = []
            if pad.buttonB.isPressed { b.insert(.a) }       // right face button
            if pad.buttonA.isPressed { b.insert(.b) }       // bottom face button
            if pad.buttonY.isPressed { b.insert(.x) }       // top face button
            if pad.buttonX.isPressed { b.insert(.y) }       // left face button
            if pad.leftShoulder.isPressed { b.insert(.l) }
            if pad.rightShoulder.isPressed { b.insert(.r) }
            if pad.buttonMenu.isPressed { b.insert(.start) }
            if pad.buttonOptions?.isPressed == true { b.insert(.select) }
            let stick = pad.leftThumbstick
            if pad.dpad.up.isPressed || stick.yAxis.value > 0.5 { b.insert(.up) }
            if pad.dpad.down.isPressed || stick.yAxis.value < -0.5 { b.insert(.down) }
            if pad.dpad.left.isPressed || stick.xAxis.value < -0.5 { b.insert(.left) }
            if pad.dpad.right.isPressed || stick.xAxis.value > 0.5 { b.insert(.right) }
            input.set(b)
        }
    }
}
