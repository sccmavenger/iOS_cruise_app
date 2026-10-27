import SwiftUI

/// The Spades table: scores, bids, the current trick, and the viewer's hand.
struct SpadesView: View {
    let table: SpadesSnapshot
    @Environment(GameCoordinator.self) private var games
    @State private var showResignConfirmation = false

    private var isMyTurn: Bool { table.currentPlayer == table.viewer }

    var body: some View {
        VStack(spacing: 16) {
            scoreboard

            if let result = table.roundResult {
                handSummary(result)
            } else {
                trickArea
            }

            statusLine

            if table.phase == .bidding, isMyTurn {
                biddingControls
            }

            handView

            Button("Resign", role: .destructive) { showResignConfirmation = true }
                .font(.footnote)
                .padding(.top, 4)
        }
        .confirmationDialog("Resign the match?", isPresented: $showResignConfirmation, titleVisibility: .visible) {
            Button("Resign", role: .destructive) { games.play(.spades(.resign)) }
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text("Your team forfeits the whole match, not just this hand.")
        }
    }

    // MARK: - Scoreboard

    private var scoreboard: some View {
        HStack(spacing: 12) {
            teamColumn(SpadesRules.teamA)
            Divider().frame(height: 44)
            teamColumn(SpadesRules.teamB)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func teamColumn(_ teamId: String) -> some View {
        let isMine = table.viewerTeam == teamId
        let members = table.players.indices
            .filter { SpadesRules.team(ofSeat: $0) == teamId }
            .map { games.name(for: table.players[$0]) }
        return VStack(spacing: 2) {
            Text(isMine ? "Your team" : "Them")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isMine ? Theme.teal : .secondary)
            Text("\(table.scores[teamId] ?? 0)")
                .font(.title3.weight(.bold).monospacedDigit())
            Text(contractLine(teamId))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(members.joined(separator: " & "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isMine ? "Your team" : "Opponents"), \(members.joined(separator: " and ")), \(table.scores[teamId] ?? 0) points, \(contractLine(teamId))")
    }

    private func contractLine(_ teamId: String) -> String {
        let bags = table.bags[teamId] ?? 0
        guard let bid = table.teamBid(teamId) else { return "Bidding… · \(bags) bags" }
        return "\(table.teamTricks(teamId))/\(bid) tricks · \(bags) bags"
    }

    // MARK: - Trick

    private var trickArea: some View {
        VStack(spacing: 8) {
            let shown = table.trick.isEmpty ? (table.lastTrick ?? []) : table.trick
            let isPrevious = table.trick.isEmpty && table.lastTrick != nil
            if shown.isEmpty {
                CardSlotView(label: "Lead")
                    .frame(height: PlayingCardView.Size.table.height)
            } else {
                HStack(spacing: 8) {
                    ForEach(shown) { play in
                        VStack(spacing: 3) {
                            PlayingCardView(card: play.card, size: .table)
                            Text(games.name(for: play.player))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .opacity(isPrevious ? 0.5 : 1)
                    }
                }
            }
            if isPrevious, let winner = table.lastTrickWinner {
                Text("\(games.name(for: winner)) took it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !table.spadesBroken, table.phase == .playing {
                Label("Spades not broken yet", systemImage: "suit.spade")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 96)
    }

    // MARK: - Status

    private var statusLine: some View {
        Group {
            if let winner = table.matchWinner {
                Text(winner == table.viewerTeam ? "Your team wins the match!" : "The other team wins the match.")
                    .font(.headline)
                    .foregroundStyle(winner == table.viewerTeam ? Theme.teal : Theme.sunset)
            } else if table.phase == .bidding {
                Text(isMyTurn ? "Your bid" : "\(games.name(for: table.currentPlayer)) is bidding…")
                    .font(.subheadline.weight(.semibold))
            } else if table.phase == .playing {
                Text(isMyTurn ? "Your turn" : "\(games.name(for: table.currentPlayer))'s turn")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isMyTurn ? Theme.sunset : .secondary)
            }
        }
    }

    // MARK: - Bidding

    private var biddingControls: some View {
        VStack(spacing: 8) {
            Text("How many tricks will you take?")
                .font(.caption)
                .foregroundStyle(.secondary)
            // A grid rather than a stepper: bidding is a single decision, and one tap is
            // fewer than thirteen presses of a plus button.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(0...SpadesRules.handSize, id: \.self) { bid in
                    Button {
                        games.play(.spades(.bid(tricks: bid)))
                    } label: {
                        Text(bid == 0 ? "Nil" : "\(bid)")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                    .tint(bid == 0 ? Theme.sunset : Theme.teal)
                    .accessibilityLabel(bid == 0 ? "Bid nil, no tricks" : "Bid \(bid) tricks")
                }
            }
            Text("Nil means you'll take none at all: +100 if you manage it, −100 if you don't.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Hand

    private var handView: some View {
        VStack(spacing: 6) {
            let legal = Set(table.legalPlays)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: -14) {
                    ForEach(table.hand) { card in
                        let playable = isMyTurn && table.phase == .playing && legal.contains(card.id)
                        Button {
                            games.play(.spades(.play(cardId: card.id)))
                        } label: {
                            PlayingCardView(card: card, isPlayable: playable)
                        }
                        .buttonStyle(.plain)
                        .disabled(!playable)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            if isMyTurn, table.phase == .playing, !table.trick.isEmpty,
               let led = table.trick.first?.card.suit,
               table.hand.contains(where: { $0.suit == led }) {
                Text("You must follow \(led.name).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Hand summary

    private func handSummary(_ result: SpadesState.RoundResult) -> some View {
        VStack(spacing: 8) {
            Text("Hand \(table.round) over")
                .font(.headline)
            ForEach([SpadesRules.teamA, SpadesRules.teamB], id: \.self) { teamId in
                let delta = result.teamScores[teamId] ?? 0
                HStack {
                    Text(table.viewerTeam == teamId ? "Your team" : "Them")
                        .font(.subheadline)
                    Spacer()
                    Text(delta >= 0 ? "+\(delta)" : "\(delta)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(delta >= 0 ? Theme.teal : .red)
                }
            }
            ForEach(table.players, id: \.self) { player in
                let bid = result.bids[player] ?? 0
                let won = result.tricksWon[player] ?? 0
                HStack {
                    Text(games.name(for: player))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if bid == 0 {
                        Text(result.nilResults[player] == true ? "Nil made" : "Nil failed")
                            .font(.caption)
                            .foregroundStyle(result.nilResults[player] == true ? Theme.teal : .red)
                    } else {
                        Text("bid \(bid), took \(won)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
