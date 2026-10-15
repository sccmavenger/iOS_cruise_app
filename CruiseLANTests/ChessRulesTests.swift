import Foundation
import Testing
@testable import iso_cruise_app

@Suite("Chess rules")
struct ChessRulesTests {
    let players = ["white", "black"]

    /// Counts leaf nodes of the legal move tree; the standard check for move generators.
    private func perft(_ state: ChessState, depth: Int) -> Int {
        let moves = ChessRules.legalMoves(in: state)
        if depth == 1 { return moves.count }
        return moves.reduce(0) { $0 + perft(ChessRules.perform($1, in: state), depth: depth - 1) }
    }

    private func square(_ name: String) -> Int {
        let characters = Array(name)
        return Int(characters[0].asciiValue! - 97) + (characters[1].wholeNumberValue! - 1) * 8
    }

    /// Plays algebraic from-to pairs such as "e2e4", alternating sides.
    private func play(_ moves: [String], from start: ChessState? = nil) throws -> ChessState {
        var state = start ?? ChessRules.newGame(players: players)
        for move in moves {
            let from = square(String(move.prefix(2))), to = square(String(move.dropFirst(2).prefix(2)))
            let promotion: ChessPiece.Kind? = move.count == 5 ? ChessPiece(fenSymbol: move.last!)?.kind : nil
            state = try ChessRules.apply(.move(from: from, to: to, promotion: promotion), by: state.playerId(for: state.turn), to: state)
        }
        return state
    }

    // MARK: - Move generation (published perft counts)

    @Test("Starting position perft 1–3: 20, 400, 8,902")
    func perftStart() {
        let start = ChessRules.newGame(players: players)
        #expect(perft(start, depth: 1) == 20)
        #expect(perft(start, depth: 2) == 400)
        #expect(perft(start, depth: 3) == 8_902)
    }

    @Test("Kiwipete perft 1–2: 48, 2,039 (castling, en passant, promotion)")
    func perftKiwipete() throws {
        let state = try #require(ChessRules.state(fen: "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"))
        #expect(perft(state, depth: 1) == 48)
        #expect(perft(state, depth: 2) == 2_039)
    }

    @Test("Position 3 perft 1–3: 14, 191, 2,812 (en passant pins)")
    func perftPosition3() throws {
        let state = try #require(ChessRules.state(fen: "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"))
        #expect(perft(state, depth: 1) == 14)
        #expect(perft(state, depth: 2) == 191)
        #expect(perft(state, depth: 3) == 2_812)
    }

    @Test("Position 4 perft 1–2: 6, 264 (promotions while in check)")
    func perftPosition4() throws {
        let state = try #require(ChessRules.state(fen: "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1"))
        #expect(perft(state, depth: 1) == 6)
        #expect(perft(state, depth: 2) == 264)
    }

    @Test("Position 5 perft 1–2: 44, 1,486")
    func perftPosition5() throws {
        let state = try #require(ChessRules.state(fen: "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8"))
        #expect(perft(state, depth: 1) == 44)
        #expect(perft(state, depth: 2) == 1_486)
    }

    // MARK: - Applying moves

    @Test("Fool's mate is checkmate for Black")
    func foolsMate() throws {
        let state = try play(["f2f3", "e7e5", "g2g4", "d8h4"])
        #expect(state.outcome == .checkmate(winner: .black))
        #expect(throws: MoveError.gameOver) { try play(["e2e4"], from: state) }
    }

