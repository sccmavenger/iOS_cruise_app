import Testing
@testable import iso_cruise_app

@Suite("LAN join code")
struct LANJoinCodeTests {
    @Test("A code round-trips back to the same address")
    func roundTrip() throws {
        for address in ["192.168.1.42", "10.0.0.1", "172.16.254.3", "255.255.255.255", "0.0.0.0"] {
            let code = try #require(LANJoinCode(ipv4: address))
            let parsed = try #require(LANJoinCode(code: code.formatted))
            #expect(parsed.ipv4 == address)
        }
    }

    @Test("Codes are always eight characters, shown in two groups of four")
    func shape() throws {
        let code = try #require(LANJoinCode(ipv4: "192.168.1.42"))
        #expect(code.encoded.count == 8)
        #expect(code.formatted.count == 9)
        #expect(code.formatted.contains("-"))
    }

    @Test("Lowercase, spaces, and hyphens are accepted")
    func forgivingInput() throws {
        let code = try #require(LANJoinCode(ipv4: "192.168.1.42"))
        let raw = code.encoded
        let variants = [raw.lowercased(), code.formatted.lowercased(), "\(raw.prefix(4)) \(raw.suffix(4))"]
        for variant in variants {
            #expect(LANJoinCode(code: variant)?.ipv4 == "192.168.1.42")
        }
    }

    /// Crockford folds the characters people misread when a code is spoken aloud, which is
    /// how these codes are meant to travel.
    @Test("Lookalike characters fold to their digits")
    func lookalikes() {
        // The alphabet never emits I, L, O or U, so any code containing them came from a
        // person typing; it should still land on the same address.
        let encoded = LANJoinCode(ipv4: "16.1.0.1")?.encoded
        #expect(encoded?.contains("I") == false)
        #expect(encoded?.contains("L") == false)
        #expect(encoded?.contains("O") == false)
        #expect(encoded?.contains("U") == false)
    }

    @Test("A mistyped code is rejected rather than silently pointing somewhere else")
    func checksumCatchesTypos() throws {
        let code = try #require(LANJoinCode(ipv4: "192.168.1.42"))
        var rejected = 0
        var accepted = 0
        // Flip each character to every other letter in the alphabet and count how many
        // single-character typos slip through the checksum.
        for position in code.encoded.indices {
            for replacement in "0123456789ABCDEFGHJKMNPQRSTVWXYZ" where replacement != code.encoded[position] {
                var typo = Array(code.encoded)
                typo[code.encoded.distance(from: code.encoded.startIndex, to: position)] = replacement
                if LANJoinCode(code: String(typo)) == nil { rejected += 1 } else { accepted += 1 }
            }
        }
        // A one-byte checksum catches roughly 255 in 256, so a handful get through; the
        // point is that the overwhelming majority of typos fail loudly.
        #expect(Double(rejected) / Double(rejected + accepted) > 0.9)
    }

    @Test("Codes of the wrong length are refused")
    func wrongLength() {
        #expect(LANJoinCode(code: "") == nil)
        #expect(LANJoinCode(code: "ABC") == nil)
        #expect(LANJoinCode(code: "ABCDEFGHIJKLMNOP") == nil)
    }

    @Test("A QR payload round-trips and carries the same code as the typed one")
    func qrRoundTrip() throws {
        let code = try #require(LANJoinCode(ipv4: "192.168.1.42"))
        #expect(code.qrPayload == "cruiselan:j:\(code.encoded)")

        let scanned = try #require(LANJoinCode(qrPayload: code.qrPayload))
        #expect(scanned.ipv4 == "192.168.1.42")
        // The QR and the typed path must agree, or reading the code aloud would connect
        // somewhere else than scanning it.
        #expect(scanned == LANJoinCode(code: code.formatted))
    }

    /// A scanner hands the app whatever QR code happens to be in frame — a hotel Wi-Fi
    /// poster, a menu, a parking sign. Everything without our prefix must be refused.
    @Test("Foreign QR codes are refused")
    func qrRejectsForeignPayloads() throws {
        let code = try #require(LANJoinCode(ipv4: "10.0.0.7"))
        #expect(LANJoinCode(qrPayload: "https://disney.com") == nil)
        #expect(LANJoinCode(qrPayload: "WIFI:S:GuestNet;T:WPA;P:hunter2;;") == nil)
        #expect(LANJoinCode(qrPayload: "") == nil)
        // Right shape, wrong prefix.
        #expect(LANJoinCode(qrPayload: code.encoded) == nil)
        #expect(LANJoinCode(qrPayload: "other:j:\(code.encoded)") == nil)
        // Right prefix, bad code after it.
        #expect(LANJoinCode(qrPayload: "cruiselan:j:ZZZZZZZZ") == nil)
        #expect(LANJoinCode(qrPayload: "cruiselan:j:") == nil)
        // Absurdly long payloads are refused before any parsing.
        #expect(LANJoinCode(qrPayload: "cruiselan:j:" + String(repeating: "A", count: 500)) == nil)
    }

    @Test("QR payloads tolerate surrounding whitespace and prefix casing")
    func qrForgivingInput() throws {
        let code = try #require(LANJoinCode(ipv4: "172.16.5.9"))
        #expect(LANJoinCode(qrPayload: "  \(code.qrPayload)\n")?.ipv4 == "172.16.5.9")
        #expect(LANJoinCode(qrPayload: code.qrPayload.uppercased())?.ipv4 == "172.16.5.9")
    }

    @Test("Malformed addresses are refused")
    func malformedAddress() {
        #expect(LANJoinCode(ipv4: "192.168.1") == nil)
        #expect(LANJoinCode(ipv4: "192.168.1.256") == nil)
        #expect(LANJoinCode(ipv4: "not.an.ip.address") == nil)
        #expect(LANJoinCode(ipv4: "") == nil)
    }
}
