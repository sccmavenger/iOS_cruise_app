import SwiftUI

struct ChessView: View {
    let state: ChessState
    @Environment(GameCoordinator.self) private var games
    @State private var selected: Int?
    /// Set while the player picks what a pawn reaching the last rank becomes.
    @State private var pendingPromotion: ChessState.LastMove?

    private var myColor: ChessPiece.Color? { state.color(for: games.localId) }
    private var isMyTurn: Bool { state.outcome == nil && state.turn == myColor && games.pendingMoveId == nil }
    private var selectedMoves: [ChessMove] {
        guard isMyTurn, let selected else { return [] }
        return ChessRules.legalMoves(from: selected, in: state)
    }
    private var targets: Set<Int> { Set(selectedMoves.map(\.to)) }
    private var checkedKing: Int? {
        guard state.outcome == nil || state.outcome == .checkmate(winner: state.turn.other),
              ChessRules.isInCheck(state.turn, in: state.board)
        else { return nil }
        return ChessRules.kingSquare(of: state.turn, in: state.board)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                badge(.white)
                Spacer()
                Text("Round \(state.round)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                badge(.black)
            }

            Text(statusText)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)

            CapturedRow(pieces: captured(of: myColor?.other ?? .black))

            EightByEightBoard(flipped: myColor == .black) { index in
                square(index)
            }

            CapturedRow(pieces: captured(of: myColor ?? .white))

            if state.outcome != nil {
                RematchControls()
            } else if myColor != nil {
                ResignButton(move: .chess(.resign))
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.15), value: state)
        .onChange(of: state) { selected = nil }
        .confirmationDialog("Promote your pawn", isPresented: Binding(
            get: { pendingPromotion != nil },
            set: { if !$0 { pendingPromotion = nil } }
        ), titleVisibility: .visible) {
            ForEach(ChessPiece.Kind.promotions, id: \.self) { kind in
                Button(kind.name) { promote(to: kind) }
            }
            Button("Cancel", role: .cancel) { pendingPromotion = nil }
        }
    }

    private func badge(_ color: ChessPiece.Color) -> some View {
        BoardPlayerBadge(
            name: games.name(for: state.playerId(for: color)),
            sideName: color.name,
            isActive: state.outcome == nil && state.turn == color
        ) {
            ChessGlyph(piece: ChessPiece(color, .king))
        }
    }

    private var statusText: String {
        switch state.outcome {
        case .checkmate(let winner):
            return winner == myColor ? "Checkmate! You win 🎉" : "Checkmate. \(games.name(for: state.playerId(for: winner))) wins"
        case .resignation(let winner):
            let loser = games.name(for: state.playerId(for: winner.other))
            return winner == myColor ? "\(loser) resigned. You win! 🎉" : "\(loser) resigned. \(games.name(for: state.playerId(for: winner))) wins"
        case .draw(let reason):
            return switch reason {
            case .stalemate: "Stalemate: it's a draw"
            case .insufficientMaterial: "Draw: no one can checkmate"
            case .fiftyMoves: "Draw: 50 moves with no capture or pawn move"
            case .repetition: "Draw: the same position came up 3 times"
            }
        case nil:
            if games.pendingMoveId != nil { return "Sending move…" }
            let inCheck = ChessRules.isInCheck(state.turn, in: state.board)
            guard isMyTurn else {
                return "\(games.name(for: state.playerId(for: state.turn)))'s turn\(inCheck ? " (in check)" : "")"
            }
            if inCheck { return "Check! Protect your king" }
            return selected == nil ? "Your turn: pick a piece" : "Your turn: pick a square"
        }
    }

    private func square(_ index: Int) -> some View {
        let light = ChessRules.isLightSquare(index)
        let piece = state.board[index]
        let isTarget = targets.contains(index)
        let isLast = state.lastMove.map { $0.from == index || $0.to == index } ?? false
        return ZStack {
            Rectangle()
                .fill(light ? Theme.foam : Theme.teal)
            if isLast {
                Rectangle().fill(Theme.sunset.opacity(0.35))
            }
            if selected == index {
                Rectangle().fill(Theme.sunset.opacity(0.6))
            }
            if checkedKing == index {
                RadialGradient(colors: [Theme.coral, Theme.coral.opacity(0)], center: .center, startRadius: 2, endRadius: 26)
            }
            if let piece {
                ChessGlyph(piece: piece)
                    .padding(4)
                    .transition(.opacity)
            }
            if isTarget {
                if piece == nil {
                    Circle()
                        .fill(Theme.night.opacity(0.35))
                        .padding(15)
                } else {
                    Circle()
                        .strokeBorder(Theme.night.opacity(0.45), lineWidth: 4)
                        .padding(1)
                }
            }
        }
        .overlay(alignment: .topLeading) { rankLabel(index, light: light) }
        .overlay(alignment: .bottomTrailing) { fileLabel(index, light: light) }
        .contentShape(.rect)
        .onTapGesture { tap(index) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(squareLabel(index, piece: piece, isTarget: isTarget))
        .accessibilityAddTraits(.isButton)
    }

    /// Rank numbers down the left edge, from the viewer's side.
    @ViewBuilder
    private func rankLabel(_ index: Int, light: Bool) -> some View {
        if ChessRules.file(index) == (myColor == .black ? 7 : 0) {
            coordinate(String(ChessRules.rank(index) + 1), light: light)
        }
    }

    /// File letters along the bottom row, from the viewer's side.
    @ViewBuilder
    private func fileLabel(_ index: Int, light: Bool) -> some View {
        if ChessRules.rank(index) == (myColor == .black ? 7 : 0) {
            coordinate(String(ChessRules.name(of: index).prefix(1)), light: light)
        }
    }

    private func coordinate(_ text: String, light: Bool) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(light ? Theme.teal : Theme.foam)
            .padding(2)
            .accessibilityHidden(true)
    }

    private func tap(_ index: Int) {
        guard isMyTurn else { return }
        if let from = selected, targets.contains(index) {
            if selectedMoves.contains(where: { $0.to == index && $0.promotion != nil }) {
                pendingPromotion = .init(from: from, to: index)
            } else {
                games.play(.chess(.move(from: from, to: index, promotion: nil)))
                selected = nil
            }
        } else if state.board[index]?.color == myColor, selected != index {
            selected = index
        } else {
            selected = nil
        }
    }

    private func promote(to kind: ChessPiece.Kind) {
        guard let move = pendingPromotion else { return }
        pendingPromotion = nil
        selected = nil
        games.play(.chess(.move(from: move.from, to: move.to, promotion: kind)))
    }

    private func squareLabel(_ index: Int, piece: ChessPiece?, isTarget: Bool) -> String {
        var parts = [ChessRules.name(of: index)]
        parts.append(piece.map { "\($0.color.name) \($0.kind.rawValue)" } ?? "empty")
        if selected == index { parts.append("selected") }
        if checkedKing == index { parts.append("in check") }
        if isTarget { parts.append(piece == nil ? "move here" : "capture") }
        return parts.joined(separator: ", ")
    }

    /// Pieces of `color` no longer on the board, most valuable first.
    private func captured(of color: ChessPiece.Color) -> [ChessPiece] {
        let starting: [(ChessPiece.Kind, Int)] = [(.queen, 1), (.rook, 2), (.bishop, 2), (.knight, 2), (.pawn, 8)]
        return starting.flatMap { kind, count in
            let remaining = state.board.count(where: { $0 == ChessPiece(color, kind) })
            return Array(repeating: ChessPiece(color, kind), count: max(0, count - remaining))
        }
    }
}

