// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(GameLibrary.self) private var library
    @State private var importing = false
    @State private var playing: GameLibrary.Game?

    var body: some View {
        NavigationStack {
            List(library.games) { game in
                Button {
                    playing = game
                } label: {
                    VStack(alignment: .leading) {
                        Text(game.title).font(.headline)
                        Text(game.gameCode).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if library.games.isEmpty {
                    ContentUnavailableView(
                        "No games yet",
                        systemImage: "rectangle.portrait.on.rectangle.portrait",
                        description: Text("Import a game you dumped from your own cartridge."))
                }
            }
            .navigationTitle("Clamshell")
            .toolbar {
                Button("Import", systemImage: "plus") { importing = true }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.ndsROM, .homebrew3DSX, .data], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { urls.forEach(library.importGame) }
            }
            .alert("Import failed", isPresented: .constant(library.importError != nil)) {
                Button("OK") { library.importError = nil }
            } message: {
                Text(library.importError ?? "")
            }
        }
        .fullScreenCover(item: $playing) { game in
            GameView(game: game)
        }
    }
}

extension UTType {
    static let ndsROM = UTType(filenameExtension: "nds", conformingTo: .data) ?? .data
    static let homebrew3DSX = UTType(filenameExtension: "3dsx", conformingTo: .data) ?? .data
}
