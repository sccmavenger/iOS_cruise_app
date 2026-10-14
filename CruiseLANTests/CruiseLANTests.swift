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
            .hello(HelloPayload(nickname: "Sam", protocolVersion: 1)),
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
        #expect(object["version"] as? Int == 1)
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
        let json = #"{"version":1,"id":"\#(UUID().uuidString)","kind":"selfDestruct","senderId":"p","sequence":1,"payload":{}}"#
        #expect(throws: EnvelopeCodecError.malformed) { try EnvelopeCodec.decode(Data(json.utf8)) }
    }

    @Test("Payload that doesn't match its kind is rejected")
    func kindPayloadMismatch() {
        let json = #"{"version":1,"id":"\#(UUID().uuidString)","kind":"chat","senderId":"p","sequence":1,"payload":{"nickname":"x","protocolVersion":1}}"#
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
    func invite(_ peer: PeerKey) { invited.append(peer) }
    func respond(toInvitation invitationId: UUID, accept: Bool) { responses.append((invitationId, accept)) }
    func send(_ data: Data, to peers: [PeerKey]) throws { sent.append((data, peers)) }
    func disconnectAll() {}

    func sentEnvelopes() -> [Envelope] {
        sent.compactMap { try? EnvelopeCodec.decode($0.0) }
    }
}

@MainActor
@Suite("Session manager")
struct SessionManagerTests {
    let transport = FakeTransport()
    let session: SessionManager
    let peerKey = PeerKey()
    let remoteId = "remote-peer-id"

    init() {
        let defaults = UserDefaults(suiteName: "tests-\(UUID().uuidString)")!
        let profile = ProfileStore(defaults: defaults)
        profile.setNickname("Local")
        session = SessionManager(transport: transport, profile: profile)
    }

    private func encode(_ payload: Envelope.Payload, sender: String? = nil, sequence: Int, id: UUID = UUID()) -> Data {
        try! EnvelopeCodec.encode(Envelope(id: id, senderId: sender ?? remoteId, sequence: sequence, payload: payload))
    }

    private func connectAndHello(key: PeerKey? = nil, id: String? = nil, name: String = "Remote") {
        let key = key ?? peerKey
        session.handle(.peerFound(key, displayName: name))
        session.handle(.peerStateChanged(key, .connected))
        session.handle(.received(encode(.hello(HelloPayload(nickname: name, protocolVersion: 1)), sender: id ?? remoteId, sequence: 1), from: key))
    }

    @Test("Connecting sends hello and binds identity")
    func handshake() throws {
        session.start()
        #expect(transport.startedName == "Local")
        connectAndHello()
        let hello = try #require(transport.sentEnvelopes().first)
        #expect(hello.kind == .hello)
        #expect(hello.senderId == session.localId)
        #expect(session.connectedIdentities.map(\.id) == [remoteId])
    }

    @Test("Chat is delivered once with the bound sender")
    func chatDelivery() {
        connectAndHello()
        let id = UUID()
        let data = encode(.chat(ChatPayload(text: "Hi there")), sequence: 2, id: id)
        session.handle(.received(data, from: peerKey))
        session.handle(.received(data, from: peerKey)) // duplicate packet
        let texts = session.chat.messages.filter { $0.kind == .text }
        #expect(texts.count == 1)
        #expect(texts.first?.text == "Hi there")
        #expect(texts.first?.senderId == remoteId)
        #expect(session.rejectedEnvelopeCount == 1)
    }

    @Test("Twenty messages in order are all delivered")
    func manyMessages() {
        connectAndHello()
        for index in 0..<20 {
            session.handle(.received(encode(.chat(ChatPayload(text: "m\(index)")), sequence: index + 2), from: peerKey))
        }
        let texts = session.chat.messages.filter { $0.kind == .text }.map(\.text)
        #expect(texts == (0..<20).map { "m\($0)" })
    }

    @Test("Messages before hello are dropped")
    func requiresHandshake() {
        session.handle(.peerFound(peerKey, displayName: "Remote"))
        session.handle(.peerStateChanged(peerKey, .connected))
        session.handle(.received(encode(.chat(ChatPayload(text: "sneaky")), sequence: 1), from: peerKey))
        #expect(session.chat.messages.filter { $0.kind == .text }.isEmpty)
        #expect(session.rejectedEnvelopeCount == 1)
    }

    @Test("Spoofed sender id is rejected")
    func spoofing() {
        connectAndHello()
        session.handle(.received(encode(.chat(ChatPayload(text: "I am someone else")), sender: "other-id", sequence: 5), from: peerKey))
        #expect(session.chat.messages.filter { $0.kind == .text }.isEmpty)
    }

    @Test("A second peer can't claim an identity already in use")
    func identityHijack() {
        connectAndHello()
        let attacker = PeerKey()
        connectAndHello(key: attacker, id: remoteId, name: "Evil")
        #expect(session.connectedIdentities.count == 1)
        #expect(session.peers[attacker]?.identity == nil)
    }

    @Test("Replayed or stale sequence numbers are rejected")
    func staleSequence() {
        connectAndHello()
        session.handle(.received(encode(.chat(ChatPayload(text: "five")), sequence: 5), from: peerKey))
        session.handle(.received(encode(.chat(ChatPayload(text: "three")), sequence: 3), from: peerKey))
        #expect(session.chat.messages.filter { $0.kind == .text }.map(\.text) == ["five"])
    }

    @Test("Malformed data is counted, not crashed on")
    func malformed() {
        connectAndHello()
        session.handle(.received(Data("💣".utf8), from: peerKey))
        session.handle(.received(Data(repeating: 0, count: 100), from: peerKey))
        #expect(session.rejectedEnvelopeCount == 2)
    }

    @Test("Flooding peers are rate limited")
    func rateLimit() {
        connectAndHello()
        for index in 0..<(SessionManager.rateLimit + 20) {
            session.handle(.received(encode(.chat(ChatPayload(text: "spam \(index)")), sequence: index + 2), from: peerKey))
        }
        let delivered = session.chat.messages.filter { $0.kind == .text }.count
        // The hello consumed one slot of the window.
        #expect(delivered == SessionManager.rateLimit - 1)
    }

    @Test("Sending chat requires a connected peer")
    func sendChat() throws {
        #expect(session.sendChat("hello") == false)
        connectAndHello()
        #expect(session.sendChat("  hello  "))
        let chat = try #require(transport.sentEnvelopes().last)
        #expect(chat.payload == .chat(ChatPayload(text: "hello")))
        #expect(transport.sent.last?.1 == [peerKey])
        #expect(session.chat.messages.last?.isLocal == true)
    }

    @Test("Disconnect clears identity and posts a notice")
    func disconnect() {
        connectAndHello()
        session.handle(.peerStateChanged(peerKey, .notConnected))
        #expect(session.connectedIdentities.isEmpty)
        #expect(session.chat.messages.last?.text.contains("disconnected") == true)
    }

    @Test("Invitations are surfaced and answered")
    func invitations() throws {
        let invitationId = UUID()
        session.handle(.invitationReceived(invitationId: invitationId, from: peerKey, displayName: "Remote"))
        let invitation = try #require(session.invitations.first)
        session.respond(to: invitation, accept: false)
        #expect(session.invitations.isEmpty)
        #expect(transport.responses.first?.0 == invitationId)
        #expect(transport.responses.first?.1 == false)
    }
}
