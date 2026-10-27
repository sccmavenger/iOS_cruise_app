import CryptoKit
import Foundation
import Testing
@testable import iso_cruise_app

// MARK: - Envelope codec

private let fixedId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

@Suite("Envelope codec")
struct EnvelopeCodecTests {
    @Test("Every payload kind round-trips")
    func roundTrip() throws {
        let lobby = UUID()
        let payloads: [Envelope.Payload] = [
            .hello(HelloPayload(nickname: "Sam", protocolVersion: 2)),
            .chat(ChatPayload(text: "Hello deck 7")),
            .lobbyOffer(LobbyOfferPayload(lobbyId: lobby, gameType: .ticTacToe, hostNickname: "Sam", maxSeats: 2, seatsTaken: 1)),
            .joinRequest(LobbyRefPayload(lobbyId: lobby)),
            .joinAccept(LobbyRosterPayload(lobbyId: lobby, gameType: .colorMatch, maxSeats: 4, players: [LobbyPlayer(id: "a", nickname: "A", isReady: true, isHost: true)])),
            .joinReject(JoinRejectPayload(lobbyId: lobby, reason: .lobbyFull)),
            .ready(ReadyPayload(lobbyId: lobby, isReady: true)),
            .startGame(StartGamePayload(lobbyId: lobby, gameType: .ticTacToe, seats: ["a", "b"])),
            .moveRequest(MoveRequestPayload(moveId: UUID(), baseRevision: 3, move: .ticTacToe(cell: 4))),
            .stateSnapshot(StateSnapshotPayload(revision: 2, state: .ticTacToe(TicTacToeRules.newGame(players: ["a", "b"])))),
            .gameEvent(GameEventPayload(event: .moveRejected, message: "Nope")),
            .rematchRequest(LobbyRefPayload(lobbyId: lobby)),
            .leave(LeavePayload(lobbyId: nil)),
            .error(ErrorPayload(code: "x", message: "y")),
            .heartbeat(EmptyPayload()),
            .presence(PresencePayload(away: true)),
            .announce(AnnouncePayload(nickname: "Sam")),
            .contactRequest(ContactPayload(nickname: "Sam")),
            .contactAccept(ContactPayload(nickname: "Sam")),
            .keys(KeysPayload(nudgeKey: Data(repeating: 1, count: 32).base64EncodedString())),
            .contactEnd(EmptyPayload()),
        ]
        #expect(Set(payloads.map(\.kind)) == Set(Envelope.Kind.allCases))

        for (index, payload) in payloads.enumerated() {
            let envelope = Envelope(sessionId: lobby, senderId: "peer-1", sequence: index, payload: payload)
            let decoded = try EnvelopeCodec.decode(try EnvelopeCodec.encode(envelope))
            #expect(decoded == envelope)
        }
    }

    @Test("Encoded JSON carries the documented fields")
    func wireFormat() throws {
        let envelope = Envelope(senderId: "p", sequence: 7, payload: .chat(ChatPayload(text: "hi")))
        let object = try #require(try JSONSerialization.jsonObject(with: EnvelopeCodec.encode(envelope)) as? [String: Any])
        #expect(object["version"] as? Int == 2)
        #expect(object["kind"] as? String == "chat")
        #expect(object["senderId"] as? String == "p")
        #expect(object["sequence"] as? Int == 7)
        #expect(object["id"] is String)
        #expect(object["payload"] is [String: Any])
    }

    @Test("Garbage, truncated, and empty data are rejected")
    func malformed() throws {
        let valid = try EnvelopeCodec.encode(Envelope(senderId: "p", sequence: 1, payload: .chat(ChatPayload(text: "hi"))))
        for data in [Data(), Data("not json".utf8), valid.prefix(valid.count / 2), Data("[]".utf8), Data("{}".utf8)] {
            #expect(throws: EnvelopeCodecError.malformed) { try EnvelopeCodec.decode(Data(data)) }
        }
    }

    @Test("Unknown kind is rejected")
    func unknownKind() {
        let json = #"{"version":2,"id":"\#(UUID().uuidString)","kind":"selfDestruct","senderId":"p","sequence":1,"payload":{}}"#
        #expect(throws: EnvelopeCodecError.malformed) { try EnvelopeCodec.decode(Data(json.utf8)) }
    }

    @Test("Payload that doesn't match its kind is rejected")
    func kindPayloadMismatch() {
        let json = #"{"version":2,"id":"\#(UUID().uuidString)","kind":"chat","senderId":"p","sequence":1,"payload":{"nickname":"x","protocolVersion":1}}"#
        #expect(throws: EnvelopeCodecError.malformed) { try EnvelopeCodec.decode(Data(json.utf8)) }
    }

    @Test("Oversized input is rejected before parsing")
    func oversized() {
        let data = Data(repeating: 0x7B, count: EnvelopeCodec.maxEnvelopeBytes + 1)
        #expect(throws: EnvelopeCodecError.tooLarge(data.count)) { try EnvelopeCodec.decode(data) }
    }

