import Foundation

/// What a player can ask the host to do in Spades.
nonisolated enum SpadesAction: Codable, Equatable, Sendable {
    /// Tricks this player expects to take. 0 is a nil bid.
    case bid(tricks: Int)
    case play(cardId: Int)
    case resign

    /// Cheap bounds check at decode time, before any rules run.
    var isStructurallyValid: Bool {
        switch self {
        case .bid(let tricks): (0...SpadesRules.handSize).contains(tricks)
        case .play(let cardId): PlayingCard.deckRange.contains(cardId)
        case .resign: true
        }
    }
}

/// Which part of a hand is in progress.
nonisolated enum SpadesPhase: String, Codable, Equatable, Sendable {
    case bidding
    case playing
    case handOver
}

/// Host-only authoritative state: holds every hand, so it never goes on the wire as-is.
nonisolated struct SpadesState: Equatable, Sendable {
    /// One card played into the current trick.
    struct Play: Codable, Equatable, Sendable, Identifiable {
        let player: String
        let card: PlayingCard

        var id: Int { card.id }
    }

    struct RoundResult: Codable, Equatable, Sendable {
        /// Points each team gained or lost this hand.
        let teamScores: [String: Int]
        let tricksWon: [String: Int]
        let bids: [String: Int]
        /// For players who bid nil: whether they made it.
        let nilResults: [String: Bool]
    }

    var players: [String]
    var hands: [String: [PlayingCard]]
    var bids: [String: Int]
    var tricksWon: [String: Int]
    var currentIndex: Int
    var leaderIndex: Int
    var trick: [Play]
    /// Whether a spade has been played on a trick someone couldn't follow.
    var spadesBroken: Bool
    var scores: [String: Int]
    var bags: [String: Int]
    var round: Int
    var roundResult: RoundResult?
    var matchWinner: String?
    var lastEvent: String

    /// Kept so the table can show the trick that just finished rather than clearing instantly.
    var lastTrick: [Play]?
    var lastTrickWinner: String?
    var lastLedSuit: PlayingCard.Suit?

    var currentPlayer: String { players[currentIndex] }

    var phase: SpadesPhase {
        if roundResult != nil { return .handOver }
        return bids.count < SpadesRules.playerCount ? .bidding : .playing
    }
}

/// What one player is allowed to see: their own hand, plus public information.
/// Other players' cards and the deal order are never included.
nonisolated struct SpadesSnapshot: Codable, Equatable, Sendable {
    var viewer: String
    var players: [String]
    var hand: [PlayingCard]
    /// Ids from `hand` that are legal right now, so the view can disable the rest instead of
    /// letting a player tap a card the host will refuse.
    var legalPlays: [Int]
    var cardCounts: [String: Int]
    var bids: [String: Int]
    var tricksWon: [String: Int]
    var trick: [SpadesState.Play]
    var lastTrick: [SpadesState.Play]?
    var lastTrickWinner: String?
    var currentPlayer: String
    var spadesBroken: Bool
    var scores: [String: Int]
    var bags: [String: Int]
    var round: Int
    var phase: SpadesPhase
    var roundResult: SpadesState.RoundResult?
    var matchWinner: String?
    var lastEvent: String

    /// The viewer's partner, who sits opposite.
    var partner: String? {
        guard let seat = players.firstIndex(of: viewer), players.count == SpadesRules.playerCount else { return nil }
        return players[(seat + 2) % SpadesRules.playerCount]
    }

    var viewerTeam: String? {
        players.firstIndex(of: viewer).map(SpadesRules.team(ofSeat:))
    }

    /// Combined bid for the viewer's team, once both partners have bid.
    func teamBid(_ teamId: String) -> Int? {
        let seats = players.indices.filter { SpadesRules.team(ofSeat: $0) == teamId }
        let values = seats.compactMap { bids[players[$0]] }
        guard values.count == seats.count else { return nil }
        return values.reduce(0, +)
    }

    func teamTricks(_ teamId: String) -> Int {
        players.indices
            .filter { SpadesRules.team(ofSeat: $0) == teamId }
            .reduce(0) { $0 + (tricksWon[players[$1]] ?? 0) }
    }

    /// Validated on receipt: a snapshot from a peer is untrusted input like any other packet.
    var isStructurallyValid: Bool {
        players.count == SpadesRules.playerCount
            && Set(players).count == players.count
            && players.contains(viewer)
            && players.contains(currentPlayer)
            && hand.count <= SpadesRules.handSize
            && Set(hand).count == hand.count
            && legalPlays.allSatisfy { PlayingCard.deckRange.contains($0) }
            && cardCounts.values.allSatisfy { (0...SpadesRules.handSize).contains($0) }
            && bids.values.allSatisfy { (0...SpadesRules.handSize).contains($0) }
            && tricksWon.values.allSatisfy { (0...SpadesRules.handSize).contains($0) }
            && trick.count <= SpadesRules.playerCount
            && (lastTrick?.count ?? 0) <= SpadesRules.playerCount
            && round >= 1
            && lastEvent.count <= 200
    }
}
