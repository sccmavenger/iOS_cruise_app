import Foundation
import Testing
@testable import iso_cruise_app

@Suite("Bluetooth nudges")
struct NudgeTests {
    @Test("Service UUIDs are stable per id, differ between ids, and are valid v4 UUIDs")
    func serviceUUID() throws {
        let a = Nudge.serviceUUIDString(for: "alice")
        #expect(a == Nudge.serviceUUIDString(for: "alice"))
        #expect(a != Nudge.serviceUUIDString(for: "bob"))
        let uuid = try #require(UUID(uuidString: a))
        #expect(uuid.uuidString.dropFirst(14).first == "4")
    }

    @Test("Payloads round-trip and fit in one Bluetooth write")
    func roundTrip() throws {
        let payload = Nudge.Payload(v: Nudge.version, from: UUID().uuidString, kind: .turn(.colorMatch))
        let data = try #require(Nudge.encode(payload))
        #expect(data.count <= Nudge.maxPayloadBytes)
        #expect(Nudge.decode(data) == payload)
    }

    @Test("Untrusted bytes are dropped")
    func rejectsBadInput() throws {
        #expect(Nudge.decode(Data("not json".utf8)) == nil)
        #expect(Nudge.decode(Data(repeating: 0x41, count: Nudge.maxPayloadBytes + 1)) == nil)
        let wrongVersion = try #require(Nudge.encode(Nudge.Payload(v: 99, from: "x", kind: .chat)))
        #expect(Nudge.decode(wrongVersion) == nil)
        let empty = try #require(Nudge.encode(Nudge.Payload(v: Nudge.version, from: "", kind: .chat)))
        #expect(Nudge.decode(empty) == nil)
    }

    @Test("Repeats of the same kind to the same person are rate-limited")
    func rateLimit() {
        var limiter = Nudge.RateLimiter(interval: 30)
        let start = Date.now
        // `#expect` can't wrap a mutating call, so collect the results first.
        let results = [
            limiter.allow("a", .chat, at: start),
            limiter.allow("a", .chat, at: start.addingTimeInterval(10)),
            limiter.allow("a", .turn(.chess), at: start.addingTimeInterval(10)),
            limiter.allow("b", .chat, at: start.addingTimeInterval(10)),
            limiter.allow("a", .chat, at: start.addingTimeInterval(31)),
        ]
        #expect(results == [true, false, true, true, true])
    }
}
