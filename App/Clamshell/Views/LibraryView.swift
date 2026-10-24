// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(GameLibrary.self) private var library
    @State private var importing = false
    @State private var playing: GameLibrary.Game?

    static let background = Color(red: 0.06, green: 0.07, blue: 0.11)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 24)], spacing: 24) {
                    ForEach(library.games) { game in
                        Button { playing = game } label: { GameCard(game: game) }
                            .buttonStyle(CardButtonStyle())
                    }
                }
                .padding(24)
            }
            .background(Self.background.ignoresSafeArea())
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
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $playing) { game in
            GameView(game: game)
        }
    }
}

/// A game as a box-shaped card: its own icon, scaled up with sharp pixels over a
/// glow of the icon's colours, and the full title underneath.
private struct GameCard: View {
    let game: GameLibrary.Game

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                let tint = game.art?.averageColor ?? (0.2, 0.25, 0.35)
                let color = Color(red: tint.r, green: tint.g, blue: tint.b)
                LinearGradient(colors: [color.opacity(0.85), color.opacity(0.35), .black.opacity(0.6)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image = game.art.flatMap(Self.image) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .padding(28)
                        .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.6))
                }
                VStack {
                    HStack {
                        Spacer()
                        Text(game.gameCode == "3DSX" ? "3DS" : "DS")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.45), in: Capsule())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                }
                .padding(10)
            }
            .aspectRatio(0.9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 2) {
                Text(game.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(red: 0.45, green: 0.95, blue: 0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let publisher = game.art?.titleLines.last, (game.art?.titleLines.count ?? 0) > 1 {
                    Text(publisher).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }

    static func image(_ art: GameArt) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(art.icon) as CFData) else { return nil }
        return CGImage(width: art.width, height: art.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: art.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Lifts a card a little on hover and press.
private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .hoverEffect(.lift)
    }
}

extension UTType {
    static let ndsROM = UTType(filenameExtension: "nds", conformingTo: .data) ?? .data
    static let homebrew3DSX = UTType(filenameExtension: "3dsx", conformingTo: .data) ?? .data
}