    @Test("Unsupported version is rejected")
    func unsupportedVersion() throws {
        let envelope = Envelope(version: 99, senderId: "p", sequence: 1, payload: .heartbeat(EmptyPayload()))
        let data = try JSONEncoder().encode(envelope)
        #expect(throws: EnvelopeCodecError.unsupportedVersion(99)) { try EnvelopeCodec.decode(data) }
    }

    @Test("Semantic bounds are enforced", arguments: [
        Envelope.Payload.chat(ChatPayload(text: "   ")),
        .chat(ChatPayload(text: String(repeating: "a", count: EnvelopeCodec.maxChatCharacters + 1))),
        .hello(HelloPayload(nickname: "\u{202E}\u{0007}", protocolVersion: 1)),
        .moveRequest(MoveRequestPayload(moveId: fixedId, baseRevision: 0, move: .ticTacToe(cell: 9))),
        .moveRequest(MoveRequestPayload(moveId: fixedId, baseRevision: -1, move: .ticTacToe(cell: 0))),
        .startGame(StartGamePayload(lobbyId: fixedId, gameType: .ticTacToe, seats: ["a", "a"])),
        .startGame(StartGamePayload(lobbyId: fixedId, gameType: .ticTacToe, seats: ["a", "b", "c"])),
        .lobbyOffer(LobbyOfferPayload(lobbyId: fixedId, gameType: .ticTacToe, hostNickname: "H", maxSeats: 4, seatsTaken: 1)),
    ])
    func invalidPayloads(payload: Envelope.Payload) throws {
        let data = try JSONEncoder().encode(Envelope(senderId: "p", sequence: 1, payload: payload))
        #expect(throws: EnvelopeCodecError.self) { try EnvelopeCodec.decode(data) }
    }

    @Test("Empty or overlong sender id is rejected")
    func senderIdBounds() throws {
        for sender in ["", String(repeating: "x", count: EnvelopeCodec.maxSenderIdLength + 1)] {
            let data = try JSONEncoder().encode(Envelope(senderId: sender, sequence: 1, payload: .heartbeat(EmptyPayload())))
            #expect(throws: EnvelopeCodecError.invalidField("senderId")) { try EnvelopeCodec.decode(data) }
        }
    }
}

// MARK: - Nickname

@Suite("Nickname sanitizing")
struct NicknameTests {
    @Test func trimsAndCollapsesWhitespace() {
        #expect(Nickname.sanitize("  Captain \n\t Sam  ") == "Captain Sam")
    }

    @Test func removesControlAndBidiCharacters() {
        #expect(Nickname.sanitize("Sam\u{202E}\u{0000}\u{0007}my") == "Sammy")
    }

    @Test func rejectsEmpty() {
        #expect(Nickname.sanitize("   ") == nil)
        #expect(Nickname.sanitize("\u{200B}\u{202E}") == nil)
    }

    @Test func truncatesToLimits() throws {
        let long = try #require(Nickname.sanitize(String(repeating: "a", count: 100)))
        #expect(long.count == Nickname.maxCharacters)

        // Composed emoji are several bytes each; the MCPeerID byte limit must still hold.
        let emoji = try #require(Nickname.sanitize(String(repeating: "👨‍👩‍👧‍👦", count: 10)))
        #expect(emoji.utf8.count <= Nickname.maxUTF8Bytes)
        #expect(emoji.allSatisfy { $0 == "👨‍👩‍👧‍👦" })
    }
}

// MARK: - Tic-Tac-Toe rules

@Suite("Tic-Tac-Toe rules")
struct TicTacToeRulesTests {
    let players = ["x-player", "o-player"]

    private func play(_ cells: [Int]) throws -> TicTacToeState {
        var state = TicTacToeRules.newGame(players: players)
        for cell in cells {
            state = try TicTacToeRules.apply(cell: cell, by: state.playerId(for: state.turn), to: state)
        }
        return state
    }

    @Test("X moves first")
    func xStarts() {
        let state = TicTacToeRules.newGame(players: players)
        #expect(state.turn == .x)
        #expect(state.playerId(for: .x) == "x-player")
    }

    @Test("Row, column, and both diagonals win", arguments: [
        ([0, 3, 1, 4, 2], [0, 1, 2]),
        ([0, 1, 3, 2, 6], [0, 3, 6]),
        ([0, 1, 4, 2, 8], [0, 4, 8]),
        ([2, 0, 4, 1, 6], [2, 4, 6]),
    ])
    func wins(moves: [Int], line: [Int]) throws {
        let state = try play(moves)
        #expect(state.outcome == .win(.x, line: line))
    }

    @Test("O can win too")
    func oWins() throws {
        let state = try play([0, 3, 1, 4, 8, 5])
        #expect(state.outcome == .win(.o, line: [3, 4, 5]))
    }

    @Test("Full board without a line is a draw")
    func draw() throws {
        let state = try play([0, 1, 2, 4, 3, 5, 7, 6, 8])
        #expect(state.outcome == .draw)
    }

