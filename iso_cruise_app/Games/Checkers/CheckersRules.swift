import Foundation

/// What a checkers player asks the host to do. A multi-jump is sent one hop at a time.
nonisolated enum CheckersAction: Codable, Equatable, Sendable {
    case move(from: Int, to: Int)
    case resign

    var isStructurallyValid: Bool {
        switch self {
        case .move(let from, let to): CheckersRules.squareRange.contains(from) && CheckersRules.squareRange.contains(to)
        case .resign: true
        }
    }
}

nonisolated struct CheckersState: Codable, Equatable, Sendable {
    enum Side: String, Codable, Sendable {
        case black, red

        var other: Side { self == .black ? .red : .black }
        var name: String { self == .black ? "Black" : "Red" }
        /// Row direction this side's men advance in.
        var forward: Int { self == .black ? 1 : -1 }
        /// Row where this side's men are crowned.
        var crownRow: Int { self == .black ? CheckersRules.size - 1 : 0 }
    }

    struct Piece: Codable, Equatable, Sendable {
        var side: Side
        var isKing = false
    }

    enum Outcome: Codable, Equatable, Sendable {
        case win(Side, byResignation: Bool)
        case draw
    }

    /// Row-major from Black's back row: index = row * 8 + column. Only dark squares are used.
    var board: [Piece?]
    /// `players[0]` plays Black and moves first.
    var players: [String]
    var turn: Side
    var outcome: Outcome?
    var round: Int
    /// Set while a multi-jump is in progress: this piece must keep jumping.
    var jumpingFrom: Int?
    /// Squares visited by the most recent turn, for highlighting.
    var lastPath: [Int]
    /// Moves in a row with no capture and no man moved (40-move rule).
    var quietMoves: Int

    func side(for playerId: String) -> Side? {
        guard let index = players.firstIndex(of: playerId) else { return nil }
        return index == 0 ? .black : .red
    }

    func playerId(for side: Side) -> String {
        players[side == .black ? 0 : 1]
    }

    func count(_ side: Side) -> Int {
        board.count(where: { $0?.side == side })
    }

    var isStructurallyValid: Bool {
        board.count == CheckersRules.squareCount
            && players.count == 2
            && players[0] != players[1]
            && round >= 1
            && quietMoves >= 0
            && (jumpingFrom.map { CheckersRules.squareRange.contains($0) } ?? true)
            && lastPath.count <= 16
            && lastPath.allSatisfy { CheckersRules.squareRange.contains($0) }
    }
}

