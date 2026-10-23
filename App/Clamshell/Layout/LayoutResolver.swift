// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// The device posture, as far as the layout cares.
enum HingeState: Equatable, Sendable {
    case none                // not a foldable, or the hinge API is unavailable
    case closed
    case partiallyOpen
    case fullyOpen
}

/// Everything the layout depends on. Pure data, so layouts are unit-testable.
struct LayoutInput: Equatable {
    var size: CGSize
    var hinge: HingeState = .none
    /// The fold's frame in the same coordinates as `size`, while it is active.
    var fold: CGRect?
    var controllerConnected = false
    /// Native screen sizes: 256 × 192 for both DS screens; 400 × 240 and 320 × 240 on the 3DS.
    var topScreenSize = CGSize(width: 256, height: 192)
    var bottomScreenSize = CGSize(width: 256, height: 192)
}

struct LayoutResult: Equatable {
    enum Kind: Equatable { case clamshell, book, stacked, landscape, focus, sideBySide }
    var kind: Kind
    var topScreen: CGRect
    var bottomScreen: CGRect
    /// Where on-screen controls go; all empty when a controller is connected. The D-pad
    /// and face buttons are drawn as the largest square that fits their rect.
    var dpad: CGRect = .zero
    var faceButtons: CGRect = .zero
    var shoulderLeft: CGRect = .zero
    var shoulderRight: CGRect = .zero
    /// Select and Start, side by side.
    var startSelect: CGRect = .zero
    /// The button that leaves the game.
    var menuButton: CGRect = .zero
}

/// Picks the layout. See "Audio, input and layouts" in the spec.
///
/// Portrait stacks the two screens like an open DS with the controls underneath.
/// Landscape tries three arrangements and keeps the one whose main screen is
/// biggest: the screens stacked in a column between the D-pad and the buttons (iPad,
/// Mac windows), side by side (wide windows without on-screen controls), or the top
/// screen large with the touch screen small at the side (phones held sideways).
enum LayoutResolver {
    static let margin: CGFloat = 8
    static let screenGap: CGFloat = 6
    static let shoulderHeight: CGFloat = 40
    static let smallButtonHeight: CGFloat = 30
    static let menuSize: CGFloat = 32

    static func resolve(_ input: LayoutInput) -> LayoutResult {
        if input.hinge == .partiallyOpen, let fold = input.fold {
            return fold.width >= fold.height ? clamshell(input, fold: fold) : book(input, fold: fold)
        }
        return input.size.width > input.size.height ? landscape(input) : portrait(input)
    }

    // MARK: - Fitting

    /// The scale that fits `screen` into `area`, preferring a whole number of device
    /// pixels per console pixel when that loses under 15% of the size.
    static func scale(_ screen: CGSize, in area: CGSize, displayScale: CGFloat = 3) -> CGFloat {
        guard area.width > 0, area.height > 0, screen.width > 0, screen.height > 0 else { return 0 }
        let fill = min(area.width / screen.width, area.height / screen.height)
        let pixelsPerConsolePixel = (fill * displayScale).rounded(.down)
        let integer = pixelsPerConsolePixel / displayScale
        return pixelsPerConsolePixel >= 1 && integer >= fill * 0.85 ? integer : fill
    }

