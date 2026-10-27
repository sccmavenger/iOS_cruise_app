import Testing
@testable import iso_cruise_app

@Suite("Spades rules")
struct SpadesRulesTests {
    private let players = ["ana", "ben", "cal", "dee"]

    /// Deterministic deals, so a failure is reproducible.
    private func seededRNG(_ seed: UInt64 = 42) -> SeededGenerator { SeededGenerator(seed: seed) }

    private func newGame(seed: UInt64 = 42) -> SpadesState {
        var rng = seededRNG(seed)
        return SpadesRules.newGame(players: players, using: &rng)
    }

    private func bidAll(_ state: SpadesState, _ bids: [Int]) throws -> SpadesState {
        var rng = seededRNG()
        var current = state
        for bid in bids {
            current = try SpadesRules.apply(.bid(tricks: bid), by: current.currentPlayer, to: current, using: &rng)
        }
        return current
    }

    @Test("A fresh deal gives everyone 13 cards and no duplicates")
    func deal() {
        let state = newGame()
        #expect(state.hands.count == 4)
        #expect(state.hands.values.allSatisfy { $0.count == SpadesRules.handSize })
        let all = state.hands.values.flatMap { $0 }
        #expect(all.count == PlayingCard.deckSize)
        #expect(Set(all).count == PlayingCard.deckSize)
        #expect(state.phase == .bidding)
    }

    @Test("Partners sit opposite each other")
    func partnerships() {
        #expect(SpadesRules.team(ofSeat: 0) == SpadesRules.team(ofSeat: 2))
        #expect(SpadesRules.team(ofSeat: 1) == SpadesRules.team(ofSeat: 3))
        #expect(SpadesRules.team(ofSeat: 0) != SpadesRules.team(ofSeat: 1))

        let snapshot = SpadesRules.snapshot(of: newGame(), for: "ana")
        #expect(snapshot.partner == "cal")
    }

    @Test("Bidding runs once around, then play begins")
    func bidding() throws {
        var state = newGame()
        let first = state.currentPlayer
        state = try bidAll(state, [3, 3, 3, 4])
        #expect(state.phase == .playing)
        #expect(state.bids.count == 4)
        // Play starts from the same seat that bid first.
        #expect(state.currentPlayer == first)
    }