/// Pure, deterministic American checkers (English draughts), following WCDF rules:
/// - 8×8 board, 12 men each, Black moves first.
/// - Men move one square diagonally forward; kings one square in any diagonal direction.
/// - Captures are mandatory, and a multi-jump must be completed with the same piece,
///   though any capture sequence may be chosen.
/// - A man that reaches the far row is crowned and its turn ends, even mid-jump.
/// - A player with no pieces or no legal move loses.
/// - 40 moves each with no capture and no man moved is a draw.
nonisolated enum CheckersRules {
    static let size = 8
    static let squareCount = size * size
    static let squareRange = 0..<squareCount
    /// 40 moves by each player.
    static let quietMoveLimit = 80

    /// One hop. `captured` is the jumped square, if any.
    struct Step: Equatable, Hashable, Sendable {
        var from: Int
        var to: Int
        var captured: Int?
    }

    static func isDark(_ square: Int) -> Bool {
        (square / size + square % size) % 2 == 0
    }

    static func square(row: Int, column: Int) -> Int? {
        (0..<size).contains(row) && (0..<size).contains(column) ? row * size + column : nil
    }

    static func newGame(players: [String], round: Int = 1) -> CheckersState {
        var board = [CheckersState.Piece?](repeating: nil, count: squareCount)
        for index in squareRange where isDark(index) {
            switch index / size {
            case 0...2: board[index] = .init(side: .black)
            case 5...7: board[index] = .init(side: .red)
            default: break
            }
        }
        return CheckersState(board: board, players: players, turn: .black, outcome: nil, round: round, jumpingFrom: nil, lastPath: [], quietMoves: 0)
    }

    /// Next round with seats swapped so the first mover alternates.
    static func rematch(from state: CheckersState) -> CheckersState {
        newGame(players: state.players.reversed(), round: state.round + 1)
    }

    /// Every legal hop for the side to move, applying forced capture and jump continuation.
    static func legalSteps(in state: CheckersState) -> [Step] {
        guard state.outcome == nil else { return [] }
        if let from = state.jumpingFrom { return jumps(from: from, in: state.board) }
        let mine = squareRange.filter { state.board[$0]?.side == state.turn }
        let captures = mine.flatMap { jumps(from: $0, in: state.board) }
        if !captures.isEmpty { return captures }
        return mine.flatMap { simpleMoves(from: $0, in: state.board) }
    }

    private static func directions(for piece: CheckersState.Piece) -> [(row: Int, column: Int)] {
        let all = [(1, -1), (1, 1), (-1, -1), (-1, 1)]
        return piece.isKing ? all : all.filter { $0.0 == piece.side.forward }
    }

    static func simpleMoves(from: Int, in board: [CheckersState.Piece?]) -> [Step] {
        guard let piece = board[from] else { return [] }
        let row = from / size, column = from % size
        return directions(for: piece).compactMap { direction in
            guard let to = square(row: row + direction.row, column: column + direction.column), board[to] == nil else { return nil }
            return Step(from: from, to: to, captured: nil)
        }
    }

    static func jumps(from: Int, in board: [CheckersState.Piece?]) -> [Step] {
        guard let piece = board[from] else { return [] }
        let row = from / size, column = from % size
        return directions(for: piece).compactMap { direction in
            guard let over = square(row: row + direction.row, column: column + direction.column),
                  let to = square(row: row + 2 * direction.row, column: column + 2 * direction.column),
                  let victim = board[over], victim.side != piece.side,
                  board[to] == nil
            else { return nil }
            return Step(from: from, to: to, captured: over)
        }
    }

    static func apply(_ action: CheckersAction, by playerId: String, to state: CheckersState) throws(MoveError) -> CheckersState {
        guard let side = state.side(for: playerId) else { throw .notAPlayer }
        guard state.outcome == nil else { throw .gameOver }
        switch action {
        case .resign:
            var next = state
            next.outcome = .win(side.other, byResignation: true)
            next.jumpingFrom = nil
            return next
        case .move(let from, let to):
            guard side == state.turn else { throw .notYourTurn }
            guard squareRange.contains(from), squareRange.contains(to) else { throw .outOfBounds }
            let legal = legalSteps(in: state)
            guard let step = legal.first(where: { $0.from == from && $0.to == to }) else {
                if state.jumpingFrom != nil { throw .mustContinueJump }
                if legal.contains(where: { $0.captured != nil }) { throw .mustCapture }
                throw .illegalMove
            }
            return perform(step, in: state)
        }
    }

    /// Applies a step already known to be legal.
    private static func perform(_ step: Step, in state: CheckersState) -> CheckersState {
        guard var piece = state.board[step.from] else { return state }
        var next = state
        let wasMan = !piece.isKing
        next.board[step.from] = nil
        if let captured = step.captured { next.board[captured] = nil }
        let crowned = wasMan && step.to / size == piece.side.crownRow
        if crowned { piece.isKing = true }
        next.board[step.to] = piece
        next.lastPath = state.jumpingFrom == nil ? [step.from, step.to] : state.lastPath + [step.to]
        next.quietMoves = (step.captured != nil || wasMan) ? 0 : state.quietMoves + 1

        // The same piece keeps jumping unless it was just crowned.
        if step.captured != nil, !crowned, !jumps(from: step.to, in: next.board).isEmpty {
            next.jumpingFrom = step.to
            return next
        }
        next.jumpingFrom = nil
        next.turn = piece.side.other
        if legalSteps(in: next).isEmpty {
            next.outcome = .win(piece.side, byResignation: false)
        } else if next.quietMoves >= quietMoveLimit {
            next.outcome = .draw
        }
        return next
    }
}
