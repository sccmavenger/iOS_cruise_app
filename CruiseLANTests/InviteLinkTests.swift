import Foundation
import Testing
@testable import iso_cruise_app

@Suite("Invite links")
struct InviteLinkTests {
    @Test("A shared link round-trips to its code")
    func roundTrip() throws {
        let url = InviteLink.url(for: "ABCD1234")
        #expect(url.absoluteString == "https://cruiselan-games.dguilloryjr.workers.dev/join/ABCD1234")
        #expect(InviteLink.code(from: url) == "ABCD1234")
    }

    @Test("Both link forms are understood; other links aren't", arguments: [
        ("https://cruiselan-games.dguilloryjr.workers.dev/join/ABCD1234", "ABCD1234"),
        ("https://cruiselan-games.dguilloryjr.workers.dev/join/abcd-1234", "ABCD1234"),
        ("cruiselan://join/ABCD1234", "ABCD1234"),
        ("cruiselan://join/abcd-1234", "ABCD1234"),
        ("https://example.com/join/ABCD1234", nil),
        ("https://cruiselan-games.dguilloryjr.workers.dev/v1/health", nil),
        ("cruiselan://join/ABC12", nil),
        ("cruiselan://other/ABCD1234", nil),
    ] as [(String, String?)])
    func parsing(link: String, expected: String?) throws {
        #expect(InviteLink.code(from: try #require(URL(string: link))) == expected)
    }

    @Test("Typed or pasted codes are cleaned the way the server reads them")
    func typed() {
        #expect(InviteLink.code(fromText: " abcd-1234 ") == "ABCD1234")
        #expect(InviteLink.code(fromText: "ABCO1234") == "ABC01234", "O reads as zero")
        #expect(InviteLink.code(fromText: "Join me: https://cruiselan-games.dguilloryjr.workers.dev/join/WXYZ5678") == nil, "a whole message isn't a code")
        #expect(InviteLink.code(fromText: "https://cruiselan-games.dguilloryjr.workers.dev/join/WXYZ5678") == "WXYZ5678")
        #expect(InviteLink.code(fromText: "1234") == nil)
    }
}
