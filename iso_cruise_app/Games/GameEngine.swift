import Foundation

/// Dispatches generic game operations to each title's pure rules.
/// Only the host calls the mutating entry points.
nonisolated enum GameEngine {
    /// Host-side authoritative state. For Color Match this includes every hand and the
    /// deck order, so it is never sent as-is; see `projection(of:for:)`.
    enum State: Equatable, Sendable {
        case ticTacToe(TicTacToeState)
        case connectFour(ConnectFourState)
        case colorMatch(ColorMatchState)

        var isFinished: Bool {
            switch self {
            case .ticTacToe(let state): state.outcome != nil
            case .connectFour(let state): state.outcome != nil
            case .colorMatch(let state): state.roundResult != nil
            }
        }
    }

    /// Returns `nil` for an invalid seat count.
    static func newGame(_ type: GameType, seats: [String]) -> State? {
        var rng = SystemRandomNumberGenerator()
        return newGame(type, seats: seats, using: &rng)
    }

    static func newGame(_ type: GameType, seats: [String], using rng: inout some RandomNumberGenerator) -> State? {
        guard (type.minPlayers...type.maxPlayers).contains(seats.count), Set(seats).count == seats.count else { return nil }
        switch type {
        case .ticTacToe: return .ticTacToe(TicTacToeRules.newGame(players: seats))
        case .connectFour: return .connectFour(ConnectFourRules.newGame(players: seats))
        case .colorMatch: return .colorMatch(ColorMatchRules.newMatch(players: seats, using: &rng))
        }
    }

    static func apply(_ move: GameMove, by playerId: String, to state: State) throws(MoveError) -> State {
        var rng = SystemRandomNumberGenerator()
        switch (state, move) {
        case (.ticTacToe(let board), .ticTacToe(let cell)):
            return .ticTacToe(try TicTacToeRules.apply(cell: cell, by: playerId, to: board))
        case (.connectFour(let board), .connectFour(let column)):
            return .connectFour(try ConnectFourRules.apply(column: column, by: playerId, to: board))
        case (.colorMatch(let table), .colorMatch(let action)):
            return .colorMatch(try ColorMatchRules.apply(action, by: playerId, to: table, using: &rng))
        default:
            throw .wrongGame
        }
    }

    /// Rematch (board games) or next round / new match (Color Match).
    static func rematch(from state: State) -> State {
        var rng = SystemRandomNumberGenerator()
        switch state {
        case .ticTacToe(let board): return .ticTacToe(TicTacToeRules.rematch(from: board))
        case .connectFour(let board): return .connectFour(ConnectFourRules.rematch(from: board))
        case .colorMatch(let table): return .colorMatch(ColorMatchRules.nextRound(from: table, using: &rng))
        }
    }

    /// The view of the authoritative state a given player is allowed to see.
    static func projection(of state: State, for playerId: String) -> GameStateSnapshot {
        switch state {
        case .ticTacToe(let board): .ticTacToe(board)
        case .connectFour(let board): .connectFour(board)
        case .colorMatch(let table): .colorMatch(ColorMatchRules.snapshot(of: table, for: playerId))
        }
    }

    /// Moves that aren't tied to whose turn it is and may legitimately be sent out of
    /// order (Call One!/Catch!), so they skip the stale-revision check.
    static func isTurnIndependent(_ move: GameMove) -> Bool {
        if case .colorMatch(let action) = move {
            switch action {
            case .callOne, .catchOne: return true
            default: return false
            }
        }
        return false
    }
}

extension GameType {
    /// Titles that are fully implemented in this build.
    nonisolated var isPlayable: Bool { true }
}
