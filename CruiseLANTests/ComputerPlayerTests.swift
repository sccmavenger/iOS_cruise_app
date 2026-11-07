import Foundation
import Testing
@testable import iso_cruise_app

@Suite("Computer player")
struct ComputerPlayerTests {
    static let computer = ComputerPlayer.playerId

    /// Plays the computer against itself-as-both-seats is impossible (one id), so a second
    /// copy of the computer plays the other seat by swapping ids each turn.
    private func selfPlay(_ type: GameType, maxTurns: Int = 600) throws -> GameEngine.State {
        let other = "human"
        var state = try #require(GameEngine.newGame(type, seats: [Self.computer, other]))
        for _ in 0..<maxTurns where !state.isFinished {
            let mover = GameEngine.projection(of: state, for: Self.computer).awaitingPlayerIds.first ?? Self.computer
            // Ask for the computer's move from the mover's point of view by relabeling seats.
            let view = mover == Self.computer ? state : relabel(state, swapping: Self.computer, with: other)
            let move = try #require(ComputerPlayer.move(in: view), "no move for \(type)")
            state = try GameEngine.apply(move, by: mover, to: state)
        }
        return state
    }

    private func relabel(_ state: GameEngine.State, swapping a: String, with b: String) -> GameEngine.State {
        let swap: ([String]) -> [String] = { $0.map { $0 == a ? b : $0 == b ? a : $0 } }
        switch state {
        case .ticTacToe(var s): s.players = swap(s.players); return .ticTacToe(s)
        case .connectFour(var s): s.players = swap(s.players); return .connectFour(s)
        case .checkers(var s): s.players = swap(s.players); return .checkers(s)
        case .chess(var s): s.players = swap(s.players); return .chess(s)
        default: return state
        }
    }

    @Test("Plays only legal moves through to the end", arguments: [GameType.ticTacToe, .connectFour, .checkers])
    func playsToTheEnd(_ type: GameType) throws {
        #expect(try selfPlay(type).isFinished)
    }

    @Test("Plays legal chess moves")
    func chessLegal() throws {
        // A full chess game can run long; legality over many plies is what matters here.
        _ = try selfPlay(.chess, maxTurns: 60)
    }

    @Test("Takes a winning Tic-Tac-Toe move")
    func takesWin() throws {
        var state = TicTacToeRules.newGame(players: [Self.computer, "human"])
        state.board = [.x, .x, nil, .o, .o, nil, nil, nil, nil]
        #expect(ComputerPlayer.move(in: .ticTacToe(state)) == .ticTacToe(cell: 2))
    }

    @Test("Blocks a Connect Four win")
    func blocks() throws {
        var state = ConnectFourRules.newGame(players: ["human", Self.computer])
        for column in [0, 1, 2] { state.board[column] = .red }
        state.board[7] = .yellow
        state.turn = .yellow
        #expect(ComputerPlayer.move(in: .connectFour(state)) == .connectFour(column: 3))
    }

    @Test("Does nothing when it isn't its turn, or for card games")
    func notItsTurn() throws {
        let board = TicTacToeRules.newGame(players: ["human", Self.computer])
        #expect(ComputerPlayer.move(in: .ticTacToe(board)) == nil)
        #expect(!ComputerPlayer.supports(.spades))
    }
}

@MainActor
@Suite("Playing the computer")
struct PlayComputerTests {
    @Test("Starts at once, the computer answers each move, and agrees to a rematch")
    func fullGame() async throws {
        let network = FakeNetwork()
        let me = network.addNode("Solo")
        let games = me.games
        games.playComputer(.ticTacToe)
        #expect(games.lobby?.phase == .playing)
        #expect(games.isComputerGame)
        // Nothing goes over the network for a game against the computer.
        #expect(network.log.isEmpty)

        // Play the first free cell whenever it's our turn, until the game ends.
        for _ in 0..<20 {
            guard case .ticTacToe(let board) = games.snapshot, board.outcome == nil else { break }
            if games.isAwaitingMe, let cell = board.board.firstIndex(where: { $0 == nil }) {
                games.play(.ticTacToe(cell: cell))
            } else {
                try await Task.sleep(for: .seconds(1))
            }
        }
        #expect(games.snapshot?.isFinished == true)
        let round = games.snapshot.flatMap { if case .ticTacToe(let b) = $0 { b.round } else { nil } }
        games.requestRematch()
        let nextRound = games.snapshot.flatMap { if case .ticTacToe(let b) = $0 { b.round } else { nil } }
        #expect(nextRound == (round ?? 0) + 1)
    }
}