    @Test("Occupied cell is rejected and state unchanged")
    func occupied() throws {
        let state = try play([4])
        #expect(throws: MoveError.occupied) {
            try TicTacToeRules.apply(cell: 4, by: "o-player", to: state)
        }
    }

    @Test("Out-of-turn and non-player moves are rejected")
    func turnOrder() throws {
        let state = TicTacToeRules.newGame(players: players)
        #expect(throws: MoveError.notYourTurn) { try TicTacToeRules.apply(cell: 0, by: "o-player", to: state) }
        #expect(throws: MoveError.notAPlayer) { try TicTacToeRules.apply(cell: 0, by: "stranger", to: state) }
        #expect(throws: MoveError.outOfBounds) { try TicTacToeRules.apply(cell: -1, by: "x-player", to: state) }
    }

    @Test("Board locks after a result")
    func locksAfterResult() throws {
        let state = try play([0, 3, 1, 4, 2])
        #expect(throws: MoveError.gameOver) { try TicTacToeRules.apply(cell: 8, by: "o-player", to: state) }
    }

    @Test("Rematch alternates the first player")
    func rematchAlternates() throws {
        let finished = try play([0, 3, 1, 4, 2])
        let next = TicTacToeRules.rematch(from: finished)
        #expect(next.round == 2)
        #expect(next.turn == .x)
        #expect(next.playerId(for: .x) == "o-player")
        #expect(next.board.allSatisfy { $0 == nil })
        #expect(TicTacToeRules.rematch(from: next).playerId(for: .x) == "x-player")
    }
}

// MARK: - Session manager (fake transport)

@MainActor
final class FakeTransport: PeerTransport {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private(set) var sent: [(Data, [PeerKey])] = []
    private(set) var invited: [PeerKey] = []
    private(set) var responses: [(UUID, Bool)] = []
    private(set) var startedName: String?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    func start(displayName: String) { startedName = displayName }
    func stop() {}
    func invite(_ peer: PeerKey) -> Bool { invited.append(peer); return true }
    func respond(toInvitation invitationId: UUID, accept: Bool) { responses.append((invitationId, accept)) }
    func send(_ data: Data, to peers: [PeerKey]) throws { sent.append((data, peers)) }
    func disconnectAll() {}
    func fingerprint(for peer: PeerKey) -> String? { peer.raw.uuidString }

    /// Packets sent on the link to `key`.
    func packets(to key: PeerKey) -> [MeshPacket] {
        sent.filter { $0.1.contains(key) }.compactMap { try? MeshPacket.decode($0.0) }
    }
}

/// Settable clock for tests.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

/// Another phone, played by the test: its own mesh identity, talking to the session over one link.
@MainActor
final class RemotePhone {
    let identity = MeshIdentity()
    let key = PeerKey()
    let name: String
    let clock: TestClock
    private var sequence = 0

    init(_ name: String, clock: TestClock) {
        self.name = name
        self.clock = clock
    }

    var id: String { identity.id }

    func envelope(_ payload: Envelope.Payload, sender: String? = nil) -> Envelope {
        sequence += 1
        return Envelope(senderId: sender ?? id, sequence: sequence, payload: payload)
    }

    func hello() -> Data {
        try! MeshPacket.broadcast(envelope(.hello(HelloPayload(nickname: name, protocolVersion: 2))), from: identity, ttl: 0, now: clock.now).encoded()
    }

    func announce(ttl: Int = MeshPacket.maxTTL, nickname: String? = nil) -> Data {
        try! MeshPacket.broadcast(envelope(.announce(AnnouncePayload(nickname: nickname ?? name))), from: identity, ttl: ttl, now: clock.now).encoded()
    }

    /// A packet sealed for `session` (or for another identity).
    func sealed(_ payload: Envelope.Payload, to session: SessionManager, sentAt: Date? = nil) -> Data {
        sealedPacket(payload, toId: session.localId, agreementKey: session.meshIdentity.agreementPublicKey, sentAt: sentAt)
    }

    func sealedPacket(_ payload: Envelope.Payload, toId: String, agreementKey: Data, sentAt: Date? = nil, ttl: Int = MeshPacket.maxTTL) -> Data {
        try! MeshPacket.sealed(envelope(payload), to: [(toId, agreementKey)], from: identity, ttl: ttl, now: sentAt ?? clock.now).encoded()
    }

    /// Opens what the session sent this phone on its link.
    func received(from transport: FakeTransport) -> [Envelope] {
        transport.packets(to: key).compactMap { try? $0.open(as: identity) }
    }
}

@MainActor
@Suite("Session manager")
struct SessionManagerTests {
    let transport = FakeTransport()
    let clock = TestClock()
    let session: SessionManager
    let safety: SafetyStore
    let remote: RemotePhone

