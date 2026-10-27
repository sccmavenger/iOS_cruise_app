/// Every title in CruiseLAN. Shared by the app and the cloud game server (compiled to
/// WebAssembly), so it uses only the Swift standard library.
nonisolated enum GameType: String, Codable, Sendable, CaseIterable, Identifiable {
    case ticTacToe
    case connectFour
    case colorMatch
    case checkers
    case chess
    case spades
    case tonk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ticTacToe: "Tic-Tac-Toe"
        case .connectFour: "Connect Four"
        case .colorMatch: "Color Match"
        case .checkers: "Checkers"
        case .chess: "Chess"
        case .spades: "Spades"
        case .tonk: "Tonk"
        }
    }

    var minPlayers: Int {
        switch self {
        case .ticTacToe, .connectFour, .checkers, .chess: 2
        case .colorMatch, .tonk: 2
        // Spades is partnerships, so it needs exactly four.
        case .spades: SpadesRules.playerCount
        }
    }

    var maxPlayers: Int {
        switch self {
        case .ticTacToe, .connectFour, .checkers, .chess: 2
        case .colorMatch, .tonk: 4
        case .spades: SpadesRules.playerCount
        }
    }
}
