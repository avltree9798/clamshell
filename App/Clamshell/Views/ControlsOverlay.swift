// SPDX-License-Identifier: GPL-3.0-or-later

import EmuKit
import SwiftUI
import UIKit

/// On-screen D-pad, face buttons, shoulders, Start and Select, each in the rect the
/// layout gives it. Skins (JSON button maps) replace this in M3.
struct ControlsOverlay: View {
    let layout: LayoutResult
    let input: InputState

    var body: some View {
        ZStack(alignment: .topLeading) {
            DPad(input: input).place(square(layout.dpad))
            FaceButtons(input: input).place(square(layout.faceButtons))
            HoldButton(label: "L", button: .l, input: input, shape: .capsule).place(layout.shoulderLeft)
            HoldButton(label: "R", button: .r, input: input, shape: .capsule).place(layout.shoulderRight)
            HStack(spacing: 10) {
                HoldButton(label: "SELECT", button: .select, input: input, shape: .capsule)
                HoldButton(label: "START", button: .start, input: input, shape: .capsule)
            }
            .frame(maxWidth: 170)
            .place(layout.startSelect)
        }
    }

    /// The largest square centred in `r`.
    private func square(_ r: CGRect) -> CGRect {
        let side = min(r.width, r.height)
        return CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
    }
}

extension View {
    /// Sizes and positions a view at `rect` inside a top-leading ZStack; hidden when empty.
    @ViewBuilder func place(_ rect: CGRect) -> some View {
        if rect.width > 0 && rect.height > 0 {
            frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
        }
    }
}

private let controlFill = Color.white.opacity(0.14)
private let controlPressed = Color.white.opacity(0.38)
private let controlStroke = Color.white.opacity(0.22)
private let controlLabel = Color.white.opacity(0.85)

/// A button that stays pressed while touched, with a light haptic on press.
struct HoldButton: View {
    enum Shape { case circle, capsule }

    let label: String
    let button: Buttons
    let input: InputState
    var shape: Shape = .circle
    var tint: Color = .white
    @State private var pressed = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                switch shape {
                case .circle:
                    Circle().fill(pressed ? controlPressed : controlFill)
                    Circle().strokeBorder(tint.opacity(0.55), lineWidth: 1.5)
                case .capsule:
                    Capsule().fill(pressed ? controlPressed : controlFill)
                    Capsule().strokeBorder(controlStroke, lineWidth: 1)
                }
                Text(label)
                    .font(.system(size: shape == .circle ? side * 0.38 : min(side * 0.42, 15), weight: .semibold, design: .rounded))
                    .foregroundStyle(controlLabel)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.06), value: pressed)
            .contentShape(Rectangle())
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
}

/// Eight-way D-pad: the touch's direction from the centre picks the buttons.
struct DPad: View {
    let input: InputState
    @State private var active: Buttons = []

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let arm = size / 3
            ZStack {
                DPadShape(arm: arm).fill(controlFill)
                DPadShape(arm: arm).stroke(controlStroke, lineWidth: 1)
                // Light up the pressed arms.
                ForEach(0..<Self.arms.count, id: \.self) { i in
                    let (name, button, offset) = Self.arms[i]
                    RoundedRectangle(cornerRadius: arm * 0.18)
                        .fill(active.contains(button) ? controlPressed : .clear)
                        .frame(width: arm, height: arm)
                        .offset(x: offset.x * arm, y: offset.y * arm)
                    Image(systemName: "arrowtriangle.\(name).fill")
                        .font(.system(size: arm * 0.3))
                        .foregroundStyle(controlLabel.opacity(0.7))
                        .offset(x: offset.x * arm, y: offset.y * arm)
                }
                Circle().fill(Color.white.opacity(0.06)).frame(width: arm * 0.6)
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dx = value.location.x - size / 2, dy = value.location.y - size / 2
                    let dead = size * 0.1
                    var b: Buttons = []
                    // Diagonals inside a 22.5° band either side of each axis count as straight.
                    if abs(dx) > dead || abs(dy) > dead {
                        if dx < -dead && abs(dx) > abs(dy) * 0.41 { b.insert(.left) }
                        if dx > dead && abs(dx) > abs(dy) * 0.41 { b.insert(.right) }
                        if dy < -dead && abs(dy) > abs(dx) * 0.41 { b.insert(.up) }
                        if dy > dead && abs(dy) > abs(dx) * 0.41 { b.insert(.down) }
                    }
                    update(b)
                }
                .onEnded { _ in update([]) })
        }
    }

    private static let arms: [(String, Buttons, CGPoint)] = [
        ("up", .up, CGPoint(x: 0, y: -1)), ("down", .down, CGPoint(x: 0, y: 1)),
        ("left", .left, CGPoint(x: -1, y: 0)), ("right", .right, CGPoint(x: 1, y: 0)),
    ]

    private func update(_ b: Buttons) {
        guard b != active else { return }
        input.release(active.subtracting(b))
        input.press(b.subtracting(active))
        if !b.subtracting(active).isEmpty { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        active = b
    }
}

/// A plus sign with rounded ends, `arm` wide.
struct DPadShape: Shape {
    let arm: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = arm * 0.18
        var path = Path()
        path.addRoundedRect(in: CGRect(x: rect.midX - arm / 2, y: rect.minY, width: arm, height: rect.height),
                            cornerSize: CGSize(width: r, height: r))
        path.addRoundedRect(in: CGRect(x: rect.minX, y: rect.midY - arm / 2, width: rect.width, height: arm),
                            cornerSize: CGSize(width: r, height: r))
        return path.normalized()
    }
}

/// A, B, X and Y in the DS diamond.
struct FaceButtons: View {
    let input: InputState

    var body: some View {
        GeometryReader { proxy in
            let d = min(proxy.size.width, proxy.size.height) / 3
            let button = d * 0.92
            ZStack {
                HoldButton(label: "X", button: .x, input: input, tint: .blue).frame(width: button, height: button).position(x: d * 1.5, y: d * 0.5)
                HoldButton(label: "Y", button: .y, input: input, tint: .green).frame(width: button, height: button).position(x: d * 0.5, y: d * 1.5)
                HoldButton(label: "A", button: .a, input: input, tint: .red).frame(width: button, height: button).position(x: d * 2.5, y: d * 1.5)
                HoldButton(label: "B", button: .b, input: input, tint: .yellow).frame(width: button, height: button).position(x: d * 1.5, y: d * 2.5)
            }
        }
    }
}
