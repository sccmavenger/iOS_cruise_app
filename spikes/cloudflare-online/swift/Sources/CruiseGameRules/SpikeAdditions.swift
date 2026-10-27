// Spike-only additions that Phase 0 would make for real.
extension String {
    /// Stdlib replacement for Foundation's `capitalized` on single lowercase words.
    var spikeCapitalized: String { prefix(1).uppercased() + dropFirst() }
}

extension GameEngine {
    /// `apply` with an injectable generator, so the server controls the randomness.
    static func apply(_ move: GameMove, by playerId: String, to state: State, using rng: inout some RandomNumberGenerator) throws(MoveError) -> State {
        switch (state, move) {
        case (.colorMatch(let table), .colorMatch(let action)):
            return .colorMatch(try ColorMatchRules.apply(action, by: playerId, to: table, using: &rng))
        case (.spades(let table), .spades(let action)):
            return .spades(try SpadesRules.apply(action, by: playerId, to: table, using: &rng))
        case (.tonk(let table), .tonk(let action)):
            return .tonk(try TonkRules.apply(action, by: playerId, to: table, using: &rng))
        default:
            return try apply(move, by: playerId, to: state)
        }
    }

    static func rematch(from state: State, using rng: inout some RandomNumberGenerator) -> State {
        switch state {
        case .colorMatch(let table): .colorMatch(ColorMatchRules.nextRound(from: table, using: &rng))
        case .spades(let table): .spades(SpadesRules.nextRound(from: table, using: &rng))
        case .tonk(let table): .tonk(TonkRules.nextRound(from: table, using: &rng))
        default: rematch(from: state)
        }
    }
}

extension Array {
    /// Fisher–Yates with 64-bit draws, so a seed deals the same deck on 64-bit iOS and 32-bit
    /// WebAssembly. The standard library's `shuffle(using:)` draws `Int`-sized values, which differ.
    mutating func portableShuffle(using rng: inout some RandomNumberGenerator) {
        guard count > 1 else { return }
        for i in stride(from: count - 1, to: 0, by: -1) {
            let j = Int(rng.next(upperBound: UInt64(i + 1)))
            swapAt(i, j)
        }
    }

    func portableShuffled(using rng: inout some RandomNumberGenerator) -> [Element] {
        var copy = self
        copy.portableShuffle(using: &rng)
        return copy
    }
}
