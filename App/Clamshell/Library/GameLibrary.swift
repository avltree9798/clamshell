// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// Games the player imported. Files live in Documents/Games so they also show
/// in the Files app; saves sit beside them as .sav files.
@Observable @MainActor
final class GameLibrary {
    struct Game: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let title: String
        let gameCode: String
        var saveURL: URL { url.deletingPathExtension().appendingPathExtension("sav") }
    }

    private(set) var games: [Game] = []
    var importError: String?

    let gamesFolder: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Games", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    init() { refresh() }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: gamesFolder, includingPropertiesForKeys: nil)) ?? []
        games = files.filter { $0.pathExtension.lowercased() == "nds" }
            .compactMap(Self.describe)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Copies a game the player picked into the library.
    func importGame(from source: URL) {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let destination = gamesFolder.appendingPathComponent(source.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            refresh()
        } catch {
            importError = "Could not import \(source.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Reads the title and game code from the cartridge header, not from any online database.
    private static func describe(_ url: URL) -> Game? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let header = try? handle.read(upToCount: 16), header.count == 16 else { return nil }
        let title = String(decoding: header.prefix(12).prefix { $0 != 0 }, as: UTF8.self)
        let code = String(decoding: header.suffix(4), as: UTF8.self)
        return Game(url: url, title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title, gameCode: code)
    }
}
