import Foundation
import Testing
@testable import iso_cruise_app

/// Every game state the host sends has to fit in one envelope (`EnvelopeCodec.maxEnvelopeBytes`).
/// Chess already had a size test; these are the equivalents for the card games, which were
/// added without one. A snapshot that overflows would fail to encode *mid-match*, which is
/// the worst possible time to find out.
@Suite("Card game snapshot sizes")
struct CardGameSnapshotSizeTests {
    /// Same measurement the chess size test makes: the encoded snapshot itself, which is by
    /// far the dominant term in the envelope that carries it.
    private func encodedSize(_ snapshot: GameStateSnapshot) throws -> Int {
        try JSONEncoder().encode(snapshot).count
    }

    @Test("A Spades snapshot fits an envelope with room to spare")
    func spadesFits() throws {
        var rng = SeededGenerator(seed: 1)
        var state = SpadesRules.newGame(players: longIds(4), using: &rng)
        // Worst realistic case: everyone has bid, a full trick is on the table, a previous
        // trick is still being shown, and the hand has just been scored.
        for player in state.players {
            state.bids[player] = 3
            state.tricksWon[player] = 3
        }
        state.trick = state.players.enumerated().map { index, player in
            .init(player: player, card: PlayingCard(suit: .hearts, rank: 2 + index))
        }
        state.lastTrick = state.trick
        state.lastTrickWinner = state.players[0]
        state.roundResult = SpadesState.RoundResult(
            teamScores: [SpadesRules.teamA: 51, SpadesRules.teamB: -80],
            tricksWon: state.tricksWon,
            bids: state.bids,
            nilResults: Dictionary(uniqueKeysWithValues: state.players.map { ($0, false) })
        )
        state.lastEvent = String(repeating: "x", count: 200)

        let size = try encodedSize(.spades(SpadesRules.snapshot(of: state, for: state.players[0])))
        #expect(size < EnvelopeCodec.maxEnvelopeBytes)
        // Leave real headroom: the packet also carries signatures and wrapped keys on top.
        #expect(size < EnvelopeCodec.maxEnvelopeBytes / 2, "Spades snapshot was \(size) bytes")
    }

    @Test("A Tonk snapshot fits an envelope even with many spreads on the table")
    func tonkFits() throws {
        var rng = SeededGenerator(seed: 2)
        var state = TonkRules.newMatch(players: longIds(4), using: &rng)
        // Worst case the rules allow: the table filled with spreads. `maxSpreads` is 32, far
        // more than a real game produces, which is exactly why it's worth measuring.
        state.spreads = (0..<TonkRules.maxSpreads).map { index in
            TonkSpread(
                id: index,
                owner: state.players[index % state.players.count],
                cards: [
                    PlayingCard(suit: .clubs, rank: 5),
                    PlayingCard(suit: .hearts, rank: 5),
                    PlayingCard(suit: .spades, rank: 5),
                ],
                kind: .set
            )
        }
        state.roundResult = TonkState.RoundResult(
            winner: state.players[0],
            reason: .caught,
            handValues: Dictionary(uniqueKeysWithValues: state.players.map { ($0, 42) }),
            points: 84
        )
        state.lastEvent = String(repeating: "x", count: 200)

        let size = try encodedSize(.tonk(TonkRules.snapshot(of: state, for: state.players[0])))
        #expect(size < EnvelopeCodec.maxEnvelopeBytes, "Tonk snapshot was \(size) bytes")
        #expect(size < EnvelopeCodec.maxEnvelopeBytes / 2, "Tonk snapshot was \(size) bytes")
    }

    /// Mesh ids are 64-character fingerprints, and they appear as dictionary *keys* all over
    /// both snapshots. Using short test names would understate the real size badly.
    private func longIds(_ count: Int) -> [String] {
        (0..<count).map { index in
            String(repeating: "\(index)", count: 64)
        }
    }
}
