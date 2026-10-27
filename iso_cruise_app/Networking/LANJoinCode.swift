import Foundation

/// A short code that carries one phone's address on the ship network, so two people can
/// connect by reading a code aloud when the network won't let them find each other.
///
/// **Why a code at all.** Guest Wi-Fi on a ship very often has "client isolation" or blocks
/// multicast, which stops phones from *discovering* each other even though they can still
/// *reach* each other. A code skips discovery entirely: you type where your friend is, and
/// the app connects straight there. It's the last tier precisely because it needs a human to
/// read something out — but it's also the only tier that survives a network that forwards no
/// multicast at all.
///
/// **Shape.** Four bytes of IPv4 address plus a one-byte checksum, in Crockford base32 — 40
/// bits, exactly eight characters, shown as `ABCD-EFGH`. The port is fixed
/// (`LANTransport.defaultPort`) so it doesn't have to be typed. Crockford's alphabet omits
/// I, L, O and U, so there's no "is that a one or an ell" over a noisy dinner table, and
/// decoding folds the lookalikes back in anyway.
///
/// **Not a secret.** The code is an address, not a credential. Anyone who guesses it can
/// open a TCP connection, which is no more than any device on the network can already do.
/// Being allowed to *talk* to someone is still decided by the contact request the user
/// answers, and every packet is still signed. So the checksum is there to catch typos, not
/// to resist an attacker.
nonisolated struct LANJoinCode: Equatable, Sendable {
    /// IPv4 address as four octets.
    let address: (UInt8, UInt8, UInt8, UInt8)

    static func == (lhs: LANJoinCode, rhs: LANJoinCode) -> Bool {
        lhs.address == rhs.address
    }

    /// Crockford base32, without the letters that get misread when spoken or typed.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    var ipv4: String {
        "\(address.0).\(address.1).\(address.2).\(address.3)"
    }

    init?(ipv4: String) {
        let parts = ipv4.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        address = (octets[0], octets[1], octets[2], octets[3])
    }

    private init(octets: [UInt8]) {
        address = (octets[0], octets[1], octets[2], octets[3])
    }

    /// The eight-character code, hyphenated for reading aloud.
    var formatted: String {
        let raw = encoded
        let middle = raw.index(raw.startIndex, offsetBy: 4)
        return "\(raw[raw.startIndex..<middle])-\(raw[middle...])"
    }

    /// The eight characters without the hyphen.
    var encoded: String {
        let bytes = [address.0, address.1, address.2, address.3, Self.checksum(address)]
        // 5 bytes = 40 bits = 8 groups of 5, so this divides evenly with no padding.
        var bits = 0
        var accumulator = 0
        var output = ""
        for byte in bytes {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(Self.alphabet[(accumulator >> bits) & 0x1F])
            }
        }
        return output
    }

    /// Parses a code the user typed. Tolerates lowercase, spaces, hyphens, and the
    /// characters Crockford folds (I and L read as 1, O reads as 0).
    init?(code: String) {
        let normalized = code.uppercased().compactMap { character -> Character? in
            switch character {
            case "-", " ": nil
            case "I", "L": "1"
            case "O": "0"
            case "U": nil
            default: character
            }
        }
        guard normalized.count == 8 else { return nil }

        var accumulator = 0
        var bits = 0
        var bytes: [UInt8] = []
        for character in normalized {
            guard let value = Self.alphabet.firstIndex(of: character) else { return nil }
            accumulator = (accumulator << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((accumulator >> bits) & 0xFF))
            }
        }
        guard bytes.count == 5 else { return nil }
        let octets = Array(bytes.prefix(4))
        guard bytes[4] == Self.checksum((octets[0], octets[1], octets[2], octets[3])) else { return nil }
        self.init(octets: octets)
    }

    /// Prefix on the QR payload, so a scan of some unrelated QR code in a hotel lobby is
    /// rejected instead of being parsed as an address.
    static let qrPrefix = "cruiselan:j:"

    /// What goes in the QR code. Deliberately the *same eight characters* as the typed code,
    /// just with a prefix: one source of truth, and a QR that won't scan in bad light can
    /// still be read aloud from the screen below it.
    var qrPayload: String { Self.qrPrefix + encoded }

    /// Parses a scanned payload. Anything without the prefix, or with a bad code after it,
    /// is refused — a scanner will happily hand us any QR code in view.
    init?(qrPayload: String) {
        let trimmed = qrPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        // Case-insensitive on the prefix only; the code itself is normalised by `init(code:)`.
        guard trimmed.count <= 64,
              trimmed.lowercased().hasPrefix(Self.qrPrefix)
        else { return nil }
        self.init(code: String(trimmed.dropFirst(Self.qrPrefix.count)))
    }

    /// A one-byte typo check. Not a security property — see the type's note.
    private static func checksum(_ address: (UInt8, UInt8, UInt8, UInt8)) -> UInt8 {
        var sum: UInt8 = 0x5A
        for octet in [address.0, address.1, address.2, address.3] {
            sum = sum &* 31 &+ octet
        }
        return sum
    }
}
