import SwiftUI

/// An 8×8 board for Checkers and Chess. Square indices are `row * 8 + column` with row 0
/// at the first player's side; `flipped` puts row 0 at the top so the second player
/// sees their own pieces at the bottom.
struct EightByEightBoard<Square: View>: View {
    var flipped = false
    @ViewBuilder var square: (_ index: Int) -> Square

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { screenRow in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { screenColumn in
                        let row = flipped ? screenRow : 7 - screenRow
                        let column = flipped ? 7 - screenColumn : screenColumn
                        square(row * 8 + column)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(6)
        .background(Theme.night, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: 440)
    }
}

/// Name, color swatch, and turn indicator for a two-player board game.
struct BoardPlayerBadge<Swatch: View>: View {
    let name: String
    let sideName: String
    let isActive: Bool
    var detail: String?
    @ViewBuilder var swatch: () -> Swatch

    var body: some View {
        HStack(spacing: 8) {
            swatch()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(isActive ? .regular.tint(Theme.teal.opacity(0.35)) : .regular, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(name == "You" ? "play" : "plays") \(sideName)\(detail.map { ", \($0)" } ?? "")\(isActive ? ", current turn" : "")")
    }
}

/// Resign with a confirmation, for games that can otherwise run long.
struct ResignButton: View {
    let move: GameMove
    @Environment(GameCoordinator.self) private var games
    @State private var confirming = false

    var body: some View {
        Button("Resign", systemImage: "flag", role: .destructive) {
            confirming = true
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.glass)
        .alert("Resign this game?", isPresented: $confirming) {
            Button("Resign", role: .destructive) { games.play(move) }
            Button("Keep Playing", role: .cancel) {}
        } message: {
            Text("Your opponent wins this round. You can still play a rematch.")
        }
    }
}
