import Foundation

/// A card from a standard 52-card deck, shared by every card game in CruiseLAN.
///
/// Color Match has its own `Card` type because it isn't a standard deck (four colours,
/// action faces, 108 cards). Anything played with a real deck — Spades, Tonk, and any future
/// card game — uses this one, so the deck, shuffling, and sorting are written once.
///
/// `id` is the card's index in a fresh deck (0..<52), which makes a card referable in a move
/// without putting the whole card on the wire, and makes "is this a real card" a range check.
nonisolated struct PlayingCard: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// 0..<52, equal to `suit.rawValue * 13 + (rank - 2)`.
    let id: Int

    var suit: Suit { Suit(rawValue: id / 13) ?? .clubs }
    /// 2...14, where 11–14 are J, Q, K, A. Ace is high in both games that use this.
    var rank: Int { id % 13 + 2 }

    init?(id: Int) {
        guard PlayingCard.deckRange.contains(id) else { return nil }
        self.id = id
    }

    init(suit: Suit, rank: Int) {
        id = suit.rawValue * 13 + (rank - 2)
    }

    static let deckSize = 52
    static let deckRange = 0..<deckSize

    /// A fresh deck in order. Callers shuffle.
    static var freshDeck: [PlayingCard] {
        deckRange.compactMap { PlayingCard(id: $0) }
    }

    nonisolated enum Suit: Int, Codable, Sendable, CaseIterable, Identifiable {
        case clubs = 0
        case diamonds = 1
        case hearts = 2
        case spades = 3

        var id: Int { rawValue }

        var symbol: String {
            switch self {
            case .clubs: "♣"
            case .diamonds: "♦"
            case .hearts: "♥"
            case .spades: "♠"
            }
        }

        var name: String {
            switch self {
            case .clubs: "Clubs"
            case .diamonds: "Diamonds"
            case .hearts: "Hearts"
            case .spades: "Spades"
            }
        }

        /// Diamonds and hearts are drawn red. Used for display only — never for rules, so a
        /// colour-blind player is never asked to tell two suits apart by colour alone.
        var isRed: Bool { self == .diamonds || self == .hearts }
    }

    /// "A", "K", "Q", "J", or the number.
    var rankName: String {
        switch rank {
        case 14: "A"
        case 13: "K"
        case 12: "Q"
        case 11: "J"
        default: "\(rank)"
        }
    }

    var shortName: String { "\(rankName)\(suit.symbol)" }

    /// Spoken form, for VoiceOver — "♠" reads poorly.
    var spokenName: String {
        let rankWord = switch rank {
        case 14: "Ace"
        case 13: "King"
        case 12: "Queen"
        case 11: "Jack"
        default: "\(rank)"
        }
        return "\(rankWord) of \(suit.name)"
    }

    /// Value when counting a hand: face cards 10, Ace 1, pips at face value.
    /// Used by Tonk; Spades doesn't count card values at all.
    var countingValue: Int {
        switch rank {
        case 14: 1
        case 13, 12, 11: 10
        default: rank
        }
    }
}

extension Array where Element == PlayingCard {
    /// Sorted for display: grouped by suit, high rank first within a suit. Keeping this in
    /// one place means a hand looks the same in every game.
    var sortedForDisplay: [PlayingCard] {
        sorted { ($0.suit.rawValue, -$0.rank) < ($1.suit.rawValue, -$1.rank) }
    }

    var countingValue: Int {
        reduce(0) { $0 + $1.countingValue }
    }
}
