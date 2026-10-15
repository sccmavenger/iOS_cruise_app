import SwiftUI

struct ConnectFourView: View {
    let state: ConnectFourState
    @Environment(GameCoordinator.self) private var games

    private var myDisc: ConnectFourState.Disc? { state.disc(for: games.localId) }
    private var isMyTurn: Bool { state.outcome == nil && state.turn == myDisc && games.pendingMoveId == nil }

    private var winningCells: Set<Int> {
        if case .win(_, let cells) = state.outcome { return Set(cells) }
        return []
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                DiscBadge(disc: .red, name: games.name(for: state.playerId(for: .red)), isActive: state.outcome == nil && state.turn == .red)
                Spacer()
                Text("Round \(state.round)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                DiscBadge(disc: .yellow, name: games.name(for: state.playerId(for: .yellow)), isActive: state.outcome == nil && state.turn == .yellow)
            }

            Text(statusText)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)

            board

            if state.outcome != nil {
                RematchControls()
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.25), value: state)
        .onChange(of: statusText) { _, text in
            AccessibilityNotification.Announcement(text).post()
        }
    }

    private var statusText: String {
        switch state.outcome {
        case .win(let disc, _):
            return disc == myDisc ? "You win! 🎉" : "\(games.name(for: state.playerId(for: disc))) wins"
        case .draw:
            return "It's a draw"
        case nil:
            if games.pendingMoveId != nil { return games.pendingMoveStatus }
            return isMyTurn ? "Your turn: tap a column" : "\(games.name(for: state.playerId(for: state.turn)))'s turn"
        }
    }

    private var board: some View {
        HStack(spacing: 6) {
            ForEach(0..<ConnectFourRules.columns, id: \.self) { column in
                columnView(column)
            }
        }
        .padding(10)
        .background(Theme.deep, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .aspectRatio(CGFloat(ConnectFourRules.columns) / CGFloat(ConnectFourRules.rows), contentMode: .fit)
        .frame(maxWidth: 380)
    }

    private func columnView(_ column: Int) -> some View {
        let landing = ConnectFourRules.landingRow(in: column, of: state.board)
        let canTap = isMyTurn && landing != nil
        return Button {
            guard canTap else { return }
            games.play(.connectFour(column: column))
        } label: {
            VStack(spacing: 6) {
                // Top row first on screen.
                ForEach((0..<ConnectFourRules.rows).reversed(), id: \.self) { row in
                    let index = row * ConnectFourRules.columns + column
                    DiscView(disc: state.board[index], isWinning: winningCells.contains(index), isLast: state.lastMove == index)
                }
            }
            .padding(.vertical, 2)
            .background(canTap ? Color.white.opacity(0.08) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(canTap)
        .accessibilityLabel(columnLabel(column))
        .accessibilityHint(canTap ? "Drops your disc in this column" : "")
    }

    private func columnLabel(_ column: Int) -> String {
        let discs = (0..<ConnectFourRules.rows).compactMap { state.disc(row: $0, column: column) }
        let free = ConnectFourRules.rows - discs.count
        let top = discs.last.map { ", top disc \($0.name)" } ?? ""
        return "Column \(column + 1), \(free == 0 ? "full" : "\(free) free")\(top)"
    }
}

/// A board cell; discs carry a symbol as well as a color for color-blind players.
struct DiscView: View {
    let disc: ConnectFourState.Disc?
    var isWinning = false
    var isLast = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.night.opacity(0.7))
            if let disc {
                Circle()
                    .fill(disc.color.gradient)
                    .overlay {
                        Image(systemName: disc.symbol)
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(disc == .red ? Color.white.opacity(0.85) : Theme.night.opacity(0.7))
                    }
                    .overlay(Circle().strokeBorder(isWinning ? Color.white : .clear, lineWidth: 3))
                    .scaleEffect(isWinning ? 1.06 : 1)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(Circle().strokeBorder(isLast && !isWinning ? Color.white.opacity(0.6) : .clear, lineWidth: 2))
    }
}

extension ConnectFourState.Disc {
    var color: Color { self == .red ? Theme.coral : Color(red: 1.0, green: 0.80, blue: 0.20) }
    var symbol: String { self == .red ? "circle.fill" : "star.fill" }
}

struct DiscBadge: View {
    let disc: ConnectFourState.Disc
    let name: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            DiscView(disc: disc)
                .frame(width: 22, height: 22)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(isActive ? .regular.tint(Theme.teal.opacity(0.35)) : .regular, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(name == "You" ? "play" : "plays") \(disc.name)\(isActive ? ", current turn" : "")")
    }
}
