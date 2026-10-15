import Foundation
import Testing
@testable import iso_cruise_app

@Suite("Connect Four rules")
struct ConnectFourRulesTests {
    let players = ["red-player", "yellow-player"]

    private func play(_ columns: [Int]) throws -> ConnectFourState {
        var state = ConnectFourRules.newGame(players: players)
        for column in columns {
            state = try ConnectFourRules.apply(column: column, by: state.playerId(for: state.turn), to: state)
        }
        return state
    }

    @Test("Discs fall to the lowest free cell")
    func gravity() throws {
        let state = try play([3, 3, 3])
        #expect(state.disc(row: 0, column: 3) == .red)
        #expect(state.disc(row: 1, column: 3) == .yellow)
        #expect(state.disc(row: 2, column: 3) == .red)
        #expect(state.disc(row: 3, column: 3) == nil)
    }

    @Test("Horizontal win")
    func horizontal() throws {
        let state = try play([0, 0, 1, 1, 2, 2, 3])
        #expect(state.outcome == .win(.red, cells: [0, 1, 2, 3]))
    }

    @Test("Vertical win")
    func vertical() throws {
        let state = try play([4, 5, 4, 5, 4, 5, 4])
        guard case .win(.red, let cells) = state.outcome else {
            Issue.record("Expected red win")
            return
        }
        #expect(cells == [4, 11, 18, 25])
    }

    @Test("Rising diagonal win")
    func risingDiagonal() throws {
        // Red builds 0,0 → 1,1 → 2,2 → 3,3
        let state = try play([0, 1, 1, 2, 2, 3, 2, 3, 3, 6, 3])
        guard case .win(.red, let cells) = state.outcome else {
            Issue.record("Expected red win, got \(String(describing: state.outcome))")
            return
        }
        #expect(cells == [0, 8, 16, 24])
    }

    @Test("Falling diagonal win")
    func fallingDiagonal() throws {
        // Red builds 3,0 → 2,1 → 1,2 → 0,3
        let state = try play([3, 2, 2, 1, 1, 0, 1, 0, 0, 6, 0])
        guard case .win(.red, let cells) = state.outcome else {
            Issue.record("Expected red win, got \(String(describing: state.outcome))")
            return
        }
        #expect(cells == [3, 9, 15, 21])
    }

    @Test("Full column is rejected and the board is unchanged")
    func fullColumn() throws {
        let state = try play([0, 0, 0, 0, 0, 0])
        #expect(throws: MoveError.columnFull) { try ConnectFourRules.apply(column: 0, by: "red-player", to: state) }
    }

    @Test("Out-of-turn, out-of-range, and non-player moves are rejected")
    func invalid() {
        let state = ConnectFourRules.newGame(players: players)
        #expect(throws: MoveError.notYourTurn) { try ConnectFourRules.apply(column: 0, by: "yellow-player", to: state) }
        #expect(throws: MoveError.outOfBounds) { try ConnectFourRules.apply(column: 7, by: "red-player", to: state) }
        #expect(throws: MoveError.notAPlayer) { try ConnectFourRules.apply(column: 0, by: "nobody", to: state) }
    }

    @Test("Full board with no line is a draw")
    func draw() throws {
        // Column order that fills the board without four in a row.
        let order = [0, 1, 0, 1, 0, 1, 2, 3, 2, 3, 2, 3, 4, 5, 4, 5, 4, 5, 6, 0, 1, 0, 1, 0, 1, 2, 3, 2, 3, 2, 3, 4, 5, 4, 5, 4, 5, 6, 6, 6, 6, 6]
        let state = try play(order)
        #expect(state.board.allSatisfy { $0 != nil })
        #expect(state.outcome == .draw)
    }

    @Test("Board locks after a win; rematch alternates the starting player")
    func lockAndRematch() throws {
        let won = try play([0, 0, 1, 1, 2, 2, 3])
        #expect(throws: MoveError.gameOver) { try ConnectFourRules.apply(column: 5, by: "yellow-player", to: won) }
        let next = ConnectFourRules.rematch(from: won)
        #expect(next.round == 2)
        #expect(next.playerId(for: .red) == "yellow-player")
        #expect(next.turn == .red)
    }
}
