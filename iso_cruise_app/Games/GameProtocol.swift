/// An action a player asks the host to perform. Clients never apply these locally;
/// the host validates them against the authoritative state.
nonisolated enum GameMove: Codable, Equatable, Sendable {
    case ticTacToe(cell: Int)
    case connectFour(column: Int)
    case colorMatch(ColorMatchAction)
    case checkers(CheckersAction)
    case chess(ChessAction)
    case spades(SpadesAction)
    case tonk(TonkAction)

    /// Cheap bounds check performed at decode time, before any game logic runs.
    var isStructurallyValid: Bool {
        switch self {
        case .ticTacToe(let cell): TicTacToeRules.cellRange.contains(cell)
        case .connectFour(let column): ConnectFourRules.columnRange.contains(column)
        case .colorMatch(let action): action.isStructurallyValid
        case .checkers(let action): action.isStructurallyValid
        case .chess(let action): action.isStructurallyValid
        case .spades(let action): action.isStructurallyValid
        case .tonk(let action): action.isStructurallyValid
        }
    }
}

/// The canonical state the host sends to one player. For hidden-information games
/// this is a per-recipient projection, never the full host state.
nonisolated enum GameStateSnapshot: Codable, Equatable, Sendable {
    case ticTacToe(TicTacToeState)
    case connectFour(ConnectFourState)
    case colorMatch(ColorMatchSnapshot)
    case checkers(CheckersState)
    case chess(ChessState)
    case spades(SpadesSnapshot)
    case tonk(TonkSnapshot)

    var gameType: GameType {
        switch self {
        case .ticTacToe: .ticTacToe
        case .connectFour: .connectFour
        case .colorMatch: .colorMatch
        case .checkers: .checkers
        case .chess: .chess
        case .spades: .spades
        case .tonk: .tonk
        }
    }

    var isStructurallyValid: Bool {
        switch self {
        case .ticTacToe(let state): state.isStructurallyValid
        case .connectFour(let state): state.isStructurallyValid
        case .colorMatch(let snapshot): snapshot.isStructurallyValid
        case .checkers(let state): state.isStructurallyValid
        case .chess(let state): state.isStructurallyValid
        case .spades(let snapshot): snapshot.isStructurallyValid
        case .tonk(let snapshot): snapshot.isStructurallyValid
        }
    }

    var playerIds: [String] {
        switch self {
        case .ticTacToe(let state): state.players
        case .connectFour(let state): state.players
        case .colorMatch(let snapshot): snapshot.players
        case .checkers(let state): state.players
        case .chess(let state): state.players
        case .spades(let snapshot): snapshot.players
        case .tonk(let snapshot): snapshot.players
        }
    }

    /// Players the game is waiting on right now: whoever's turn it is, or whoever must
    /// answer a Wild Draw Four. Empty once the round is over.
    var awaitingPlayerIds: Set<String> {
        switch self {
        case .ticTacToe(let state): state.outcome == nil ? [state.playerId(for: state.turn)] : []
        case .connectFour(let state): state.outcome == nil ? [state.playerId(for: state.turn)] : []
        case .colorMatch(let snapshot): snapshot.roundResult == nil ? [snapshot.drawFourTarget ?? snapshot.currentPlayer] : []
        case .checkers(let state): state.outcome == nil ? [state.playerId(for: state.turn)] : []
        case .chess(let state): state.outcome == nil ? [state.playerId(for: state.turn)] : []
        // Both card games wait on exactly one player, including during Spades bidding.
        case .spades(let snapshot): snapshot.phase == .handOver ? [] : [snapshot.currentPlayer]
        case .tonk(let snapshot): snapshot.phase == .roundOver ? [] : [snapshot.currentPlayer]
        }
    }

    /// The round is over and players can vote for a rematch / next round.
    var isFinished: Bool {
        switch self {
        case .ticTacToe(let state): state.outcome != nil
        case .connectFour(let state): state.outcome != nil
        case .colorMatch(let snapshot): snapshot.roundResult != nil
        case .checkers(let state): state.outcome != nil
        case .chess(let state): state.outcome != nil
        case .spades(let snapshot): snapshot.roundResult != nil
        case .tonk(let snapshot): snapshot.roundResult != nil
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
    case illegalMove
    case mustCapture
    case mustContinueJump
    case leavesKingInCheck
    case promotionRequired

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
        case .illegalMove: "That piece can't move there."
        case .mustCapture: "You have a jump available, and jumping is required."
        case .mustContinueJump: "Keep jumping with the same piece."
        case .leavesKingInCheck: "That would leave your king in check."
        case .promotionRequired: "Choose a piece for your pawn to become."
        }
    }
}
