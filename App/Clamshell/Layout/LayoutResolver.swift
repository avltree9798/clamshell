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
    /// Native screen size, e.g. 256 × 192 for the DS.
    var screenSize = CGSize(width: 256, height: 192)
}

struct LayoutResult: Equatable {
    enum Kind: Equatable { case clamshell, book, stacked, landscape, controllerOnly }
    var kind: Kind
    var topScreen: CGRect
    var bottomScreen: CGRect
    /// Where on-screen controls go; empty when a controller is connected.
    var leftControls: CGRect = .zero
    var rightControls: CGRect = .zero
    var shoulderLeft: CGRect = .zero
    var shoulderRight: CGRect = .zero
}

/// Picks the layout. See "Audio, input and layouts" in the spec.
enum LayoutResolver {
    static func resolve(_ input: LayoutInput) -> LayoutResult {
        let size = input.size
        if input.hinge == .partiallyOpen, let fold = input.fold {
            if fold.width >= fold.height {
                return clamshell(input, fold: fold)
            }
            return book(input, fold: fold)
        }
        if input.controllerConnected {
            return size.width > size.height ? sideBySide(input, kind: .controllerOnly) : stacked(input, controls: false)
        }
        return size.width > size.height ? landscape(input) : stacked(input, controls: true)
    }

    /// Largest rect of the screen's aspect ratio inside `area` (in points), preferring a
    /// whole number of device pixels per console pixel when that loses under 15% of the size.
    static func fit(_ screen: CGSize, in area: CGRect, scale displayScale: CGFloat = 3) -> CGRect {
        guard area.width > 0, area.height > 0 else { return .zero }
        let fill = min(area.width / screen.width, area.height / screen.height)
        let pixelsPerConsolePixel = (fill * displayScale).rounded(.down)
        let integer = pixelsPerConsolePixel / displayScale
        let s = pixelsPerConsolePixel >= 1 && integer >= fill * 0.85 ? integer : fill
        let w = screen.width * s, h = screen.height * s
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    /// iPhone Duo half-open, fold horizontal: top screen above the fold, touch screen and
    /// controls below it, like a real DS.
    static func clamshell(_ input: LayoutInput, fold: CGRect) -> LayoutResult {
        let upper = CGRect(x: 0, y: 0, width: input.size.width, height: fold.minY)
        let lower = CGRect(x: 0, y: fold.maxY, width: input.size.width, height: input.size.height - fold.maxY)
        let top = fit(input.screenSize, in: upper.insetBy(dx: 8, dy: 8))
        let shoulderHeight: CGFloat = input.controllerConnected ? 0 : 28
        let controlWidth: CGFloat = input.controllerConnected ? 0 : min(lower.width * 0.17, 110)
        let screenArea = CGRect(x: controlWidth, y: lower.minY + shoulderHeight + 8,
                                width: lower.width - controlWidth * 2, height: lower.height - shoulderHeight - 16)
        let bottom = fit(input.screenSize, in: screenArea)
        var result = LayoutResult(kind: .clamshell, topScreen: top, bottomScreen: bottom)
        if !input.controllerConnected {
            result.leftControls = CGRect(x: 0, y: bottom.minY, width: bottom.minX, height: bottom.height)
            result.rightControls = CGRect(x: bottom.maxX, y: bottom.minY, width: input.size.width - bottom.maxX, height: bottom.height)
            result.shoulderLeft = CGRect(x: 8, y: lower.minY + 4, width: lower.width * 0.25, height: shoulderHeight - 4)
            result.shoulderRight = CGRect(x: lower.maxX - 8 - lower.width * 0.25, y: lower.minY + 4,
                                          width: lower.width * 0.25, height: shoulderHeight - 4)
        }
        return result
    }

    /// Half-open with the fold vertical: one screen per page, like a book.
    static func book(_ input: LayoutInput, fold: CGRect) -> LayoutResult {
        let left = CGRect(x: 0, y: 0, width: fold.minX, height: input.size.height)
        let right = CGRect(x: fold.maxX, y: 0, width: input.size.width - fold.maxX, height: input.size.height)
        return LayoutResult(kind: .book, topScreen: fit(input.screenSize, in: left.insetBy(dx: 8, dy: 8)),
                            bottomScreen: fit(input.screenSize, in: right.insetBy(dx: 8, dy: 8)))
    }

    static func stacked(_ input: LayoutInput, controls: Bool) -> LayoutResult {
        let size = input.size
        let controlHeight: CGFloat = controls ? min(size.height * 0.28, 260) : 0
        let screensHeight = size.height - controlHeight
        let top = fit(input.screenSize, in: CGRect(x: 0, y: 0, width: size.width, height: screensHeight / 2))
        let bottom = fit(input.screenSize, in: CGRect(x: 0, y: screensHeight / 2, width: size.width, height: screensHeight / 2))
        var result = LayoutResult(kind: .stacked, topScreen: top, bottomScreen: bottom)
        if controls {
            let strip = CGRect(x: 0, y: screensHeight, width: size.width, height: controlHeight)
            result.leftControls = CGRect(x: strip.minX, y: strip.minY, width: strip.width / 2, height: strip.height)
            result.rightControls = CGRect(x: strip.midX, y: strip.minY, width: strip.width / 2, height: strip.height)
            result.shoulderLeft = CGRect(x: 8, y: strip.minY, width: strip.width * 0.2, height: 32)
            result.shoulderRight = CGRect(x: strip.maxX - 8 - strip.width * 0.2, y: strip.minY, width: strip.width * 0.2, height: 32)
        }
        return result
    }

    static func sideBySide(_ input: LayoutInput, kind: LayoutResult.Kind) -> LayoutResult {
        let half = input.size.width / 2
        return LayoutResult(kind: kind,
                            topScreen: fit(input.screenSize, in: CGRect(x: 0, y: 0, width: half, height: input.size.height)),
                            bottomScreen: fit(input.screenSize, in: CGRect(x: half, y: 0, width: half, height: input.size.height)))
    }

    /// Phone held sideways: big top screen in the middle, touch screen small at the side.
    static func landscape(_ input: LayoutInput) -> LayoutResult {
        let size = input.size
        let side = size.width * 0.2
        let top = fit(input.screenSize, in: CGRect(x: side, y: 0, width: size.width - side * 2, height: size.height))
        let bottom = fit(input.screenSize, in: CGRect(x: size.width - side, y: 0, width: side, height: size.height / 2))
        var result = LayoutResult(kind: .landscape, topScreen: top, bottomScreen: bottom)
        result.leftControls = CGRect(x: 0, y: size.height * 0.4, width: side, height: size.height * 0.6)
        result.rightControls = CGRect(x: size.width - side, y: size.height * 0.5, width: side, height: size.height * 0.5)
        result.shoulderLeft = CGRect(x: 0, y: 0, width: side, height: 36)
        result.shoulderRight = CGRect(x: 0, y: 44, width: side, height: 36)
        return result
    }
}
