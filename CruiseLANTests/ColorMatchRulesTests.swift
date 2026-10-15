import Foundation
import Testing
@testable import iso_cruise_app

/// Deterministic RNG for reproducible shuffles in tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Color Match rules")
final class ColorMatchRulesTests {
    var rng = SplitMix64(state: 42)
    private var nextId = 1_000

    // MARK: - Helpers

    private func card(_ color: CardColor?, _ face: CardFace) -> Card {
        nextId += 1
        return Card(id: nextId, color: color, face: face)
    }

    private func table(
        players: [String],
        hands: [String: [Card]],
        top: Card,
        active: CardColor? = nil,
        drawPile: [Card] = [],
        current: Int = 0,
        direction: Int = 1
    ) -> ColorMatchState {
        ColorMatchState(
            players: players,
            hands: hands,
            drawPile: drawPile,
            discardPile: [top],
            activeColor: active ?? top.color ?? .red,
            currentIndex: current,
            direction: direction,
            drawnCardId: nil,
            pendingDrawFour: nil,
            vulnerablePlayer: nil,
            scores: Dictionary(uniqueKeysWithValues: players.map { ($0, 0) }),
            round: 1,
            roundResult: nil,
            matchWinner: nil,
            lastEvent: ""
        )
    }

    /// Plenty of filler cards for draw piles.
    private func filler(_ count: Int) -> [Card] {
        (0..<count).map { _ in card(.green, .number(5)) }
    }

    // MARK: - Deck and dealing (CM-01)

