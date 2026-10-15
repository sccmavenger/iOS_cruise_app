import Foundation

nonisolated struct ChessPiece: Codable, Equatable, Hashable, Sendable {
    enum Color: String, Codable, Sendable {
        case white, black

        var other: Color { self == .white ? .black : .white }
        var name: String { self == .white ? "White" : "Black" }
        /// Rank direction this color's pawns advance in.
        var forward: Int { self == .white ? 1 : -1 }
    }

    enum Kind: String, Codable, Sendable, CaseIterable {
        case king, queen, rook, bishop, knight, pawn

        static let promotions: [Kind] = [.queen, .rook, .bishop, .knight]

        var name: String { rawValue.capitalized }
    }

    var color: Color
    var kind: Kind

    init(_ color: Color, _ kind: Kind) {
        self.color = color
        self.kind = kind
    }

    /// FEN letter: uppercase for White.
    var fenSymbol: Character {
        let letter: Character = switch kind {
        case .king: "k"
        case .queen: "q"
        case .rook: "r"
        case .bishop: "b"
        case .knight: "n"
        case .pawn: "p"
        }
        return color == .white ? Character(letter.uppercased()) : letter
    }

    init?(fenSymbol: Character) {
        let kind: Kind
        switch fenSymbol.lowercased() {
        case "k": kind = .king
        case "q": kind = .queen
        case "r": kind = .rook
        case "b": kind = .bishop
        case "n": kind = .knight
        case "p": kind = .pawn
        default: return nil
        }
        self.init(fenSymbol.isUppercase ? .white : .black, kind)
    }
}

/// What a chess player asks the host to do.
nonisolated enum ChessAction: Codable, Equatable, Sendable {
    case move(from: Int, to: Int, promotion: ChessPiece.Kind?)
    case resign

    var isStructurallyValid: Bool {
        switch self {
        case .move(let from, let to, let promotion):
            ChessRules.squareRange.contains(from) && ChessRules.squareRange.contains(to)
                && (promotion.map { ChessPiece.Kind.promotions.contains($0) } ?? true)
        case .resign:
            true
        }
    }
}

nonisolated struct ChessMove: Equatable, Hashable, Sendable {
    var from: Int
    var to: Int
    var promotion: ChessPiece.Kind?
}

nonisolated struct ChessState: Codable, Equatable, Sendable {
    struct CastlingRights: Codable, Equatable, Sendable {
        var whiteKingside = true
        var whiteQueenside = true
        var blackKingside = true
        var blackQueenside = true
    }

    enum DrawReason: String, Codable, Sendable {
        case stalemate, insufficientMaterial, fiftyMoves, repetition
    }

    enum Outcome: Codable, Equatable, Sendable {
        case checkmate(winner: ChessPiece.Color)
        case resignation(winner: ChessPiece.Color)
        case draw(DrawReason)
    }

    struct LastMove: Codable, Equatable, Sendable {
        var from: Int
        var to: Int
    }

    /// index = rank * 8 + file, with rank 0 being White's back rank (a1 = 0, h8 = 63).
    var board: [ChessPiece?]
    /// `players[0]` plays White and moves first.
    var players: [String]
    var turn: ChessPiece.Color
    var castling: CastlingRights
    /// Square a pawn may capture onto en passant this move.
    var enPassant: Int?
    /// Plies since the last capture or pawn move (50-move rule).
    var halfmoveClock: Int
    var fullmoveNumber: Int
    /// Position keys since the last capture or pawn move, including the current one.
    var positionHistory: [String]
    var outcome: Outcome?
    var round: Int
    var lastMove: LastMove?
    /// Pieces taken so far, in order. Shown beside the board; promotions don't add here.
    var capturedPieces: [ChessPiece] = []

    func color(for playerId: String) -> ChessPiece.Color? {
        guard let index = players.firstIndex(of: playerId) else { return nil }
        return index == 0 ? .white : .black
    }

    func playerId(for color: ChessPiece.Color) -> String {
        players[color == .white ? 0 : 1]
    }

    var isStructurallyValid: Bool {
        board.count == ChessRules.squareCount
            && players.count == 2
            && players[0] != players[1]
            && round >= 1
            && halfmoveClock >= 0
            && fullmoveNumber >= 1
            && (enPassant.map { ChessRules.squareRange.contains($0) } ?? true)
            && (lastMove.map { ChessRules.squareRange.contains($0.from) && ChessRules.squareRange.contains($0.to) } ?? true)
            && positionHistory.count <= ChessRules.fiftyMoveLimit + 1
            && positionHistory.allSatisfy { $0.count <= 80 }
            && capturedPieces.count <= 30
    }
}