    init() {
        let defaults = UserDefaults(suiteName: "tests-\(UUID().uuidString)")!
        let profile = ProfileStore(defaults: defaults)
        profile.setNickname("Local")
        safety = SafetyStore(defaults: defaults)
        let clock = clock
        session = SessionManager(transport: transport, profile: profile, safety: safety, now: { clock.now })
        remote = RemotePhone("Remote", clock: clock)
        session.start()
        session.handle(.started)
    }

    private func link(_ phone: RemotePhone) {
        session.handle(.peerFound(phone.key, displayName: phone.name))
        session.handle(.peerStateChanged(phone.key, .connected))
        session.handle(.received(phone.hello(), from: phone.key))
    }

    /// Links the remote phone and makes it a contact: it asks, this user accepts.
    private func befriend(_ phone: RemotePhone) throws {
        link(phone)
        session.handle(.received(phone.sealed(.contactRequest(ContactPayload(nickname: phone.name)), to: session), from: phone.key))
        let request = try #require(session.invitations.first { $0.from == phone.id })
        session.respond(to: request, accept: true)
    }

    private func texts() -> [String] {
        session.chat.messages.filter { $0.kind == .text }.map(\.text)
    }

    // MARK: Links and contacts

    @Test("A new link sends a hello and an announcement; linked phones aren't contacts")
    func linking() throws {
        #expect(transport.startedName == "Local")
        link(remote)
        let packets = transport.packets(to: remote.key)
        let hello = try #require(packets.first)
        #expect(hello.ttl == 0 && hello.isBroadcast)
        #expect(try hello.open(as: remote.identity).kind == .hello)
        #expect(packets.contains { (try? $0.open(as: remote.identity).kind) == .announce })
        #expect(session.directory[remote.id]?.hops == 0)
        #expect(session.connectedIdentities.isEmpty)
        #expect(session.discoveredPeople.map(\.id) == [remote.id])
    }

    @Test("A contact request waits in Requests; accepting makes a connected contact")
    func acceptRequest() throws {
        link(remote)
        session.handle(.received(remote.sealed(.contactRequest(ContactPayload(nickname: "Remote")), to: session), from: remote.key))
        let request = try #require(session.invitations.first)
        #expect(request.labeledName == "Remote #\(Nickname.tag(for: remote.id))")
        #expect(session.discoveredPeople.isEmpty) // listed under Requests instead
        session.respond(to: request, accept: true)
        #expect(session.connectedIdentities.map(\.id) == [remote.id])
        #expect(remote.received(from: transport).contains { $0.kind == .contactAccept })
    }

    @Test("Asking someone to connect: only their acceptance of our request makes them a contact")
    func sendRequest() throws {
        link(remote)
        // An acceptance nobody asked for is ignored.
        session.handle(.received(remote.sealed(.contactAccept(ContactPayload(nickname: "Remote")), to: session), from: remote.key))
        #expect(!session.isContact(remote.id))

        #expect(session.requestContact(remote.id))
        #expect(session.isRequested(remote.id))
        #expect(remote.received(from: transport).contains { $0.kind == .contactRequest })
        session.handle(.received(remote.sealed(.contactAccept(ContactPayload(nickname: "Remote")), to: session), from: remote.key))
        #expect(session.connectedIdentities.map(\.id) == [remote.id])
    }

    @Test("Chat from a contact is delivered once")
    func chatDelivery() throws {
        try befriend(remote)
        let data = remote.sealed(.chat(ChatPayload(text: "Hi there")), to: session)
        session.handle(.received(data, from: remote.key))
        session.handle(.received(data, from: remote.key)) // duplicate packet
        #expect(texts() == ["Hi there"])
        #expect(session.chat.messages.last { $0.kind == .text }?.senderId == remote.id)
    }

    @Test("Chat from someone who isn't a contact is never shown")
    func strangersAreIgnored() {
        link(remote)
        session.handle(.received(remote.sealed(.chat(ChatPayload(text: "hey kid")), to: session), from: remote.key))
        #expect(texts().isEmpty)
    }

    @Test("Sending chat seals it for contacts only, and nobody else can read it")
    func sendChat() throws {
        #expect(session.sendChat("hello") == .noRecipients)
        try befriend(remote)
        let eavesdropper = RemotePhone("Eve", clock: clock)
        link(eavesdropper)
        #expect(session.sendChat("  hello  ") == .sent)
        #expect(remote.received(from: transport).contains { $0.payload == .chat(ChatPayload(text: "hello")) })
        // The relay on the other link gets the packet but can't open it.
        let relayed = transport.packets(to: eavesdropper.key).filter { !$0.isBroadcast }
        #expect(!relayed.isEmpty)
        #expect(relayed.allSatisfy { (try? $0.open(as: eavesdropper.identity)) == nil })
    }

    // MARK: Forgery, tampering, replay

