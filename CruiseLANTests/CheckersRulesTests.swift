import Foundation
import Testing
@testable import iso_cruise_app

@Suite("Checkers rules")
struct CheckersRulesTests {
    let players = ["black-player", "red-player"]

    private func sq(_ row: Int, _ column: Int) -> Int { row * 8 + column }

    /// An empty board with only the given pieces.
    private func position(_ pieces: [Int: CheckersState.Piece], turn: CheckersState.Side = .black) -> CheckersState {
        var state = CheckersRules.newGame(players: players)
        state.board = Array(repeating: nil, count: CheckersRules.squareCount)
        for (square, piece) in pieces { state.board[square] = piece }
        state.turn = turn
        return state
    }

    private func move(_ from: Int, _ to: Int, in state: CheckersState) throws -> CheckersState {
        try CheckersRules.apply(.move(from: from, to: to), by: state.playerId(for: state.turn), to: state)
    }

    @Test("Setup: 12 pieces each on dark squares; Black moves first with 7 options")
    func setup() {
        let state = CheckersRules.newGame(players: players)
        #expect(state.count(.black) == 12)
        #expect(state.count(.red) == 12)
        #expect(state.board.indices.allSatisfy { state.board[$0] == nil || CheckersRules.isDark($0) })
        #expect(state.turn == .black)
        #expect(CheckersRules.legalSteps(in: state).count == 7)
    }

    @Test("Men move diagonally forward only")
    func menForwardOnly() throws {
        let state = position([sq(3, 3): .init(side: .black)])
        let steps = Set(CheckersRules.legalSteps(in: state).map(\.to))
        #expect(steps == [sq(4, 2), sq(4, 4)])
        #expect(throws: MoveError.illegalMove) { try move(sq(3, 3), sq(2, 2), in: state) }
    }

    @Test("Kings move one square in all four diagonal directions")
    func kingMoves() {
        let state = position([sq(3, 3): .init(side: .black, isKing: true)])
        #expect(Set(CheckersRules.legalSteps(in: state).map(\.to)) == [sq(4, 2), sq(4, 4), sq(2, 2), sq(2, 4)])
    }

    @Test("Captures are mandatory")
    func forcedCapture() throws {
        let state = position([sq(2, 2): .init(side: .black), sq(3, 3): .init(side: .red), sq(0, 6): .init(side: .black), sq(7, 7): .init(side: .red)])
        #expect(throws: MoveError.mustCapture) { try move(sq(0, 6), sq(1, 7), in: state) }
        let next = try move(sq(2, 2), sq(4, 4), in: state)
        #expect(next.board[sq(3, 3)] == nil)
        #expect(next.turn == .red)
    }

    @Test("A multi-jump continues with the same piece until no jumps remain")
    func multiJump() throws {
        let state = position([
            sq(0, 0): .init(side: .black),
            sq(1, 1): .init(side: .red),
            sq(3, 3): .init(side: .red),
            sq(7, 7): .init(side: .red),
        ])
        let first = try move(sq(0, 0), sq(2, 2), in: state)
        #expect(first.turn == .black)
        #expect(first.jumpingFrom == sq(2, 2))
        #expect(throws: MoveError.notYourTurn) { try CheckersRules.apply(.move(from: sq(7, 7), to: sq(6, 6)), by: "red-player", to: first) }
        let second = try move(sq(2, 2), sq(4, 4), in: first)
        #expect(second.jumpingFrom == nil)
        #expect(second.turn == .red)
        #expect(second.lastPath == [sq(0, 0), sq(2, 2), sq(4, 4)])
        #expect(second.count(.red) == 1)
    }

    @Test("Reaching the far row crowns a man and ends the turn, even mid-jump")
    func crowningEndsTurn() throws {
        // After jumping to row 7 a king could jump back over (6, 4), but the turn ends.
        let state = position([
            sq(5, 1): .init(side: .black),
            sq(6, 2): .init(side: .red),
            sq(6, 4): .init(side: .red),
            sq(4, 6): .init(side: .red),
        ])
        let next = try move(sq(5, 1), sq(7, 3), in: state)
        #expect(next.board[sq(7, 3)] == .init(side: .black, isKing: true))
        #expect(next.jumpingFrom == nil)
        #expect(next.turn == .red)
    }

    @Test("Capturing the last piece wins")
    func lastPieceWins() throws {
        let state = position([sq(2, 2): .init(side: .black), sq(3, 3): .init(side: .red)])
        let next = try move(sq(2, 2), sq(4, 4), in: state)
        #expect(next.outcome == .win(.black, byResignation: false))
        #expect(throws: MoveError.gameOver) { try move(sq(4, 4), sq(5, 5), in: next) }
    }

    @Test("A player with no legal move loses")
    func blockedLoses() throws {
        // Red's only man at (1, 1) is blocked by Black men it can't jump; Black's own
        // jumps over it are blocked too, so Black is free to make a quiet move.
        let state = position([
            sq(1, 1): .init(side: .red),
            sq(0, 0): .init(side: .black),
            sq(0, 2): .init(side: .black),
            sq(2, 0): .init(side: .black),
            sq(2, 2): .init(side: .black),
            sq(3, 5): .init(side: .black),
        ])
        let next = try move(sq(3, 5), sq(4, 6), in: state)
        #expect(next.outcome == .win(.black, byResignation: false))
    }

    @Test("40 moves each with no capture or man move is a draw")
    func fortyMoveRule() throws {
        var state = position([sq(0, 0): .init(side: .black, isKing: true), sq(7, 7): .init(side: .red, isKing: true)])
        state.quietMoves = CheckersRules.quietMoveLimit - 1
        let next = try move(sq(0, 0), sq(1, 1), in: state)
        #expect(next.outcome == .draw)
    }

    @Test("Out-of-turn, non-player, and off-board moves are rejected")
    func invalid() {
        let state = CheckersRules.newGame(players: players)
        #expect(throws: MoveError.notYourTurn) { try CheckersRules.apply(.move(from: sq(5, 1), to: sq(4, 0)), by: "red-player", to: state) }
        #expect(throws: MoveError.notAPlayer) { try CheckersRules.apply(.move(from: sq(2, 0), to: sq(3, 1)), by: "nobody", to: state) }
        #expect(throws: MoveError.outOfBounds) { try CheckersRules.apply(.move(from: sq(2, 0), to: 64), by: "black-player", to: state) }
        #expect(!CheckersAction.move(from: -1, to: 3).isStructurallyValid)
    }

    @Test("Resigning ends the round; rematch swaps who moves first")
    func resignAndRematch() throws {
        let state = CheckersRules.newGame(players: players)
        let resigned = try CheckersRules.apply(.resign, by: "red-player", to: state)
        #expect(resigned.outcome == .win(.black, byResignation: true))
        let next = CheckersRules.rematch(from: resigned)
        #expect(next.round == 2)
        #expect(next.playerId(for: .black) == "red-player")
    }
}
