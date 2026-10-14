import SwiftUI

struct TicTacToeView: View {
    let state: TicTacToeState
    @Environment(GameCoordinator.self) private var games

    private var myMark: TicTacToeState.Mark? { state.mark(for: games.localId) }
    private var isMyTurn: Bool { state.outcome == nil && state.turn == myMark && games.pendingMoveId == nil }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                PlayerBadge(mark: .x, name: games.name(for: state.playerId(for: .x)), isActive: state.outcome == nil && state.turn == .x)
                Spacer()
                Text("Round \(state.round)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                PlayerBadge(mark: .o, name: games.name(for: state.playerId(for: .o)), isActive: state.outcome == nil && state.turn == .o)
            }

            Text(statusText)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)

            board
                .frame(maxWidth: 360)

            if state.outcome != nil {
                RematchControls()
            }
        }
        .animation(.snappy, value: state)
    }

    private var statusText: String {
        switch state.outcome {
        case .win(let mark, _):
            return mark == myMark ? "You win! 🎉" : "\(games.name(for: state.playerId(for: mark))) wins"
        case .draw:
            return "It's a draw"
        case nil:
            if games.pendingMoveId != nil { return "Sending move…" }
            return isMyTurn ? "Your turn" : "\(games.name(for: state.playerId(for: state.turn)))'s turn"
        }
    }

    private var winningLine: Set<Int> {
        if case .win(_, let line) = state.outcome { return Set(line) }
        return []
    }

    private var board: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        cell(row * 3 + column)
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.deep.opacity(0.85), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func cell(_ index: Int) -> some View {
        let mark = state.board[index]
        let isWinning = winningLine.contains(index)
        let canTap = isMyTurn && mark == nil
        return Button {
            guard canTap else { return }
            games.play(.ticTacToe(cell: index))
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isWinning ? Theme.coral : Color.white.opacity(canTap ? 0.22 : 0.12))
                if let mark {
                    Image(systemName: mark == .x ? "xmark" : "circle")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundStyle(isWinning ? Color.white : (mark == .x ? Theme.foam : Theme.sunset))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(canTap)
        .accessibilityLabel(cellLabel(index, mark: mark))
        .accessibilityHint(canTap ? "Places your \(myMark?.symbol ?? "") here" : "")
    }

    private func cellLabel(_ index: Int, mark: TicTacToeState.Mark?) -> String {
        let row = index / 3 + 1
        let column = index % 3 + 1
        let content = mark.map { $0.symbol } ?? "empty"
        return "Row \(row), column \(column), \(content)"
    }
}

struct PlayerBadge: View {
    let mark: TicTacToeState.Mark
    let name: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: mark == .x ? "xmark" : "circle")
                .font(.headline.weight(.heavy))
                .foregroundStyle(mark == .x ? Theme.teal : Theme.sunset)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(isActive ? .regular.tint(Theme.teal.opacity(0.35)) : .regular, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) \(name == "You" ? "play" : "plays") \(mark.symbol)\(isActive ? ", current turn" : "")")
    }
}