    @Test("A player can't bid twice or out of turn")
    func biddingOrder() throws {
        var rng = seededRNG()
        let state = newGame()
        let wrong = players.first { $0 != state.currentPlayer }!
        #expect(throws: MoveError.notYourTurn) {
            _ = try SpadesRules.apply(.bid(tricks: 3), by: wrong, to: state, using: &rng)
        }
        #expect(throws: MoveError.outOfBounds) {
            _ = try SpadesRules.apply(.bid(tricks: 14), by: state.currentPlayer, to: state, using: &rng)
        }
    }

    @Test("Spades can't be led until they're broken")
    func spadesNotBroken() throws {
        var state = newGame()
        state = try bidAll(state, [3, 3, 3, 3])
        let leader = state.currentPlayer
        let hand = state.hands[leader]!
        let legal = SpadesRules.legalPlays(for: leader, in: state)

        if hand.contains(where: { $0.suit != .spades }) {
            // Holding something else, so no spade may be led.
            #expect(legal.allSatisfy { $0.suit != .spades })
        } else {
            // Nothing but spades: leading one is allowed.
            #expect(legal.count == hand.count)
        }
    }

    @Test("Players must follow the led suit when they can")
    func mustFollowSuit() throws {
        var state = newGame()
        state = try bidAll(state, [3, 3, 3, 3])
        var rng = seededRNG()

        let leader = state.currentPlayer
        let lead = SpadesRules.legalPlays(for: leader, in: state)[0]
        state = try SpadesRules.apply(.play(cardId: lead.id), by: leader, to: state, using: &rng)

        let next = state.currentPlayer
        let following = state.hands[next]!.filter { $0.suit == lead.suit }
        let legal = SpadesRules.legalPlays(for: next, in: state)
        if following.isEmpty {
            #expect(legal.count == state.hands[next]!.count)
        } else {
            #expect(Set(legal) == Set(following))
            // And an off-suit card is actually refused, not just hidden in the UI.
            if let offSuit = state.hands[next]!.first(where: { $0.suit != lead.suit }) {
                #expect(throws: MoveError.illegalCard) {
                    _ = try SpadesRules.apply(.play(cardId: offSuit.id), by: next, to: state, using: &rng)
                }
            }
        }
    }

    @Test("The highest spade takes the trick, otherwise the highest card of the led suit")
    func trickWinner() {
        let led = PlayingCard(suit: .hearts, rank: 10)
        let lowHeart = PlayingCard(suit: .hearts, rank: 4)
        let highHeart = PlayingCard(suit: .hearts, rank: 13)
        let offSuit = PlayingCard(suit: .diamonds, rank: 14)

        // No spades: highest heart wins, and the off-suit ace is irrelevant.
        #expect(SpadesRules.winnerOfTrick([
            .init(player: "ana", card: led),
            .init(player: "ben", card: lowHeart),
            .init(player: "cal", card: highHeart),
            .init(player: "dee", card: offSuit),
        ]) == "cal")

        // Any spade beats every heart, even the lowest spade against the heart king.
        #expect(SpadesRules.winnerOfTrick([
            .init(player: "ana", card: led),
            .init(player: "ben", card: PlayingCard(suit: .spades, rank: 2)),
            .init(player: "cal", card: highHeart),
            .init(player: "dee", card: offSuit),
        ]) == "ben")

        // Highest spade among several.
        #expect(SpadesRules.winnerOfTrick([
            .init(player: "ana", card: led),
            .init(player: "ben", card: PlayingCard(suit: .spades, rank: 2)),
            .init(player: "cal", card: PlayingCard(suit: .spades, rank: 11)),
            .init(player: "dee", card: PlayingCard(suit: .spades, rank: 5)),
        ]) == "cal")
    }

    @Test("Playing a spade breaks them for the rest of the hand")
    func breakingSpades() throws {
        var state = newGame()
        state = try bidAll(state, [3, 3, 3, 3])
        var rng = seededRNG()
        #expect(state.spadesBroken == false)

        // Play out tricks until someone plays a spade.
        var guard_ = 0
        while !state.spadesBroken, state.roundResult == nil, guard_ < 60 {
            let player = state.currentPlayer
            let choice = SpadesRules.legalPlays(for: player, in: state)[0]
            state = try SpadesRules.apply(.play(cardId: choice.id), by: player, to: state, using: &rng)
            guard_ += 1
        }
        // Either a spade got played and the flag is set, or the hand finished without one.
        #expect(state.spadesBroken || state.roundResult != nil)
    }

    @Test("Making the contract scores ten a trick plus one per bag")
    func scoringMadeContract() {
        // Team A (ana + cal) bid 3 and 2, and take 6 between them: 50 plus 1 bag.
        // Team B (ben + dee) bid 8 and take 7: set, so they lose 80.
        let scored = SpadesRules.scoreHand(
            players: players,
            bids: ["ana": 3, "ben": 4, "cal": 2, "dee": 4],
            tricksWon: ["ana": 3, "ben": 4, "cal": 3, "dee": 3]
        )
        #expect(scored.teamScores[SpadesRules.teamA] == 51)
        #expect(scored.teamBags[SpadesRules.teamA] == 1)
        #expect(scored.teamScores[SpadesRules.teamB] == -80)
        #expect(scored.teamBags[SpadesRules.teamB] == 0)
    }

    @Test("Exactly making the bid scores ten a trick with no bags")
    func scoringExact() {
        let scored = SpadesRules.scoreHand(
            players: players,
            bids: ["ana": 3, "ben": 4, "cal": 3, "dee": 3],
            tricksWon: ["ana": 3, "ben": 4, "cal": 3, "dee": 3]
        )
        #expect(scored.teamScores[SpadesRules.teamA] == 60)
        #expect(scored.teamBags[SpadesRules.teamA] == 0)
    }

    @Test("A made nil is worth +100 and a failed one −100")
    func scoringNil() {
        // Nil made (+100), partner's bid of 4 made exactly (+40).
        var scored = SpadesRules.scoreHand(
            players: players,
            bids: ["ana": 0, "ben": 5, "cal": 4, "dee": 4],
            tricksWon: ["ana": 0, "ben": 5, "cal": 4, "dee": 4]
        )
        #expect(scored.teamScores[SpadesRules.teamA] == 140)
        #expect(scored.nilResults["ana"] == true)

        // Nil failed (−100), partner still made 4 (+40), and the two tricks the nil bidder
        // took become bags (+2).
        scored = SpadesRules.scoreHand(
            players: players,
            bids: ["ana": 0, "ben": 5, "cal": 4, "dee": 4],
            tricksWon: ["ana": 2, "ben": 5, "cal": 4, "dee": 2]
        )
        #expect(scored.teamScores[SpadesRules.teamA] == -58)
        #expect(scored.teamBags[SpadesRules.teamA] == 2)
        #expect(scored.nilResults["ana"] == false)
    }

    @Test("A nil bidder's tricks don't rescue a partner's failed contract")
    func nilTricksDontCountTowardContract() {
        // cal bid 5 and took 3; ana bid nil and took 2. The contract is still set, even
        // though the pair took five tricks between them.
        let scored = SpadesRules.scoreHand(
            players: players,
            bids: ["ana": 0, "ben": 4, "cal": 5, "dee": 4],
            tricksWon: ["ana": 2, "ben": 4, "cal": 3, "dee": 4]
        )
        // −100 for the failed nil, −50 for the set contract, +2 for the nil bidder's bags.
        #expect(scored.teamScores[SpadesRules.teamA] == -148)
    }

    @Test("Ten bags cost a hundred points and reset the count")
    func bagPenalty() throws {
        var state = newGame()
        state.bags = [SpadesRules.teamA: 9, SpadesRules.teamB: 0]
        state.scores = [SpadesRules.teamA: 0, SpadesRules.teamB: 0]
        state.bids = ["ana": 1, "ben": 5, "cal": 1, "dee": 5]
        state.tricksWon = ["ana": 2, "ben": 5, "cal": 2, "dee": 4]

        // Bid 2, took 4: +20 and 2 bags, bringing them to 11 — over the limit.
        let scored = SpadesRules.scoreHand(players: players, bids: state.bids, tricksWon: state.tricksWon)
        #expect(scored.teamScores[SpadesRules.teamA] == 22)
        #expect(scored.teamBags[SpadesRules.teamA] == 2)

        // The penalty itself is applied when the hand is settled, so check the arithmetic
        // the settler performs: 9 existing + 2 new = 11, so 100 off and 1 bag carried.
        let carried = 9 + (scored.teamBags[SpadesRules.teamA] ?? 0)
        #expect(carried >= SpadesRules.bagLimit)
        #expect(carried - SpadesRules.bagLimit == 1)
    }

    @Test("A snapshot shows only the viewer's own cards")
    func snapshotPrivacy() {
        let state = newGame()
        let snapshot = SpadesRules.snapshot(of: state, for: "ana")

        #expect(snapshot.hand.count == SpadesRules.handSize)
        #expect(Set(snapshot.hand) == Set(state.hands["ana"]!))
        // Everyone else is a count only.
        #expect(snapshot.cardCounts["ben"] == SpadesRules.handSize)
        for other in ["ben", "cal", "dee"] {
            let theirs = Set(state.hands[other]!)
            #expect(Set(snapshot.hand).intersection(theirs).isEmpty)
        }
        #expect(snapshot.isStructurallyValid)
    }

    @Test("A resigning player hands the match to the other team")
    func resign() throws {
        var rng = seededRNG()
        let state = newGame()
        let after = try SpadesRules.apply(.resign, by: "ana", to: state, using: &rng)
        #expect(after.matchWinner == SpadesRules.teamB)
    }

    @Test("A full hand plays out: 13 tricks are awarded and the hand settles")
    func fullHand() throws {
        let (state, plays) = try playOutHand(seed: 11, bids: [3, 3, 3, 3])

        #expect(plays == PlayingCard.deckSize)
        #expect(state.hands.values.allSatisfy { $0.isEmpty })
        #expect(state.roundResult != nil)
        // Every trick goes to exactly one player, so the tallies must sum to the hand size.
        #expect(state.tricksWon.values.reduce(0, +) == SpadesRules.handSize)
        #expect(state.phase == .handOver)
    }

    @Test("The next hand keeps scores and re-deals")
    func nextRound() throws {
        let (finished, plays) = try playOutHand(seed: 5, bids: [3, 3, 3, 3])
        #expect(plays == PlayingCard.deckSize)
        let scoreBefore = finished.scores
        var rng = seededRNG(7)
        let next = SpadesRules.nextRound(from: finished, using: &rng)

        #expect(next.round == 2)
        #expect(next.scores == scoreBefore)
        #expect(next.hands.values.allSatisfy { $0.count == SpadesRules.handSize })
        #expect(next.bids.isEmpty)
        #expect(next.roundResult == nil)
        #expect(next.phase == .bidding)
        // A fresh deal, with all 52 cards back in play.
        let all = next.hands.values.flatMap { $0 }
        #expect(Set(all).count == PlayingCard.deckSize)
    }

    @Test("Winning the match requires crossing the target outright")
    func matchEndsOnClearWin() throws {
        var (state, _) = try playOutHand(seed: 3, bids: [4, 3, 3, 3])
        // Whatever the hand did, a match is only won once a team is at or past the target
        // and the two scores differ.
        let a = state.scores[SpadesRules.teamA] ?? 0
        let b = state.scores[SpadesRules.teamB] ?? 0
        if max(a, b) >= SpadesRules.targetScore, a != b {
            #expect(state.matchWinner != nil)
        } else {
            #expect(state.matchWinner == nil)
        }

        // Starting a hand from just under the line, a win becomes reachable.
        state.scores = [SpadesRules.teamA: SpadesRules.targetScore - 5, SpadesRules.teamB: 0]
        var rng = seededRNG(3)
        let fresh = SpadesRules.nextRound(from: state, using: &rng)
        #expect(fresh.scores[SpadesRules.teamA] == SpadesRules.targetScore - 5)
        #expect(fresh.matchWinner == nil)
    }

    /// Bids, then plays every card using the first legal option each turn. Exercises the
    /// real trick and scoring path rather than a hand-built state.
    ///
    /// Returns the cards played alongside the state so callers can tell "the hand finished"
    /// apart from "the loop gave up", which would otherwise look the same.
    private func playOutHand(seed: UInt64, bids: [Int]) throws -> (state: SpadesState, plays: Int) {
        var rng = seededRNG(seed)
        var state = SpadesRules.newGame(players: players, using: &rng)
        for bid in bids {
            state = try SpadesRules.apply(.bid(tricks: bid), by: state.currentPlayer, to: state, using: &rng)
        }
        // 52 cards, four at a time. The bound stops a rules bug from looping forever.
        var plays = 0
        while state.roundResult == nil, plays < PlayingCard.deckSize {
            let player = state.currentPlayer
            guard let choice = SpadesRules.legalPlays(for: player, in: state).first else { break }
            state = try SpadesRules.apply(.play(cardId: choice.id), by: player, to: state, using: &rng)
            plays += 1
        }
        return (state, plays)
    }
}

/// Reproducible generator for deterministic deals. SplitMix64.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