    /// Largest rect of the screen's aspect ratio inside `area`, centred.
    static func fit(_ screen: CGSize, in area: CGRect) -> CGRect {
        let s = scale(screen, in: area.size)
        let w = screen.width * s, h = screen.height * s
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    /// Both screens in a column, at one scale, centred in `area`.
    static func column(_ input: LayoutInput, in area: CGRect) -> (top: CGRect, bottom: CGRect) {
        let t = input.topScreenSize, b = input.bottomScreenSize
        let s = scale(CGSize(width: max(t.width, b.width), height: t.height + b.height),
                      in: CGSize(width: area.width, height: area.height - screenGap))
        let height = (t.height + b.height) * s + screenGap
        let y = area.midY - height / 2
        let top = CGRect(x: area.midX - t.width * s / 2, y: y, width: t.width * s, height: t.height * s)
        let bottom = CGRect(x: area.midX - b.width * s / 2, y: top.maxY + screenGap, width: b.width * s, height: b.height * s)
        return (top, bottom)
    }

    /// Both screens in a row, at one scale, centred in `area`.
    static func row(_ input: LayoutInput, in area: CGRect) -> (top: CGRect, bottom: CGRect) {
        let t = input.topScreenSize, b = input.bottomScreenSize
        let s = scale(CGSize(width: t.width + b.width, height: max(t.height, b.height)),
                      in: CGSize(width: area.width - screenGap, height: area.height))
        let width = (t.width + b.width) * s + screenGap
        let x = area.midX - width / 2
        let top = CGRect(x: x, y: area.midY - t.height * s / 2, width: t.width * s, height: t.height * s)
        let bottom = CGRect(x: top.maxX + screenGap, y: area.midY - b.height * s / 2, width: b.width * s, height: b.height * s)
        return (top, bottom)
    }

    /// The square a D-pad or face-button cluster gets for a given window.
    static func padSize(_ size: CGSize) -> CGFloat {
        min(max(min(size.width, size.height) * 0.3, 120), 190)
    }

    // MARK: - Portrait

    /// Screens stacked at the top, controls in the space left underneath.
    static func portrait(_ input: LayoutInput) -> LayoutResult {
        let size = input.size
        let controls = !input.controllerConnected
        let pad = padSize(size)
        let controlsHeight = controls ? shoulderHeight + pad + smallButtonHeight + margin * 4 : menuSize + margin
        let screenArea = CGRect(x: margin, y: margin, width: size.width - margin * 2,
                                height: size.height - controlsHeight - margin * 2)
        var (top, bottom) = column(input, in: screenArea)
        // Screens sit at the top; whatever height they leave goes to the controls.
        let lift = top.minY - margin
        top.origin.y -= lift
        bottom.origin.y -= lift
        var result = LayoutResult(kind: .stacked, topScreen: top, bottomScreen: bottom)
        guard controls else {
            result.menuButton = CGRect(x: size.width - margin - menuSize, y: size.height - margin - menuSize,
                                       width: menuSize, height: menuSize)
            return result
        }
        let area = CGRect(x: margin, y: bottom.maxY + margin, width: size.width - margin * 2,
                          height: size.height - bottom.maxY - margin * 2)
        let shoulderWidth = min(area.width * 0.3, 160)
        result.shoulderLeft = CGRect(x: area.minX, y: area.minY, width: shoulderWidth, height: shoulderHeight)
        result.shoulderRight = CGRect(x: area.maxX - shoulderWidth, y: area.minY, width: shoulderWidth, height: shoulderHeight)
        result.menuButton = CGRect(x: area.midX - menuSize / 2, y: area.minY + (shoulderHeight - menuSize) / 2,
                                   width: menuSize, height: menuSize)
        let padArea = CGRect(x: area.minX, y: result.shoulderLeft.maxY + margin,
                             width: area.width, height: area.maxY - result.shoulderLeft.maxY - margin * 2 - smallButtonHeight)
        let side = min(max(pad, min(padArea.height, 200)), padArea.height, area.width * 0.42)
        result.dpad = CGRect(x: padArea.minX, y: padArea.midY - side / 2, width: side, height: side)
        result.faceButtons = CGRect(x: padArea.maxX - side, y: padArea.midY - side / 2, width: side, height: side)
        result.startSelect = CGRect(x: area.midX - 80, y: area.maxY - smallButtonHeight, width: 160, height: smallButtonHeight)
        return result
    }

    // MARK: - Landscape

    static func landscape(_ input: LayoutInput) -> LayoutResult {
        let size = input.size
        let controls = !input.controllerConnected
        let side: CGFloat = controls ? min(max(size.width * 0.2, 150), 240) : 0
        let middle = CGRect(x: side + margin, y: margin, width: size.width - side * 2 - margin * 2, height: size.height - margin * 2)

        // How big the top screen gets in each arrangement.
        let stacked = column(input, in: middle)
        let paired = row(input, in: middle)
        let focusTop = fit(input.topScreenSize, in: middle)
        // Focus shrinks the touch screen, so it is only worth it when the other two leave
        // the top screen much smaller (phones held sideways).
        var kind: LayoutResult.Kind = stacked.top.width >= paired.top.width ? .landscape : .sideBySide
        if controls && max(stacked.top.width, paired.top.width) < focusTop.width * 0.6 { kind = .focus }

        var result: LayoutResult
        switch kind {
        case .sideBySide:
            result = LayoutResult(kind: .sideBySide, topScreen: paired.top, bottomScreen: paired.bottom)
        case .focus:
            return focus(input, side: side, top: focusTop)
        default:
            result = LayoutResult(kind: .landscape, topScreen: stacked.top, bottomScreen: stacked.bottom)
        }
        guard controls else {
            result.menuButton = CGRect(x: size.width - margin - menuSize, y: margin, width: menuSize, height: menuSize)
            return result
        }
        // Controls in the side columns: shoulders at the top, D-pad and face buttons
        // a little below the middle where thumbs rest, Select and Start under the buttons.
        let left = CGRect(x: margin, y: margin, width: side - margin, height: size.height - margin * 2)
        let right = CGRect(x: size.width - side, y: margin, width: side - margin, height: size.height - margin * 2)
        result.shoulderLeft = CGRect(x: left.minX, y: left.minY, width: left.width, height: shoulderHeight)
        result.shoulderRight = CGRect(x: right.minX, y: right.minY, width: right.width, height: shoulderHeight)
        result.menuButton = CGRect(x: left.midX - menuSize / 2, y: result.shoulderLeft.maxY + margin, width: menuSize, height: menuSize)
        let pad = min(padSize(size), left.width, (left.height - shoulderHeight - smallButtonHeight - margin * 4))
        let padY = min(left.minY + left.height * 0.58 - pad / 2, left.maxY - smallButtonHeight - margin * 2 - pad)
        result.dpad = CGRect(x: left.midX - pad / 2, y: padY, width: pad, height: pad)
        result.faceButtons = CGRect(x: right.midX - pad / 2, y: padY, width: pad, height: pad)
        result.startSelect = CGRect(x: right.minX, y: result.faceButtons.maxY + margin, width: right.width,
                                    height: smallButtonHeight)
        return result
    }

    /// Phone held sideways: the top screen as big as it goes, the touch screen small in
    /// the right column above the face buttons.
    static func focus(_ input: LayoutInput, side: CGFloat, top: CGRect) -> LayoutResult {
        let size = input.size
        let left = CGRect(x: margin, y: margin, width: side - margin * 2, height: size.height - margin * 2)
        let right = CGRect(x: size.width - side + margin, y: margin, width: side - margin * 2, height: size.height - margin * 2)
        let shoulders = shoulderHeight - 6
        let pad = min(padSize(size), left.width, left.height * 0.5)
        var result = LayoutResult(kind: .focus, topScreen: top, bottomScreen: .zero)
        result.shoulderLeft = CGRect(x: left.minX, y: left.minY, width: left.width, height: shoulders)
        result.shoulderRight = CGRect(x: right.minX, y: right.minY, width: right.width, height: shoulders)
        result.menuButton = CGRect(x: left.midX - menuSize / 2, y: result.shoulderLeft.maxY + margin, width: menuSize, height: menuSize)
        result.startSelect = CGRect(x: right.minX, y: right.maxY - smallButtonHeight, width: right.width, height: smallButtonHeight)
        result.faceButtons = CGRect(x: right.midX - pad / 2, y: result.startSelect.minY - margin - pad, width: pad, height: pad)
        result.dpad = CGRect(x: left.midX - pad / 2, y: result.faceButtons.minY, width: pad, height: pad)
        result.bottomScreen = fit(input.bottomScreenSize, in: CGRect(
            x: right.minX, y: result.shoulderRight.maxY + margin,
            width: right.width, height: result.faceButtons.minY - result.shoulderRight.maxY - margin * 2))
        return result
    }

    // MARK: - iPhone Duo

    /// Half-open with the fold horizontal: top screen above the fold, touch screen and
    /// controls below it, like a real DS.
    static func clamshell(_ input: LayoutInput, fold: CGRect) -> LayoutResult {
        let upper = CGRect(x: 0, y: 0, width: input.size.width, height: fold.minY)
        let lower = CGRect(x: 0, y: fold.maxY, width: input.size.width, height: input.size.height - fold.maxY)
        let top = fit(input.topScreenSize, in: upper.insetBy(dx: margin, dy: margin))
        let controls = !input.controllerConnected
        let shoulders: CGFloat = controls ? 30 : 0
        let controlWidth: CGFloat = controls ? min(lower.width * 0.22, 150) : 0
        let screenArea = CGRect(x: controlWidth, y: lower.minY + shoulders + margin,
                                width: lower.width - controlWidth * 2, height: lower.height - shoulders - smallButtonHeight - margin * 3)
        let bottom = fit(input.bottomScreenSize, in: screenArea)
        var result = LayoutResult(kind: .clamshell, topScreen: top, bottomScreen: bottom)
        result.menuButton = CGRect(x: upper.maxX - margin - menuSize, y: margin, width: menuSize, height: menuSize)
        guard controls else { return result }
        let pad = min(controlWidth - margin * 2, bottom.height)
        result.dpad = CGRect(x: controlWidth / 2 - pad / 2, y: bottom.midY - pad / 2, width: pad, height: pad)
        result.faceButtons = CGRect(x: lower.maxX - controlWidth / 2 - pad / 2, y: bottom.midY - pad / 2, width: pad, height: pad)
        let shoulderWidth = lower.width * 0.25
        result.shoulderLeft = CGRect(x: margin, y: lower.minY + 4, width: shoulderWidth, height: shoulders - 4)
        result.shoulderRight = CGRect(x: lower.maxX - margin - shoulderWidth, y: lower.minY + 4, width: shoulderWidth, height: shoulders - 4)
        result.startSelect = CGRect(x: lower.midX - 80, y: lower.maxY - margin - smallButtonHeight, width: 160, height: smallButtonHeight)
        return result
    }

    /// Half-open with the fold vertical: one screen per page, like a book.
    static func book(_ input: LayoutInput, fold: CGRect) -> LayoutResult {
        let left = CGRect(x: 0, y: 0, width: fold.minX, height: input.size.height)
        let right = CGRect(x: fold.maxX, y: 0, width: input.size.width - fold.maxX, height: input.size.height)
        var result = LayoutResult(kind: .book, topScreen: fit(input.topScreenSize, in: left.insetBy(dx: margin, dy: margin)),
                                  bottomScreen: fit(input.bottomScreenSize, in: right.insetBy(dx: margin, dy: margin)))
        result.menuButton = CGRect(x: input.size.width - margin - menuSize, y: margin, width: menuSize, height: menuSize)
        return result
    }
}
