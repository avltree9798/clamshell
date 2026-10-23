// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit
import SwiftUI
import UIKit

/// On-screen D-pad, face buttons, shoulders, Start and Select, placed in the
/// areas the layout leaves free. Skins (JSON button maps) replace this in M3.
struct ControlsOverlay: View {
    let layout: LayoutResult
    let input: InputState

    var body: some View {
        ZStack(alignment: .topLeading) {
            DPad(input: input)
                .frame(width: side(layout.leftControls), height: side(layout.leftControls))
                .position(x: layout.leftControls.midX, y: layout.leftControls.midY)
            FaceButtons(input: input)
                .frame(width: side(layout.rightControls), height: side(layout.rightControls))
                .position(x: layout.rightControls.midX, y: layout.rightControls.midY)
            HoldButton(label: "L", button: .l, input: input)
                .frame(width: layout.shoulderLeft.width, height: layout.shoulderLeft.height)
                .position(x: layout.shoulderLeft.midX, y: layout.shoulderLeft.midY)
            HoldButton(label: "R", button: .r, input: input)
                .frame(width: layout.shoulderRight.width, height: layout.shoulderRight.height)
                .position(x: layout.shoulderRight.midX, y: layout.shoulderRight.midY)
            HStack(spacing: 12) {
                HoldButton(label: "Select", button: .select, input: input)
                HoldButton(label: "Start", button: .start, input: input)
            }
            .frame(width: 150, height: 28)
            .position(x: layout.rightControls.midX, y: layout.rightControls.maxY - 18)
        }
    }

    private func side(_ r: CGRect) -> CGFloat { max(min(r.width, r.height) * 0.85, 0) }
}

/// A button that stays pressed while touched, with a light haptic on press.
struct HoldButton: View {
    let label: String
    let button: Buttons
    let input: InputState
    @State private var pressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.white.opacity(pressed ? 0.35 : 0.15))
            .overlay(Text(label).font(.caption.bold()).foregroundStyle(.white.opacity(0.8)))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        input.press(button)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
                .onEnded { _ in
                    pressed = false
                    input.release(button)
                })
    }
}

/// Eight-way D-pad: the touch's direction from the centre picks the buttons.
struct DPad: View {
    let input: InputState
    @State private var active: Buttons = []

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Rectangle().fill(.white.opacity(0.15)).frame(width: size.width / 3, height: size.height)
                Rectangle().fill(.white.opacity(0.15)).frame(width: size.width, height: size.height / 3)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dx = value.location.x - size.width / 2, dy = value.location.y - size.height / 2
                    let dead = size.width * 0.12
                    var b: Buttons = []
                    if dx < -dead { b.insert(.left) } else if dx > dead { b.insert(.right) }
                    if dy < -dead { b.insert(.up) } else if dy > dead { b.insert(.down) }
                    update(b)
                }
                .onEnded { _ in update([]) })
        }
    }

    private func update(_ b: Buttons) {
        guard b != active else { return }
        input.release(active.subtracting(b))
        input.press(b.subtracting(active))
        if !b.subtracting(active).isEmpty { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        active = b
    }
}

/// A, B, X and Y in the DS diamond.
struct FaceButtons: View {
    let input: InputState

    var body: some View {
        GeometryReader { proxy in
            let d = min(proxy.size.width, proxy.size.height) / 3
            ZStack {
                HoldButton(label: "X", button: .x, input: input).frame(width: d, height: d).position(x: d * 1.5, y: d * 0.5)
                HoldButton(label: "Y", button: .y, input: input).frame(width: d, height: d).position(x: d * 0.5, y: d * 1.5)
                HoldButton(label: "A", button: .a, input: input).frame(width: d, height: d).position(x: d * 2.5, y: d * 1.5)
                HoldButton(label: "B", button: .b, input: input).frame(width: d, height: d).position(x: d * 1.5, y: d * 2.5)
            }
        }
    }
}
