import Foundation

/// Dispatches generic game operations to each title's pure rules.
/// Only the host calls the mutating entry points.
nonisolated enum GameEngine {
    /// Returns `nil` for titles that aren't playable in this build or for an invalid seat count.
    static func newGame(_ type: GameType, seats: [String]) -> GameStateSnapshot? {
        guard (type.minPlayers...type.maxPlayers).contains(seats.count), Set(seats).count == seats.count else { return nil }
        switch type {
        case .ticTacToe:
            return .ticTacToe(TicTacToeRules.newGame(players: seats))
        case .connectFour, .colorMatch:
            return nil
        }
    }

    static func apply(_ move: GameMove, by playerId: String, to state: GameStateSnapshot) throws(MoveError) -> GameStateSnapshot {
        switch (state, move) {
        case (.ticTacToe(let board), .ticTacToe(let cell)):
            .ticTacToe(try TicTacToeRules.apply(cell: cell, by: playerId, to: board))
        }
    }

    static func rematch(from state: GameStateSnapshot) -> GameStateSnapshot {
        switch state {
        case .ticTacToe(let board):
            .ticTacToe(TicTacToeRules.rematch(from: board))
        }
    }

    /// The view of the authoritative state that a given player is allowed to see.
    /// Perfect-information games share one view; hidden-information games must override this.
    static func projection(of state: GameStateSnapshot, for playerId: String) -> GameStateSnapshot {
        state
    }
}

extension GameType {
    /// Titles that are fully implemented in this build.
    nonisolated var isPlayable: Bool {
        switch self {
        case .ticTacToe: true
        case .connectFour, .colorMatch: false
        }
    }
}