    @Test("A packet claiming someone else's id is rejected")
    func impersonation() throws {
        try befriend(remote)
        let mallory = RemotePhone("Mallory", clock: clock)
        link(mallory)
        // Mallory signs with her own key but puts Remote's id on the packet...
        var packet = try MeshPacket.decode(mallory.sealed(.chat(ChatPayload(text: "I'm Remote")), to: session))
        packet.origin = remote.id
        session.handle(.received(try packet.encoded(), from: mallory.key))
        // ...or seals a packet whose envelope names Remote as the sender.
        session.handle(.received(mallory.sealedPacket(.chat(ChatPayload(text: "Still Remote")), toId: session.localId,
                                                      agreementKey: session.meshIdentity.agreementPublicKey), from: mallory.key))
        let forged = mallory.envelope(.chat(ChatPayload(text: "Remote again")), sender: remote.id)
        let data = try MeshPacket.sealed(forged, to: [(session.localId, session.meshIdentity.agreementPublicKey)],
                                         from: mallory.identity, ttl: 6, now: clock.now).encoded()
        session.handle(.received(data, from: mallory.key))
        #expect(texts().isEmpty)
        #expect(session.rejectedEnvelopeCount >= 2)
    }

    @Test("A packet altered in transit is rejected")
    func tampering() throws {
        try befriend(remote)
        var packet = try MeshPacket.decode(remote.sealed(.chat(ChatPayload(text: "original")), to: session))
        packet.body[packet.body.startIndex] ^= 0xFF
        session.handle(.received(try packet.encoded(), from: remote.key))
        var resigned = try MeshPacket.decode(remote.sealed(.chat(ChatPayload(text: "original 2")), to: session))
        resigned.sentAt += 1 // signed field
        session.handle(.received(try resigned.encoded(), from: remote.key))
        #expect(texts().isEmpty)
        #expect(session.rejectedEnvelopeCount == 2)
    }

    @Test("Old packets can't be replayed later")
    func staleReplay() throws {
        try befriend(remote)
        let old = remote.sealed(.chat(ChatPayload(text: "from earlier")), to: session,
                                sentAt: clock.now.addingTimeInterval(-MeshPacket.freshness - 1))
        session.handle(.received(old, from: remote.key))
        #expect(texts().isEmpty)
        #expect(session.rejectedEnvelopeCount == 1)
    }

    @Test("Malformed data is counted, not crashed on")
    func malformed() {
        link(remote)
        session.handle(.received(Data("💣".utf8), from: remote.key))
        session.handle(.received(Data(repeating: 0, count: 100), from: remote.key))
        #expect(session.rejectedEnvelopeCount == 2)
    }

    // MARK: Relaying

    @Test("Packets for others are relayed onward, never back, with one less hop, unread")
    func relaying() throws {
        let alice = RemotePhone("Alice", clock: clock), bob = RemotePhone("Bob", clock: clock)
        link(alice)
        link(bob)
        let carol = MeshIdentity()
        let data = alice.sealedPacket(.chat(ChatPayload(text: "for Carol")), toId: carol.id, agreementKey: carol.agreementPublicKey, ttl: 4)
        session.handle(.received(data, from: alice.key))
        let original = try MeshPacket.decode(data)
        let toBob = transport.packets(to: bob.key).filter { $0.id == original.id }
        #expect(toBob.count == 1)
        #expect(toBob.first?.ttl == 3)
        #expect(transport.packets(to: alice.key).allSatisfy { $0.id != original.id })
        // Carol can still open it; the relay couldn't.
        #expect(try toBob.first?.open(as: carol).payload == .chat(ChatPayload(text: "for Carol")))
        #expect(texts().isEmpty)
        // A second copy (arriving another way) isn't relayed again.
        session.handle(.received(data, from: bob.key))
        #expect(transport.packets(to: alice.key).allSatisfy { $0.id != original.id })
    }

    @Test("A packet on its last hop isn't relayed")
    func hopLimit() throws {
        let alice = RemotePhone("Alice", clock: clock), bob = RemotePhone("Bob", clock: clock)
        link(alice)
        link(bob)
        let carol = MeshIdentity()
        let data = alice.sealedPacket(.chat(ChatPayload(text: "last hop")), toId: carol.id, agreementKey: carol.agreementPublicKey, ttl: 1)
        session.handle(.received(data, from: alice.key))
        let id = try MeshPacket.decode(data).id
        #expect(transport.packets(to: bob.key).allSatisfy { $0.id != id })
    }

    @Test("One phone flooding the mesh is cut off at its first neighbor")
    func floodControl() {
        let alice = RemotePhone("Alice", clock: clock), bob = RemotePhone("Bob", clock: clock)
        link(alice)
        link(bob)
        let carol = MeshIdentity()
        let before = transport.packets(to: bob.key).count
        for index in 0..<(SessionManager.originRateLimit + 40) {
            session.handle(.received(alice.sealedPacket(.chat(ChatPayload(text: "spam \(index)")), toId: carol.id,
                                                        agreementKey: carol.agreementPublicKey), from: alice.key))
        }
        let relayed = transport.packets(to: bob.key).count - before
        // The hello took one slot of Alice's budget.
        #expect(relayed == SessionManager.originRateLimit - 1)
    }

