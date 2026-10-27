/// Tonk (Tunk): a fast rummy for two to four, played to a points target.
///
/// **On which Tonk.** Tonk is a folk game and its rules vary by region — hand size, whether
/// you may hit other people's spreads, and what a caught drop costs all differ from table to
/// table. One consistent ruleset is implemented here and stated plainly in the app's How to
/// Play, so nobody has to guess which version the app means:
///
/// - Five cards each from a standard 52-card deck. Face cards 10, Ace 1, pips at face value.
/// - A dealt hand of exactly 49 or 50 is **Tonk**: an immediate win worth double.
/// - On your turn: draw from the stock or take the top discard, optionally lay down spreads
///   (three or more of a rank, or three or more in sequence in one suit) and hit any spread
///   on the table, then discard one card.
/// - A card just taken from the discard pile can't be discarded again on the same turn.
/// - Playing your last card **goes out** and wins the round.
/// - Instead of drawing you may **drop**. Lowest hand wins. If anyone ties or beats the
///   dropper, the dropper is *caught* and pays double.
/// - The winner scores what the losers were caught holding; first to `targetScore` wins.
///
/// Hidden information: hands and the stock order. Only `snapshot(of:for:)` goes on the wire.
nonisolated enum TonkRules {
    static let minPlayers = 2
    static let maxPlayers = 4
    static let handSize = 5
    static let targetScore = 100
    /// A dealt hand of either value wins immediately.
    static let tonkValues: Set<Int> = [49, 50]
    /// Caps that keep an untrusted snapshot bounded.
    static let maxSpreads = 32
    static let maxSpreadSize = 13

    // MARK: - Setup

    static func newMatch(players: [String], using rng: inout some RandomNumberGenerator) -> TonkState {
        precondition((minPlayers...maxPlayers).contains(players.count), "Tonk takes two to four players")
        var state = TonkState(
            players: players,
            hands: [:],
            stock: [],
            discard: [],
            spreads: [],
            currentIndex: 0,
            phase: .mustDraw,
            tookDiscardId: nil,
            scores: Dictionary(uniqueKeysWithValues: players.map { ($0, 0) }),
            round: 1,
            roundResult: nil,
            matchWinner: nil,
            lastEvent: "New round."
        )
        deal(&state, using: &rng)
        return state
    }

    private static func deal(_ state: inout TonkState, using rng: inout some RandomNumberGenerator) {
        var deck = PlayingCard.freshDeck
        deck.portableShuffle(using: &rng)
        for (offset, player) in state.players.enumerated() {
            state.hands[player] = Array(deck[(offset * handSize)..<((offset + 1) * handSize)])
        }
        var rest = Array(deck.dropFirst(handSize * state.players.count))
        // One card starts the discard pile.
        state.discard = rest.isEmpty ? [] : [rest.removeFirst()]
        state.stock = rest
        state.spreads = []
        state.currentIndex = (state.round - 1) % state.players.count
        state.phase = .mustDraw
        state.tookDiscardId = nil
        state.roundResult = nil

        // A hand of 49 or 50 wins before anyone plays.
        for player in state.players where tonkValues.contains((state.hands[player] ?? []).countingValue) {
            finish(&state, winner: player, reason: .tonk)
            return
        }
    }

    // MARK: - Moves

    static func apply(
        _ action: TonkAction,
        by playerId: String,
        to state: TonkState,
        using rng: inout some RandomNumberGenerator
    ) throws(MoveError) -> TonkState {
        guard state.players.contains(playerId) else { throw .notAPlayer }
        guard state.matchWinner == nil else { throw .gameOver }
        if case .resign = action {
            var next = state
            next.matchWinner = state.players.first { $0 != playerId } ?? playerId
            next.lastEvent = "A player resigned."
            return next
        }
        guard state.roundResult == nil else { throw .gameOver }
        guard state.currentPlayer == playerId else { throw .notYourTurn }

        switch action {
        case .drawFromStock:
            return try drawFromStock(by: playerId, to: state, using: &rng)
        case .takeDiscard:
            return try takeDiscard(by: playerId, to: state)
        case .discard(let cardId):
            return try discard(cardId: cardId, by: playerId, to: state)
        case .spread(let cardIds):
            return try spread(cardIds: cardIds, by: playerId, to: state)
        case .hit(let spreadId, let cardId):
            return try hit(spreadId: spreadId, cardId: cardId, by: playerId, to: state)
        case .drop:
            return try drop(by: playerId, to: state)
        case .resign:
            throw .notAllowed // handled above
        }
    }

    private static func drawFromStock(
        by playerId: String,
        to state: TonkState,
        using rng: inout some RandomNumberGenerator
    ) throws(MoveError) -> TonkState {
        guard state.phase == .mustDraw else { throw .notAllowed }
        var next = state
        if next.stock.isEmpty {
            // Reshuffle the discard pile, keeping its top card in place.
            guard next.discard.count > 1 else {
                // Nothing left anywhere: lowest hand takes the round.
                finishByCount(&next, reason: .stockExhausted)
                return next
            }
            let top = next.discard.removeLast()
            next.stock = next.discard.portableShuffled(using: &rng)
            next.discard = [top]
        }
        let card = next.stock.removeLast()
        next.hands[playerId, default: []].append(card)
        next.phase = .mustDiscard
        next.tookDiscardId = nil
        next.lastEvent = "Drew from the stock."
        return next
    }

    private static func takeDiscard(by playerId: String, to state: TonkState) throws(MoveError) -> TonkState {
        guard state.phase == .mustDraw else { throw .notAllowed }
        var next = state
        guard let card = next.discard.popLast() else { throw .notAllowed }
        next.hands[playerId, default: []].append(card)
        next.phase = .mustDiscard
        // Barred from being discarded straight back this turn.
        next.tookDiscardId = card.id
        next.lastEvent = "Took \(card.shortName) from the pile."
        return next
    }

    private static func discard(cardId: Int, by playerId: String, to state: TonkState) throws(MoveError) -> TonkState {
        guard state.phase == .mustDiscard else { throw .notAllowed }
        guard let card = PlayingCard(id: cardId) else { throw .outOfBounds }
        guard var hand = state.hands[playerId], hand.contains(card) else { throw .notInHand }
        guard cardId != state.tookDiscardId else { throw .illegalCard }

        var next = state
        hand.removeAll { $0 == card }
        next.hands[playerId] = hand
        next.discard.append(card)
        next.tookDiscardId = nil
        next.lastEvent = "Discarded \(card.shortName)."

        if hand.isEmpty {
            finish(&next, winner: playerId, reason: .wentOut)
            return next
        }
        next.currentIndex = (next.currentIndex + 1) % next.players.count
        next.phase = .mustDraw
        return next
    }

    private static func spread(cardIds: [Int], by playerId: String, to state: TonkState) throws(MoveError) -> TonkState {
        guard state.phase == .mustDiscard else { throw .notAllowed }
        guard state.spreads.count < maxSpreads else { throw .notAllowed }
        let cards = cardIds.compactMap(PlayingCard.init(id:))
        guard cards.count == cardIds.count else { throw .outOfBounds }
        guard var hand = state.hands[playerId], cards.allSatisfy(hand.contains) else { throw .notInHand }
        guard let kind = classify(cards) else { throw .illegalCard }
        // Spreading everything would leave nothing to discard, and a turn must end in a
        // discard — so going out happens on the discard, not here.
        guard hand.count - cards.count >= 1 else { throw .notAllowed }

        var next = state
        for card in cards { hand.removeAll { $0 == card } }
        next.hands[playerId] = hand
        let id = (next.spreads.map(\.id).max() ?? -1) + 1
        next.spreads.append(TonkSpread(id: id, owner: playerId, cards: sortSpread(cards, kind: kind), kind: kind))
        next.lastEvent = kind == .set ? "Spread a set." : "Spread a run."
        return next
    }

    private static func hit(spreadId: Int, cardId: Int, by playerId: String, to state: TonkState) throws(MoveError) -> TonkState {
        guard state.phase == .mustDiscard else { throw .notAllowed }
        guard let card = PlayingCard(id: cardId) else { throw .outOfBounds }
        guard var hand = state.hands[playerId], hand.contains(card) else { throw .notInHand }
        guard let index = state.spreads.firstIndex(where: { $0.id == spreadId }) else { throw .outOfBounds }
        var spread = state.spreads[index]
        guard spread.cards.count < maxSpreadSize else { throw .notAllowed }
        guard classify(sortSpread(spread.cards + [card], kind: spread.kind)) == spread.kind else { throw .illegalCard }
        guard hand.count >= 2 else { throw .notAllowed } // must keep one to discard

        var next = state
        hand.removeAll { $0 == card }
        next.hands[playerId] = hand
        spread.cards = sortSpread(spread.cards + [card], kind: spread.kind)
        next.spreads[index] = spread
        next.lastEvent = "Hit a spread with \(card.shortName)."
        return next
    }

    private static func drop(by playerId: String, to state: TonkState) throws(MoveError) -> TonkState {
        // Only before drawing: dropping after seeing a new card would make it a free look.
        guard state.phase == .mustDraw else { throw .notAllowed }
        var next = state
        let mine = (next.hands[playerId] ?? []).countingValue
        let lowestOther = next.players
            .filter { $0 != playerId }
            .map { (next.hands[$0] ?? []).countingValue }
            .min() ?? Int.max

        if mine < lowestOther {
            finish(&next, winner: playerId, reason: .drop)
        } else {
            // Caught: whoever is lowest wins, and the dropper pays double.
            let winner = next.players
                .filter { $0 != playerId }
                .min { ((next.hands[$0] ?? []).countingValue, $0) < ((next.hands[$1] ?? []).countingValue, $1) }
            finish(&next, winner: winner ?? playerId, reason: .caught, caught: playerId)
        }
        return next
    }

    // MARK: - Round ends

    /// Lowest hand wins when nobody went out and the cards ran out.
    private static func finishByCount(_ state: inout TonkState, reason: TonkState.RoundResult.Reason) {
        let winner = state.players.min {
            ((state.hands[$0] ?? []).countingValue, $0) < ((state.hands[$1] ?? []).countingValue, $1)
        }
        finish(&state, winner: winner ?? state.players[0], reason: reason)
    }

    /// Settles a round: the winner scores what everyone else was holding.
    private static func finish(
        _ state: inout TonkState,
        winner: String,
        reason: TonkState.RoundResult.Reason,
        caught: String? = nil
    ) {
        let handValues = Dictionary(uniqueKeysWithValues: state.players.map { ($0, (state.hands[$0] ?? []).countingValue) })
        var points = state.players
            .filter { $0 != winner }
            .reduce(0) { $0 + (handValues[$1] ?? 0) }
        // Tonk and a caught drop are both worth double, which is what makes dropping a risk.
        if reason == .tonk || reason == .caught { points *= 2 }

        state.scores[winner, default: 0] += points
        state.roundResult = TonkState.RoundResult(
            winner: winner,
            reason: reason,
            handValues: handValues,
            points: points
        )
        state.phase = .roundOver
        state.lastEvent = switch reason {
        case .tonk: "Tonk! Dealt 49 or 50."
        case .wentOut: "Went out."
        case .drop: "Dropped with the lowest hand."
        case .caught: "Caught the drop — double."
        case .stockExhausted: "Cards ran out; lowest hand wins."
        }
        _ = caught
        if (state.scores[winner] ?? 0) >= targetScore {
            state.matchWinner = winner
        }
    }

    /// Next round, keeping scores. A finished match starts over.
    static func nextRound(from state: TonkState, using rng: inout some RandomNumberGenerator) -> TonkState {
        var next = state
        if next.matchWinner != nil {
            next.scores = Dictionary(uniqueKeysWithValues: next.players.map { ($0, 0) })
            next.round = 1
            next.matchWinner = nil
        } else {
            next.round += 1
        }
        deal(&next, using: &rng)
        if next.roundResult == nil { next.lastEvent = "New round." }
        return next
    }

    // MARK: - Melds

    /// Whether `cards` form a valid set or run, or neither.
    static func classify(_ cards: [PlayingCard]) -> TonkSpread.Kind? {
        guard cards.count >= 3, Set(cards).count == cards.count else { return nil }
        if Set(cards.map(\.rank)).count == 1 { return .set }

        guard Set(cards.map(\.suit)).count == 1 else { return nil }
        let ranks = cards.map(\.rank).sorted()
        // Ace is high here, consistent with the rest of the app, so Q-K-A runs and A-2-3
        // does not. Stated in How to Play so it isn't a surprise.
        guard zip(ranks, ranks.dropFirst()).allSatisfy({ $1 == $0 + 1 }) else { return nil }
        return .run
    }

    /// Runs read low to high; sets are grouped by suit so they look tidy.
    static func sortSpread(_ cards: [PlayingCard], kind: TonkSpread.Kind) -> [PlayingCard] {
        switch kind {
        case .run: cards.sorted { $0.rank < $1.rank }
        case .set: cards.sorted { $0.suit.rawValue < $1.suit.rawValue }
        }
    }

    /// Spreads the given cards could legally form, for the view's "Spread" affordance.
    static func suggestedSpreads(in hand: [PlayingCard]) -> [[PlayingCard]] {
        var found: [[PlayingCard]] = []
        // Sets: any rank the player holds three or more of.
        let byRank = Dictionary(grouping: hand, by: \.rank)
        for (_, cards) in byRank where cards.count >= 3 {
            found.append(cards.sorted { $0.suit.rawValue < $1.suit.rawValue })
        }
        // Runs: the longest consecutive block in each suit, if it reaches three.
        let bySuit = Dictionary(grouping: hand, by: \.suit)
        for (_, cards) in bySuit {
            let ranks = cards.map(\.rank).sorted()
            var block: [Int] = []
            for rank in ranks {
                if let last = block.last, rank != last + 1 {
                    if block.count >= 3 { found.append(cards.filter { block.contains($0.rank) }.sorted { $0.rank < $1.rank }) }
                    block = []
                }
                block.append(rank)
            }
            if block.count >= 3 {
                found.append(cards.filter { block.contains($0.rank) }.sorted { $0.rank < $1.rank })
            }
        }
        return found
    }

    // MARK: - Projection

    static func snapshot(of state: TonkState, for playerId: String) -> TonkSnapshot {
        TonkSnapshot(
            viewer: playerId,
            players: state.players,
            hand: (state.hands[playerId] ?? []).sortedForDisplay,
            cardCounts: state.hands.mapValues(\.count),
            spreads: state.spreads,
            topDiscard: state.topDiscard,
            stockCount: state.stock.count,
            currentPlayer: state.currentPlayer,
            phase: state.phase,
            tookDiscardId: state.currentPlayer == playerId ? state.tookDiscardId : nil,
            scores: state.scores,
            round: state.round,
            roundResult: state.roundResult,
            matchWinner: state.matchWinner,
            lastEvent: state.lastEvent
        )
    }
}
