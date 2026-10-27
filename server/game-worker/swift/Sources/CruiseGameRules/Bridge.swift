#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif


/// SplitMix64: deterministic generator used when the caller passes a seed (golden tests).
public struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// One JSON request in, one JSON response out: the whole surface the Room Durable Object sees.
/// Ops: `new` (game, seats), `apply` (state, seat, move), `rematch` (state), `views` (state).
public enum Bridge {
    struct Request: Decodable {
        var op: String
        var game: GameType?
        var seats: [String]?
        var state: GameEngine.State?
        var seat: String?
        var move: GameMove?
        /// Decimal string so JavaScript never rounds it. Absent: system randomness (WASI random_get).
        var seed: String?
    }

    struct Response: Encodable {
        var ok: Bool
        var error: String?
        var message: String?
        var state: GameEngine.State?
        var views: [String: GameStateSnapshot]?
        var awaiting: [String]?
        var finished: Bool?
        /// Call One!/Catch!/resign: allowed even if the player's view is a revision behind.
        var turnIndependent: Bool?
        /// `legalMoves` only: every legal move for whoever is up (board games; used by test bots).
        var moves: [GameMove]?
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static func handle(_ input: String) -> String {
        let response: Response
        do {
            let request = try JSONDecoder().decode(Request.self, from: Data(input.utf8))
            response = run(request)
        } catch {
            response = Response(ok: false, error: "badRequest", message: "\(error)".prefix(300).description)
        }
        guard let data = try? encoder.encode(response) else { return #"{"ok":false,"error":"encodeFailed"}"# }
        return String(decoding: data, as: UTF8.self)
    }

    static func run(_ request: Request) -> Response {
        if let seed = request.seed, let value = UInt64(seed) {
            var rng = SplitMix64(seed: value)
            return run(request, using: &rng)
        }
        var rng = SystemRandomNumberGenerator()
        return run(request, using: &rng)
    }

    static func run(_ request: Request, using rng: inout some RandomNumberGenerator) -> Response {
        switch request.op {
        case "new":
            guard let game = request.game, let seats = request.seats,
                  let state = GameEngine.newGame(game, seats: seats, using: &rng)
            else { return Response(ok: false, error: "badSeats") }
            return result(state, seats: seats)
        case "apply":
            guard let state = request.state, let seat = request.seat, let move = request.move else { return Response(ok: false, error: "badRequest") }
            let turnIndependent = GameEngine.isTurnIndependent(move)
            guard move.isStructurallyValid else {
                return Response(ok: false, error: "outOfBounds", message: MoveError.outOfBounds.message, turnIndependent: turnIndependent)
            }
            do {
                var response = result(try GameEngine.apply(move, by: seat, to: state, using: &rng), seats: seats(of: state))
                response.turnIndependent = turnIndependent
                return response
            } catch {
                return Response(ok: false, error: "\(error)", message: error.message, turnIndependent: turnIndependent)
            }
        case "rematch":
            guard let state = request.state else { return Response(ok: false, error: "badRequest") }
            return result(GameEngine.rematch(from: state, using: &rng), seats: seats(of: state))
        case "legalMoves":
            // For test players: board games' states are public, so a bot holding the view can ask.
            guard let state = request.state else { return Response(ok: false, error: "badRequest") }
            let moves: [GameMove] = switch state {
            case .ticTacToe(let s): s.board.indices.filter { s.board[$0] == nil }.map { .ticTacToe(cell: $0) }
            case .connectFour(let s): ConnectFourRules.columnRange.filter { ConnectFourRules.landingRow(in: $0, of: s.board) != nil }.map { .connectFour(column: $0) }
            case .checkers(let s): CheckersRules.legalSteps(in: s).map { .checkers(.move(from: $0.from, to: $0.to)) }
            case .chess(let s): ChessRules.legalMoves(in: s).map { .chess(.move(from: $0.from, to: $0.to, promotion: $0.promotion)) }
            case .colorMatch, .spades, .tonk: []
            }
            return Response(ok: true, moves: moves)
        case "views":
            // Current projections without changing anything: used when a player resumes.
            guard let state = request.state else { return Response(ok: false, error: "badRequest") }
            return result(state, seats: seats(of: state))
        default:
            return Response(ok: false, error: "unknownOp")
        }
    }

    static func seats(of state: GameEngine.State) -> [String] {
        GameEngine.projection(of: state, for: "").playerIds
    }

    static func result(_ state: GameEngine.State, seats: [String]) -> Response {
        var views: [String: GameStateSnapshot] = [:]
        for seat in seats { views[seat] = GameEngine.projection(of: state, for: seat) }
        let awaiting = views[seats[0]]?.awaitingPlayerIds ?? []
        return Response(ok: true, state: state, views: views, awaiting: seats.filter { awaiting.contains($0) }, finished: state.isFinished)
    }
}