    @Test("Castling moves the rook; moving the king removes both rights")
    func castling() throws {
        let state = try play(["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "e1g1"])
        #expect(state.board[square("g1")] == ChessPiece(.white, .king))
        #expect(state.board[square("f1")] == ChessPiece(.white, .rook))
        #expect(state.board[square("h1")] == nil)
        #expect(!state.castling.whiteKingside && !state.castling.whiteQueenside)
        #expect(state.castling.blackKingside)
    }

    @Test("Can't castle through an attacked square")
    func castlingThroughCheck() throws {
        let state = try #require(ChessRules.state(fen: "4k3/8/8/8/8/8/5r2/4K2R w K - 0 1"))
        #expect(throws: MoveError.self) { try play(["e1g1"], from: state) }
    }

    @Test("En passant captures the passed pawn and is only available immediately")
    func enPassant() throws {
        let state = try play(["e2e4", "a7a6", "e4e5", "d7d5", "e5d6"])
        #expect(state.board[square("d5")] == nil)
        #expect(state.board[square("d6")] == ChessPiece(.white, .pawn))

        let missed = try play(["e2e4", "a7a6", "e4e5", "d7d5", "h2h3", "a6a5"])
        #expect(throws: MoveError.illegalMove) { try play(["e5d6"], from: missed) }
    }

    @Test("Promotion requires a choice and places the chosen piece")
    func promotion() throws {
        let state = try #require(ChessRules.state(fen: "8/P6k/8/8/8/8/8/K7 w - - 0 1"))
        #expect(throws: MoveError.promotionRequired) { try play(["a7a8"], from: state) }
        let promoted = try play(["a7a8n"], from: state)
        #expect(promoted.board[square("a8")] == ChessPiece(.white, .knight))
    }

    @Test("Moves that expose the king are rejected with a clear reason")
    func pinned() throws {
        let state = try #require(ChessRules.state(fen: "4k3/4r3/8/8/8/8/4B3/4K3 w - - 0 1"))
        #expect(throws: MoveError.leavesKingInCheck) { try play(["e2d3"], from: state) }
    }

    @Test("Out-of-turn, non-player, and malformed moves are rejected")
    func invalid() {
        let state = ChessRules.newGame(players: players)
        #expect(throws: MoveError.notYourTurn) { try ChessRules.apply(.move(from: 52, to: 36, promotion: nil), by: "black", to: state) }
        #expect(throws: MoveError.notAPlayer) { try ChessRules.apply(.move(from: 12, to: 28, promotion: nil), by: "nobody", to: state) }
        #expect(throws: MoveError.illegalMove) { try ChessRules.apply(.move(from: 12, to: 36, promotion: nil), by: "white", to: state) }
        #expect(throws: MoveError.illegalMove) { try ChessRules.apply(.move(from: 12, to: 28, promotion: .queen), by: "white", to: state) }
        #expect(!ChessAction.move(from: 12, to: 28, promotion: .king).isStructurallyValid)
        #expect(!ChessAction.move(from: 64, to: 28, promotion: nil).isStructurallyValid)
    }

    // MARK: - Endings

    @Test("Stalemate is a draw")
    func stalemate() throws {
        let state = try #require(ChessRules.state(fen: "7k/8/6Q1/8/8/8/8/K7 w - - 0 1"))
        let next = try play(["g6f7"], from: state)
        #expect(next.outcome == .draw(.stalemate))
    }

    @Test("Bare kings and lone minor pieces are dead draws")
    func insufficientMaterial() throws {
        // The white king takes the last black piece, leaving bare kings.
        let bare = try #require(ChessRules.state(fen: "7k/8/8/8/8/8/1q6/K7 w - - 0 1"))
        #expect(try play(["a1b2"], from: bare).outcome == .draw(.insufficientMaterial))
        #expect(ChessRules.hasInsufficientMaterial(try #require(ChessRules.state(fen: "k7/8/8/8/8/8/8/KB6 w - - 0 1")).board))
        #expect(!ChessRules.hasInsufficientMaterial(try #require(ChessRules.state(fen: "k7/8/8/8/8/8/8/KBB5 w - - 0 1")).board))
    }

    @Test("Threefold repetition is a draw")
    func repetition() throws {
        let state = try play(["g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1", "f6g8"])
        #expect(state.outcome == .draw(.repetition))
    }

    @Test("50 moves without a capture or pawn move is a draw")
    func fiftyMoves() throws {
        let state = try #require(ChessRules.state(fen: "k7/8/8/8/8/8/8/K6R w - - 99 80"))
        #expect(try play(["h1h2"], from: state).outcome == .draw(.fiftyMoves))
    }

    @Test("Resigning ends the game; rematch swaps colors")
    func resignAndRematch() throws {
        let state = ChessRules.newGame(players: players)
        let resigned = try ChessRules.apply(.resign, by: "black", to: state)
        #expect(resigned.outcome == .resignation(winner: .white))
        let next = ChessRules.rematch(from: resigned)
        #expect(next.round == 2)
        #expect(next.playerId(for: .white) == "black")
        #expect(next.outcome == nil)
    }

    @Test("A long game's snapshot stays well under the envelope limit")
    func snapshotSize() throws {
        var state = try #require(ChessRules.state(fen: "k7/8/8/8/8/8/8/K6R w - - 0 1"))
        state.positionHistory = Array(repeating: String(repeating: "x", count: 70), count: ChessRules.fiftyMoveLimit)
        let data = try JSONEncoder().encode(GameStateSnapshot.chess(state))
        #expect(data.count < EnvelopeCodec.maxEnvelopeBytes / 2)
    }
}
