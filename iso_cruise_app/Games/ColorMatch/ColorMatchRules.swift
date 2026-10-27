/// Pure Color Match rules. Only the host calls these; clients see projections.
///
/// Implements 03-GAME-RULES.md: 108-card deck, 7-card deal, numbered start card,
/// match color/number/symbol, Wild Draw Four only without the active color,
/// draw-one-then-play-or-pass, no stacking, Skip/Reverse/Draw Two, Wild Draw Four
/// challenge (offender +4 / challenger +6), Call One!/Catch! with a "next player's
/// first action" deadline, final draw penalties before scoring, discard reshuffle,
/// and cumulative scoring to 500.
nonisolated enum ColorMatchRules {
    static let deckSize = 108
    static let deckRange = 0..<deckSize
    static let handSize = 7
    static let minPlayers = 2
    static let maxPlayers = 4
    static let targetScore = 500

    // MARK: - Deck and dealing

    /// The full 108-card deck in a fixed order: per color one 0, two each of 1–9,
    /// Skip, Reverse, and Draw Two (25 × 4 = 100), plus 4 Wild and 4 Wild Draw Four.
    static func fullDeck() -> [Card] {
        var faces: [(CardColor?, CardFace)] = []
        for color in CardColor.allCases {
            faces.append((color, .number(0)))
            for value in 1...9 {
                faces.append((color, .number(value)))
                faces.append((color, .number(value)))
            }
            for action in [CardFace.skip, .reverse, .drawTwo] {
                faces.append((color, action))
                faces.append((color, action))
            }
        }
        for _ in 0..<4 { faces.append((nil, .wild)) }
        for _ in 0..<4 { faces.append((nil, .wildDrawFour)) }
        return faces.enumerated().map { Card(id: $0.offset, color: $0.element.0, face: $0.element.1) }
    }

    static func newMatch(players: [String], using rng: inout some RandomNumberGenerator) -> ColorMatchState {
        newRound(players: players, scores: Dictionary(uniqueKeysWithValues: players.map { ($0, 0) }), round: 1, deck: fullDeck().portableShuffled(using: &rng), using: &rng)
    }

    /// Deals a round from an already-ordered deck. The starting player rotates each round.
    static func newRound(
        players: [String],
        scores: [String: Int],
        round: Int,
        deck: [Card],
        using rng: inout some RandomNumberGenerator
    ) -> ColorMatchState {
        var pile = deck
        var hands: [String: [Card]] = [:]
        for player in players { hands[player] = [] }
        for _ in 0..<handSize {
            for player in players {
                hands[player]?.append(pile.removeLast())
            }
        }

        // Flip a numbered starting card. Action or wild cards go back and the pile is reshuffled.
        var start = pile.removeLast()
        while !isNumber(start) {
            pile.append(start)
            pile.portableShuffle(using: &rng)
            start = pile.removeLast()
        }

        let starter = (round - 1) % players.count
        return ColorMatchState(
            players: players,
            hands: hands,
            drawPile: pile,
            discardPile: [start],
            activeColor: start.color ?? .red,
            currentIndex: starter,
            direction: 1,
            drawnCardId: nil,
            pendingDrawFour: nil,
            vulnerablePlayer: nil,
            scores: scores,
            round: round,
            roundResult: nil,
            matchWinner: nil,
            lastEvent: "Round \(round) started"
        )
    }

    /// Starts the next round, or a fresh match once someone reached the target score.
    static func nextRound(from state: ColorMatchState, using rng: inout some RandomNumberGenerator) -> ColorMatchState {
        if state.matchWinner != nil {
            return newMatch(players: state.players, using: &rng)
        }
        return newRound(players: state.players, scores: state.scores, round: state.round + 1, deck: fullDeck().portableShuffled(using: &rng), using: &rng)
    }

    static func isNumber(_ card: Card) -> Bool {
        if case .number = card.face { return true }
        return false
    }

    // MARK: - Legality

    /// Matches the active color, number, or symbol, or is a wild.
    ///
    /// Wild Draw Four is only *legal* without a card of the active color, but as in the
    /// classic game it can be played as a bluff; the target's challenge is what
    /// enforces the rule (see `isLegalDrawFour` and `respondToDrawFour`).
    static func isPlayable(_ card: Card, on state: ColorMatchState, hand: [Card]) -> Bool {
        if card.face.isWild { return true }
        return card.color == state.activeColor || card.face == state.topCard.face
    }

    /// Whether playing Wild Draw Four from this hand would survive a challenge.
    static func isLegalDrawFour(hand: [Card], activeColor: CardColor) -> Bool {
        !hand.contains { $0.color == activeColor }
    }

    static func playableCardIds(for player: String, in state: ColorMatchState) -> Set<Int> {
        guard state.roundResult == nil, state.pendingDrawFour == nil, state.currentPlayer == player,
              let hand = state.hands[player]
        else { return [] }
        if let drawn = state.drawnCardId {
            return hand.first { $0.id == drawn }.map { isPlayable($0, on: state, hand: hand) ? [drawn] : [] } ?? []
        }
        return Set(hand.filter { isPlayable($0, on: state, hand: hand) }.map(\.id))
    }

    // MARK: - Applying actions

    static func apply(
        _ action: ColorMatchAction,
        by player: String,
        to state: ColorMatchState,
        using rng: inout some RandomNumberGenerator
    ) throws(MoveError) -> ColorMatchState {
        guard state.players.contains(player) else { throw .notAPlayer }
        guard state.roundResult == nil else { throw .gameOver }
        var next = state

        switch action {
        case .catchOne(let target):
            // Anyone except the offender may catch before the deadline.
            // Only while they still hold exactly one card (they may have drawn since).
            guard target != player, next.vulnerablePlayer == target, next.hands[target]?.count == 1 else { throw .notAllowed }
            next.vulnerablePlayer = nil
            draw(2, for: target, in: &next, using: &rng)
            next.lastEvent = "\(nameToken(player)) caught \(nameToken(target)): +2 cards"
            return next

        case .callOne:
            guard next.vulnerablePlayer == player else { throw .notAllowed }
            next.vulnerablePlayer = nil
            next.lastEvent = "\(nameToken(player)) called One!"
            return next

        case .respondToDrawFour(let challenge):
            guard let pending = next.pendingDrawFour, pending.target == player else { throw .notAllowed }
            closeCallOneWindow(actor: player, in: &next)
            next.pendingDrawFour = nil
            if challenge && pending.wasIllegal {
                // Successful challenge: offender draws 4, challenger takes a normal turn.
                draw(4, for: pending.offender, in: &next, using: &rng)
                next.lastEvent = "\(nameToken(player)) challenged and won: \(nameToken(pending.offender)) +4"
            } else if challenge {
                // Failed challenge: challenger draws 6 and loses their turn.
                draw(6, for: player, in: &next, using: &rng)
                advance(by: 1, in: &next)
                next.lastEvent = "\(nameToken(player)) challenged and lost: +6"
            } else {
                draw(4, for: player, in: &next, using: &rng)
                advance(by: 1, in: &next)
                next.lastEvent = "\(nameToken(player)) drew 4"
            }
            return next

        case .draw:
            guard next.pendingDrawFour == nil else { throw .notAllowed }
            guard next.currentPlayer == player else { throw .notYourTurn }
            guard next.drawnCardId == nil else { throw .notAllowed }
            closeCallOneWindow(actor: player, in: &next)
            let drawn = draw(1, for: player, in: &next, using: &rng)
            if let card = drawn.first, let hand = next.hands[player], isPlayable(card, on: next, hand: hand) {
                next.drawnCardId = card.id
                next.lastEvent = "\(nameToken(player)) drew a card"
            } else {
                advance(by: 1, in: &next)
                next.lastEvent = drawn.isEmpty ? "\(nameToken(player)) couldn't draw and passed" : "\(nameToken(player)) drew and passed"
            }
            return next

        case .pass:
            guard next.currentPlayer == player else { throw .notYourTurn }
            guard next.drawnCardId != nil else { throw .notAllowed }
            next.drawnCardId = nil
            advance(by: 1, in: &next)
            next.lastEvent = "\(nameToken(player)) passed"
            return next

        case .play(let cardId, let chosenColor, let callOne):
            guard next.pendingDrawFour == nil else { throw .notAllowed }
            guard next.currentPlayer == player else { throw .notYourTurn }
            guard var hand = next.hands[player], let index = hand.firstIndex(where: { $0.id == cardId }) else { throw .notInHand }
            if let drawn = next.drawnCardId, drawn != cardId { throw .notAllowed }
            let card = hand[index]
            guard isPlayable(card, on: next, hand: hand) else { throw .illegalCard }
            if card.face.isWild, chosenColor == nil { throw .colorRequired }

            closeCallOneWindow(actor: player, in: &next)
            // Legality of Wild Draw Four is judged on the hand at the moment of play.
            let heldActiveColor = !isLegalDrawFour(hand: hand.filter { $0.id != cardId }, activeColor: next.activeColor)

            hand.remove(at: index)
            next.hands[player] = hand
            next.discardPile.append(card)
            next.drawnCardId = nil
            next.activeColor = card.face.isWild ? (chosenColor ?? next.activeColor) : (card.color ?? next.activeColor)
            next.lastEvent = "\(nameToken(player)) played \(card.name)" + (card.face.isWild ? " (\(next.activeColor.name))" : "")

            if hand.count == 1 && !callOne {
                next.vulnerablePlayer = player
            }

            resolveEffect(of: card, playedBy: player, heldActiveColor: heldActiveColor, in: &next, using: &rng)

            if hand.isEmpty {
                finishRound(winner: player, in: &next)
            }
            return next
        }
    }

    /// The deadline for catching a missed "One!" is the next player's first action.
    private static func closeCallOneWindow(actor: String, in state: inout ColorMatchState) {
        if let vulnerable = state.vulnerablePlayer, vulnerable != actor {
            state.vulnerablePlayer = nil
        }
    }

    private static func resolveEffect(
        of card: Card,
        playedBy player: String,
        heldActiveColor: Bool,
        in state: inout ColorMatchState,
        using rng: inout some RandomNumberGenerator
    ) {
        let isFinalCard = state.hands[player]?.isEmpty ?? false
        let twoPlayers = state.players.count == 2

        switch card.face {
        case .number, .wild:
            advance(by: 1, in: &state)
        case .skip:
            state.lastEvent += ". \(nameToken(peekNext(in: state))) is skipped"
            advance(by: 2, in: &state)
        case .reverse:
            if twoPlayers {
                state.lastEvent += ". \(nameToken(peekNext(in: state))) is skipped"
                advance(by: 2, in: &state) // acts as Skip
            } else {
                state.direction *= -1
                advance(by: 1, in: &state)
            }
        case .drawTwo:
            let victim = peekNext(in: state)
            draw(2, for: victim, in: &state, using: &rng)
            state.lastEvent += ". \(nameToken(victim)) draws 2 and is skipped"
            advance(by: 2, in: &state)
        case .wildDrawFour:
            let victim = peekNext(in: state)
            if isFinalCard {
                // Apply the penalty before scoring; no challenge once the round is over.
                draw(4, for: victim, in: &state, using: &rng)
                advance(by: 2, in: &state)
            } else {
                // The target must accept or challenge before play continues.
                state.pendingDrawFour = .init(offender: player, target: victim, wasIllegal: heldActiveColor)
                advance(by: 1, in: &state)
            }
        }
    }

    private static func finishRound(winner: String, in state: inout ColorMatchState) {
        var handPoints: [String: Int] = [:]
        for player in state.players where player != winner {
            handPoints[player] = state.hands[player, default: []].reduce(0) { $0 + $1.face.points }
        }
        let points = handPoints.values.reduce(0, +)
        state.scores[winner, default: 0] += points
        state.roundResult = .init(winner: winner, points: points, handPoints: handPoints)
        state.pendingDrawFour = nil
        state.vulnerablePlayer = nil
        state.drawnCardId = nil
        if state.scores[winner, default: 0] >= targetScore {
            state.matchWinner = winner
        }
        state.lastEvent = "\(nameToken(winner)) won the round (+\(points))"
    }

    // MARK: - Helpers

    private static func peekNext(in state: ColorMatchState) -> String {
        let count = state.players.count
        return state.players[((state.currentIndex + state.direction) % count + count) % count]
    }

    private static func advance(by steps: Int, in state: inout ColorMatchState) {
        let count = state.players.count
        state.currentIndex = ((state.currentIndex + steps * state.direction) % count + count) % count
    }

    /// Draws up to `count` cards, reshuffling the discard pile (keeping the top card)
    /// when the draw pile runs out. Returns the cards actually drawn.
    @discardableResult
    static func draw(_ count: Int, for player: String, in state: inout ColorMatchState, using rng: inout some RandomNumberGenerator) -> [Card] {
        var drawn: [Card] = []
        for _ in 0..<count {
            if state.drawPile.isEmpty {
                guard state.discardPile.count > 1 else { break }
                let top = state.discardPile.removeLast()
                state.drawPile = state.discardPile.portableShuffled(using: &rng)
                state.discardPile = [top]
            }
            guard let card = state.drawPile.popLast() else { break }
            state.hands[player, default: []].append(card)
            drawn.append(card)
        }
        return drawn
    }

    /// Player ids are rendered as names by the UI; events carry a token it can substitute.
    static func nameToken(_ player: String) -> String { "{\(player)}" }

    // MARK: - Projection

    /// The per-player view: own hand plus public counts. No deck order, no other hands.
    static func snapshot(of state: ColorMatchState, for viewer: String) -> ColorMatchSnapshot {
        ColorMatchSnapshot(
            viewer: viewer,
            players: state.players,
            hand: state.hands[viewer] ?? [],
            cardCounts: state.hands.mapValues(\.count),
            topCard: state.topCard,
            activeColor: state.activeColor,
            currentPlayer: state.currentPlayer,
            direction: state.direction,
            drawPileCount: state.drawPile.count,
            drawnCardId: state.currentPlayer == viewer ? state.drawnCardId : nil,
            drawFourTarget: state.pendingDrawFour?.target,
            drawFourOffender: state.pendingDrawFour?.offender,
            vulnerablePlayer: state.vulnerablePlayer,
            scores: state.scores,
            round: state.round,
            roundResult: state.roundResult,
            matchWinner: state.matchWinner,
            lastEvent: state.lastEvent
        )
    }
}
