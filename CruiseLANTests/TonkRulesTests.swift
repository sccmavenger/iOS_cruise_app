import Testing
@testable import iso_cruise_app

@Suite("Tonk rules")
struct TonkRulesTests {
    private let players = ["ana", "ben", "cal"]

    private func newMatch(seed: UInt64 = 42, players: [String]? = nil) -> TonkState {
        var rng = SeededGenerator(seed: seed)
        return TonkRules.newMatch(players: players ?? self.players, using: &rng)
    }

    private func apply(_ action: TonkAction, by player: String, to state: TonkState) throws -> TonkState {
        var rng = SeededGenerator(seed: 1)
        return try TonkRules.apply(action, by: player, to: state, using: &rng)
    }

    // MARK: - Melds

    @Test("Three or more of a rank is a set")
    func sets() {
        let three = [
            PlayingCard(suit: .clubs, rank: 7),
            PlayingCard(suit: .hearts, rank: 7),
            PlayingCard(suit: .spades, rank: 7),
        ]
        #expect(TonkRules.classify(three) == .set)
        #expect(TonkRules.classify(three + [PlayingCard(suit: .diamonds, rank: 7)]) == .set)
        // Two isn't enough.
        #expect(TonkRules.classify(Array(three.prefix(2))) == nil)
    }