/// Small row of captured pieces above and below the board.
private struct CapturedRow: View {
    let pieces: [ChessPiece]

    var body: some View {
        HStack(spacing: -4) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                ChessGlyph(piece: piece)
                    .frame(width: 20, height: 20)
            }
        }
        .frame(height: 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pieces.isEmpty ? "" : "Captured: \(pieces.map(\.kind.rawValue).joined(separator: ", "))")
        .accessibilityHidden(pieces.isEmpty)
    }
}

/// A chess piece drawn from the Unicode chess glyphs: the filled glyph in the piece's
/// color with the outline glyph on top, so White and Black read clearly on any square.
struct ChessGlyph: View {
    let piece: ChessPiece

    var body: some View {
        ZStack {
            glyph(filled: true)
                .foregroundStyle(piece.color == .white ? Color.white : Theme.night)
            glyph(filled: false)
                .foregroundStyle(piece.color == .white ? Theme.night : Color.white.opacity(0.35))
        }
        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
        .accessibilityHidden(true)
    }

    private func glyph(filled: Bool) -> some View {
        // U+FE0E asks for text presentation so the pawn never renders as an emoji.
        Text((filled ? piece.kind.filledGlyph : piece.kind.outlineGlyph) + "\u{FE0E}")
            .font(.system(size: 200))
            .minimumScaleFactor(0.01)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The glyphs carry generous built-in line spacing; scale up to fill the square.
            .scaleEffect(1.25)
    }
}

private extension ChessPiece.Kind {
    var outlineGlyph: String {
        switch self {
        case .king: "\u{2654}"
        case .queen: "\u{2655}"
        case .rook: "\u{2656}"
        case .bishop: "\u{2657}"
        case .knight: "\u{2658}"
        case .pawn: "\u{2659}"
        }
    }

    var filledGlyph: String {
        switch self {
        case .king: "\u{265A}"
        case .queen: "\u{265B}"
        case .rook: "\u{265C}"
        case .bishop: "\u{265D}"
        case .knight: "\u{265E}"
        case .pawn: "\u{265F}"
        }
    }
}

#Preview {
    let profile = ProfileStore()
    let session = SessionManager(transport: MultipeerTransport(), profile: profile)
    ScrollView {
        if let state = ChessRules.state(fen: "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1") {
            ChessView(state: state).padding()
        }
    }
    .environment(GameCoordinator(session: session))
}