    @Test("Deck has 108 classic cards with unique ids")
    func deck() {
        let deck = ColorMatchRules.fullDeck()
        #expect(deck.count == 108)
        #expect(Set(deck.map(\.id)).count == 108)
        for color in CardColor.allCases {
            let cards = deck.filter { $0.color == color }
            #expect(cards.count == 25)
            #expect(cards.filter { $0.face == .number(0) }.count == 1)
            for value in 1...9 { #expect(cards.filter { $0.face == .number(value) }.count == 2) }
            for action in [CardFace.skip, .reverse, .drawTwo] { #expect(cards.filter { $0.face == action }.count == 2) }
        }
        #expect(deck.filter { $0.face == .wild }.count == 4)
        #expect(deck.filter { $0.face == .wildDrawFour }.count == 4)
    }

    @Test("Deals 7 cards each to 2, 3, and 4 players with a numbered start card", arguments: [2, 3, 4])
    func dealing(playerCount: Int) {
        var rng = SplitMix64(state: UInt64(playerCount))
        let players = (0..<playerCount).map { "p\($0)" }
        let state = ColorMatchRules.newMatch(players: players, using: &rng)
        for player in players { #expect(state.hands[player]?.count == 7) }
        #expect(ColorMatchRules.isNumber(state.topCard))
        #expect(state.drawPile.count == 108 - 7 * playerCount - 1)
        let all = state.hands.values.flatMap { $0 } + state.drawPile + state.discardPile
        #expect(Set(all.map(\.id)).count == 108)
        #expect(state.activeColor == state.topCard.color)
    }

    @Test("An action start card is put back until a number turns up")
    func startCardIsNumber() {
        var rng = SplitMix64(state: 7)
        var deck = ColorMatchRules.fullDeck()
        // Force the flip position (last after dealing 14) to be a wild.
        let wild = deck.first { $0.face == .wildDrawFour }!
        deck.removeAll { $0.id == wild.id }
        deck.insert(wild, at: deck.count - 14)
        let state = ColorMatchRules.newRound(players: ["a", "b"], scores: ["a": 0, "b": 0], round: 1, deck: deck, using: &rng)
        #expect(ColorMatchRules.isNumber(state.topCard))
        #expect(state.drawPile.contains { $0.id == wild.id })
    }

    // MARK: - Matching (CM-02)

    @Test("Color, number, and symbol matches are accepted; others are rejected unchanged")
    func matching() throws {
        let top = card(.red, .number(5))
        let sameColor = card(.red, .number(9)), sameNumber = card(.blue, .number(5)), mismatch = card(.green, .number(2))
        let state = table(players: ["a", "b"], hands: ["a": [sameColor, sameNumber, mismatch], "b": filler(3)], top: top, drawPile: filler(5))

        _ = try ColorMatchRules.apply(.play(cardId: sameColor.id, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        _ = try ColorMatchRules.apply(.play(cardId: sameNumber.id, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        #expect(throws: MoveError.illegalCard) {
            try ColorMatchRules.apply(.play(cardId: mismatch.id, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        }
        #expect(throws: MoveError.notYourTurn) {
            try ColorMatchRules.apply(.draw, by: "b", to: state, using: &rng)
        }
        #expect(throws: MoveError.notInHand) {
            try ColorMatchRules.apply(.play(cardId: 99_999, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        }

        let skipTop = card(.blue, .skip), redSkip = card(.red, .skip)
        let symbolState = table(players: ["a", "b"], hands: ["a": [redSkip, card(.red, .number(1))], "b": filler(3)], top: skipTop, drawPile: filler(5))
        _ = try ColorMatchRules.apply(.play(cardId: redSkip.id, chosenColor: nil, callOne: false), by: "a", to: symbolState, using: &rng)
    }

    // MARK: - Actions (CM-03, CM-04)

    @Test("Skip: the next player loses their turn")
    func skip() throws {
        let skip = card(.red, .skip)
        let state = table(players: ["a", "b", "c"], hands: ["a": [skip, card(.red, .number(1))], "b": filler(3), "c": filler(3)], top: card(.red, .number(4)))
        let next = try ColorMatchRules.apply(.play(cardId: skip.id, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        #expect(next.currentPlayer == "c")
    }

    @Test("Reverse flips direction with 3 players")
    func reverseThree() throws {
        let reverse = card(.red, .reverse)
        let state = table(players: ["a", "b", "c"], hands: ["a": [reverse, card(.red, .number(1))], "b": filler(3), "c": filler(3)], top: card(.red, .number(4)))
        let next = try ColorMatchRules.apply(.play(cardId: reverse.id, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        #expect(next.direction == -1)
        #expect(next.currentPlayer == "c")
    }

    @Test("Reverse acts as Skip with 2 players")
    func reverseTwo() throws {
        let reverse = card(.red, .reverse)
        let state = table(players: ["a", "b"], hands: ["a": [reverse, card(.red, .number(1))], "b": filler(3)], top: card(.red, .number(4)))
        let next = try ColorMatchRules.apply(.play(cardId: reverse.id, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        #expect(next.currentPlayer == "a")
    }

    @Test("Draw Two: next player draws 2 and loses their turn (no stacking)")
    func drawTwo() throws {
        let drawTwo = card(.red, .drawTwo)
        let state = table(players: ["a", "b", "c"], hands: ["a": [drawTwo, card(.red, .number(1))], "b": [card(.red, .drawTwo)], "c": filler(3)], top: card(.red, .number(4)), drawPile: filler(10))
        let next = try ColorMatchRules.apply(.play(cardId: drawTwo.id, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        #expect(next.hands["b"]?.count == 3)
        #expect(next.currentPlayer == "c")
    }

    @Test("Wild sets the chosen color and requires a choice")
    func wildColor() throws {
        let wild = card(nil, .wild)
        let state = table(players: ["a", "b"], hands: ["a": [wild, card(.red, .number(1))], "b": filler(3)], top: card(.red, .number(4)))
        #expect(throws: MoveError.colorRequired) {
            try ColorMatchRules.apply(.play(cardId: wild.id, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        }
        let next = try ColorMatchRules.apply(.play(cardId: wild.id, chosenColor: .blue, callOne: false), by: "a", to: state, using: &rng)
        #expect(next.activeColor == .blue)
        #expect(next.currentPlayer == "b")
    }

    // MARK: - Wild Draw Four challenge (CM-05)

    @Test("Accepting Wild Draw Four: draw 4 and lose the turn")
    func drawFourAccept() throws {
        let wd4 = card(nil, .wildDrawFour)
        let state = table(players: ["a", "b", "c"], hands: ["a": [wd4, card(.blue, .number(1))], "b": filler(2), "c": filler(2)], top: card(.red, .number(4)), drawPile: filler(20))
        let played = try ColorMatchRules.apply(.play(cardId: wd4.id, chosenColor: .green, callOne: false), by: "a", to: state, using: &rng)
        #expect(played.pendingDrawFour?.target == "b")
        #expect(throws: MoveError.notAllowed) { try ColorMatchRules.apply(.draw, by: "b", to: played, using: &rng) }
        let accepted = try ColorMatchRules.apply(.respondToDrawFour(challenge: false), by: "b", to: played, using: &rng)
        #expect(accepted.hands["b"]?.count == 6)
        #expect(accepted.currentPlayer == "c")
        #expect(accepted.activeColor == .green)
    }

    @Test("Failed challenge of a legal Wild Draw Four: challenger draws 6 and loses the turn")
    func drawFourFailedChallenge() throws {
        let wd4 = card(nil, .wildDrawFour)
        // "a" holds no red (the active color), so the play is legal.
        let state = table(players: ["a", "b", "c"], hands: ["a": [wd4, card(.blue, .number(1))], "b": filler(2), "c": filler(2)], top: card(.red, .number(4)), drawPile: filler(20))
        let played = try ColorMatchRules.apply(.play(cardId: wd4.id, chosenColor: .green, callOne: false), by: "a", to: state, using: &rng)
        let result = try ColorMatchRules.apply(.respondToDrawFour(challenge: true), by: "b", to: played, using: &rng)
        #expect(result.hands["b"]?.count == 8)
        #expect(result.hands["a"]?.count == 1)
        #expect(result.currentPlayer == "c")
    }

    @Test("Successful challenge of a bluffed Wild Draw Four: offender draws 4, challenger plays")
    func drawFourSuccessfulChallenge() throws {
        let wd4 = card(nil, .wildDrawFour)
        // "a" still holds a red card, so the play was illegal.
        let state = table(players: ["a", "b", "c"], hands: ["a": [wd4, card(.red, .number(1))], "b": filler(2), "c": filler(2)], top: card(.red, .number(4)), drawPile: filler(20))
        let played = try ColorMatchRules.apply(.play(cardId: wd4.id, chosenColor: .green, callOne: true), by: "a", to: state, using: &rng)
        let result = try ColorMatchRules.apply(.respondToDrawFour(challenge: true), by: "b", to: played, using: &rng)
        #expect(result.hands["a"]?.count == 5)
        #expect(result.hands["b"]?.count == 2)
        #expect(result.currentPlayer == "b")
    }

    @Test("Only the target may answer a Wild Draw Four")
    func drawFourOnlyTarget() throws {
        let wd4 = card(nil, .wildDrawFour)
        let state = table(players: ["a", "b", "c"], hands: ["a": [wd4, card(.blue, .number(1))], "b": filler(2), "c": filler(2)], top: card(.red, .number(4)), drawPile: filler(20))
        let played = try ColorMatchRules.apply(.play(cardId: wd4.id, chosenColor: .green, callOne: false), by: "a", to: state, using: &rng)
        #expect(throws: MoveError.notAllowed) {
            try ColorMatchRules.apply(.respondToDrawFour(challenge: true), by: "c", to: played, using: &rng)
        }
    }

    // MARK: - Draw flow (CM-06)

    @Test("Draw a playable card, then play it")
    func drawThenPlay() throws {
        let playable = card(.red, .number(8))
        let state = table(players: ["a", "b"], hands: ["a": [card(.blue, .number(1))], "b": filler(3)], top: card(.red, .number(4)), drawPile: [playable])
        let drew = try ColorMatchRules.apply(.draw, by: "a", to: state, using: &rng)
        #expect(drew.drawnCardId == playable.id)
        #expect(drew.currentPlayer == "a")
        // Only the drawn card may be played now.
        #expect(throws: MoveError.notAllowed) { try ColorMatchRules.apply(.draw, by: "a", to: drew, using: &rng) }
        let played = try ColorMatchRules.apply(.play(cardId: playable.id, chosenColor: nil, callOne: false), by: "a", to: drew, using: &rng)
        #expect(played.topCard.id == playable.id)
        #expect(played.currentPlayer == "b")
    }

    @Test("Draw a playable card, then pass")
    func drawThenPass() throws {
        let playable = card(.red, .number(8))
        let state = table(players: ["a", "b"], hands: ["a": [card(.blue, .number(1))], "b": filler(3)], top: card(.red, .number(4)), drawPile: [playable])
        let drew = try ColorMatchRules.apply(.draw, by: "a", to: state, using: &rng)
        let passed = try ColorMatchRules.apply(.pass, by: "a", to: drew, using: &rng)
        #expect(passed.currentPlayer == "b")
        #expect(passed.hands["a"]?.count == 2)
    }

    @Test("Drawing an unplayable card passes automatically; passing without drawing is rejected")
    func drawAndPass() throws {
        let state = table(players: ["a", "b"], hands: ["a": [card(.blue, .number(1))], "b": filler(3)], top: card(.red, .number(4)), drawPile: [card(.yellow, .number(2))])
        #expect(throws: MoveError.notAllowed) { try ColorMatchRules.apply(.pass, by: "a", to: state, using: &rng) }
        let drew = try ColorMatchRules.apply(.draw, by: "a", to: state, using: &rng)
        #expect(drew.currentPlayer == "b")
        #expect(drew.drawnCardId == nil)
    }

    // MARK: - Call One / Catch (CM-07)

    @Test("Missing Call One can be caught before the next player's first action: +2")
    func catchBeforeDeadline() throws {
        let play = card(.red, .number(3))
        let state = table(players: ["a", "b", "c"], hands: ["a": [play, card(.red, .number(1))], "b": filler(3), "c": filler(3)], top: card(.red, .number(4)), drawPile: filler(10))
        let played = try ColorMatchRules.apply(.play(cardId: play.id, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        #expect(played.vulnerablePlayer == "a")
        // Anyone but the offender can catch, even when it isn't their turn.
        let caught = try ColorMatchRules.apply(.catchOne(target: "a"), by: "c", to: played, using: &rng)
        #expect(caught.hands["a"]?.count == 3)
        #expect(caught.vulnerablePlayer == nil)
        #expect(throws: MoveError.notAllowed) { try ColorMatchRules.apply(.catchOne(target: "a"), by: "b", to: caught, using: &rng) }
    }

    @Test("No penalty after the deadline (next player acted)")
    func catchAfterDeadline() throws {
        let play = card(.red, .number(3))
        let state = table(players: ["a", "b", "c"], hands: ["a": [play, card(.red, .number(1))], "b": [card(.red, .number(7)), card(.red, .number(8))], "c": filler(3)], top: card(.red, .number(4)), drawPile: filler(10))
        let played = try ColorMatchRules.apply(.play(cardId: play.id, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        let nextActed = try ColorMatchRules.apply(.play(cardId: state.hands["b"]![0].id, chosenColor: nil, callOne: false), by: "b", to: played, using: &rng)
        #expect(nextActed.vulnerablePlayer == "b") // b now has one card and didn't call
        #expect(throws: MoveError.notAllowed) { try ColorMatchRules.apply(.catchOne(target: "a"), by: "c", to: nextActed, using: &rng) }
    }

    @Test("Calling One while playing, or right after, protects the player")
    func callOneProtects() throws {
        let play = card(.red, .number(3))
        let state = table(players: ["a", "b"], hands: ["a": [play, card(.red, .number(1))], "b": filler(3)], top: card(.red, .number(4)), drawPile: filler(10))
        let calledWithPlay = try ColorMatchRules.apply(.play(cardId: play.id, chosenColor: nil, callOne: true), by: "a", to: state, using: &rng)
        #expect(calledWithPlay.vulnerablePlayer == nil)
        #expect(throws: MoveError.notAllowed) { try ColorMatchRules.apply(.catchOne(target: "a"), by: "b", to: calledWithPlay, using: &rng) }

        let forgot = try ColorMatchRules.apply(.play(cardId: play.id, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        let lateCall = try ColorMatchRules.apply(.callOne, by: "a", to: forgot, using: &rng)
        #expect(lateCall.vulnerablePlayer == nil)
        #expect(throws: MoveError.notAllowed) { try ColorMatchRules.apply(.catchOne(target: "a"), by: "b", to: lateCall, using: &rng) }
    }

    // MARK: - Reshuffle (CM-08)

    @Test("Empty draw pile: discards are reshuffled, keeping the top card")
    func reshuffle() throws {
        let top = card(.red, .number(4))
        var state = table(players: ["a", "b"], hands: ["a": [card(.blue, .number(1))], "b": filler(3)], top: top, drawPile: [])
        state.discardPile = [card(.green, .number(6)), card(.yellow, .number(7)), top]
        let drew = try ColorMatchRules.apply(.draw, by: "a", to: state, using: &rng)
        #expect(drew.topCard.id == top.id)
        #expect(drew.discardPile.count == 1)
        #expect(drew.hands["a"]?.count == 2)
        #expect(drew.drawPile.count == 1)
    }

    @Test("No cards anywhere: drawing passes")
    func nothingToDraw() throws {
        let state = table(players: ["a", "b"], hands: ["a": [card(.blue, .number(1))], "b": filler(3)], top: card(.red, .number(4)), drawPile: [])
        let drew = try ColorMatchRules.apply(.draw, by: "a", to: state, using: &rng)
        #expect(drew.hands["a"]?.count == 1)
        #expect(drew.currentPlayer == "b")
    }

    // MARK: - Scoring (CM-09)

    @Test("Final Draw Two is applied before scoring")
    func finalDrawTwo() throws {
        let last = card(.red, .drawTwo)
        let victimHand = [card(.blue, .number(3)), card(nil, .wild)] // 3 + 50
        let state = table(players: ["a", "b"], hands: ["a": [last], "b": victimHand], top: card(.red, .number(4)), drawPile: [card(.green, .skip), card(.green, .number(9))])
        let done = try ColorMatchRules.apply(.play(cardId: last.id, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        #expect(done.hands["b"]?.count == 4)
        #expect(done.roundResult?.winner == "a")
        #expect(done.roundResult?.points == 3 + 50 + 20 + 9)
        #expect(done.scores["a"] == 82)
    }

    @Test("Final Wild Draw Four penalty is applied before scoring")
    func finalDrawFour() throws {
        let last = card(nil, .wildDrawFour)
        let state = table(players: ["a", "b", "c"], hands: ["a": [last], "b": [card(.red, .number(2))], "c": [card(.blue, .number(1))]], top: card(.red, .number(4)), drawPile: (0..<4).map { _ in card(.yellow, .number(1)) })
        let done = try ColorMatchRules.apply(.play(cardId: last.id, chosenColor: .blue, callOne: false), by: "a", to: state, using: &rng)
        #expect(done.hands["b"]?.count == 5)
        #expect(done.pendingDrawFour == nil)
        #expect(done.roundResult?.points == (2 + 4) + 1)
        #expect(done.roundResult?.handPoints == ["b": 6, "c": 1])
    }

    @Test("First to 500 wins the match; next round keeps scores; new match resets")
    func matchLifecycle() throws {
        let last = card(.red, .number(1))
        var state = table(players: ["a", "b"], hands: ["a": [last], "b": [card(nil, .wild)]], top: card(.red, .number(4)))
        state.scores = ["a": 460, "b": 120]
        let done = try ColorMatchRules.apply(.play(cardId: last.id, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        #expect(done.scores["a"] == 510)
        #expect(done.matchWinner == "a")
        #expect(throws: MoveError.gameOver) { try ColorMatchRules.apply(.draw, by: "b", to: done, using: &rng) }

        let fresh = ColorMatchRules.nextRound(from: done, using: &rng)
        #expect(fresh.scores == ["a": 0, "b": 0])
        #expect(fresh.round == 1)

        var notOver = done
        notOver.matchWinner = nil
        let round2 = ColorMatchRules.nextRound(from: notOver, using: &rng)
        #expect(round2.scores == done.scores)
        #expect(round2.round == 2)
        #expect(round2.currentPlayer == "b") // starting player rotates
    }

    // MARK: - Privacy (PRIV-01)

    @Test("Snapshots contain only the viewer's hand: no other hands, no deck order")
    func privacy() throws {
        var rng = SplitMix64(state: 99)
        let state = ColorMatchRules.newMatch(players: ["a", "b", "c"], using: &rng)
        let snapshot = ColorMatchRules.snapshot(of: state, for: "a")
        #expect(snapshot.hand == state.hands["a"])
        #expect(snapshot.cardCounts["b"] == 7)

        let json = try JSONEncoder().encode(GameStateSnapshot.colorMatch(snapshot))
        let decoded = try JSONSerialization.jsonObject(with: json)
        var ids = Set<Int>()
        collectCardIds(decoded, into: &ids)
        let allowed = Set(state.hands["a"]!.map(\.id) + [state.topCard.id])
        #expect(ids.isSubset(of: allowed), "Leaked card ids: \(ids.subtracting(allowed))")
        #expect(json.count < EnvelopeCodec.maxEnvelopeBytes)
    }

    private func collectCardIds(_ value: Any, into ids: inout Set<Int>) {
        if let dict = value as? [String: Any] {
            if let id = dict["id"] as? Int, dict["face"] != nil { ids.insert(id) }
            dict.values.forEach { collectCardIds($0, into: &ids) }
        } else if let array = value as? [Any] {
            array.forEach { collectCardIds($0, into: &ids) }
        }
    }

    @Test("Catch only works while the player still holds exactly one card")
    func catchNeedsOneCard() throws {
        let skip = card(.red, .skip)
        // Two players: A plays a Skip as their second-to-last card without calling One, then draws.
        var state = table(players: ["a", "b"], hands: ["a": [skip, card(.blue, .number(1))], "b": filler(3)], top: card(.red, .number(4)), drawPile: filler(5))
        state = try ColorMatchRules.apply(.play(cardId: skip.id, chosenColor: nil, callOne: false), by: "a", to: state, using: &rng)
        #expect(state.vulnerablePlayer == "a")
        state = try ColorMatchRules.apply(.draw, by: "a", to: state, using: &rng)
        #expect((state.hands["a"]?.count ?? 0) > 1)
        #expect(throws: MoveError.notAllowed) {
            _ = try ColorMatchRules.apply(.catchOne(target: "a"), by: "b", to: state, using: &self.rng)
        }
    }
}
