import SwiftUI

struct CheckersView: View {
    let state: CheckersState
    @Environment(GameCoordinator.self) private var games
    @State private var selected: Int?

    private var mySide: CheckersState.Side? { state.side(for: games.localId) }
    private var isMyTurn: Bool { state.outcome == nil && state.turn == mySide && games.pendingMoveId == nil }
    private var legal: [CheckersRules.Step] { isMyTurn ? CheckersRules.legalSteps(in: state) : [] }
    private var mustJump: Bool { legal.contains { $0.captured != nil } }
    /// The piece whose moves are shown: a piece mid-jump is always active.
    private var active: Int? { state.jumpingFrom ?? selected }
    private var movable: Set<Int> { Set(legal.map(\.from)) }
    private var targets: Set<Int> {
        guard let active else { return [] }
        return Set(legal.filter { $0.from == active }.map(\.to))
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                badge(.black)
                Spacer()
                Text("Round \(state.round)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                badge(.red)
            }

            Text(statusText)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)

            EightByEightBoard(flipped: mySide == .red) { index in
                square(index)
            }

            if state.outcome != nil {
                RematchControls()
            } else if mySide != nil {
                ResignButton(move: .checkers(.resign))
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.2), value: state)
        .onChange(of: state) { selected = nil }
    }

    private func badge(_ side: CheckersState.Side) -> some View {
        BoardPlayerBadge(
            name: games.name(for: state.playerId(for: side)),
            sideName: side.name,
            isActive: state.outcome == nil && state.turn == side,
            detail: "\(state.count(side)) pieces"
        ) {
            CheckerPieceView(piece: .init(side: side))
        }
    }

    private var statusText: String {
        switch state.outcome {
        case .win(let side, let byResignation):
            let loser = games.name(for: state.playerId(for: side.other))
            if side == mySide { return byResignation ? "\(loser) resigned. You win! 🎉" : "You win! 🎉" }
            let winner = games.name(for: state.playerId(for: side))
            return byResignation ? "\(loser) resigned. \(winner) wins" : "\(winner) wins"
        case .draw:
            return "It's a draw: 40 moves with no jumps"
        case nil:
            if games.pendingMoveId != nil { return "Sending move…" }
            guard isMyTurn else { return "\(games.name(for: state.playerId(for: state.turn)))'s turn" }
            if state.jumpingFrom != nil { return "Keep jumping!" }
            if mustJump { return "You must jump!" }
            return active == nil ? "Your turn: pick a piece" : "Your turn: pick a square"
        }
    }

    private func square(_ index: Int) -> some View {
        let dark = CheckersRules.isDark(index)
        let piece = state.board[index]
        let isTarget = targets.contains(index)
        let isSelected = active == index
        return ZStack {
            Rectangle()
                .fill(dark ? Theme.deep : Theme.foam.opacity(0.9))
            if state.lastPath.contains(index) {
                Rectangle().strokeBorder(Theme.sunset, lineWidth: 3)
            }
            if let piece {
                CheckerPieceView(piece: piece, isSelected: isSelected, isMovable: isMyTurn && active == nil && movable.contains(index))
                    .padding(4)
                    .transition(.scale.combined(with: .opacity))
            }
            if isTarget {
                Circle()
                    .fill(Theme.sunset.opacity(0.85))
                    .padding(14)
            }
        }
        .contentShape(.rect)
        .onTapGesture { tap(index) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(squareLabel(index, piece: piece, isTarget: isTarget, isSelected: isSelected))
        .accessibilityAddTraits(dark ? .isButton : [])
        .accessibilityHidden(!dark)
    }

    private func tap(_ index: Int) {
        guard isMyTurn else { return }
        if let active, targets.contains(index) {
            games.play(.checkers(.move(from: active, to: index)))
            selected = nil
        } else if state.jumpingFrom == nil, movable.contains(index) {
            selected = selected == index ? nil : index
        } else {
            selected = nil
        }
    }

    private func squareLabel(_ index: Int, piece: CheckersState.Piece?, isTarget: Bool, isSelected: Bool) -> String {
        // Numbered from the viewer's side so "row 1" is always the nearest row.
        let row = index / CheckersRules.size, column = index % CheckersRules.size
        let flipped = mySide == .red
        var parts = ["Row \((flipped ? 7 - row : row) + 1), column \((flipped ? 7 - column : column) + 1)"]
        if let piece { parts.append("\(piece.side.name) \(piece.isKing ? "king" : "piece")") } else { parts.append("empty") }
        if isSelected { parts.append("selected") }
        if isTarget { parts.append("move here") }
        return parts.joined(separator: ", ")
    }
}

/// A checker with a crown for kings; Black and Red also differ in ring style for color-blind players.
struct CheckerPieceView: View {
    let piece: CheckersState.Piece
    var isSelected = false
    var isMovable = false

    var body: some View {
        ZStack {
            Circle()
                .fill(piece.side == .black ? AnyShapeStyle(Theme.night.gradient) : AnyShapeStyle(Theme.coral.gradient))
            Circle()
                .strokeBorder(piece.side == .black ? Color.white.opacity(0.35) : Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: piece.side == .black ? [] : [3, 2]))
                .padding(3)
            if piece.isKing {
                Image(systemName: "crown.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .foregroundStyle(Theme.sunset)
            }
        }
        .overlay(Circle().strokeBorder(isSelected ? Theme.sunset : isMovable ? Color.white.opacity(0.7) : .clear, lineWidth: isSelected ? 3 : 1.5))
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1.5)
        .scaleEffect(isSelected ? 1.08 : 1)
    }
}

#Preview {
    let profile = ProfileStore()
    let session = SessionManager(transport: MultipeerTransport(), profile: profile)
    var state = CheckersRules.newGame(players: ["a", "b"])
    state.board[18] = nil
    state.board[27] = .init(side: .black, isKing: true)
    state.board[45] = nil
    state.lastPath = [18, 27]
    return ScrollView {
        CheckersView(state: state).padding()
    }
    .environment(GameCoordinator(session: session))
}
