import Foundation

// Color Match: CruiseLAN's original take on classic shedding-card rules
// (see 03-GAME-RULES.md). Original name, symbols, and art.

nonisolated enum CardColor: String, Codable, Sendable, CaseIterable, Identifiable {
    case red, yellow, green, blue

    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}

nonisolated enum CardFace: Codable, Equatable, Hashable, Sendable {
    case number(Int)
    case skip
    case reverse
    case drawTwo
    case wild
    case wildDrawFour

    var isWild: Bool { self == .wild || self == .wildDrawFour }

    /// Scoring value for cards left in a hand at the end of a round.
    var points: Int {
        switch self {
        case .number(let value): value
        case .skip, .reverse, .drawTwo: 20
        case .wild, .wildDrawFour: 50
        }
    }

    var name: String {
        switch self {
        case .number(let value): "\(value)"
        case .skip: "Skip"
        case .reverse: "Reverse"
        case .drawTwo: "Draw Two"
        case .wild: "Wild"
        case .wildDrawFour: "Wild Draw Four"
        }
    }
}

nonisolated struct Card: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Unique within a deck (0..<108), so actions can reference a specific card.
    let id: Int
    /// `nil` for wild cards.
    let color: CardColor?
    let face: CardFace

    var name: String {
        if let color { return "\(color.name) \(face.name)" }
        return face.name
    }
}

/// Everything a player can ask the host to do in Color Match.
nonisolated enum ColorMatchAction: Codable, Equatable, Sendable {
    /// `callOne` is the "Call One!" button pressed while playing the second-to-last card.
    case play(cardId: Int, chosenColor: CardColor?, callOne: Bool)
    case draw
    /// Only allowed after drawing a card that could be played.
    case pass
    /// Target of a Wild Draw Four: accept the four cards or challenge.
    case respondToDrawFour(challenge: Bool)
    /// "Call One!" pressed after the play, before the deadline.
    case callOne
    case catchOne(target: String)

    var isStructurallyValid: Bool {
        switch self {
        case .play(let cardId, _, _): ColorMatchRules.deckRange.contains(cardId)
        case .catchOne(let target): !target.isEmpty && target.count <= 64
        case .draw, .pass, .respondToDrawFour, .callOne: true
        }
    }
}

/// Host-only authoritative state. Never sent over the network as-is.
nonisolated struct ColorMatchState: Equatable, Sendable {
    struct PendingDrawFour: Equatable, Sendable {
        let offender: String
        let target: String
        /// Whether the offender held a card of the active color when they played it.
        let wasIllegal: Bool
    }

    struct RoundResult: Codable, Equatable, Sendable {
        let winner: String
        let points: Int
        /// Points each loser was holding.
        let handPoints: [String: Int]
    }

    var players: [String]
    var hands: [String: [Card]]
    var drawPile: [Card]
    var discardPile: [Card]
    var activeColor: CardColor
    var currentIndex: Int
    /// +1 clockwise, -1 counter-clockwise.
    var direction: Int
    /// Card the current player just drew and may still play (draw-then-play).
    var drawnCardId: Int?
    var pendingDrawFour: PendingDrawFour?
    /// Player who reached one card without calling it, until the next player acts.
    var vulnerablePlayer: String?
    var scores: [String: Int]
    var round: Int
    var roundResult: RoundResult?
    var matchWinner: String?
    /// Short public description of the last thing that happened.
    var lastEvent: String

    var currentPlayer: String { players[currentIndex] }
    var topCard: Card { discardPile[discardPile.count - 1] }
    var isRoundOver: Bool { roundResult != nil }
}

/// What one player is allowed to see: their own hand plus public information.
/// The deck order and other players' cards are never included.
nonisolated struct ColorMatchSnapshot: Codable, Equatable, Sendable {
    var viewer: String
    var players: [String]
    var hand: [Card]
    var cardCounts: [String: Int]
    var topCard: Card
    var activeColor: CardColor
    var currentPlayer: String
    var direction: Int
    var drawPileCount: Int
    /// The viewer's own drawn card they may still play.
    var drawnCardId: Int?
    /// Target who must accept or challenge a Wild Draw Four.
    var drawFourTarget: String?
    var drawFourOffender: String?
    var vulnerablePlayer: String?
    var scores: [String: Int]
    var round: Int
    var roundResult: ColorMatchState.RoundResult?
    var matchWinner: String?
    var lastEvent: String

    var isStructurallyValid: Bool {
        (ColorMatchRules.minPlayers...ColorMatchRules.maxPlayers).contains(players.count)
            && Set(players).count == players.count
            && players.contains(viewer)
            && players.contains(currentPlayer)
            && hand.count <= ColorMatchRules.deckSize
            && cardCounts.values.allSatisfy { (0...ColorMatchRules.deckSize).contains($0) }
            && (0...ColorMatchRules.deckSize).contains(drawPileCount)
            && (direction == 1 || direction == -1)
            && lastEvent.count <= 200
            && round >= 1
    }
}