    @Test("Three or more in sequence in one suit is a run")
    func runs() {
        let run = [
            PlayingCard(suit: .hearts, rank: 5),
            PlayingCard(suit: .hearts, rank: 6),
            PlayingCard(suit: .hearts, rank: 7),
        ]
        #expect(TonkRules.classify(run) == .run)
        // Order doesn't matter going in.
        #expect(TonkRules.classify(run.reversed()) == .run)
        // Mixed suits isn't a run.
        #expect(TonkRules.classify([
            PlayingCard(suit: .hearts, rank: 5),
            PlayingCard(suit: .clubs, rank: 6),
            PlayingCard(suit: .hearts, rank: 7),
        ]) == nil)
        // A gap isn't a run.
        #expect(TonkRules.classify([
            PlayingCard(suit: .hearts, rank: 5),
            PlayingCard(suit: .hearts, rank: 6),
            PlayingCard(suit: .hearts, rank: 8),
        ]) == nil)
    }

    /// Ace is high everywhere in this app, so Q-K-A runs and A-2-3 does not. Stated in the
    /// rules doc so it isn't a surprise at the table.
    @Test("Ace is high: Q-K-A is a run, A-2-3 is not")
    func aceIsHigh() {
        #expect(TonkRules.classify([
            PlayingCard(suit: .spades, rank: 12),
            PlayingCard(suit: .spades, rank: 13),
            PlayingCard(suit: .spades, rank: 14),
        ]) == .run)
        #expect(TonkRules.classify([
            PlayingCard(suit: .spades, rank: 14),
            PlayingCard(suit: .spades, rank: 2),
            PlayingCard(suit: .spades, rank: 3),
        ]) == nil)
    }

    @Test("Card values: face cards 10, Ace 1, pips at face value")
    func counting() {
        #expect(PlayingCard(suit: .clubs, rank: 14).countingValue == 1)
        #expect(PlayingCard(suit: .clubs, rank: 13).countingValue == 10)
        #expect(PlayingCard(suit: .clubs, rank: 11).countingValue == 10)
        #expect(PlayingCard(suit: .clubs, rank: 7).countingValue == 7)
        #expect([
            PlayingCard(suit: .clubs, rank: 13),
            PlayingCard(suit: .hearts, rank: 14),
            PlayingCard(suit: .spades, rank: 5),
        ].countingValue == 16)
    }

    // MARK: - Setup

    @Test("A fresh deal gives five cards each, one on the pile, the rest in stock")
    func deal() {
        let state = newMatch()
        guard state.roundResult == nil else { return } // a dealt Tonk ends it immediately
        #expect(state.hands.count == 3)
        #expect(state.hands.values.allSatisfy { $0.count == TonkRules.handSize })
        #expect(state.discard.count == 1)
        #expect(state.stock.count == PlayingCard.deckSize - 15 - 1)
        #expect(state.phase == .mustDraw)
    }

    @Test("A dealt 49 or 50 is an instant win worth double")
    func dealtTonk() {
        // Search seeds for a deal that produces a Tonk, rather than asserting on one seed.
        var found: TonkState?
        for seed in UInt64(0)..<400 {
            let state = newMatch(seed: seed)
            if state.roundResult?.reason == .tonk { found = state; break }
        }
        guard let state = found else { return } // vanishingly rare; nothing to assert
        let result = state.roundResult!
        #expect(TonkRules.tonkValues.contains(result.handValues[result.winner] ?? 0))
        // Double the losers' holdings.
        let losers = state.players.filter { $0 != result.winner }
        let held = losers.reduce(0) { $0 + (result.handValues[$1] ?? 0) }
        #expect(result.points == held * 2)
    }

    // MARK: - Turn structure

    @Test("A turn is draw, then discard — in that order")
    func turnOrder() throws {
        var state = newMatch()
        try #require(state.roundResult == nil)
        let player = state.currentPlayer

        // Can't discard before drawing.
        let card = state.hands[player]![0]
        #expect(throws: MoveError.notAllowed) {
            _ = try apply(.discard(cardId: card.id), by: player, to: state)
        }

        state = try apply(.drawFromStock, by: player, to: state)
        #expect(state.phase == .mustDiscard)
        #expect(state.hands[player]!.count == TonkRules.handSize + 1)

        // Can't draw twice.
        #expect(throws: MoveError.notAllowed) {
            _ = try apply(.drawFromStock, by: player, to: state)
        }

        state = try apply(.discard(cardId: state.hands[player]![0].id), by: player, to: state)
        #expect(state.hands[player]!.count == TonkRules.handSize)
        #expect(state.currentPlayer != player)
        #expect(state.phase == .mustDraw)
    }

    @Test("Only the player whose turn it is may act")
    func turnEnforced() throws {
        let state = newMatch()
        try #require(state.roundResult == nil)
        let other = players.first { $0 != state.currentPlayer }!
        #expect(throws: MoveError.notYourTurn) {
            _ = try apply(.drawFromStock, by: other, to: state)
        }
        #expect(throws: MoveError.notAPlayer) {
            _ = try apply(.drawFromStock, by: "stranger", to: state)
        }
    }

    @Test("A card taken from the pile can't be discarded straight back")
    func cantReturnTakenCard() throws {
        var state = newMatch()
        try #require(state.roundResult == nil)
        let player = state.currentPlayer
        let taken = state.topDiscard!

        state = try apply(.takeDiscard, by: player, to: state)
        #expect(state.tookDiscardId == taken.id)
        #expect(throws: MoveError.illegalCard) {
            _ = try apply(.discard(cardId: taken.id), by: player, to: state)
        }

        // Any other card is fine.
        let other = state.hands[player]!.first { $0.id != taken.id }!
        state = try apply(.discard(cardId: other.id), by: player, to: state)
        #expect(state.tookDiscardId == nil)
    }

    @Test("You can't discard a card you don't hold")
    func mustHoldTheCard() throws {
        var state = newMatch()
        try #require(state.roundResult == nil)
        let player = state.currentPlayer
        state = try apply(.drawFromStock, by: player, to: state)
        let notHeld = PlayingCard.freshDeck.first { !state.hands[player]!.contains($0) }!
        #expect(throws: MoveError.notInHand) {
            _ = try apply(.discard(cardId: notHeld.id), by: player, to: state)
        }
    }

    // MARK: - Spreads

    @Test("Spreading moves cards from hand to the table")
    func spreading() throws {
        var state = newMatch()
        // Hand-build a spreadable hand so the test doesn't depend on the shuffle.
        let player = state.currentPlayer
        let set = [
            PlayingCard(suit: .clubs, rank: 9),
            PlayingCard(suit: .hearts, rank: 9),
            PlayingCard(suit: .spades, rank: 9),
        ]
        state.hands[player] = set + [PlayingCard(suit: .diamonds, rank: 4), PlayingCard(suit: .clubs, rank: 2)]
        state.roundResult = nil
        state.phase = .mustDiscard

        state = try apply(.spread(cardIds: set.map(\.id)), by: player, to: state)
        #expect(state.spreads.count == 1)
        #expect(state.spreads[0].kind == .set)
        #expect(state.spreads[0].cards.count == 3)
        #expect(state.hands[player]!.count == 2)
    }

    @Test("An invalid spread is refused and the hand is unchanged")
    func invalidSpread() throws {
        var state = newMatch()
        let player = state.currentPlayer
        let junk = [
            PlayingCard(suit: .clubs, rank: 9),
            PlayingCard(suit: .hearts, rank: 4),
            PlayingCard(suit: .spades, rank: 12),
        ]
        state.hands[player] = junk + [PlayingCard(suit: .diamonds, rank: 2), PlayingCard(suit: .clubs, rank: 3)]
        state.roundResult = nil
        state.phase = .mustDiscard

        #expect(throws: MoveError.illegalCard) {
            _ = try apply(.spread(cardIds: junk.map(\.id)), by: player, to: state)
        }
        #expect(state.hands[player]!.count == 5)
        #expect(state.spreads.isEmpty)
    }

    @Test("A spread must leave at least one card to discard")
    func spreadMustLeaveADiscard() throws {
        var state = newMatch()
        let player = state.currentPlayer
        let run = [
            PlayingCard(suit: .hearts, rank: 5),
            PlayingCard(suit: .hearts, rank: 6),
            PlayingCard(suit: .hearts, rank: 7),
        ]
        // Exactly the spread and nothing else: laying it down would leave nothing to discard.
        state.hands[player] = run
        state.roundResult = nil
        state.phase = .mustDiscard
        #expect(throws: MoveError.notAllowed) {
            _ = try apply(.spread(cardIds: run.map(\.id)), by: player, to: state)
        }
    }

    @Test("Hitting adds a card to an existing spread")
    func hitting() throws {
        var state = newMatch()
        let player = state.currentPlayer
        let run = [
            PlayingCard(suit: .hearts, rank: 5),
            PlayingCard(suit: .hearts, rank: 6),
            PlayingCard(suit: .hearts, rank: 7),
        ]
        state.spreads = [TonkSpread(id: 0, owner: "ben", cards: run, kind: .run)]
        state.hands[player] = [
            PlayingCard(suit: .hearts, rank: 8),
            PlayingCard(suit: .clubs, rank: 2),
            PlayingCard(suit: .diamonds, rank: 3),
        ]
        state.roundResult = nil
        state.phase = .mustDiscard

        let extending = PlayingCard(suit: .hearts, rank: 8)
        state = try apply(.hit(spreadId: 0, cardId: extending.id), by: player, to: state)
        #expect(state.spreads[0].cards.count == 4)
        #expect(state.hands[player]!.count == 2)

        // A card that doesn't extend the run is refused.
        let wrong = PlayingCard(suit: .clubs, rank: 2)
        #expect(throws: MoveError.illegalCard) {
            _ = try apply(.hit(spreadId: 0, cardId: wrong.id), by: player, to: state)
        }
    }

    // MARK: - Ending a round

    @Test("Playing the last card goes out and wins the round")
    func goingOut() throws {
        var state = newMatch()
        let player = state.currentPlayer
        let last = PlayingCard(suit: .clubs, rank: 3)
        state.hands[player] = [last]
        state.roundResult = nil
        state.phase = .mustDiscard

        state = try apply(.discard(cardId: last.id), by: player, to: state)
        #expect(state.roundResult?.winner == player)
        #expect(state.roundResult?.reason == .wentOut)
        #expect(state.phase == .roundOver)
    }

    @Test("Dropping with the lowest hand wins")
    func dropWins() throws {
        var state = newMatch()
        let player = state.currentPlayer
        state.hands[player] = [PlayingCard(suit: .clubs, rank: 2), PlayingCard(suit: .hearts, rank: 3)]
        for other in players where other != player {
            state.hands[other] = [PlayingCard(suit: .spades, rank: 13), PlayingCard(suit: .diamonds, rank: 12)]
        }
        state.roundResult = nil
        state.phase = .mustDraw

        state = try apply(.drop, by: player, to: state)
        #expect(state.roundResult?.winner == player)
        #expect(state.roundResult?.reason == .drop)
        // 20 held by each of the two opponents, no doubling.
        #expect(state.roundResult?.points == 40)
    }

    @Test("A caught drop pays double to the lowest hand")
    func dropCaught() throws {
        var state = newMatch()
        let player = state.currentPlayer
        let others = players.filter { $0 != player }
        state.hands[player] = [PlayingCard(suit: .clubs, rank: 10)]
        // One opponent is lower, so the drop is caught.
        state.hands[others[0]] = [PlayingCard(suit: .spades, rank: 2)]
        state.hands[others[1]] = [PlayingCard(suit: .diamonds, rank: 13)]
        state.roundResult = nil
        state.phase = .mustDraw

        state = try apply(.drop, by: player, to: state)
        #expect(state.roundResult?.reason == .caught)
        #expect(state.roundResult?.winner == others[0])
        // The winner collects 10 + 10 held by the others, doubled.
        #expect(state.roundResult?.points == 40)
    }

    @Test("A tie catches the dropper: ties go against them")
    func tiedDropIsCaught() throws {
        var state = newMatch()
        let player = state.currentPlayer
        let others = players.filter { $0 != player }
        state.hands[player] = [PlayingCard(suit: .clubs, rank: 5)]
        state.hands[others[0]] = [PlayingCard(suit: .spades, rank: 5)]
        state.hands[others[1]] = [PlayingCard(suit: .diamonds, rank: 9)]
        state.roundResult = nil
        state.phase = .mustDraw

        state = try apply(.drop, by: player, to: state)
        #expect(state.roundResult?.reason == .caught)
    }

    @Test("Dropping is only allowed before drawing")
    func dropOnlyBeforeDrawing() throws {
        var state = newMatch()
        try #require(state.roundResult == nil)
        let player = state.currentPlayer
        state = try apply(.drawFromStock, by: player, to: state)
        #expect(throws: MoveError.notAllowed) {
            _ = try apply(.drop, by: player, to: state)
        }
    }

    @Test("Reaching the target ends the match")
    func matchEnd() throws {
        var state = newMatch()
        let player = state.currentPlayer
        state.scores[player] = TonkRules.targetScore - 5
        state.hands[player] = [PlayingCard(suit: .clubs, rank: 3)]
        for other in players where other != player {
            state.hands[other] = [PlayingCard(suit: .spades, rank: 13)]
        }
        state.roundResult = nil
        state.phase = .mustDiscard

        state = try apply(.discard(cardId: PlayingCard(suit: .clubs, rank: 3).id), by: player, to: state)
        #expect(state.matchWinner == player)
    }

    @Test("The next round re-deals and keeps scores")
    func nextRound() throws {
        var state = newMatch()
        state.scores = ["ana": 30, "ben": 10, "cal": 0]
        state.roundResult = TonkState.RoundResult(
            winner: "ana", reason: .wentOut, handValues: [:], points: 10
        )
        var rng = SeededGenerator(seed: 9)
        let next = TonkRules.nextRound(from: state, using: &rng)

        #expect(next.round == 2)
        #expect(next.scores["ana"] == 30)
        if next.roundResult == nil {
            #expect(next.hands.values.allSatisfy { $0.count == TonkRules.handSize })
            #expect(next.phase == .mustDraw)
        }
    }

    // MARK: - Privacy

    @Test("A snapshot shows only the viewer's own hand")
    func snapshotPrivacy() {
        let state = newMatch()
        let snapshot = TonkRules.snapshot(of: state, for: "ana")

        #expect(Set(snapshot.hand) == Set(state.hands["ana"] ?? []))
        for other in ["ben", "cal"] {
            #expect(Set(snapshot.hand).intersection(Set(state.hands[other] ?? [])).isEmpty)
        }
        // Counts only for everyone else, and the stock is a number, never an order.
        #expect(snapshot.cardCounts["ben"] == state.hands["ben"]?.count)
        #expect(snapshot.stockCount == state.stock.count)
        #expect(snapshot.isStructurallyValid)
    }

    @Test("Only the player on turn learns which card they just took")
    func takenCardIsPrivate() throws {
        var state = newMatch()
        try #require(state.roundResult == nil)
        let player = state.currentPlayer
        state = try apply(.takeDiscard, by: player, to: state)

        #expect(TonkRules.snapshot(of: state, for: player).tookDiscardId != nil)
        let other = players.first { $0 != player }!
        #expect(TonkRules.snapshot(of: state, for: other).tookDiscardId == nil)
    }

    // MARK: - Structural validation

    @Test("Malformed actions are rejected before any rules run")
    func structuralValidation() {
        #expect(TonkAction.discard(cardId: -1).isStructurallyValid == false)
        #expect(TonkAction.discard(cardId: 52).isStructurallyValid == false)
        #expect(TonkAction.discard(cardId: 0).isStructurallyValid)
        // Too few cards, duplicates, and out-of-range ids are all refused.
        #expect(TonkAction.spread(cardIds: [1, 2]).isStructurallyValid == false)
        #expect(TonkAction.spread(cardIds: [1, 1, 1]).isStructurallyValid == false)
        #expect(TonkAction.spread(cardIds: [1, 2, 99]).isStructurallyValid == false)
        #expect(TonkAction.spread(cardIds: [1, 2, 3]).isStructurallyValid)
        #expect(TonkAction.hit(spreadId: -1, cardId: 0).isStructurallyValid == false)
    }

    @Test("Two players is a valid table")
    func twoPlayers() {
        let state = newMatch(seed: 3, players: ["ana", "ben"])
        guard state.roundResult == nil else { return }
        #expect(state.hands.count == 2)
        #expect(state.hands.values.allSatisfy { $0.count == TonkRules.handSize })
    }
}
