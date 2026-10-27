/// Standard-library helpers for the game rules. The rules are also compiled to WebAssembly for
/// the cloud game server, where Foundation would add megabytes and isn't otherwise needed, so
/// nothing under Games/*Rules, *Model, GameEngine, GameProtocol, GameType or PlayingCard may
/// import Foundation.

extension String {
    /// "red" → "Red". The rules only capitalize single lowercase words (enum raw values).
    nonisolated var capitalizedWord: String { prefix(1).uppercased() + dropFirst() }
}

extension Array {
    /// Fisher–Yates with 64-bit draws. The standard library's `shuffle(using:)` draws
    /// `Int`-sized values, so the same seed deals a different deck on 64-bit iOS and on
    /// 32-bit WebAssembly. This one deals identically everywhere, which lets the server's
    /// cross-platform tests cover dealing. Real games pass a secure generator either way.
    nonisolated mutating func portableShuffle(using rng: inout some RandomNumberGenerator) {
        guard count > 1 else { return }
        for i in stride(from: count - 1, to: 0, by: -1) {
            swapAt(i, Int(rng.next(upperBound: UInt64(i + 1))))
        }
    }

    nonisolated func portableShuffled(using rng: inout some RandomNumberGenerator) -> [Element] {
        var copy = self
        copy.portableShuffle(using: &rng)
        return copy
    }
}