    @Test("People several phones away are found through relayed announcements")
    func discoveryThroughRelays() {
        let alice = RemotePhone("Alice", clock: clock)
        link(alice)
        let faraway = RemotePhone("Faraway", clock: clock)
        session.handle(.received(faraway.announce(ttl: MeshPacket.maxTTL - 2), from: alice.key))
        let person = session.discoveredPeople.first { $0.id == faraway.id }
        #expect(person?.hops == 2)
        #expect(session.requestContact(faraway.id))
    }

    // MARK: Reachability

    @Test("A contact not heard from for a while counts as away, and is back when heard again")
    func reachability() throws {
        try befriend(remote)
        clock.now += SessionManager.reachableWindow + 1
        session.tick()
        #expect(session.connectedIdentities.isEmpty)
        #expect(session.awayIdentityIds == [remote.id])
        #expect(session.chat.messages.last?.text.contains("disconnected") == true)
        session.handle(.received(remote.announce(), from: remote.key))
        #expect(session.connectedIdentities.map(\.id) == [remote.id])
        #expect(session.chat.messages.last?.text.contains("is back") == true)
    }

    @Test("Losing the only link to a contact makes them away right away")
    func linkDrop() throws {
        try befriend(remote)
        session.handle(.peerStateChanged(remote.key, .notConnected))
        #expect(session.connectedIdentities.isEmpty)
        #expect(session.awayIdentityIds == [remote.id])
    }

    @Test("Messages sent while a contact is away are held and delivered when they're back")
    func outboxForAway() throws {
        var queuedFor: [String] = []
        session.onChatQueuedForAway = { ids, _, _, _ in queuedFor = ids }
        try befriend(remote)
        session.handle(.received(remote.sealed(.presence(PresencePayload(away: true)), to: session), from: remote.key))
        #expect(session.awayIdentityIds == [remote.id])
        #expect(session.steppedAwayIds == [remote.id])

        #expect(session.sendChat("see you at dinner") == .sent)
        #expect(queuedFor == [remote.id])
        #expect(session.chat.messages.last?.isHeld == true)

        clock.now += 1
        session.handle(.received(remote.announce(), from: remote.key))
        #expect(remote.received(from: transport).contains { $0.payload == .chat(ChatPayload(text: "see you at dinner")) })
        #expect(session.chat.messages.last { $0.kind == .text }?.isHeld == false)
    }

    @Test("A message that came by Bluetooth is filed once, even when the mesh copy arrives later")
    func bluetoothThenMesh() throws {
        var notified = 0
        session.onChatReceived = { _, _, _ in notified += 1 }
        try befriend(remote)
        let id = UUID()
        #expect(session.receiveBluetoothChat(id: id, text: "At the pool", conversationId: nil, from: remote.id) == ChatStore.everyoneId)
        let dm = ConversationRef.directId(session.localId, remote.id)
        #expect(session.receiveBluetoothChat(id: UUID(), text: "Just you", conversationId: dm, from: remote.id) == dm)
        // The same message later through the mesh: not shown or announced again.
        var envelope = remote.envelope(.chat(ChatPayload(text: "At the pool")))
        envelope.id = id
        let data = try MeshPacket.sealed(envelope, to: [(session.localId, session.meshIdentity.agreementPublicKey)],
                                         from: remote.identity, ttl: 6, now: clock.now).encoded()
        session.handle(.received(data, from: remote.key))
        #expect(texts() == ["At the pool", "Just you"])
        #expect(notified == 0)
    }

    @Test("Bluetooth messages from strangers, or that fail the filter, are dropped")
    func bluetoothChecks() throws {
        let stranger = RemotePhone("Stranger", clock: clock)
        #expect(session.receiveBluetoothChat(id: UUID(), text: "hi", conversationId: nil, from: stranger.id) == nil)
        try befriend(remote)
        #expect(session.receiveBluetoothChat(id: UUID(), text: "send nudes", conversationId: nil, from: remote.id) == nil)
        #expect(session.receiveBluetoothChat(id: UUID(), text: "hi", conversationId: UUID(), from: remote.id) == nil) // unknown group
        #expect(texts().isEmpty)
    }

    @Test("A held message goes out later with its original id")
    func outboxKeepsId() throws {
        try befriend(remote)
        session.handle(.received(remote.sealed(.presence(PresencePayload(away: true)), to: session), from: remote.key))
        #expect(session.sendChat("later") == .sent)
        let held = try #require(session.chat.messages.last { $0.kind == .text })
        clock.now += 1
        session.handle(.received(remote.announce(), from: remote.key))
        let resent = remote.received(from: transport).first { $0.payload == .chat(ChatPayload(text: "later")) }
        #expect(resent?.id == held.id)
    }

