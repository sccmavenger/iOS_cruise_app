nonisolated struct TicTacToeState: Codable, Equatable, Sendable {
    enum Mark: String, Codable, Sendable {
        case x, o

        var other: Mark { self == .x ? .o : .x }
        var symbol: String { self == .x ? "X" : "O" }
    }

    enum Outcome: Codable, Equatable, Sendable {
        case win(Mark, line: [Int])
        case draw
    }

    /// Nine cells, row-major from the top-left.
    var board: [Mark?]
    /// `players[0]` plays X, `players[1]` plays O.
    var players: [String]
    var turn: Mark
    var outcome: Outcome?
    /// 1-based round counter; increments on rematch.
    var round: Int

    func mark(for playerId: String) -> Mark? {
        guard let index = players.firstIndex(of: playerId) else { return nil }
        return index == 0 ? .x : .o
    }

    func playerId(for mark: Mark) -> String {
        players[mark == .x ? 0 : 1]
    }

    var isStructurallyValid: Bool {
        board.count == TicTacToeRules.cellCount
            && players.count == 2
            && players[0] != players[1]
            && round >= 1
    }
}

/// Pure, deterministic Tic-Tac-Toe rules. The host is the only caller that commits results.
nonisolated enum TicTacToeRules {
    static let cellCount = 9
    static let cellRange = 0..<cellCount

    static let lines: [[Int]] = [
        [0, 1, 2], [3, 4, 5], [6, 7, 8], // rows
        [0, 3, 6], [1, 4, 7], [2, 5, 8], // columns
        [0, 4, 8], [2, 4, 6],            // diagonals
    ]

    /// X always moves first; `players[0]` is X.
    static func newGame(players: [String], round: Int = 1) -> TicTacToeState {
        TicTacToeState(
            board: Array(repeating: nil, count: cellCount),
            players: players,
            turn: .x,
            outcome: nil,
            round: round
        )
    }

    /// Starts the next round with seats swapped so the first player alternates.
    static func rematch(from state: TicTacToeState) -> TicTacToeState {
        newGame(players: state.players.reversed(), round: state.round + 1)
    }

    static func apply(cell: Int, by playerId: String, to state: TicTacToeState) throws(MoveError) -> TicTacToeState {
        guard let mark = state.mark(for: playerId) else { throw .notAPlayer }
        guard state.outcome == nil else { throw .gameOver }
        guard mark == state.turn else { throw .notYourTurn }
        guard cellRange.contains(cell) else { throw .outOfBounds }
        guard state.board[cell] == nil else { throw .occupied }

        var next = state
        next.board[cell] = mark
        next.outcome = outcome(of: next.board)
        if next.outcome == nil {
            next.turn = mark.other
        }
        return next
    }

    static func outcome(of board: [TicTacToeState.Mark?]) -> TicTacToeState.Outcome? {
        for line in lines {
            if let first = board[line[0]], board[line[1]] == first, board[line[2]] == first {
                return .win(first, line: line)
            }
        }
        return board.allSatisfy({ $0 != nil }) ? .draw : nil
    }
}
