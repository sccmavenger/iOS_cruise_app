import Foundation

nonisolated struct ConnectFourState: Codable, Equatable, Sendable {
    enum Disc: String, Codable, Sendable {
        case red, yellow

        var other: Disc { self == .red ? .yellow : .red }
        var name: String { self == .red ? "Red" : "Yellow" }
    }

    enum Outcome: Codable, Equatable, Sendable {
        /// `cells` are board indices of the winning line.
        case win(Disc, cells: [Int])
        case draw
    }

    /// Row-major from the **bottom** row: index = row * columns + column.
    var board: [Disc?]
    /// `players[0]` plays red and moves first.
    var players: [String]
    var turn: Disc
    var outcome: Outcome?
    var round: Int
    /// Most recent drop, for animation and VoiceOver announcements.
    var lastMove: Int?

    func disc(for playerId: String) -> Disc? {
        guard let index = players.firstIndex(of: playerId) else { return nil }
        return index == 0 ? .red : .yellow
    }

    func playerId(for disc: Disc) -> String {
        players[disc == .red ? 0 : 1]
    }

    func disc(row: Int, column: Int) -> Disc? {
        board[row * ConnectFourRules.columns + column]
    }

    var isStructurallyValid: Bool {
        board.count == ConnectFourRules.cellCount
            && players.count == 2
            && players[0] != players[1]
            && round >= 1
            && (lastMove.map { ConnectFourRules.cellRange.contains($0) } ?? true)
    }
}

/// Pure, deterministic Connect Four rules (7 columns × 6 rows, gravity drops).
nonisolated enum ConnectFourRules {
    static let columns = 7
    static let rows = 6
    static let cellCount = columns * rows
    static let cellRange = 0..<cellCount
    static let columnRange = 0..<columns

    static func newGame(players: [String], round: Int = 1) -> ConnectFourState {
        ConnectFourState(board: Array(repeating: nil, count: cellCount), players: players, turn: .red, outcome: nil, round: round, lastMove: nil)
    }

    /// Next round with seats swapped so the starting player alternates.
    static func rematch(from state: ConnectFourState) -> ConnectFourState {
        newGame(players: state.players.reversed(), round: state.round + 1)
    }

    /// Lowest free row in a column, or `nil` if the column is full.
    static func landingRow(in column: Int, of board: [ConnectFourState.Disc?]) -> Int? {
        (0..<rows).first { board[$0 * columns + column] == nil }
    }

    static func apply(column: Int, by playerId: String, to state: ConnectFourState) throws(MoveError) -> ConnectFourState {
        guard let disc = state.disc(for: playerId) else { throw .notAPlayer }
        guard state.outcome == nil else { throw .gameOver }
        guard disc == state.turn else { throw .notYourTurn }
        guard columnRange.contains(column) else { throw .outOfBounds }
        guard let row = landingRow(in: column, of: state.board) else { throw .columnFull }

        var next = state
        let index = row * columns + column
        next.board[index] = disc
        next.lastMove = index
        if let line = winningLine(through: index, in: next.board) {
            next.outcome = .win(disc, cells: line)
        } else if next.board.allSatisfy({ $0 != nil }) {
            next.outcome = .draw
        } else {
            next.turn = disc.other
        }
        return next
    }

    /// Checks the four line directions through the newly placed disc.
    static func winningLine(through index: Int, in board: [ConnectFourState.Disc?]) -> [Int]? {
        guard let disc = board[index] else { return nil }
        let row = index / columns, column = index % columns
        let directions = [(0, 1), (1, 0), (1, 1), (1, -1)] // horizontal, vertical, both diagonals

        for (dRow, dColumn) in directions {
            var cells = [index]
            for sign in [1, -1] {
                var r = row + dRow * sign, c = column + dColumn * sign
                while (0..<rows).contains(r), (0..<columns).contains(c), board[r * columns + c] == disc {
                    cells.append(r * columns + c)
                    r += dRow * sign
                    c += dColumn * sign
                }
            }
            if cells.count >= 4 { return cells.sorted() }
        }
        return nil
    }
}
