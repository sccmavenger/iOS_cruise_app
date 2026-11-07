/// A simple opponent for playing a two-player board game alone. It plays on this phone only:
/// the game is hosted locally, so it works with no one nearby and no internet.
///
/// It looks one move ahead: it takes a win when there is one, blocks an immediate loss, prefers
/// captures, and avoids leaving a piece where it can be taken. Ties are broken at random so
/// games vary. It's meant to be a friendly opponent, not a strong one.
nonisolated enum ComputerPlayer {
    /// The computer's seat id. Can't collide with a real player: mesh ids and online seats
    /// have other shapes.
    static let playerId = "computer"
    static let nickname = "Computer"

    static func supports(_ type: GameType) -> Bool {
        switch type {
        case .ticTacToe, .connectFour, .checkers, .chess: true
        case .colorMatch, .spades, .tonk: false
        }
    }

    /// The computer's next move, or nil if it isn't the computer's turn.
    static func move(in state: GameEngine.State) -> GameMove? {
        switch state {
        case .ticTacToe(let board): ticTacToeMove(board).map { .ticTacToe(cell: $0) }
        case .connectFour(let board): connectFourMove(board).map { .connectFour(column: $0) }
        case .checkers(let board): checkersMove(board).map { .checkers(.move(from: $0.from, to: $0.to)) }
        case .chess(let board): chessMove(board).map { .chess(.move(from: $0.from, to: $0.to, promotion: $0.promotion)) }
        case .colorMatch, .spades, .tonk: nil
        }
    }

    /// Highest score wins; equal scores are picked between at random.
    private static func best<T>(_ candidates: [T], score: (T) -> Int) -> T? {
        let scored = candidates.map { ($0, score($0)) }
        guard let top = scored.map(\.1).max() else { return nil }
        return scored.filter { $0.1 == top }.randomElement()?.0
    }

    // MARK: - Tic-Tac-Toe

    private static func ticTacToeMove(_ state: TicTacToeState) -> Int? {
        guard state.outcome == nil, state.playerId(for: state.turn) == playerId else { return nil }
        let me = state.turn
        let free = TicTacToeRules.cellRange.filter { state.board[$0] == nil }
        return best(free) { cell in
            if completesLine(cell, for: me, on: state.board) { return 100 }
            if completesLine(cell, for: me.other, on: state.board) { return 50 }
            // Centre, then corners, then edges.
            return cell == 4 ? 3 : [0, 2, 6, 8].contains(cell) ? 2 : 1
        }
    }

    private static func completesLine(_ cell: Int, for mark: TicTacToeState.Mark, on board: [TicTacToeState.Mark?]) -> Bool {
        var next = board
        next[cell] = mark
        if case .win = TicTacToeRules.outcome(of: next) { return true }
        return false
    }

    // MARK: - Connect Four

    private static func connectFourMove(_ state: ConnectFourState) -> Int? {
        guard state.outcome == nil, state.playerId(for: state.turn) == playerId else { return nil }
        let me = state.turn
        let open = ConnectFourRules.columnRange.filter { ConnectFourRules.landingRow(in: $0, of: state.board) != nil }
        return best(open) { column in
            if wins(column, for: me, on: state.board) { return 100 }
            if wins(column, for: me.other, on: state.board) { return 50 }
            // Don't drop a disc that lets the opponent win right on top of it.
            var after = state.board
            if let row = ConnectFourRules.landingRow(in: column, of: after) {
                after[row * ConnectFourRules.columns + column] = me
            }
            if wins(column, for: me.other, on: after) { return -50 }
            // Central columns take part in more lines.
            return 3 - abs(column - 3)
        }
    }

    private static func wins(_ column: Int, for disc: ConnectFourState.Disc, on board: [ConnectFourState.Disc?]) -> Bool {
        guard let row = ConnectFourRules.landingRow(in: column, of: board) else { return false }
        var next = board
        let index = row * ConnectFourRules.columns + column
        next[index] = disc
        return ConnectFourRules.winningLine(through: index, in: next) != nil
    }

    // MARK: - Checkers

    private static func checkersMove(_ state: CheckersState) -> CheckersRules.Step? {
        guard state.outcome == nil, state.playerId(for: state.turn) == playerId else { return nil }
        let me = state.turn
        return best(CheckersRules.legalSteps(in: state)) { step in
            guard let next = try? CheckersRules.apply(.move(from: step.from, to: step.to), by: playerId, to: state) else { return .min }
            if case .win(let side, _) = next.outcome, side == me { return 1000 }
            var score = step.captured == nil ? 0 : 10
            if next.board[step.to]?.isKing == true, state.board[step.from]?.isKing == false { score += 8 }
            // Still jumping: the follow-up is chosen next time. Otherwise, avoid being jumped.
            if next.turn != me, CheckersRules.legalSteps(in: next).contains(where: { $0.captured == step.to }) {
                score -= 12
            }
            return score
        }
    }

    // MARK: - Chess

    private static func chessMove(_ state: ChessState) -> ChessMove? {
        guard state.outcome == nil, state.playerId(for: state.turn) == playerId else { return nil }
        let me = state.turn
        return best(ChessRules.legalMoves(in: state)) { move in
            guard let next = try? ChessRules.apply(.move(from: move.from, to: move.to, promotion: move.promotion), by: playerId, to: state) else { return .min }
            if case .checkmate(let winner) = next.outcome, winner == me { return 10_000 }
            if case .draw = next.outcome { return -500 }
            var score = state.board[move.to].map { value($0.kind) } ?? 0
            if let promotion = move.promotion { score += value(promotion) - value(.pawn) }
            // Don't leave the moved piece where it can simply be taken.
            if let moved = next.board[move.to], ChessRules.isAttacked(move.to, by: me.other, in: next.board) {
                score -= value(moved.kind)
            }
            if ChessRules.isInCheck(me.other, in: next.board) { score += 1 }
            return score
        }
    }

    private static func value(_ kind: ChessPiece.Kind) -> Int {
        switch kind {
        case .pawn: 100
        case .knight, .bishop: 300
        case .rook: 500
        case .queen: 900
        case .king: 0
        }
    }
}
