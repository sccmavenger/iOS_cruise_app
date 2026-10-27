import SwiftUI

/// The Color Match table as seen by one player. Everything shown comes from the host's
/// per-player snapshot; local "playable" highlighting is a hint, the host decides.
struct ColorMatchView: View {
    let table: ColorMatchSnapshot
    @Environment(GameCoordinator.self) private var games

    @State private var callOneArmed = false
    @State private var wildCard: Card?

    private var me: String { games.localId }
    private var isMyTurn: Bool { table.currentPlayer == me && table.roundResult == nil }
    private var mustRespondToDrawFour: Bool { table.drawFourTarget == me && table.roundResult == nil }
    private var isBusy: Bool { games.pendingMoveId != nil }

    var body: some View {
        VStack(spacing: 14) {
            opponents
            centerTable
            Text(eventText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 20)
                .accessibilityAddTraits(.updatesFrequently)

            if let result = table.roundResult {
                RoundResultCard(table: table, result: result)
                RematchControls(
                    title: table.matchWinner == nil ? "Next Round" : "New Match",
                    waitingTitle: "Waiting for other players…"
                )
            } else {
                statusBanner
                controls
                hand
            }
        }
        .animation(.snappy, value: table)
        .sheet(item: $wildCard) { card in
            WildColorPicker(
                card: card,
                bluffWarning: card.face == .wildDrawFour
                    && !ColorMatchRules.isLegalDrawFour(hand: table.hand.filter { $0.id != card.id }, activeColor: table.activeColor)
                    ? "Heads up: you have a \(table.activeColor.name) card, so you could be challenged and draw 4."
                    : nil
            ) { color in
                play(card, color: color)
                wildCard = nil
            }
            // Sized to content and scrollable, so larger text sizes still fit. Swipe down to cancel.
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert(drawFourTitle, isPresented: Binding(get: { mustRespondToDrawFour && !isBusy }, set: { _ in })) {
            Button("Draw 4") { games.play(.colorMatch(.respondToDrawFour(challenge: false))) }
            Button("Challenge!") { games.play(.colorMatch(.respondToDrawFour(challenge: true))) }
        } message: {
            Text("Challenge if you think they had a card of the color in play. If you're right, they draw 4 and you take your turn. If you're wrong, you draw 6.")
        }
        .onChange(of: table.hand.count) { _, count in
            if count != 2 { callOneArmed = false }
        }
    }

    // MARK: - Sections

    private var opponents: some View {
        HStack(spacing: 8) {
            ForEach(table.players.filter { $0 != me }, id: \.self) { player in
                OpponentChip(
                    name: games.name(for: player),
                    count: table.cardCounts[player] ?? 0,
                    score: table.scores[player] ?? 0,
                    isTurn: table.currentPlayer == player && table.roundResult == nil,
                    canCatch: table.vulnerablePlayer == player
                ) {
                    games.play(.colorMatch(.catchOne(target: player)))
                }
            }
        }
    }

    private var centerTable: some View {
        HStack(spacing: 22) {
            Button {
                games.play(.colorMatch(.draw))
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    CardBackView(width: 70)
                    Text("\(table.drawPileCount)")
                        .font(.caption2.bold())
                        .padding(5)
                        .background(.thinMaterial, in: Capsule())
                        .offset(x: 6, y: 6)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canDraw)
            .accessibilityLabel("Draw pile, \(table.drawPileCount) cards")
            .accessibilityHint(canDraw ? "Draws one card" : "")

            ColorMatchCardView(card: table.topCard, width: 84)
                .accessibilityLabel("Top card \(table.topCard.name)")

            VStack(spacing: 8) {
                ActiveColorChip(color: table.activeColor)
                Image(systemName: table.direction == 1 ? "arrow.clockwise" : "arrow.counterclockwise")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(table.direction == 1 ? "Play goes clockwise" : "Play goes counterclockwise")
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var statusBanner: some View {
        let text: String = {
            if mustRespondToDrawFour { return "Wild Draw Four! Draw 4 or challenge." }
            if let target = table.drawFourTarget { return "Waiting for \(games.name(for: target)) to answer the Wild Draw Four…" }
            if isBusy { return "Sending…" }
            if isMyTurn { return table.drawnCardId != nil ? "Play the card you drew, or pass" : "Your turn" }
            return "\(games.name(for: table.currentPlayer))'s turn"
        }()
        Text(text)
            .font(.title3.bold())
            .foregroundStyle(isMyTurn ? Theme.teal : .primary)
            .multilineTextAlignment(.center)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if table.vulnerablePlayer == me {
                Button {
                    games.play(.colorMatch(.callOne))
                } label: {
                    Label("Call One!", systemImage: "megaphone.fill")
                        .font(.headline)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.coral)
            } else if isMyTurn, table.hand.count == 2 {
                Button {
                    callOneArmed.toggle()
                } label: {
                    Label(callOneArmed ? "One! ✓" : "Call One!", systemImage: "megaphone.fill")
                        .font(.headline)
                }
                .buttonStyle(.glass)
                .tint(callOneArmed ? .green : Theme.coral)
                .accessibilityHint("Tap before playing your second-to-last card")
            }

            if isMyTurn, table.drawnCardId != nil {
                Button("Pass") { games.play(.colorMatch(.pass)) }
                    .buttonStyle(.glass)
                    .disabled(isBusy)
            } else if isMyTurn {
                Button {
                    games.play(.colorMatch(.draw))
                } label: {
                    Label("Draw", systemImage: "rectangle.stack.badge.plus")
                }
                .buttonStyle(.glass)
                .disabled(!canDraw)
            }
        }
        .frame(minHeight: 44)
    }

    private var hand: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Your hand (\(table.hand.count))").font(.headline)
                if table.hand.count > 6 {
                    Label("Swipe for more", systemImage: "hand.draw")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Score \(table.scores[me] ?? 0)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: -22) {
                    ForEach(sortedHand) { card in
                        let playable = isPlayable(card)
                        Button {
                            tap(card)
                        } label: {
                            ColorMatchCardView(card: card, width: 62, isHighlighted: playable, isDimmed: isMyTurn && !playable)
                                .offset(y: playable ? -10 : 0)
                        }
                        .buttonStyle(.plain)
                        .disabled(!playable || isBusy)
                        .accessibilityLabel(card.name + (playable ? ", playable" : ""))
                        .accessibilityHint(playable ? "Plays this card" : "")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Logic

    private var canDraw: Bool {
        isMyTurn && table.drawnCardId == nil && table.drawFourTarget == nil && !isBusy
    }

    /// Client-side hint mirroring `ColorMatchRules.isPlayable`; the host re-validates.
    private func isPlayable(_ card: Card) -> Bool {
        guard isMyTurn, table.drawFourTarget == nil else { return false }
        if let drawn = table.drawnCardId, drawn != card.id { return false }
        if card.face.isWild { return true }
        return card.color == table.activeColor || card.face == table.topCard.face
    }

    private func tap(_ card: Card) {
        if card.face.isWild {
            wildCard = card
        } else {
            play(card, color: nil)
        }
    }

    private func play(_ card: Card, color: CardColor?) {
        games.play(.colorMatch(.play(cardId: card.id, chosenColor: color, callOne: callOneArmed)))
        callOneArmed = false
    }

    private var sortedHand: [Card] {
        table.hand.sorted { lhs, rhs in
            let order = { (card: Card) -> Int in card.color.map { CardColor.allCases.firstIndex(of: $0)! } ?? 4 }
            if order(lhs) != order(rhs) { return order(lhs) < order(rhs) }
            return lhs.face.points < rhs.face.points
        }
    }

    /// The host's event line with names filled in on this phone. The host could send anything,
    /// so it's filtered like chat before it's shown.
    private var eventText: String {
        var text = table.lastEvent
        // The rules write "{player} draws 2 and is skipped"; for this phone's player that has to
        // read "you draw 2 and are skipped".
        let mine = ColorMatchRules.nameToken(games.localId)
        text = text.replacingOccurrences(of: "\(mine) draws 2 and is skipped", with: "\(mine) draw 2 and are skipped")
            .replacingOccurrences(of: "\(mine) is skipped", with: "\(mine) are skipped")
        for player in table.players {
            let token = ColorMatchRules.nameToken(player)
            let name = games.name(for: player)
            // "You" at the start of the line, "you" in the middle.
            if text.hasPrefix(token) {
                text = name + text.dropFirst(token.count)
            }
            text = text.replacingOccurrences(of: token, with: name == "You" ? "you" : name)
        }
        // A sentence that starts with "you" after an earlier one ("… Draw Two. you draw 2").
        text = text.replacingOccurrences(of: ". you ", with: ". You ")
        guard !text.contains("{"), ContentFilter.shared.check(text).isAllowed else { return "" }
        return text
    }

    private var drawFourTitle: String {
        let offender = table.drawFourOffender.map(games.name(for:)) ?? "Someone"
        return "\(offender) played Wild Draw Four"
    }
}

/// Big, labeled color buttons for choosing a wild card's color.
struct WildColorPicker: View {
    let card: Card
    let bluffWarning: String?
    let onPick: (CardColor) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Choose a color for \(card.name)")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(CardColor.allCases) { color in
                    Button {
                        onPick(color)
                    } label: {
                        Label(color.name, systemImage: color.symbol)
                            .font(.title3.bold())
                            .foregroundStyle(color.ink)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .background(color.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let bluffWarning {
                Text(bluffWarning)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
    }
}

struct OpponentChip: View {
    let name: String
    let count: Int
    let score: Int
    let isTurn: Bool
    let canCatch: Bool
    let onCatch: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait.fill")
                    .accessibilityHidden(true)
                Text("\(count)")
                    .font(.headline)
            }
            if count == 1 {
                Text("ONE!")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(Theme.coral)
            }
            if canCatch {
                Button("Catch!", action: onCatch)
                    .font(.subheadline.weight(.bold))
                    .frame(minHeight: 44)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.coral)
            }
            Text("\(score) pts")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .glassEffect(isTurn ? .regular.tint(Theme.teal.opacity(0.35)) : .regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(count == 1 ? "1 card" : "\(count) cards"), \(score) points\(isTurn ? ", their turn" : "")\(canCatch ? ". Didn't call One, you can catch them" : "")")
        .accessibilityActions {
            if canCatch {
                Button("Catch \(name)", action: onCatch)
            }
        }
    }
}

struct RoundResultCard: View {
    let table: ColorMatchSnapshot
    let result: ColorMatchState.RoundResult
    @Environment(GameCoordinator.self) private var games

    var body: some View {
        VStack(spacing: 10) {
            if let champion = table.matchWinner {
                Text(champion == games.localId ? "You won the match! 🏆" : "\(games.name(for: champion)) won the match! 🏆")
                    .font(.title2.bold())
            } else {
                Text(result.winner == games.localId ? "You won the round! 🎉" : "\(games.name(for: result.winner)) won the round")
                    .font(.title2.bold())
            }
            Text("+\(result.points) points").font(.headline).foregroundStyle(Theme.teal)

            VStack(spacing: 6) {
                ForEach(table.players.sorted { (table.scores[$0] ?? 0) > (table.scores[$1] ?? 0) }, id: \.self) { player in
                    HStack {
                        Text(games.name(for: player))
                        Spacer()
                        if let held = result.handPoints[player] {
                            Text("held \(held)").foregroundStyle(.secondary).font(.caption)
                        }
                        Text("\(table.scores[player] ?? 0)").fontWeight(.bold).monospacedDigit()
                    }
                }
            }
            Text("First to \(ColorMatchRules.targetScore) wins the match.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}
