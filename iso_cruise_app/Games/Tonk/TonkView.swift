import SwiftUI

/// The Tonk table: piles, spreads, scores, and the viewer's hand.
///
/// Cards are selected first and acted on second, because a Tonk turn has several possible
/// actions for the same card (discard it, spread with it, hit a spread with it) and a single
/// tap can't say which.
struct TonkView: View {
    let table: TonkSnapshot
    @Environment(GameCoordinator.self) private var games
    @State private var selected: Set<Int> = []
    @State private var showResignConfirmation = false

    private var isMyTurn: Bool { table.currentPlayer == table.viewer }
    private var selectedCards: [PlayingCard] {
        table.hand.filter { selected.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 16) {
            scoreboard

            if let result = table.roundResult {
                roundSummary(result)
            } else {
                piles
            }

            statusLine

            if !table.spreads.isEmpty { spreadsView }

            handView

            if isMyTurn, table.roundResult == nil { actions }

            Button("Resign", role: .destructive) { showResignConfirmation = true }
                .font(.footnote)
                .padding(.top, 4)
        }
        .onChange(of: table.hand) { _, _ in
            // Drop any selection that refers to cards no longer held, so a stale tap can't
            // submit a move for a card that's already gone.
            selected = selected.intersection(Set(table.hand.map(\.id)))
        }
        .confirmationDialog("Resign the match?", isPresented: $showResignConfirmation, titleVisibility: .visible) {
            Button("Resign", role: .destructive) { games.play(.tonk(.resign)) }
            Button("Keep playing", role: .cancel) {}
        }
    }

    // MARK: - Scoreboard

    private var scoreboard: some View {
        HStack(spacing: 10) {
            ForEach(table.players, id: \.self) { player in
                VStack(spacing: 2) {
                    Text(games.name(for: player))
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(player == table.currentPlayer ? Theme.sunset : .secondary)
                    Text("\(table.scores[player] ?? 0)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                    Text("\(table.cardCounts[player] ?? 0) cards")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(games.name(for: player)), \(table.scores[player] ?? 0) points, \(table.cardCounts[player] ?? 0) cards")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Piles

    private var piles: some View {
        HStack(spacing: 28) {
            VStack(spacing: 4) {
                Button {
                    games.play(.tonk(.drawFromStock))
                } label: {
                    if table.stockCount > 0 {
                        PlayingCardBackView(size: .table)
                    } else {
                        CardSlotView(label: "Empty", size: .table)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canDraw)
                .accessibilityLabel("Stock pile, \(table.stockCount) cards. Draw.")
                Text("Stock · \(table.stockCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                Button {
                    games.play(.tonk(.takeDiscard))
                } label: {
                    if let top = table.topDiscard {
                        PlayingCardView(card: top, size: .table)
                    } else {
                        CardSlotView(label: "Empty", size: .table)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canDraw || table.topDiscard == nil)
                .accessibilityLabel(table.topDiscard.map { "Discard pile, \($0.spokenName). Take it." } ?? "Discard pile, empty")
                Text("Pile")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 90)
    }

    private var canDraw: Bool { isMyTurn && table.phase == .mustDraw }

    // MARK: - Status

    private var statusLine: some View {
        VStack(spacing: 2) {
            if let winner = table.matchWinner {
                Text(winner == table.viewer ? "You win the match!" : "\(games.name(for: winner)) wins the match.")
                    .font(.headline)
                    .foregroundStyle(winner == table.viewer ? Theme.teal : Theme.sunset)
            } else if isMyTurn {
                Text(table.phase == .mustDraw ? "Draw a card, or drop" : "Spread, hit, then discard")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.sunset)
            } else {
                Text("\(games.name(for: table.currentPlayer))'s turn")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text("Your hand counts \(table.handValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Spreads

    private var spreadsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On the table")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(table.spreads) { spread in
                        Button {
                            // Hitting uses exactly one selected card.
                            if let card = selectedCards.first, selectedCards.count == 1 {
                                games.play(.tonk(.hit(spreadId: spread.id, cardId: card.id)))
                                selected.removeAll()
                            }
                        } label: {
                            VStack(spacing: 3) {
                                HStack(spacing: -10) {
                                    ForEach(spread.cards) { card in
                                        PlayingCardView(card: card, size: .small)
                                    }
                                }
                                Text(games.name(for: spread.owner))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canHit)
                        .accessibilityLabel("\(spread.kind == .set ? "Set" : "Run") of \(spread.cards.count), laid by \(games.name(for: spread.owner))")
                        .accessibilityHint(canHit ? "Add your selected card" : "")
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var canHit: Bool {
        isMyTurn && table.phase == .mustDiscard && selectedCards.count == 1 && table.hand.count >= 2
    }

    // MARK: - Hand

    private var handView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: -14) {
                ForEach(table.hand) { card in
                    Button {
                        if selected.contains(card.id) { selected.remove(card.id) } else { selected.insert(card.id) }
                    } label: {
                        PlayingCardView(
                            card: card,
                            isPlayable: isMyTurn,
                            isSelected: selected.contains(card.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isMyTurn)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if table.phase == .mustDraw {
                    Button("Drop") { games.play(.tonk(.drop)) }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.sunset)
                        .accessibilityHint("Claim the lowest hand. If anyone ties or beats you, you pay double.")
                }
                if table.phase == .mustDiscard {
                    Button("Discard") {
                        if let card = selectedCards.first, selectedCards.count == 1 {
                            games.play(.tonk(.discard(cardId: card.id)))
                            selected.removeAll()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.teal)
                    .disabled(selectedCards.count != 1 || selectedCards.first?.id == table.tookDiscardId)

                    Button("Spread") {
                        games.play(.tonk(.spread(cardIds: selectedCards.map(\.id).sorted())))
                        selected.removeAll()
                    }
                    .buttonStyle(.bordered)
                    .disabled(TonkRules.classify(selectedCards) == nil || table.hand.count - selectedCards.count < 1)
                }
            }
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var hint: String {
        if table.phase == .mustDraw {
            return "Take the top of the stock or the pile. Or drop if you think your hand is lowest."
        }
        if selectedCards.isEmpty {
            return "Tap a card to select it."
        }
        if selectedCards.count == 1 {
            if selectedCards[0].id == table.tookDiscardId {
                return "You just took that card — you can't discard it back this turn."
            }
            return "Discard it, or tap a spread on the table to add it."
        }
        return TonkRules.classify(selectedCards) == nil
            ? "Three or more of a rank, or three or more in a row in one suit."
            : "Tap Spread to lay these down."
    }

    // MARK: - Round summary

    private func roundSummary(_ result: TonkState.RoundResult) -> some View {
        VStack(spacing: 8) {
            Text(result.winner == table.viewer ? "You won the round" : "\(games.name(for: result.winner)) won the round")
                .font(.headline)
            Text(reasonText(result.reason))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("+\(result.points) points")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.teal)
            ForEach(table.players, id: \.self) { player in
                HStack {
                    Text(games.name(for: player))
                        .font(.caption)
                    Spacer()
                    Text("held \(result.handValues[player] ?? 0)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func reasonText(_ reason: TonkState.RoundResult.Reason) -> String {
        switch reason {
        case .tonk: "Dealt 49 or 50 — an instant win, worth double."
        case .wentOut: "Played every card."
        case .drop: "Dropped with the lowest hand."
        case .caught: "The drop was caught, so it cost double."
        case .stockExhausted: "The cards ran out, so the lowest hand took it."
        }
    }
}
