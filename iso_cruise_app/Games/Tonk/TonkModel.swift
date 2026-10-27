/// What a player can ask the host to do in Tonk.
nonisolated enum TonkAction: Codable, Equatable, Sendable {
    case drawFromStock
    case takeDiscard
    case discard(cardId: Int)
    /// Lay down a set or run of three or more.
    case spread(cardIds: [Int])
    /// Add a card to a spread already on the table.
    case hit(spreadId: Int, cardId: Int)
    /// Claim the lowest hand and end the round.
    case drop
    case resign

    var isStructurallyValid: Bool {
        switch self {
        case .discard(let cardId):
            PlayingCard.deckRange.contains(cardId)
        case .spread(let cardIds):
            // Bounded before any rules run: a spread can never be larger than a hand, and
            // duplicate ids would otherwise let one card be counted twice.
            (3...TonkRules.maxSpreadSize).contains(cardIds.count)
                && Set(cardIds).count == cardIds.count
                && cardIds.allSatisfy { PlayingCard.deckRange.contains($0) }
        case .hit(let spreadId, let cardId):
            spreadId >= 0 && spreadId < TonkRules.maxSpreads && PlayingCard.deckRange.contains(cardId)
        case .drawFromStock, .takeDiscard, .drop, .resign:
            true
        }
    }
}

/// A set (three or more of a rank) or a run (three or more in sequence, one suit) on the table.
nonisolated struct TonkSpread: Codable, Equatable, Sendable, Identifiable {
    let id: Int
    /// Who laid it down. Anyone may hit any spread.
    let owner: String
    var cards: [PlayingCard]

    enum Kind: String, Codable, Sendable {
        case set
        case run
    }

    var kind: Kind

    var value: Int { cards.countingValue }
}

nonisolated enum TonkPhase: String, Codable, Equatable, Sendable {
    /// The player must draw before doing anything else.
    case mustDraw
    /// Drawn; may spread, hit, then must discard.
    case mustDiscard
    case roundOver
}

/// Host-only authoritative state: holds every hand and the stock order.
nonisolated struct TonkState: Equatable, Sendable {
    struct RoundResult: Codable, Equatable, Sendable {
        let winner: String
        /// How the round ended, for the summary line.
        let reason: Reason
        /// Points each player was caught holding.
        let handValues: [String: Int]
        let points: Int

        enum Reason: String, Codable, Sendable {
            /// Dealt 49 or 50 — an instant win, double stake.
            case tonk
            /// Went out by playing every card.
            case wentOut
            /// Dropped with the lowest hand.
            case drop
            /// Dropped but someone was lower or tied: the dropper pays double.
            case caught
            case stockExhausted
        }
    }

    var players: [String]
    var hands: [String: [PlayingCard]]
    var stock: [PlayingCard]
    var discard: [PlayingCard]
    var spreads: [TonkSpread]
    var currentIndex: Int
    var phase: TonkPhase
    /// Set when the current player took the top discard, which bars discarding it straight back.
    var tookDiscardId: Int?
    var scores: [String: Int]
    var round: Int
    var roundResult: RoundResult?
    var matchWinner: String?
    var lastEvent: String

    var currentPlayer: String { players[currentIndex] }
    var topDiscard: PlayingCard? { discard.last }
}

/// What one player may see: their own hand, the spreads, counts, and the top discard.
nonisolated struct TonkSnapshot: Codable, Equatable, Sendable {
    var viewer: String
    var players: [String]
    var hand: [PlayingCard]
    var cardCounts: [String: Int]
    var spreads: [TonkSpread]
    var topDiscard: PlayingCard?
    var stockCount: Int
    var currentPlayer: String
    var phase: TonkPhase
    var tookDiscardId: Int?
    var scores: [String: Int]
    var round: Int
    var roundResult: TonkState.RoundResult?
    var matchWinner: String?
    var lastEvent: String

    /// The viewer's hand value, shown so they can judge whether to drop. This is their own
    /// information, so showing it reveals nothing.
    var handValue: Int { hand.countingValue }

    /// Whether dropping is allowed: only at the start of a turn, before drawing.
    var canDrop: Bool { currentPlayer == viewer && phase == .mustDraw }

    var isStructurallyValid: Bool {
        (TonkRules.minPlayers...TonkRules.maxPlayers).contains(players.count)
            && Set(players).count == players.count
            && players.contains(viewer)
            && players.contains(currentPlayer)
            && hand.count <= PlayingCard.deckSize
            && Set(hand).count == hand.count
            && spreads.count <= TonkRules.maxSpreads
            && spreads.allSatisfy { $0.cards.count <= TonkRules.maxSpreadSize }
            && (0...PlayingCard.deckSize).contains(stockCount)
            && cardCounts.values.allSatisfy { (0...PlayingCard.deckSize).contains($0) }
            && round >= 1
            && lastEvent.count <= 200
    }
}

/// Storage only: the cloud game server saves the full table between moves. Players only ever
/// receive `TonkSnapshot`.
extension TonkState: Codable {}
