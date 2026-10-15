import Foundation

/// An action a player asks the host to perform. Clients never apply these locally;
/// the host validates them against the authoritative state.
nonisolated enum GameMove: Codable, Equatable, Sendable {
    case ticTacToe(cell: Int)
    case connectFour(column: Int)
    case colorMatch(ColorMatchAction)

    /// Cheap bounds check performed at decode time, before any game logic runs.
    var isStructurallyValid: Bool {
        switch self {
        case .ticTacToe(let cell): TicTacToeRules.cellRange.contains(cell)
        case .connectFour(let column): ConnectFourRules.columnRange.contains(column)
        case .colorMatch(let action): action.isStructurallyValid
        }
    }
}

/// The canonical state the host sends to one player. For hidden-information games
/// this is a per-recipient projection, never the full host state.
nonisolated enum GameStateSnapshot: Codable, Equatable, Sendable {
    case ticTacToe(TicTacToeState)
    case connectFour(ConnectFourState)
    case colorMatch(ColorMatchSnapshot)

    var gameType: GameType {
        switch self {
        case .ticTacToe: .ticTacToe
        case .connectFour: .connectFour
        case .colorMatch: .colorMatch
        }
    }

    var isStructurallyValid: Bool {
        switch self {
        case .ticTacToe(let state): state.isStructurallyValid
        case .connectFour(let state): state.isStructurallyValid
        case .colorMatch(let snapshot): snapshot.isStructurallyValid
        }
    }

    var playerIds: [String] {
        switch self {
        case .ticTacToe(let state): state.players
        case .connectFour(let state): state.players
        case .colorMatch(let snapshot): snapshot.players
        }
    }

    /// The round is over and players can vote for a rematch / next round.
    var isFinished: Bool {
        switch self {
        case .ticTacToe(let state): state.outcome != nil
        case .connectFour(let state): state.outcome != nil
        case .colorMatch(let snapshot): snapshot.roundResult != nil
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
    case columnFull
    case notAllowed
    case notInHand
    case illegalCard
    case colorRequired

    var message: String {
        switch self {
        case .notAPlayer: "You're not seated in this game."
        case .notYourTurn: "It's not your turn."
        case .gameOver: "This round is already over."
        case .occupied: "That square is already taken."
        case .outOfBounds: "That move isn't on the board."
        case .wrongGame: "That move doesn't belong to this game."
        case .columnFull: "That column is full."
        case .notAllowed: "You can't do that right now."
        case .notInHand: "That card isn't in your hand."
        case .illegalCard: "That card doesn't match. Play a matching color, number, or symbol, or draw."
        case .colorRequired: "Pick a color for your wild card."
        }
    }
}
