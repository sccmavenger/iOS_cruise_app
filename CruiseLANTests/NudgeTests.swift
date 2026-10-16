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

    @Test("Sealed nudges open only with the pair's key and name the right sender")
    func sealAndOpen() throws {
        let original = message(.chat(preview: "See you at the pool", conversationId: UUID()))
        let data = try #require(Nudge.seal(original, from: sender, key: key))
        let opened = try #require(Nudge.open(data, keys: ["someone-else": SymmetricKey(size: .bits256), sender: key]))
        #expect(opened.from == sender)
        #expect(opened.message.id == original.id)
        #expect(opened.message.kind == original.kind)
        // JSON keeps the timestamp to about a microsecond.
        #expect(abs(opened.message.sentAt.timeIntervalSince(original.sentAt)) < 0.001)
        // Without the key, nothing opens.
        #expect(Nudge.open(data, keys: ["x": SymmetricKey(size: .bits256)]) == nil)
        #expect(Nudge.open(data, keys: [:]) == nil)
    }

    @Test("Nothing on the air identifies the sender")
    func anonymousOnTheWire() throws {
        let data = try #require(Nudge.seal(message(.turn(.chess)), from: sender, key: key))
        #expect(data.range(of: Data(sender.utf8)) == nil)
        #expect(data.first == UInt8(Nudge.version))
    }

    @Test("Tampered, old, or malformed bytes are dropped")
    func rejectsBadInput() throws {
        let keys = [sender: key]
        let data = try #require(Nudge.seal(message(.turn(.chess)), from: sender, key: key))
        var tampered = data
        tampered[tampered.count - 1] ^= 0xFF
        #expect(Nudge.open(tampered, keys: keys) == nil)

        let stale = try #require(Nudge.seal(message(.turn(.chess), sentAt: .now.addingTimeInterval(-Nudge.maxAge - 10)), from: sender, key: key))
        #expect(Nudge.open(stale, keys: keys) == nil)
        let future = try #require(Nudge.seal(message(.turn(.chess), sentAt: .now.addingTimeInterval(Nudge.maxAge + 10)), from: sender, key: key))
        #expect(Nudge.open(future, keys: keys) == nil)
        #expect(Nudge.open(Data("not a nudge".utf8), keys: keys) == nil)
        #expect(Nudge.open(Data(repeating: 3, count: Nudge.maxPayloadBytes + 1), keys: keys) == nil)
        var wrongVersion = data
        wrongVersion[0] = 2
        #expect(Nudge.open(wrongVersion, keys: keys) == nil)
    }

    @Test("The largest move still fits in one Bluetooth write")
    func moveFits() throws {
        let request = MoveRequestPayload(moveId: UUID(), baseRevision: 9_999, move: .colorMatch(.catchOne(target: UUID().uuidString)))
        let data = try #require(Nudge.seal(message(.move(lobbyId: UUID(), request: request)), from: sender, key: key))
        #expect(data.count < Nudge.maxPayloadBytes)
        let long = try #require(Nudge.seal(message(.chat(preview: Nudge.preview(of: String(repeating: "🛳️", count: 200)), conversationId: UUID())), from: sender, key: key))
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

    @Test("The saved identity is reused while recent and replaced after it expires")
    func identityStore() {
        var clock = Date.now
        let store = IdentityStore(service: "test.identity.\(UUID().uuidString)", now: { clock })
        defer { store.clear() }
        let key = Data(repeating: 7, count: 32)
        let snapshot = IdentityStore.Snapshot(localId: "me", lastActive: clock, known: ["a": "Alex"],
                                              inboundKeys: ["a": key], outboundKeys: ["a": key])
        store.save(snapshot)
        #expect(store.load() == snapshot)
        clock = clock.addingTimeInterval(IdentityStore.lifetime + 1)
        #expect(store.load() == nil)
    }

    @Test("Chat nudges are rate-limited per conversation")
    func chatTopics() {
        let a = Nudge.Kind.chat(preview: "x", conversationId: UUID()).topic
        let b = Nudge.Kind.chat(preview: "x", conversationId: UUID()).topic
        #expect(a != b)
        #expect(Nudge.Kind.chat(preview: nil, conversationId: nil).topic == "chat-everyone")
        #expect(Nudge.Kind.invite(.chess).topic == "invite-chess")
    }

    @Test("A normal-length message fits in one Bluetooth write whole; a very long one doesn't")
    func wholeMessages() throws {
        let key = SymmetricKey(size: .bits256)
        let sender = MeshIdentity().id
        let typical = String(repeating: "Meet at the pool deck by the slides at 3? ", count: 4) // ~170 bytes, longer than most chats
        let message = Nudge.Message(id: UUID(), sentAt: Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded()),
                                    kind: .message(id: UUID(), text: typical, conversationId: UUID()))
        let data = try #require(Nudge.seal(message, from: sender, key: key))
        #expect(Nudge.open(data, keys: [sender: key])?.message == message)
        let long = String(repeating: "x", count: EnvelopeCodec.maxChatCharacters)
        #expect(Nudge.seal(Nudge.Message(id: UUID(), sentAt: .now, kind: .message(id: UUID(), text: long, conversationId: nil)),
                           from: sender, key: key) == nil)
    }
}
