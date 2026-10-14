import Foundation

/// An action a player asks the host to perform. Clients never apply these locally;
/// the host validates them against the authoritative state.
nonisolated enum GameMove: Codable, Equatable, Sendable {
    case ticTacToe(cell: Int)

    /// Cheap bounds check performed at decode time, before any game logic runs.
    var isStructurallyValid: Bool {
        switch self {
        case .ticTacToe(let cell):
            TicTacToeRules.cellRange.contains(cell)
        }
    }
}

/// The canonical game state broadcast by the host. For hidden-information games this
/// is a per-recipient projection, never the full host state.
nonisolated enum GameStateSnapshot: Codable, Equatable, Sendable {
    case ticTacToe(TicTacToeState)

    var gameType: GameType {
        switch self {
        case .ticTacToe: .ticTacToe
        }
    }

    var isStructurallyValid: Bool {
        switch self {
        case .ticTacToe(let state):
            state.isStructurallyValid
        }
    }

    var playerIds: [String] {
        switch self {
        case .ticTacToe(let state): state.players
        }
    }

    var isFinished: Bool {
        switch self {
        case .ticTacToe(let state): state.outcome != nil
        }
    }
}

/// Reasons the host refuses a move. Invalid moves never change state.
nonisolated enum MoveError: Error, Equatable, Sendable {
    case notAPlayer
    case notYourTurn
    case gameOver
    case occupied
    case outOfBounds
    case wrongGame

    var message: String {
        switch self {
        case .notAPlayer: "You're not seated in this game."
        case .notYourTurn: "It's not your turn."
        case .gameOver: "This round is already over."
        case .occupied: "That square is already taken."
        case .outOfBounds: "That move isn't on the board."
        case .wrongGame: "That move doesn't belong to this game."
        }
    }
}