/// Pure, deterministic chess under FIDE rules: castling, en passant, promotion, check,
/// checkmate, and stalemate. To keep things simple for kids, the claimable draws
/// (50-move rule, threefold repetition) and dead positions are applied automatically.
nonisolated enum ChessRules {
    static let squareCount = 64
    static let squareRange = 0..<squareCount
    /// 50 moves by each player.
    static let fiftyMoveLimit = 100

    static func file(_ square: Int) -> Int { square % 8 }
    static func rank(_ square: Int) -> Int { square / 8 }

    static func square(file: Int, rank: Int) -> Int? {
        (0..<8).contains(file) && (0..<8).contains(rank) ? rank * 8 + file : nil
    }

    /// Algebraic name such as "e4".
    static func name(of square: Int) -> String {
        let fileLetter = Character(UnicodeScalar(UInt8(97 + file(square))))
        return "\(fileLetter)\(rank(square) + 1)"
    }

    static func isLightSquare(_ square: Int) -> Bool {
        (file(square) + rank(square)) % 2 == 1
    }

    private static let knightOffsets = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    private static let kingOffsets = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    private static let rookDirections = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    private static let bishopDirections = [(1, 1), (1, -1), (-1, 1), (-1, -1)]

    // MARK: - Setup

    static func newGame(players: [String], round: Int = 1) -> ChessState {
        var board = [ChessPiece?](repeating: nil, count: squareCount)
        let backRank: [ChessPiece.Kind] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for file in 0..<8 {
            board[file] = ChessPiece(.white, backRank[file])
            board[8 + file] = ChessPiece(.white, .pawn)
            board[48 + file] = ChessPiece(.black, .pawn)
            board[56 + file] = ChessPiece(.black, backRank[file])
        }
        var state = ChessState(
            board: board, players: players, turn: .white, castling: .init(), enPassant: nil,
            halfmoveClock: 0, fullmoveNumber: 1, positionHistory: [], outcome: nil, round: round, lastMove: nil
        )
        state.positionHistory = [positionKey(of: state)]
        return state
    }

    /// Next round with seats swapped so each player alternates colors.
    static func rematch(from state: ChessState) -> ChessState {
        newGame(players: state.players.reversed(), round: state.round + 1)
    }

    /// Loads a FEN position (used by tests and for debugging).
    static func state(fen: String, players: [String] = ["white", "black"]) -> ChessState? {
        let fields = fen.split(separator: " ")
        guard fields.count >= 4 else { return nil }
        let rows = fields[0].split(separator: "/")
        guard rows.count == 8 else { return nil }
        var board = [ChessPiece?](repeating: nil, count: squareCount)
        for (index, row) in rows.enumerated() {
            let rank = 7 - index
            var file = 0
            for character in row {
                if let skip = character.wholeNumberValue {
                    file += skip
                } else {
                    guard file < 8, let piece = ChessPiece(fenSymbol: character) else { return nil }
                    board[rank * 8 + file] = piece
                    file += 1
                }
            }
            guard file == 8 else { return nil }
        }
        let castlingField = fields[2]
        let castling = ChessState.CastlingRights(
            whiteKingside: castlingField.contains("K"),
            whiteQueenside: castlingField.contains("Q"),
            blackKingside: castlingField.contains("k"),
            blackQueenside: castlingField.contains("q")
        )
        var enPassant: Int?
        if fields[3] != "-" {
            let characters = Array(fields[3])
            guard characters.count == 2, let fileValue = characters[0].asciiValue, let rankValue = characters[1].wholeNumberValue,
                  let target = square(file: Int(fileValue) - 97, rank: rankValue - 1)
            else { return nil }
            enPassant = target
        }
        var state = ChessState(
            board: board, players: players, turn: fields[1] == "b" ? .black : .white, castling: castling, enPassant: enPassant,
            halfmoveClock: fields.count > 4 ? Int(fields[4]) ?? 0 : 0,
            fullmoveNumber: fields.count > 5 ? Int(fields[5]) ?? 1 : 1,
            positionHistory: [], outcome: nil, round: 1, lastMove: nil
        )
        state.positionHistory = [positionKey(of: state)]
        return state
    }

    // MARK: - Attacks

    static func isAttacked(_ target: Int, by color: ChessPiece.Color, in board: [ChessPiece?]) -> Bool {
        let file = file(target), rank = rank(target)

        // A pawn attacks diagonally forward, so look one rank behind the target from its side.
        for fileStep in [-1, 1] {
            if let from = square(file: file + fileStep, rank: rank - color.forward), board[from] == ChessPiece(color, .pawn) {
                return true
            }
        }
        for (fileStep, rankStep) in knightOffsets {
            if let from = square(file: file + fileStep, rank: rank + rankStep), board[from] == ChessPiece(color, .knight) {
                return true
            }
        }
        for (fileStep, rankStep) in kingOffsets {
            if let from = square(file: file + fileStep, rank: rank + rankStep), board[from] == ChessPiece(color, .king) {
                return true
            }
        }
        for (directions, slider) in [(rookDirections, ChessPiece.Kind.rook), (bishopDirections, .bishop)] {
            for (fileStep, rankStep) in directions {
                var current = square(file: file + fileStep, rank: rank + rankStep)
                while let from = current {
                    if let piece = board[from] {
                        if piece.color == color, piece.kind == slider || piece.kind == .queen { return true }
                        break
                    }
                    current = square(file: Self.file(from) + fileStep, rank: Self.rank(from) + rankStep)
                }
            }
        }
        return false
    }

    static func kingSquare(of color: ChessPiece.Color, in board: [ChessPiece?]) -> Int? {
        board.firstIndex(of: ChessPiece(color, .king))
    }

    static func isInCheck(_ color: ChessPiece.Color, in board: [ChessPiece?]) -> Bool {
        guard let king = kingSquare(of: color, in: board) else { return false }
        return isAttacked(king, by: color.other, in: board)
    }

    // MARK: - Move generation

    /// Every legal move for the side to move. Ignores `outcome`; callers check that.
    static func legalMoves(in state: ChessState) -> [ChessMove] {
        squareRange.flatMap { legalMoves(from: $0, in: state) }
    }

    static func legalMoves(from square: Int, in state: ChessState) -> [ChessMove] {
        pseudoLegalMoves(from: square, in: state).filter { !isInCheck(state.turn, in: board(after: $0, in: state)) }
    }

    /// Moves that follow piece movement but may leave the mover's king in check.
    /// Castling is fully checked here because its path squares matter too.
    static func pseudoLegalMoves(from origin: Int, in state: ChessState) -> [ChessMove] {
        guard let piece = state.board[origin], piece.color == state.turn else { return [] }
        let board = state.board
        let file = file(origin), rank = rank(origin)
        var targets: [Int] = []

        func addSteps(_ offsets: [(Int, Int)]) {
            for (fileStep, rankStep) in offsets {
                if let to = square(file: file + fileStep, rank: rank + rankStep), board[to]?.color != piece.color {
                    targets.append(to)
                }
            }
        }

        func addSlides(_ directions: [(Int, Int)]) {
            for (fileStep, rankStep) in directions {
                var current = square(file: file + fileStep, rank: rank + rankStep)
                while let to = current {
                    if let occupant = board[to] {
                        if occupant.color != piece.color { targets.append(to) }
                        break
                    }
                    targets.append(to)
                    current = square(file: Self.file(to) + fileStep, rank: Self.rank(to) + rankStep)
                }
            }
        }

        switch piece.kind {
        case .pawn:
            let forward = piece.color.forward
            let startRank = piece.color == .white ? 1 : 6
            if let one = square(file: file, rank: rank + forward), board[one] == nil {
                targets.append(one)
                if rank == startRank, let two = square(file: file, rank: rank + 2 * forward), board[two] == nil {
                    targets.append(two)
                }
            }
            for fileStep in [-1, 1] {
                guard let capture = square(file: file + fileStep, rank: rank + forward) else { continue }
                if let occupant = board[capture], occupant.color != piece.color {
                    targets.append(capture)
                } else if capture == state.enPassant {
                    targets.append(capture)
                }
            }
            let promotionRank = piece.color == .white ? 7 : 0
            return targets.flatMap { to in
                Self.rank(to) == promotionRank
                    ? ChessPiece.Kind.promotions.map { ChessMove(from: origin, to: to, promotion: $0) }
                    : [ChessMove(from: origin, to: to)]
            }
        case .knight:
            addSteps(knightOffsets)
        case .bishop:
            addSlides(bishopDirections)
        case .rook:
            addSlides(rookDirections)
        case .queen:
            addSlides(rookDirections + bishopDirections)
        case .king:
            addSteps(kingOffsets)
            targets += castlingTargets(for: piece.color, from: origin, in: state)
        }
        return targets.map { ChessMove(from: origin, to: $0) }
    }

    private static func castlingTargets(for color: ChessPiece.Color, from origin: Int, in state: ChessState) -> [Int] {
        let home = color == .white ? 4 : 60
        guard origin == home, !isAttacked(home, by: color.other, in: state.board) else { return [] }
        let rights = state.castling
        let (kingside, queenside) = color == .white
            ? (rights.whiteKingside, rights.whiteQueenside)
            : (rights.blackKingside, rights.blackQueenside)
        var targets: [Int] = []
        let rook = ChessPiece(color, .rook)
        if kingside, state.board[home + 3] == rook,
           state.board[home + 1] == nil, state.board[home + 2] == nil,
           !isAttacked(home + 1, by: color.other, in: state.board), !isAttacked(home + 2, by: color.other, in: state.board) {
            targets.append(home + 2)
        }
        if queenside, state.board[home - 4] == rook,
           state.board[home - 1] == nil, state.board[home - 2] == nil, state.board[home - 3] == nil,
           !isAttacked(home - 1, by: color.other, in: state.board), !isAttacked(home - 2, by: color.other, in: state.board) {
            targets.append(home - 2)
        }
        return targets
    }

    /// The board after a move, including castling's rook hop, en passant captures, and promotion.
    static func board(after move: ChessMove, in state: ChessState) -> [ChessPiece?] {
        var board = state.board
        guard let piece = board[move.from] else { return board }
        board[move.from] = nil
        if piece.kind == .pawn, move.to == state.enPassant, file(move.to) != file(move.from), board[move.to] == nil {
            board[move.to - 8 * piece.color.forward] = nil
        }
        if piece.kind == .king, abs(file(move.to) - file(move.from)) == 2 {
            let rankStart = rank(move.from) * 8
            if file(move.to) == 6 {
                board[rankStart + 5] = board[rankStart + 7]
                board[rankStart + 7] = nil
            } else {
                board[rankStart + 3] = board[rankStart]
                board[rankStart] = nil
            }
        }
        board[move.to] = move.promotion.map { ChessPiece(piece.color, $0) } ?? piece
        return board
    }

    // MARK: - Applying moves

    static func apply(_ action: ChessAction, by playerId: String, to state: ChessState) throws(MoveError) -> ChessState {
        guard let color = state.color(for: playerId) else { throw .notAPlayer }
        guard state.outcome == nil else { throw .gameOver }
        switch action {
        case .resign:
            var next = state
            next.outcome = .resignation(winner: color.other)
            return next
        case .move(let from, let to, let promotion):
            guard color == state.turn else { throw .notYourTurn }
            guard squareRange.contains(from), squareRange.contains(to) else { throw .outOfBounds }
            let candidates = legalMoves(from: from, in: state).filter { $0.to == to }
            guard !candidates.isEmpty else {
                let wouldBeLegal = pseudoLegalMoves(from: from, in: state).contains { $0.to == to }
                throw wouldBeLegal ? .leavesKingInCheck : .illegalMove
            }
            let move: ChessMove
            if candidates.contains(where: { $0.promotion != nil }) {
                guard let promotion, let chosen = candidates.first(where: { $0.promotion == promotion }) else { throw .promotionRequired }
                move = chosen
            } else {
                guard promotion == nil else { throw .illegalMove }
                move = candidates[0]
            }
            return perform(move, in: state)
        }
    }

    /// Applies a move already known to be legal and decides whether the game ended.
    static func perform(_ move: ChessMove, in state: ChessState) -> ChessState {
        guard let piece = state.board[move.from] else { return state }
        var next = state
        let isCapture = state.board[move.to] != nil || (piece.kind == .pawn && file(move.from) != file(move.to))
        if let taken = state.board[move.to] {
            next.capturedPieces.append(taken)
        } else if isCapture {
            next.capturedPieces.append(ChessPiece(piece.color.other, .pawn)) // en passant
        }
        next.board = board(after: move, in: state)

        // Moving a king or rook, or capturing a rook at home, removes those castling rights.
        for touched in [move.from, move.to] {
            switch touched {
            case 0: next.castling.whiteQueenside = false
            case 7: next.castling.whiteKingside = false
            case 4: next.castling.whiteKingside = false; next.castling.whiteQueenside = false
            case 56: next.castling.blackQueenside = false
            case 63: next.castling.blackKingside = false
            case 60: next.castling.blackKingside = false; next.castling.blackQueenside = false
            default: break
            }
        }
        next.enPassant = piece.kind == .pawn && abs(move.to - move.from) == 16 ? (move.from + move.to) / 2 : nil
        next.halfmoveClock = piece.kind == .pawn || isCapture ? 0 : state.halfmoveClock + 1
        if state.turn == .black { next.fullmoveNumber += 1 }
        next.turn = state.turn.other
        next.lastMove = .init(from: move.from, to: move.to)

        // Positions before a capture or pawn move can never repeat, so history restarts there.
        let key = positionKey(of: next)
        next.positionHistory = next.halfmoveClock == 0 ? [key] : state.positionHistory + [key]

        if legalMoves(in: next).isEmpty {
            next.outcome = isInCheck(next.turn, in: next.board) ? .checkmate(winner: state.turn) : .draw(.stalemate)
        } else if hasInsufficientMaterial(next.board) {
            next.outcome = .draw(.insufficientMaterial)
        } else if next.halfmoveClock >= fiftyMoveLimit {
            next.outcome = .draw(.fiftyMoves)
        } else if next.positionHistory.count(where: { $0 == key }) >= 3 {
            next.outcome = .draw(.repetition)
        }
        return next
    }

    // MARK: - Draw detection

    /// Identifies a position for repetition: placement, side to move, castling rights,
    /// and the en passant square only when a capture there is actually possible.
    static func positionKey(of state: ChessState) -> String {
        var key = String(state.board.map { $0?.fenSymbol ?? "." })
        key.append(state.turn == .white ? "w" : "b")
        let rights = state.castling
        key += (rights.whiteKingside ? "K" : "") + (rights.whiteQueenside ? "Q" : "") + (rights.blackKingside ? "k" : "") + (rights.blackQueenside ? "q" : "")
        if let target = state.enPassant,
           legalMoves(in: state).contains(where: { $0.to == target && state.board[$0.from]?.kind == .pawn }) {
            key += name(of: target)
        }
        return key
    }

    /// Neither side can ever checkmate: bare kings, a lone minor piece,
    /// or only bishops that all stand on the same square color.
    static func hasInsufficientMaterial(_ board: [ChessPiece?]) -> Bool {
        let pieces = squareRange.compactMap { square in board[square].map { (square, $0) } }.filter { $0.1.kind != .king }
        if pieces.isEmpty { return true }
        if pieces.count == 1, pieces[0].1.kind == .bishop || pieces[0].1.kind == .knight { return true }
        if pieces.allSatisfy({ $0.1.kind == .bishop }) {
            return Set(pieces.map { isLightSquare($0.0) }).count == 1
        }
        return false
    }
}
