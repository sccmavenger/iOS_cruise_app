import CryptoKit
import Foundation
import Testing
@testable import iso_cruise_app

@Suite("Bluetooth nudges")
struct NudgeTests {
    let key = SymmetricKey(size: .bits256)
    let sender = UUID().uuidString

    private func message(_ kind: Nudge.Kind, sentAt: Date = .now) -> Nudge.Message {
        Nudge.Message(id: UUID(), sentAt: sentAt, kind: kind)
    }

    @Test("Service UUIDs are stable per id, differ between ids, and are valid v4 UUIDs")
    func serviceUUID() throws {
        let a = Nudge.serviceUUIDString(for: "alice")
        #expect(a == Nudge.serviceUUIDString(for: "alice"))
        #expect(a != Nudge.serviceUUIDString(for: "bob"))
        let uuid = try #require(UUID(uuidString: a))
        #expect(uuid.uuidString.dropFirst(14).first == "4")
    }

    @Test("Sealed nudges open only with the pair's key and keep their content")
    func sealAndOpen() throws {
        let original = message(.chat(preview: "See you at the pool"))
        let data = try #require(Nudge.seal(original, from: sender, key: key))
        let opened = try #require(Nudge.open(data, key: { $0 == sender ? key : nil }))
        #expect(opened.from == sender)
        #expect(opened.message == original)
        // Another key, or an unknown sender, can't open it.
        #expect(Nudge.open(data, key: { _ in SymmetricKey(size: .bits256) }) == nil)
        #expect(Nudge.open(data, key: { _ in nil }) == nil)
    }

    @Test("Tampered, claimed-by-someone-else, old, or malformed bytes are dropped")
    func rejectsBadInput() throws {
        let data = try #require(Nudge.seal(message(.turn(.chess)), from: sender, key: key))
        var tampered = data
        tampered[tampered.count - 1] ^= 0xFF
        #expect(Nudge.open(tampered, key: { _ in key }) == nil)

        // Re-labeling the sender doesn't help: the box only opens with the real sender's key.
        let impostor = String(repeating: "x", count: sender.utf8.count)
        var relabeled = data
        relabeled.replaceSubrange(2..<(2 + sender.utf8.count), with: Data(impostor.utf8))
        let otherKey = SymmetricKey(size: .bits256)
        #expect(Nudge.open(relabeled, key: { $0 == impostor ? otherKey : nil }) == nil)

        let stale = try #require(Nudge.seal(message(.turn(.chess), sentAt: .now.addingTimeInterval(-Nudge.maxAge - 10)), from: sender, key: key))
        #expect(Nudge.open(stale, key: { _ in key }) == nil)
        #expect(Nudge.open(Data("not a nudge".utf8), key: { _ in key }) == nil)
        #expect(Nudge.open(Data(repeating: 2, count: Nudge.maxPayloadBytes + 1), key: { _ in key }) == nil)
    }

    @Test("The largest move still fits in one Bluetooth write")
    func moveFits() throws {
        let request = MoveRequestPayload(moveId: UUID(), baseRevision: 9_999, move: .colorMatch(.catchOne(target: UUID().uuidString)))
        let data = try #require(Nudge.seal(message(.move(lobbyId: UUID(), request: request)), from: sender, key: key))
        #expect(data.count < Nudge.maxPayloadBytes)
        let long = try #require(Nudge.seal(message(.chat(preview: Nudge.preview(of: String(repeating: "🛳️", count: 200)))), from: sender, key: key))
        #expect(long.count < Nudge.maxPayloadBytes)
    }

    @Test("Previews are short and never split a character")
    func preview() {
        let text = String(repeating: "🛳️", count: 100)
        let short = Nudge.preview(of: text)
        #expect(short.utf8.count <= Nudge.maxPreviewBytes + "…".utf8.count)
        #expect(short.hasSuffix("…"))
        #expect(Nudge.preview(of: "Hi!") == "Hi!")
    }

    @Test("Replays are dropped")
    func replay() {
        var guardian = Nudge.ReplayGuard()
        let id = UUID()
        let first = guardian.isNew(id), second = guardian.isNew(id)
        #expect(first)
        #expect(!second)
    }

    @Test("Topics are rate-limited per person; forgetting a person resets them")
    func rateLimit() {
        var limiter = Nudge.RateLimiter(interval: 30)
        let start = Date.now
        // `#expect` can't wrap a mutating call, so collect the results first.
        var results = [
            limiter.allow("a", "chat", at: start),
            limiter.allow("a", "chat", at: start.addingTimeInterval(10)),
            limiter.allow("a", "turn-chess", at: start.addingTimeInterval(10)),
            limiter.allow("b", "chat", at: start.addingTimeInterval(10)),
            limiter.allow("a", "chat", at: start.addingTimeInterval(31)),
        ]
        limiter.forget("a")
        results.append(limiter.allow("a", "chat", at: start.addingTimeInterval(32)))
        #expect(results == [true, false, true, true, true, true])
        #expect(Nudge.Kind.move(lobbyId: UUID(), request: MoveRequestPayload(moveId: UUID(), baseRevision: 0, move: .ticTacToe(cell: 0))).topic == nil)
    }
}