    @Test("Going to the background drops contacts quietly and reports it as a local suspend")
    func suspendAndResume() throws {
        var drops: [SessionManager.DropReason] = []
        session.onPeerDisconnected = { _, reason in drops.append(reason) }
        try befriend(remote)
        session.suspend()
        #expect(drops == [.localSuspend])
        #expect(session.status == .idle)
        #expect(session.connectedIdentities.isEmpty)
        #expect(session.chat.messages.last?.text.contains("disconnected") != true)
        #expect(session.awayIdentityIds == [remote.id])
        session.resume()
        #expect(transport.startedName == "Local")
    }

    @Test("Bluetooth nudge keys are exchanged with contacts through the mesh")
    func nudgeKeys() throws {
        try befriend(remote)
        let keys = remote.received(from: transport).compactMap { envelope -> KeysPayload? in
            if case .keys(let keys) = envelope.payload { return keys }
            return nil
        }
        let given = try #require(keys.last.flatMap { Data(base64Encoded: $0.nudgeKey) })
        #expect(session.nudgeKey(openingFrom: remote.id)?.withUnsafeBytes { Data($0) } == given)
        let theirs = Data(repeating: 7, count: 32)
        session.handle(.received(remote.sealed(.keys(KeysPayload(nudgeKey: theirs.base64EncodedString())), to: session), from: remote.key))
        #expect(session.nudgeKey(sealingTo: remote.id)?.withUnsafeBytes { Data($0) } == theirs)
    }

    // MARK: Safety

    @Test("Outgoing messages are filtered and never sent")
    func outgoingFiltered() throws {
        try befriend(remote)
        let before = transport.sent.count
        #expect(session.sendChat("what the fuck") == .filtered(.inappropriate))
        #expect(session.sendChat("text me 555 123 4567") == .filtered(.personalInfo))
        #expect(transport.sent.count == before)
    }

    @Test("Incoming bad messages are hidden; three strikes blocks the sender")
    func incomingFilteredAndAutoBlock() throws {
        try befriend(remote)
        session.handle(.received(remote.sealed(.chat(ChatPayload(text: "you are shit")), to: session), from: remote.key))
        #expect(texts().isEmpty)
        #expect(session.chat.messages.last?.text.contains("hidden by the safety filter") == true)

        session.handle(.received(remote.sealed(.chat(ChatPayload(text: "f u c k")), to: session), from: remote.key))
        session.handle(.received(remote.sealed(.chat(ChatPayload(text: "send nudes")), to: session), from: remote.key))
        #expect(safety.isBlocked(identityId: remote.id))
        #expect(session.connectedIdentities.isEmpty)

        // Further traffic from a blocked person is ignored, even clean messages.
        session.handle(.received(remote.sealed(.chat(ChatPayload(text: "hi again")), to: session), from: remote.key))
        #expect(texts().isEmpty)
    }

    @Test("Blocking removes their messages, stops relaying for them, and ignores their requests")
    func manualBlock() throws {
        try befriend(remote)
        session.handle(.received(remote.sealed(.chat(ChatPayload(text: "hello friend")), to: session), from: remote.key))
        session.block(identityId: remote.id)
        #expect(texts().isEmpty)
        #expect(session.sendChat("anyone?") == .noRecipients)
        #expect(session.awayIdentityIds.isEmpty)

        session.handle(.received(remote.sealed(.contactRequest(ContactPayload(nickname: "Remote")), to: session), from: remote.key))
        #expect(session.invitations.isEmpty)
        #expect(!session.discoveredPeople.contains { $0.id == remote.id })
    }

    @Test("Blocks persist and can be undone")
    func persistAndUnblock() throws {
        link(remote)
        session.block(identityId: remote.id)
        let person = try #require(safety.blocked.first)
        session.handle(.received(remote.announce(), from: remote.key))
        #expect(session.discoveredPeople.isEmpty)
        session.unblock(person)
        #expect(safety.blocked.isEmpty)
        clock.now += 1
        session.handle(.received(remote.announce(), from: remote.key))
        #expect(session.discoveredPeople.map(\.id) == [remote.id])
    }

    @Test("Inappropriate nicknames are shown as Player")
    func badNicknames() throws {
        let rude = RemotePhone("b1tch", clock: clock)
        link(rude)
        #expect(session.discoveredPeople.first?.nickname == "Player")
    }

