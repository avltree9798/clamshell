// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct ClamshellApp: App {
    @State private var library = GameLibrary()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
        }
    }
}
