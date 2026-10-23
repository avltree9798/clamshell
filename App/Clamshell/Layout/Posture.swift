// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Reports the hinge state and the fold's frame to a view.
///
/// iPhone Duo's hinge and reserved-region APIs ship in the iOS 27.1 SDK. Their
/// names below come from Apple's public documentation and developer forum
/// answers (`onHingeChange`, `reservedRegions(kind: .division)`); build with
/// `CLAMSHELL_HINGE_API` defined once the project uses that SDK, and check the
/// exact signatures then. Without the flag, every device reports `.none` and
/// the app uses the ordinary phone and iPad layouts.
struct PostureReader: ViewModifier {
    @Binding var hinge: HingeState
    @Binding var fold: CGRect?

    func body(content: Content) -> some View {
        #if CLAMSHELL_HINGE_API
        if #available(iOS 27.1, *) {
            GeometryReader { proxy in
                content
                    .onHingeChange { _, newContext in
                        switch newContext.hinge.status {
                        case .closed: hinge = .closed
                        case .partiallyOpen: hinge = .partiallyOpen
                        case .fullyOpen: hinge = .fullyOpen
                        @unknown default: hinge = .none
                        }
                    }
                    .onChange(of: proxy.size, initial: true) {
                        let division = proxy.reservedRegions(kind: .division).first { $0.isActive }
                        fold = division?.frame
                    }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    func readPosture(hinge: Binding<HingeState>, fold: Binding<CGRect?>) -> some View {
        modifier(PostureReader(hinge: hinge, fold: fold))
    }
}