    @Test("Contact requests: decline mutes that person, and a crowd can't pile up requests")
    func requestLimits() throws {
        link(remote)
        session.handle(.received(remote.sealed(.contactRequest(ContactPayload(nickname: "Remote")), to: session), from: remote.key))
        session.respond(to: try #require(session.invitations.first), accept: false)
        session.handle(.received(remote.sealed(.contactRequest(ContactPayload(nickname: "Remote")), to: session), from: remote.key))
        #expect(session.invitations.isEmpty)

        for index in 0...SessionManager.maxWaitingRequests {
            let phone = RemotePhone("Person \(index)", clock: clock)
            session.handle(.received(phone.announce(), from: remote.key))
            session.handle(.received(phone.sealed(.contactRequest(ContactPayload(nickname: phone.name)), to: session), from: remote.key))
        }
        #expect(session.invitations.count == SessionManager.maxWaitingRequests)
    }

    @Test("Requests expire if nobody answers")
    func requestExpiry() {
        link(remote)
        session.handle(.received(remote.sealed(.contactRequest(ContactPayload(nickname: "Remote")), to: session), from: remote.key))
        #expect(session.invitations.count == 1)
        clock.now += SessionManager.requestLifetime + 1
        session.tick()
        #expect(session.invitations.isEmpty)
    }

    @Test("Disconnect from Everyone ends every contact and tells them")
    func disconnectEveryone() throws {
        try befriend(remote)
        session.disconnectAll()
        #expect(session.knownIdentities.isEmpty)
        #expect(remote.received(from: transport).contains { $0.kind == .contactEnd })
        // Their messages are no longer accepted.
        session.handle(.received(remote.sealed(.chat(ChatPayload(text: "still there?")), to: session), from: remote.key))
        #expect(texts().isEmpty)
    }

    @Test("Link requests from other phones are accepted automatically; blocked phones are refused")
    func linkInvitations() {
        let invitationId = UUID()
        session.handle(.invitationReceived(invitationId: invitationId, from: remote.key, displayName: "Remote"))
        #expect(transport.responses.last?.0 == invitationId)
        #expect(transport.responses.last?.1 == true)
        #expect(session.invitations.isEmpty) // no prompt: a link isn't a contact

        safety.block(fingerprint: remote.key.raw.uuidString, name: "Remote", identityId: nil)
        let second = PeerKey()
        _ = second
        session.handle(.invitationReceived(invitationId: UUID(), from: remote.key, displayName: "Remote"))
        #expect(transport.responses.last?.1 == false)
    }
}

@Suite("Mesh packets")
struct MeshPacketTests {
    @Test("Ids are fingerprints of the signing key")
    func ids() {
        let identity = MeshIdentity()
        #expect(MeshIdentity.isValidId(identity.id))
        #expect(identity.id == MeshIdentity.id(for: identity.signingPublicKey))
        #expect(MeshIdentity().id != identity.id)
    }

    @Test("Sealed for several people: each can open it, nobody else can, and the wrapped keys name no one")
    func multiRecipient() throws {
        let sender = MeshIdentity(), a = MeshIdentity(), b = MeshIdentity(), outsider = MeshIdentity()
        let envelope = Envelope(senderId: sender.id, sequence: 1, payload: .chat(ChatPayload(text: "group hello")))
        let packet = try MeshPacket.sealed(envelope, to: [(a.id, a.agreementPublicKey), (b.id, b.agreementPublicKey)], from: sender, ttl: 6)
        try packet.verify()
        #expect(try packet.open(as: a) == envelope)
        #expect(try packet.open(as: b) == envelope)
        #expect(throws: MeshPacketError.notForMe) { try packet.open(as: outsider) }
        let wire = try packet.encoded()
        #expect(!String(decoding: wire, as: UTF8.self).contains(a.id))
        #expect(!String(decoding: wire, as: UTF8.self).contains("group hello"))
    }

    @Test("Saved keys restore the same identity")
    func restore() throws {
        let identity = MeshIdentity()
        let restored = try #require(MeshIdentity(signing: identity.signingKey.rawRepresentation, agreement: identity.agreementKey.rawRepresentation))
        #expect(restored.id == identity.id)
    }

    @Test("Oversized or malformed packets are rejected")
    func bounds() {
        #expect(throws: MeshPacketError.self) { try MeshPacket.decode(Data(repeating: 0x7B, count: MeshPacket.maxPacketBytes + 1)) }
        #expect(throws: MeshPacketError.self) { try MeshPacket.decode(Data("{}".utf8)) }
    }
}

@MainActor
@Suite("Connection settings")
struct ConnectionSettingsTests {
    @Test("Turning Nearby radio off keeps that transport from starting; the Wi-Fi one still starts")
    func radioOff() {
        let radio = FakeTransport(), lan = FakeTransport()
        let composite = CompositeTransport(children: [.init(radio, tier: .multipeer), .init(lan, tier: nil)])
        composite.setEnabled(false, for: .multipeer)
        composite.start(displayName: "Sam")
        #expect(radio.startedName == nil)
        #expect(lan.startedName == "Sam")
        #expect(!composite.isEnabled(.multipeer))
        composite.setEnabled(true, for: .multipeer)
        composite.start(displayName: "Sam")
        #expect(radio.startedName == "Sam")
    }

    @Test("The choice is remembered, and on by default")
    func persisted() {
        let defaults = UserDefaults(suiteName: "settings-\(UUID().uuidString)")!
        #expect(ConnectionSettings(defaults: defaults).nearbyRadioEnabled)
        var applied: [Bool] = []
        let settings = ConnectionSettings(defaults: defaults)
        settings.apply = { applied.append($0) }
        settings.nearbyRadioEnabled = false
        #expect(applied == [false])
        #expect(!ConnectionSettings(defaults: defaults).nearbyRadioEnabled)
    }
}
