/// Spades: four players in two fixed partnerships, bidding and trick-taking.
///
/// Seats 0 and 2 are one team, seats 1 and 3 the other, so partners sit opposite — the
/// standard arrangement. The ruleset here is the common North American one:
///
/// - 13 cards each, Ace high, spades are always trump.
/// - Everyone bids the number of tricks they expect, 0–13. A bid of 0 is **nil**.
/// - Spades can't be *led* until they're "broken" (a spade has been played on a trick someone
///   couldn't follow), unless the leader holds nothing else.
/// - A team making its combined bid scores 10 per trick bid, plus 1 per overtrick ("bag").
///   Missing it loses 10 per trick bid. Ten accumulated bags cost 100.
/// - Nil scores ±100 for that player, separately from the partnership's bid.
/// - First team to `targetScore` wins.
///
/// Hidden information: each player's hand. `snapshot(of:for:)` is the only thing that ever
/// goes on the wire, and it contains the viewer's hand and nothing of anyone else's.
nonisolated enum SpadesRules {
    static let playerCount = 4
    static let handSize = 13
    static let targetScore = 500
    /// Bags that trigger the penalty, and what it costs.
    static let bagLimit = 10
    static let bagPenalty = 100
    static let nilBonus = 100

    // MARK: - Setup

    static func newGame(players: [String], using rng: inout some RandomNumberGenerator) -> SpadesState {
        precondition(players.count == playerCount, "Spades is a four-player game")
        var state = SpadesState(
            players: players,
            hands: [:],
            bids: [:],
            tricksWon: [:],
            currentIndex: 0,
            leaderIndex: 0,
            trick: [],
            spadesBroken: false,
            scores: [teamA: 0, teamB: 0],
            bags: [teamA: 0, teamB: 0],
            round: 1,
            roundResult: nil,
            matchWinner: nil,
            lastEvent: "Place your bids."
        )
        deal(&state, using: &rng)
        return state
    }

    /// Deals a fresh hand and resets everything round-scoped. Scores and bags carry over.
    private static func deal(_ state: inout SpadesState, using rng: inout some RandomNumberGenerator) {
        var deck = PlayingCard.freshDeck
        deck.portableShuffle(using: &rng)
        for (offset, player) in state.players.enumerated() {
            state.hands[player] = Array(deck[(offset * handSize)..<((offset + 1) * handSize)])
        }
        state.bids = [:]
        state.tricksWon = Dictionary(uniqueKeysWithValues: state.players.map { ($0, 0) })
        state.trick = []
        state.spadesBroken = false
        // The deal rotates each round, so the same player doesn't always lead.
        state.leaderIndex = (state.round - 1) % playerCount
        state.currentIndex = state.leaderIndex
        state.roundResult = nil
    }

    /// Team identifiers. Partnerships are by seat, so they're stable for the whole match.
    static let teamA = "A"
    static let teamB = "B"

    static func team(ofSeat index: Int) -> String {
        index % 2 == 0 ? teamA : teamB
    }

    static func team(of player: String, in state: SpadesState) -> String? {
        state.players.firstIndex(of: player).map(team(ofSeat:))
    }

    // MARK: - Moves

    static func apply(
        _ action: SpadesAction,
        by playerId: String,
        to state: SpadesState,
        using rng: inout some RandomNumberGenerator
    ) throws(MoveError) -> SpadesState {
        guard state.players.contains(playerId) else { throw .notAPlayer }
        guard state.matchWinner == nil else { throw .gameOver }

        switch action {
        case .bid(let tricks):
            return try bid(tricks, by: playerId, to: state)
        case .play(let cardId):
            return try play(cardId: cardId, by: playerId, to: state, using: &rng)
        case .resign:
            var next = state
            // Resigning hands the match to the other team rather than ending in a void.
            guard let quitting = team(of: playerId, in: state) else { throw .notAPlayer }
            next.matchWinner = quitting == teamA ? teamB : teamA
            next.lastEvent = "A player resigned."
            return next
        }
    }

    private static func bid(_ tricks: Int, by playerId: String, to state: SpadesState) throws(MoveError) -> SpadesState {
        guard state.phase == .bidding else { throw .notAllowed }
        guard (0...handSize).contains(tricks) else { throw .outOfBounds }
        guard state.currentPlayer == playerId else { throw .notYourTurn }
        guard state.bids[playerId] == nil else { throw .notAllowed }

        var next = state
        next.bids[playerId] = tricks
        next.lastEvent = tricks == 0 ? "A nil bid." : "Bid of \(tricks)."
        if next.bids.count == playerCount {
            // Everyone has bid; the dealer's left leads.
            next.currentIndex = next.leaderIndex
            next.lastEvent = "Bidding complete. Play begins."
        } else {
            next.currentIndex = (next.currentIndex + 1) % playerCount
        }
        return next
    }

    private static func play(
        cardId: Int,
        by playerId: String,
        to state: SpadesState,
        using rng: inout some RandomNumberGenerator
    ) throws(MoveError) -> SpadesState {
        guard state.phase == .playing else { throw .notAllowed }
        guard state.currentPlayer == playerId else { throw .notYourTurn }
        guard let card = PlayingCard(id: cardId) else { throw .outOfBounds }
        guard var hand = state.hands[playerId], hand.contains(card) else { throw .notInHand }
        guard legalPlays(for: playerId, in: state).contains(card) else {
            throw state.trick.isEmpty ? .notAllowed : .illegalCard
        }

        var next = state
        hand.removeAll { $0 == card }
        next.hands[playerId] = hand
        next.trick.append(SpadesState.Play(player: playerId, card: card))
        if card.suit == .spades { next.spadesBroken = true }
        next.lastEvent = "Played \(card.shortName)."

        if next.trick.count == playerCount {
            // Trick complete: award it and lead from the winner.
            let winner = winnerOfTrick(next.trick)
            next.tricksWon[winner, default: 0] += 1
            next.lastLedSuit = next.trick.first?.card.suit
            next.lastTrick = next.trick
            next.lastTrickWinner = winner
            next.trick = []
            next.leaderIndex = next.players.firstIndex(of: winner) ?? next.leaderIndex
            next.currentIndex = next.leaderIndex
            next.lastEvent = "Trick won."

            if next.hands.values.allSatisfy(\.isEmpty) {
                score(&next)
                if next.matchWinner == nil { /* next round starts on rematch */ }
            }
        } else {
            next.currentIndex = (next.currentIndex + 1) % playerCount
        }
        return next
    }

    /// Cards `playerId` may legally play right now.
    ///
    /// Exposed so the view can grey out the rest: a trick-taking game where the app silently
    /// refuses a tap is miserable to learn.
    static func legalPlays(for playerId: String, in state: SpadesState) -> [PlayingCard] {
        guard let hand = state.hands[playerId], state.phase == .playing else { return [] }
        guard let led = state.trick.first?.card.suit else {
            // Leading. Spades are barred until broken, unless that's all there is.
            let nonSpades = hand.filter { $0.suit != .spades }
            return state.spadesBroken || nonSpades.isEmpty ? hand : nonSpades
        }
        let following = hand.filter { $0.suit == led }
        return following.isEmpty ? hand : following
    }

    /// Highest spade if any were played, otherwise the highest card of the led suit.
    static func winnerOfTrick(_ trick: [SpadesState.Play]) -> String {
        let spades = trick.filter { $0.card.suit == .spades }
        if let best = spades.max(by: { $0.card.rank < $1.card.rank }) { return best.player }
        let led = trick[0].card.suit
        let followers = trick.filter { $0.card.suit == led }
        return followers.max(by: { $0.card.rank < $1.card.rank })?.player ?? trick[0].player
    }

    // MARK: - Scoring

    /// What one hand did to each team, before it's applied to the running totals.
    ///
    /// Separated from `score(_:)` because this is the part worth testing: it's pure
    /// arithmetic over bids and tricks, and reaching it through a contrived final trick
    /// tested the trick logic rather than the scoring.
    struct HandScore: Equatable, Sendable {
        /// Points gained or lost, excluding the ten-bag penalty.
        var teamScores: [String: Int]
        /// Bags earned this hand.
        var teamBags: [String: Int]
        /// For players who bid nil: whether they made it.
        var nilResults: [String: Bool]
    }

    static func scoreHand(players: [String], bids: [String: Int], tricksWon: [String: Int]) -> HandScore {
        var result = HandScore(teamScores: [:], teamBags: [:], nilResults: [:])

        for teamId in [teamA, teamB] {
            let members = players.indices
                .filter { team(ofSeat: $0) == teamId }
                .map { players[$0] }

            var contracted = 0
            var takenTowardContract = 0
            var delta = 0
            var nilTricks = 0

            for player in members {
                let bidValue = bids[player] ?? 0
                let won = tricksWon[player] ?? 0
                if bidValue == 0 {
                    // Nil scores on its own and its tricks don't help the team's contract —
                    // they become bags, which is what makes a failed nil doubly painful.
                    let made = won == 0
                    result.nilResults[player] = made
                    delta += made ? nilBonus : -nilBonus
                    nilTricks += won
                } else {
                    contracted += bidValue
                    takenTowardContract += won
                }
            }

            if contracted > 0 {
                if takenTowardContract >= contracted {
                    delta += contracted * 10
                    result.teamBags[teamId] = takenTowardContract - contracted + nilTricks
                } else {
                    delta -= contracted * 10
                    result.teamBags[teamId] = nilTricks
                }
            } else {
                // Both partners bid nil: every trick taken is a bag.
                result.teamBags[teamId] = nilTricks
            }

            // Each bag is worth a point on top of the contract.
            delta += result.teamBags[teamId] ?? 0
            result.teamScores[teamId] = delta
        }
        return result
    }

    /// Scores a finished hand into `roundResult` and applies it to the running totals.
    private static func score(_ state: inout SpadesState) {
        let hand = scoreHand(players: state.players, bids: state.bids, tricksWon: state.tricksWon)

        // Apply bags and the penalty for accumulating ten of them.
        for teamId in [teamA, teamB] {
            state.scores[teamId, default: 0] += hand.teamScores[teamId] ?? 0
            let total = (state.bags[teamId] ?? 0) + (hand.teamBags[teamId] ?? 0)
            if total >= bagLimit {
                state.scores[teamId, default: 0] -= bagPenalty
                state.bags[teamId] = total - bagLimit
            } else {
                state.bags[teamId] = total
            }
        }

        state.roundResult = SpadesState.RoundResult(
            teamScores: hand.teamScores,
            tricksWon: state.tricksWon,
            bids: state.bids,
            nilResults: hand.nilResults
        )

        // A match only ends on a clear win; if both cross the line the higher score takes it,
        // and a tie plays another hand.
        let a = state.scores[teamA] ?? 0
        let b = state.scores[teamB] ?? 0
        if max(a, b) >= targetScore, a != b {
            state.matchWinner = a > b ? teamA : teamB
            state.lastEvent = "Match over."
        } else {
            state.lastEvent = "Hand over."
        }
    }

    /// Next hand, keeping scores and bags. A finished match starts over.
    static func nextRound(from state: SpadesState, using rng: inout some RandomNumberGenerator) -> SpadesState {
        var next = state
        if next.matchWinner != nil {
            next.scores = [teamA: 0, teamB: 0]
            next.bags = [teamA: 0, teamB: 0]
            next.round = 1
            next.matchWinner = nil
        } else {
            next.round += 1
        }
        next.lastTrick = nil
        next.lastTrickWinner = nil
        next.lastLedSuit = nil
        deal(&next, using: &rng)
        next.lastEvent = "Place your bids."
        return next
    }

    // MARK: - Projection

    /// What one player may see. Other hands appear only as counts.
    static func snapshot(of state: SpadesState, for playerId: String) -> SpadesSnapshot {
        SpadesSnapshot(
            viewer: playerId,
            players: state.players,
            hand: (state.hands[playerId] ?? []).sortedForDisplay,
            legalPlays: legalPlays(for: playerId, in: state).map(\.id).sorted(),
            cardCounts: state.hands.mapValues(\.count),
            bids: state.bids,
            tricksWon: state.tricksWon,
            trick: state.trick,
            lastTrick: state.lastTrick,
            lastTrickWinner: state.lastTrickWinner,
            currentPlayer: state.currentPlayer,
            spadesBroken: state.spadesBroken,
            scores: state.scores,
            bags: state.bags,
            round: state.round,
            phase: state.phase,
            roundResult: state.roundResult,
            matchWinner: state.matchWinner,
            lastEvent: state.lastEvent
        )
    }
}
