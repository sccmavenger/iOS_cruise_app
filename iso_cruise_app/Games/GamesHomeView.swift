import SwiftUI

/// The single Games tab listing all three titles.
struct GamesHomeView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(GameType.allCases) { game in
                        GameTile(game: game, isAvailable: false)
                    }
                }
                .padding()
            }
            .navigationTitle("Games")
        }
    }
}

struct GameTile: View {
    let game: GameType
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 16) {
            GameArtwork(game: game)
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.displayName)
                    .font(.headline)
                Text(game.tagline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(game.playerCountText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.teal)
                if !isAvailable {
                    Text("Coming soon")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.fill.tertiary, in: Capsule())
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isAvailable {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}

extension GameType {
    var tagline: String {
        switch self {
        case .ticTacToe: "Three in a row wins."
        case .connectFour: "Drop discs, connect four."
        case .colorMatch: "Match colors and numbers, empty your hand."
        }
    }

    var playerCountText: String {
        minPlayers == maxPlayers ? "\(minPlayers) players" : "\(minPlayers)–\(maxPlayers) players"
    }
}

/// Small illustrated thumbnails drawn with SwiftUI shapes (no external art).
struct GameArtwork: View {
    let game: GameType

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(background)
            switch game {
            case .ticTacToe: ticTacToe
            case .connectFour: connectFour
            case .colorMatch: colorMatch
            }
        }
    }

    private var background: LinearGradient {
        switch game {
        case .ticTacToe: LinearGradient(colors: [Theme.teal, Theme.deep], startPoint: .top, endPoint: .bottom)
        case .connectFour: LinearGradient(colors: [Theme.deep, Theme.night], startPoint: .top, endPoint: .bottom)
        case .colorMatch: LinearGradient(colors: [Theme.sunset, Theme.coral], startPoint: .top, endPoint: .bottom)
        }
    }

    private var ticTacToe: some View {
        let marks = ["xmark", "", "circle", "", "xmark", "", "circle", "", "xmark"]
        return Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let symbol = marks[row * 3 + column]
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white.opacity(0.18))
                            .frame(width: 20, height: 20)
                            .overlay {
                                if !symbol.isEmpty {
                                    Image(systemName: symbol)
                                        .font(.system(size: 11, weight: .heavy))
                                        .foregroundStyle(symbol == "xmark" ? Theme.foam : Theme.sunset)
                                }
                            }
                    }
                }
            }
        }
    }

    private var connectFour: some View {
        let pattern: [[Color?]] = [
            [nil, nil, nil, nil],
            [nil, nil, Theme.sunset, nil],
            [nil, Theme.sunset, Theme.foam, nil],
            [Theme.sunset, Theme.foam, Theme.foam, Theme.sunset],
        ]
        return VStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { column in
                        Circle()
                            .fill(pattern[row][column] ?? .white.opacity(0.15))
                            .frame(width: 13, height: 13)
                    }
                }
            }
        }
        .padding(6)
        .background(Theme.teal.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private var colorMatch: some View {
        ZStack {
            card(color: Theme.deep, label: "7").rotationEffect(.degrees(-16)).offset(x: -12)
            card(color: Theme.teal, label: "⟲").rotationEffect(.degrees(2))
            card(color: .white, label: "★", foreground: Theme.coral).rotationEffect(.degrees(18)).offset(x: 12)
        }
    }

    private func card(color: Color, label: String, foreground: Color = .white) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color)
            .frame(width: 30, height: 44)
            .overlay(Text(label).font(.system(size: 16, weight: .black)).foregroundStyle(foreground))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

#Preview {
    GamesHomeView()
}
