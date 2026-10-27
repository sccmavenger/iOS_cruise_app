import CryptoKit
import Foundation
import Testing
@testable import iso_cruise_app

/// In-memory network of devices. Each device has a real `SessionManager` and
/// `GameCoordinator`; sends are delivered synchronously to the receiving session.
@MainActor
final class FakeNetwork {
    @MainActor
    final class Node {
        let name: String
        let transport: HubTransport
        let session: SessionManager
        let games: GameCoordinator
        /// How this node refers to each other node.
        var keys: [ObjectIdentifier: PeerKey] = [:]

        init(name: String, network: FakeNetwork) {
            self.name = name
            transport = HubTransport()
            let defaults = UserDefaults(suiteName: "net-\(UUID().uuidString)")!
            let profile = ProfileStore(defaults: defaults)
            profile.setNickname(name)
            session = SessionManager(transport: transport, profile: profile, safety: SafetyStore(defaults: defaults))
            games = GameCoordinator(session: session)
            transport.network = network
            transport.owner = self
            session.start()
            session.handle(.started)
        }

        var id: String { session.localId }
    }

    @MainActor
    final class HubTransport: PeerTransport {
        let events = AsyncStream<TransportEvent> { _ in }
        weak var network: FakeNetwork?
        weak var owner: Node?
        func start(displayName: String) {}
        func stop() {}
        func invite(_ peer: PeerKey) -> Bool { true }
        func respond(toInvitation invitationId: UUID, accept: Bool) {}
        func disconnectAll() {}
        func fingerprint(for peer: PeerKey) -> String? { peer.raw.uuidString }
        func send(_ data: Data, to peers: [PeerKey]) throws {
            guard let network, let owner else { return }
            for key in peers {
                network.deliver(data, from: owner, toKey: key)
            }
        }
    }

    private(set) var nodes: [Node] = []
    /// Lets tests drop or capture traffic.
    var interceptor: ((Data, Node, Node) -> Bool)?
    private(set) var log: [(from: String, to: String, envelope: Envelope)] = []

    func addNode(_ name: String) -> Node {
        let node = Node(name: name, network: self)
        nodes.append(node)
        return node
    }

    func connect(_ a: Node, _ b: Node, befriend: Bool = true) {
        let keyForB = PeerKey(), keyForA = PeerKey()
        a.keys[ObjectIdentifier(b)] = keyForB
        b.keys[ObjectIdentifier(a)] = keyForA
        a.session.handle(.peerFound(keyForB, displayName: b.name))
        b.session.handle(.peerFound(keyForA, displayName: a.name))
        a.session.handle(.peerStateChanged(keyForB, .connected))
        b.session.handle(.peerStateChanged(keyForA, .connected))
        if befriend { makeContacts(a, b) }
    }

    /// One asks to connect and the other accepts (as people would in People › Requests).
    func makeContacts(_ a: Node, _ b: Node) {
        guard !a.session.isContact(b.id) else { return }
        a.session.requestContact(b.id)
        if let request = b.session.invitations.first(where: { $0.from == a.id }) {
            b.session.respond(to: request, accept: true)
        }
    }

    /// The envelope inside a packet, as `reader` would see it (nil if it's not for them).
    func envelope(in data: Data, for reader: Node) -> Envelope? {
        guard let packet = try? MeshPacket.decode(data) else { return nil }
        return try? packet.open(as: reader.session.meshIdentity)
    }

    /// A packet sealed by `sender`'s phone for `recipient`, carrying any envelope (even a forged one).
    func sealed(_ envelope: Envelope, from sender: Node, to recipient: Node) throws -> Data {
        try MeshPacket.sealed(envelope, to: [(recipient.id, recipient.session.meshIdentity.agreementPublicKey)],
                              from: sender.session.meshIdentity, ttl: MeshPacket.maxTTL).encoded()
    }

    func disconnect(_ a: Node, _ b: Node) {
        guard let keyForB = a.keys[ObjectIdentifier(b)], let keyForA = b.keys[ObjectIdentifier(a)] else { return }
        a.session.handle(.peerStateChanged(keyForB, .notConnected))
        b.session.handle(.peerStateChanged(keyForA, .notConnected))
    }

    /// Like MultipeerConnectivity, deliveries are in order and one at a time: a message sent
    /// while another is being handled waits until that one finishes.
    private var pending: [(Data, Node, PeerKey)] = []
    private var isDelivering = false

    fileprivate func deliver(_ data: Data, from sender: Node, toKey key: PeerKey) {
        pending.append((data, sender, key))
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }
        while !pending.isEmpty {
            let (data, sender, key) = pending.removeFirst()
            guard let receiver = nodes.first(where: { sender.keys[ObjectIdentifier($0)] == key }),
                  let senderKey = receiver.keys[ObjectIdentifier(sender)]
            else { continue }
            if let envelope = envelope(in: data, for: receiver) {
                log.append((sender.name, receiver.name, envelope))
            }
            if let interceptor, !interceptor(data, sender, receiver) { continue }
            receiver.session.handle(.received(data, from: senderKey))
        }
    }

    /// Sends raw bytes from one node to another, bypassing the sender's session.
    func inject(_ data: Data, from sender: Node, to receiver: Node) {
        guard let key = sender.keys[ObjectIdentifier(receiver)] else { return }
        deliver(data, from: sender, toKey: key)
    }
}

@MainActor
@Suite("Lobby and match synchronization")
struct GameCoordinatorTests {
    let network = FakeNetwork()
    let host: FakeNetwork.Node
    let guest: FakeNetwork.Node

    init() {
        host = network.addNode("Hana")
        guest = network.addNode("Gus")
        network.connect(host, guest)
    }

    /// Hosts a Tic-Tac-Toe lobby, has the guest join and ready up, and starts the game.
    private func startTicTacToe() throws -> UUID {
        host.games.hostLobby(.ticTacToe)
        let offer = try #require(guest.games.offers(for: .ticTacToe).first)
        guest.games.join(offer)
        guest.games.setReady(true)
        #expect(host.games.canStart)
        host.games.startGame()
        return offer.id
    }

    private func tttState(_ node: FakeNetwork.Node) -> TicTacToeState? {
        if case .ticTacToe(let state) = node.games.snapshot { return state }
        return nil
    }

    /// Plays a cell as whoever's turn it is.
    private func play(_ cell: Int) throws {
        let state = try #require(tttState(host))
        let mover = state.playerId(for: state.turn) == host.id ? host : guest
        mover.games.play(.ticTacToe(cell: cell))
    }

    @Test("Offer, join, ready, start: both devices get the same initial state")
    func lobbyFlow() throws {
        host.games.hostLobby(.ticTacToe)
        let offer = try #require(guest.games.offers(for: .ticTacToe).first)
        #expect(offer.host.id == host.id)
        #expect(offer.payload.seatsTaken == 1)

        guest.games.join(offer)
        #expect(guest.games.lobby?.id == offer.id)
        #expect(host.games.lobby?.players.count == 2)
        #expect(host.games.canStart == false) // guest not ready

        guest.games.setReady(true)
        #expect(host.games.lobby?.player(guest.id)?.isReady == true)
        #expect(guest.games.lobby?.player(guest.id)?.isReady == true)

        host.games.startGame()
        #expect(host.games.lobby?.phase == .playing)
        #expect(guest.games.lobby?.phase == .playing)
        #expect(host.games.snapshot == guest.games.snapshot)
        #expect(guest.games.revision == 0)
    }

    @Test("A win by row is shown identically on both devices")
    func winSync() throws {
        _ = try startTicTacToe()
        for cell in [0, 3, 1, 4, 2] { try play(cell) }
        let hostState = try #require(tttState(host))
        #expect(hostState.outcome == .win(.x, line: [0, 1, 2]))
        #expect(tttState(guest) == hostState)
        #expect(guest.games.revision == 5)
    }

    @Test("Client moves out of turn or onto occupied cells are rejected by the host")
    func invalidClientMoves() throws {
        _ = try startTicTacToe()
        // Host plays X first; guest trying to move now is out of turn.
        guest.games.play(.ticTacToe(cell: 4))
        #expect(guest.games.notice == MoveError.notYourTurn.message)
        #expect(tttState(host)?.board.allSatisfy { $0 == nil } == true)

        host.games.play(.ticTacToe(cell: 4))
        guest.games.play(.ticTacToe(cell: 4))
        #expect(guest.games.notice == MoveError.occupied.message)
        #expect(tttState(guest)?.board[4] == .x)
        #expect(host.games.revision == 1)
    }

    @Test("Repeated move request with the same id causes exactly one transition")
    func duplicateMoveRequest() throws {
        let lobbyId = try startTicTacToe()
        host.games.play(.ticTacToe(cell: 0))
        let request = MoveRequestPayload(moveId: UUID(), baseRevision: 1, move: .ticTacToe(cell: 4))
        guest.session.send(.moveRequest(request), sessionId: lobbyId, to: [host.id])
        guest.session.send(.moveRequest(request), sessionId: lobbyId, to: [host.id])
        #expect(host.games.revision == 2)
        #expect(tttState(host)?.board.compactMap { $0 }.count == 2)
    }

    @Test("Move based on an old revision is rejected")
    func staleMoveRequest() throws {
        let lobbyId = try startTicTacToe()
        host.games.play(.ticTacToe(cell: 0))
        let stale = MoveRequestPayload(moveId: UUID(), baseRevision: 0, move: .ticTacToe(cell: 4))
        guest.session.send(.moveRequest(stale), sessionId: lobbyId, to: [host.id])
        #expect(host.games.revision == 1)
        #expect(guest.games.notice == MoveErrorMessage.staleBoard)
    }

    @Test("Older snapshot revisions are ignored by clients")
    func staleSnapshotIgnored() throws {
        let lobbyId = try startTicTacToe()
        host.games.play(.ticTacToe(cell: 0))
        let current = guest.games.snapshot
        let old = StateSnapshotPayload(revision: 0, state: .ticTacToe(TicTacToeRules.newGame(players: [host.id, guest.id])))
        host.session.send(.stateSnapshot(old), sessionId: lobbyId, to: [guest.id])
        #expect(guest.games.snapshot == current)
        #expect(guest.games.revision == 1)
    }

    @Test("Snapshots and game events from a non-host are ignored")
    func nonHostAuthorityIgnored() throws {
        let intruder = network.addNode("Ivan")
        network.connect(intruder, guest)
        let lobbyId = try startTicTacToe()

        var forged = TicTacToeRules.newGame(players: [host.id, guest.id])
        forged.board[0] = .o
        forged.board[1] = .o
        forged.board[2] = .o
        forged.outcome = .win(.o, line: [0, 1, 2])
        intruder.session.send(.stateSnapshot(StateSnapshotPayload(revision: 99, state: .ticTacToe(forged))), sessionId: lobbyId, to: [guest.id])
        intruder.session.send(.gameEvent(GameEventPayload(event: .hostEnded, message: "fake")), sessionId: lobbyId, to: [guest.id])

        #expect(guest.games.revision == 0)
        #expect(tttState(guest)?.outcome == nil)
        #expect(guest.games.lobby?.phase == .playing)
    }

    @Test("A client can't move on behalf of the other player")
    func cannotImpersonateInMove() throws {
        _ = try startTicTacToe()
        // It's X's (host's) turn. A forged envelope claiming the host's sender id is
        // rejected by the session layer before the coordinator sees it.
        let forged = Envelope(sessionId: host.games.lobby?.id, senderId: host.id, sequence: 999,
                              payload: .moveRequest(MoveRequestPayload(moveId: UUID(), baseRevision: 0, move: .ticTacToe(cell: 0))))
        network.inject(try network.sealed(forged, from: guest, to: host), from: guest, to: host)
        #expect(host.games.revision == 0)
        #expect(host.session.rejectedEnvelopeCount == 1)
    }

    @Test("Host dropping pauses the match; the guest can't move until the host is back")
    func hostAwayPauses() throws {
        _ = try startTicTacToe()
        host.games.play(.ticTacToe(cell: 0))
        network.disconnect(host, guest)
        #expect(guest.games.lobby?.phase == .playing)
        #expect(guest.games.awayIds == [host.id])
        #expect(guest.games.isHostAway)

        guest.games.play(.ticTacToe(cell: 4))
        #expect(guest.games.notice?.contains("stepped away") == true)
        #expect(guest.games.pendingMoveId == nil)

        network.connect(host, guest)
        #expect(guest.games.awayIds.isEmpty)
        #expect(host.games.awayIds.isEmpty)
        guest.games.play(.ticTacToe(cell: 4))
        #expect(host.games.revision == 2)
        #expect(tttState(guest) == tttState(host))
    }

    @Test("A guest who was away is caught up on moves they missed")
    func guestCatchUp() throws {
        _ = try startTicTacToe()
        network.disconnect(host, guest)
        #expect(host.games.awayIds == [guest.id])
        host.games.play(.ticTacToe(cell: 0)) // X moves while O is away
        #expect(guest.games.revision == 0)

        network.connect(host, guest)
        #expect(guest.games.revision == 1)
        #expect(tttState(guest) == tttState(host))
    }

    @Test("Someone who doesn't come back in time ends the match")
    func awayTimeout() throws {
        _ = try startTicTacToe()
        network.disconnect(host, guest)
        guest.games.awayTimedOut(PeerIdentity(id: host.id, nickname: "Hana"))
        guard case .ended(let reason) = guest.games.lobby?.phase else {
            Issue.record("Expected ended phase")
            return
        }
        #expect(reason.contains("host"))
        host.games.awayTimedOut(PeerIdentity(id: guest.id, nickname: "Gus"))
        guard case .ended = host.games.lobby?.phase else {
            Issue.record("Expected ended phase for the host")
            return
        }
    }

    @Test("Each pair of contacts shares a private Bluetooth key, exchanged through the mesh")
    func nudgeKeyExchange() throws {
        let raw = { (key: SymmetricKey?) in key.map { $0.withUnsafeBytes { Data($0) } } }
        let hostToGuest = try #require(raw(host.session.nudgeKey(sealingTo: guest.id)))
        #expect(hostToGuest == raw(guest.session.nudgeKey(openingFrom: host.id)))
        let guestToHost = try #require(raw(guest.session.nudgeKey(sealingTo: host.id)))
        #expect(guestToHost == raw(host.session.nudgeKey(openingFrom: guest.id)))
        #expect(hostToGuest != guestToHost)

        // A third phone gets different keys.
        let third = network.addNode("Tess")
        network.connect(third, host)
        #expect(raw(third.session.nudgeKey(sealingTo: host.id)) != guestToHost)
    }

    @Test("A peer that says it's stepping away shows as away, not disconnected, and can still get messages")
    func steppingAway() throws {
        host.session.send(.presence(PresencePayload(away: true)))
        network.disconnect(host, guest)
        #expect(guest.session.chat.messages.last?.text.contains("stepped away") == true)
        #expect(guest.session.awayIdentityIds == [host.id])
        #expect(guest.session.canChat)
        #expect(guest.session.sendChat("brb?") == .sent)

        network.connect(host, guest)
        #expect(guest.session.steppedAwayIds.isEmpty)
        #expect(host.session.chat.messages.contains { $0.text == "brb?" })
    }

    @Test("While the host is away, a guest's move is relayed, applied by the host, and synced on return")
    func relayedMove() throws {
        var hostTurns: [GameType] = []
        host.games.onTurnStarted = { hostTurns.append($0) }
        var relayed: (hostId: String, lobbyId: UUID, request: MoveRequestPayload, done: (Bool) -> Void)?
        guest.games.onRelayMove = { relayed = ($0, $1, $2, $3) }

        _ = try startTicTacToe()
        host.games.play(.ticTacToe(cell: 0)) // Now it's the guest's turn.
        hostTurns = []
        network.disconnect(host, guest)      // The host locks their phone.

        guest.games.play(.ticTacToe(cell: 4))
        let relay = try #require(relayed)
        #expect(relay.hostId == host.id)
        #expect(guest.games.pendingMoveId == relay.request.moveId)

        // The Bluetooth write wakes the host's app, which applies the move and says it's their turn.
        host.games.receiveRelayedMove(relay.request, lobbyId: relay.lobbyId, from: guest.id)
        relay.done(true)
        #expect(host.games.revision == 2)
        #expect(hostTurns == [.ticTacToe])
        #expect(guest.games.relayedMoveDelivered)

        // A replay of the same move does nothing.
        host.games.receiveRelayedMove(relay.request, lobbyId: relay.lobbyId, from: guest.id)
        #expect(host.games.revision == 2)

        network.connect(host, guest)
        #expect(guest.games.revision == 2)
        #expect(guest.games.pendingMoveId == nil)
        #expect(tttState(guest) == tttState(host))
    }

    @Test("A relayed move that can't be delivered is released so the player can try again")
    func relayFailure() throws {
        guest.games.onRelayMove = { _, _, _, done in done(false) }
        _ = try startTicTacToe()
        host.games.play(.ticTacToe(cell: 0))
        network.disconnect(host, guest)
        guest.games.play(.ticTacToe(cell: 4))
        #expect(guest.games.pendingMoveId == nil)
        #expect(guest.games.notice?.contains("Couldn't reach") == true)
    }

    @Test("Relayed moves from a non-player or for another game are ignored")
    func relayedMoveValidation() throws {
        let lobbyId = try startTicTacToe()
        let bogus = MoveRequestPayload(moveId: UUID(), baseRevision: 0, move: .ticTacToe(cell: 0))
        host.games.receiveRelayedMove(bogus, lobbyId: UUID(), from: guest.id)
        host.games.receiveRelayedMove(bogus, lobbyId: lobbyId, from: "stranger")
        #expect(host.games.revision == 0)
    }

    // MARK: - Hardening regressions

    @Test("A guest who returns after the match ended is told it ended")
    func endedWhileAway() throws {
        let third = network.addNode("Tess")
        network.connect(third, host)
        network.connect(third, guest)
        host.games.hostLobby(.colorMatch)
        for node in [guest, third] {
            let offer = try #require(node.games.offers(for: .colorMatch).first)
            node.games.join(offer)
            node.games.setReady(true)
        }
        host.games.startGame()
        network.disconnect(host, third)                    // Tess steps away.
        guest.games.leave()                                // Gus leaves, so the match ends while Tess is away.
        network.connect(host, third)                       // Tess is back.
        guard case .ended = third.games.lobby?.phase else {
            Issue.record("Tess should learn the match ended, not stay on the old board")
            return
        }
    }

    @Test("A rematch vote cast while the host was away still counts")
    func rematchVoteWhileHostAway() throws {
        _ = try startTicTacToe()
        for cell in [0, 3, 1, 4, 2] { try play(cell) }
        network.disconnect(host, guest)
        guest.games.requestRematch()
        network.connect(host, guest)
        host.games.requestRematch()
        #expect(tttState(host)?.round == 2)
    }

    @Test("Stepping away in the lobby keeps your seat; the host can't start until you're back")
    func lobbyAway() throws {
        host.games.hostLobby(.ticTacToe)
        let offer = try #require(guest.games.offers(for: .ticTacToe).first)
        guest.games.join(offer)
        guest.games.setReady(true)
        network.disconnect(host, guest)
        #expect(host.games.lobby?.players.count == 2)
        #expect(!host.games.canStart)
        #expect(guest.games.lobby?.phase == .lobby)
        network.connect(host, guest)
        #expect(host.games.canStart)
    }

    @Test("A guest who missed the start message joins the match from the first snapshot")
    func lostStartMessage() throws {
        host.games.hostLobby(.ticTacToe)
        let offer = try #require(guest.games.offers(for: .ticTacToe).first)
        guest.games.join(offer)
        guest.games.setReady(true)
        // Drop just the start message.
        network.interceptor = { [network] data, _, receiver in
            guard let envelope = network.envelope(in: data, for: receiver) else { return true }
            return envelope.kind != .startGame
        }
        host.games.startGame()
        network.interceptor = nil
        #expect(guest.games.lobby?.phase == .playing)
        #expect(guest.games.snapshot == host.games.snapshot)
    }

    @Test("Inviting someone already in a game says they're busy instead of 'declined'")
    func busyInvite() throws {
        let third = network.addNode("Tess")
        network.connect(third, host)
        network.connect(third, guest)
        _ = try startTicTacToe()                 // Gus is playing with Hana.
        third.games.hostLobby(.chess)
        let gus = try #require(third.session.identity(for: guest.id))
        third.games.invite(gus)
        #expect(third.games.notice?.contains("in another game") == true)
    }

    @Test("A finished game on screen doesn't block a new invitation")
    func invitationAfterEndedGame() throws {
        let third = network.addNode("Tess")
        network.connect(third, host)
        network.connect(third, guest)
        _ = try startTicTacToe()
        host.games.leave()                        // Gus now sees "Game over".
        guard case .ended = guest.games.lobby?.phase else { Issue.record("expected ended"); return }
        third.games.hostLobby(.chess)
        third.games.invite(try #require(third.session.identity(for: guest.id)))
        #expect(guest.games.invitation?.payload.gameType == .chess)
    }

    @Test("Host-sent text that fails the safety filter isn't shown")
    func filteredHostText() throws {
        let lobbyId = try startTicTacToe()
        host.session.send(.gameEvent(GameEventPayload(event: .moveRejected, message: "call me 555 123 4567")), sessionId: lobbyId, to: [guest.id])
        #expect(guest.games.notice?.contains("555") != true)
    }

    // MARK: - Conversations

    @Test("A one-on-one chat reaches only the other person, in the same conversation on both phones")
    func directChat() throws {
        let third = network.addNode("Tess")
        network.connect(third, host)
        network.connect(third, guest)
        let guestIdentity = try #require(host.session.identity(for: guest.id))
        let dm = host.session.directConversation(with: guestIdentity)
        #expect(host.session.sendChat("Just us", in: dm.id) == .sent)

        #expect(guest.session.chat.messages(in: dm.id).map(\.text) == ["Just us"])
        #expect(guest.session.chat.conversation(dm.id)?.kind == .direct)
        #expect(guest.session.chat.unread[dm.id] == 1)
        #expect(!third.session.chat.messages.contains { $0.text == "Just us" })
        // The guest replies in the same chat.
        #expect(guest.session.sendChat("Hi back", in: dm.id) == .sent)
        #expect(host.session.chat.messages(in: dm.id).map(\.text) == ["Just us", "Hi back"])
    }

    @Test("A group reaches only its members and keeps its name")
    func groupChat() throws {
        let third = network.addNode("Tess"), fourth = network.addNode("Dev")
        for node in [third, fourth] {
            network.connect(node, host)
            network.connect(node, guest)
        }
        network.connect(third, fourth)
        let members = try [guest, third].map { try #require(host.session.identity(for: $0.id)) }
        let group = host.session.createGroup(name: "Pool Crew", with: members)
        #expect(host.session.sendChat("Pool at 3?", in: group.id) == .sent)

        for member in [guest, third] {
            #expect(member.session.chat.messages(in: group.id).map(\.text) == ["Pool at 3?"])
            #expect(member.session.chat.conversation(group.id)?.name == "Pool Crew")
        }
        #expect(!fourth.session.chat.messages.contains { $0.text == "Pool at 3?" })
        // A member replies to the whole group.
        #expect(third.session.sendChat("Yes!", in: group.id) == .sent)
        #expect(guest.session.chat.messages(in: group.id).map(\.text) == ["Pool at 3?", "Yes!"])
    }

    @Test("Messages claiming a conversation the sender isn't in, or changing a group's members, are rejected")
    func conversationSpoofing() throws {
        let third = network.addNode("Tess")
        network.connect(third, host)
        network.connect(third, guest)
        let guestIdentity = try #require(host.session.identity(for: guest.id))
        let group = host.session.createGroup(name: nil, with: [guestIdentity])
        host.session.sendChat("hello group", in: group.id)

        // Tess isn't a member but claims to be writing in the group with a different member list.
        var forged = try #require(group.ref)
        forged.members.append(ConversationMember(id: third.id, nickname: "Tess"))
        third.session.send(.chat(ChatPayload(text: "let me in", conversation: forged)), to: [guest.id])
        #expect(!guest.session.chat.messages.contains { $0.text == "let me in" })

        // A conversation that doesn't include the recipient is dropped too.
        let elsewhere = ConversationRef(id: UUID(), kind: .group, name: nil,
                                        members: [ConversationMember(id: third.id, nickname: "Tess"), ConversationMember(id: host.id, nickname: "Hana")])
        third.session.send(.chat(ChatPayload(text: "not for you", conversation: elsewhere)), to: [guest.id])
        #expect(!guest.session.chat.messages.contains { $0.text == "not for you" })
    }

    @Test("A private message to someone away is held and lands in the right chat when they're back")
    func directChatWhileAway() throws {
        var queued: (ids: [String], conversation: UUID)?
        host.session.onChatQueuedForAway = { ids, _, conversation, _ in queued = (ids, conversation) }
        let guestIdentity = try #require(host.session.identity(for: guest.id))
        let dm = host.session.directConversation(with: guestIdentity)
        network.disconnect(host, guest)
        #expect(host.session.canChat(in: dm.id))
        #expect(host.session.sendChat("Dinner at 7", in: dm.id) == .sent)
        #expect(queued?.ids == [guest.id])
        #expect(queued?.conversation == dm.id)

        network.connect(host, guest)
        #expect(guest.session.chat.messages(in: dm.id).map(\.text) == ["Dinner at 7"])
    }

    @Test("Inviting someone who is away nudges them, and the invitation arrives when they're back")
    func inviteWhileAway() throws {
        var invited: [(String, GameType)] = []
        host.games.onInviteAway = { invited.append(($0, $1)) }
        network.disconnect(host, guest)
        host.games.hostLobby(.chess)
        let guestIdentity = try #require(host.session.knownIdentities[guest.id])
        host.games.invite(guestIdentity)
        #expect(invited.map(\.0) == [guest.id])
        #expect(invited.map(\.1) == [.chess])
        #expect(guest.games.invitation == nil)

        network.connect(host, guest)
        #expect(guest.games.invitation?.payload.gameType == .chess)
    }

    @Test("Turn hooks: the player whose turn starts is told, and an away player is nudged")
    func turnHooks() throws {
        var guestTurns: [GameType] = []
        var nudged: [String] = []
        guest.games.onTurnStarted = { guestTurns.append($0) }
        host.games.onNudgeNeeded = { id, _ in nudged.append(id) }
        _ = try startTicTacToe()
        #expect(guestTurns.isEmpty) // X (host) moves first
        host.games.play(.ticTacToe(cell: 0))
        #expect(guestTurns == [.ticTacToe])

        // The guest steps away on their turn: the host asks for a nudge.
        network.disconnect(host, guest)
        #expect(nudged == [guest.id])
    }

    @Test("Guest leaving ends the match for the host")
    func guestLeaves() throws {
        _ = try startTicTacToe()
        guest.games.leave()
        #expect(guest.games.lobby == nil)
        guard case .ended = host.games.lobby?.phase else {
            Issue.record("Expected ended phase")
            return
        }
    }

    @Test("Full lobby rejects a third player")
    func fullLobby() throws {
        let third = network.addNode("Tess")
        network.connect(third, host)
        host.games.hostLobby(.ticTacToe)
        let offer = try #require(guest.games.offers(for: .ticTacToe).first)
        let staleOffer = try #require(third.games.offers(for: .ticTacToe).first)
        guest.games.join(offer)
        // Third joins with the offer it saw before the lobby filled.
        third.games.join(GameCoordinator.Offer(payload: staleOffer.payload, host: staleOffer.host))
        #expect(third.games.lobby == nil)
        #expect(third.games.notice == "That game is full.")
        #expect(host.games.lobby?.players.count == 2)
        #expect(third.games.offers(for: .ticTacToe).first?.isFull == true)
    }

    @Test("Direct invitation can be accepted or declined")
    func invitations() throws {
        host.games.hostLobby(.ticTacToe)
        let guestIdentity = try #require(host.session.identity(for: guest.id))
        host.games.invite(guestIdentity)
        #expect(guest.games.invitation?.host.id == host.id)

        guest.games.respondToInvitation(accept: false)
        #expect(guest.games.invitation == nil)
        #expect(host.games.notice?.contains("declined") == true)

        // Right after a decline, the same host can't pop the invitation up again.
        host.games.invite(guestIdentity)
        #expect(guest.games.invitation == nil)

        // The guest can still join on their own.
        let offer = try #require(guest.games.offers(for: .ticTacToe).first)
        guest.games.join(offer)
        #expect(guest.games.lobby?.id == host.games.lobby?.id)
    }

    @Test("Rematch needs both votes and alternates who starts")
    func rematch() throws {
        _ = try startTicTacToe()
        for cell in [0, 3, 1, 4, 2] { try play(cell) }
        host.games.requestRematch()
        #expect(tttState(host)?.round == 1)
        #expect(guest.games.rematchVotes.contains(host.id))

        guest.games.requestRematch()
        let next = try #require(tttState(guest))
        #expect(next.round == 2)
        #expect(next.playerId(for: .x) == guest.id)
        #expect(tttState(host) == next)
        #expect(host.games.rematchVotes.isEmpty)
    }

    @Test("A lobby you've played in is not listed as open afterwards")
    func endedLobbyNotListed() throws {
        let lobbyId = try startTicTacToe()
        guest.games.leave()
        #expect(guest.games.lobby == nil)
        #expect(!guest.games.openOffers.contains { $0.id == lobbyId })
        host.games.dismissEndedMatch()
        #expect(host.games.lobby == nil)
    }

    @Test("Blocking the opponent ends the match; a blocked host's game disappears")
    func blockingDuringGames() throws {
        _ = try startTicTacToe()
        guest.session.block(identityId: host.id)
        guard case .ended = guest.games.lobby?.phase else {
            Issue.record("Expected the match to end for the blocker")
            return
        }
        guest.games.dismissEndedMatch()
        host.games.leave()
        host.games.hostLobby(.ticTacToe)
        #expect(guest.games.offers(for: .ticTacToe).isEmpty)
    }

    @Test("Connect Four plays over the network with identical boards")
    func connectFourOverNetwork() throws {
        host.games.hostLobby(.connectFour)
        let offer = try #require(guest.games.offers(for: .connectFour).first)
        guest.games.join(offer)
        guest.games.setReady(true)
        host.games.startGame()
        for column in [0, 1, 0, 1, 0, 1] {
            guard case .connectFour(let state) = host.games.snapshot else { Issue.record("no state"); return }
            let mover = state.playerId(for: state.turn) == host.id ? host : guest
            mover.games.play(.connectFour(column: column))
        }
        host.games.play(.connectFour(column: 0))
        guard case .connectFour(let hostState) = host.games.snapshot, case .connectFour(let guestState) = guest.games.snapshot else {
            Issue.record("missing snapshots"); return
        }
        #expect(hostState == guestState)
        guard case .win(.red, _) = hostState.outcome else { Issue.record("expected red win"); return }
    }

    @Test("Chess plays over the network to checkmate with identical boards")
    func chessOverNetwork() throws {
        host.games.hostLobby(.chess)
        let offer = try #require(guest.games.offers(for: .chess).first)
        guest.games.join(offer)
        guest.games.setReady(true)
        host.games.startGame()
        // Fool's mate: f3, e5, g4, Qh4#.
        for (from, to) in [(13, 21), (52, 36), (14, 30), (59, 31)] {
            guard case .chess(let state) = host.games.snapshot else { Issue.record("no state"); return }
            let mover = state.playerId(for: state.turn) == host.id ? host : guest
            mover.games.play(.chess(.move(from: from, to: to, promotion: nil)))
        }
        guard case .chess(let hostState) = host.games.snapshot, case .chess(let guestState) = guest.games.snapshot else {
            Issue.record("missing snapshots"); return
        }
        #expect(hostState == guestState)
        #expect(hostState.outcome == .checkmate(winner: .black))
    }

    @Test("Checkers resign is accepted even against a stale board")
    func checkersResignOverNetwork() throws {
        host.games.hostLobby(.checkers)
        let offer = try #require(guest.games.offers(for: .checkers).first)
        guest.games.join(offer)
        guest.games.setReady(true)
        host.games.startGame()
        guard case .checkers(let state) = host.games.snapshot else { Issue.record("no state"); return }
        let resigner = state.playerId(for: .red) == host.id ? host : guest
        resigner.games.play(.checkers(.resign))
        guard case .checkers(let hostState) = host.games.snapshot, case .checkers(let guestState) = guest.games.snapshot else {
            Issue.record("missing snapshots"); return
        }
        #expect(hostState == guestState)
        #expect(hostState.outcome == .win(.black, byResignation: true))
        #expect(GameEngine.isTurnIndependent(.checkers(.resign)))
        #expect(!GameEngine.isTurnIndependent(.checkers(.move(from: 0, to: 9))))
    }

    @Test("Color Match with 3 players: each device gets only its own hand")
    func colorMatchPrivateHands() throws {
        let third = network.addNode("Tess")
        network.connect(third, host)
        network.connect(third, guest)
        host.games.hostLobby(.colorMatch)
        for node in [guest, third] {
            let offer = try #require(node.games.offers(for: .colorMatch).first)
            node.games.join(offer)
            node.games.setReady(true)
        }
        #expect(host.games.lobby?.players.count == 3)
        host.games.startGame()

        var hands: [String: [Card]] = [:]
        for node in [host, guest, third] {
            guard case .colorMatch(let table) = node.games.snapshot else { Issue.record("\(node.name) has no table"); return }
            #expect(table.viewer == node.id)
            #expect(table.hand.count == 7)
            #expect(table.cardCounts.values.allSatisfy { $0 == 7 })
            hands[node.id] = table.hand
        }
        // Hands are disjoint, so nobody received anyone else's cards.
        let allIds = hands.values.flatMap { $0.map(\.id) }
        #expect(Set(allIds).count == 21)

        // Every snapshot on the wire was addressed to the player it describes.
        for entry in network.log {
            if case .stateSnapshot(let payload) = entry.envelope.payload, case .colorMatch(let table) = payload.state {
                let recipient = network.nodes.first { $0.name == entry.to }!
                #expect(table.viewer == recipient.id)
            }
        }
    }

    @Test("Color Match: a client's legal play is applied by the host and seen by everyone")
    func colorMatchPlayOverNetwork() throws {
        host.games.hostLobby(.colorMatch)
        let offer = try #require(guest.games.offers(for: .colorMatch).first)
        guest.games.join(offer)
        guest.games.setReady(true)
        host.games.startGame()

        // Whoever's turn it is draws a card; both devices see the draw pile shrink.
        guard case .colorMatch(let before) = host.games.snapshot else { Issue.record("no table"); return }
        let mover = before.currentPlayer == host.id ? host : guest
        mover.games.play(.colorMatch(.draw))
        guard case .colorMatch(let hostAfter) = host.games.snapshot, case .colorMatch(let guestAfter) = guest.games.snapshot else {
            Issue.record("missing tables"); return
        }
        #expect(hostAfter.drawPileCount == before.drawPileCount - 1)
        #expect(guestAfter.drawPileCount == hostAfter.drawPileCount)
        #expect(hostAfter.cardCounts == guestAfter.cardCounts)
        #expect(guestAfter.cardCounts[mover.id] == 8)
    }

    @Test("Public broadcasts contain only lobby metadata")
    func noUnexpectedBroadcastContent() throws {
        _ = try startTicTacToe()
        let kinds = Set(network.log.map(\.envelope.kind))
        // Mesh housekeeping (hello, announce, contact setup, Bluetooth keys) plus the lobby and game.
        #expect(kinds.isSubset(of: [.hello, .announce, .contactRequest, .contactAccept, .keys,
                                    .lobbyOffer, .joinRequest, .joinAccept, .ready, .startGame, .stateSnapshot, .leave]))
    }
}

@MainActor
@Suite("Mesh relaying")
struct MeshNetworkTests {
    let network = FakeNetwork()

    @Test("Two contacts out of each other's range chat and play through a phone in between, which sees nothing")
    func relayedChatAndGame() throws {
        let ana = network.addNode("Ana"), ben = network.addNode("Ben"), cal = network.addNode("Cal")
        // A chain: Ana – Ben – Cal. Ana and Cal never link directly, and Ben isn't anyone's contact.
        network.connect(ana, ben, befriend: false)
        network.connect(ben, cal, befriend: false)
        #expect(ana.session.discoveredPeople.first { $0.id == cal.id }?.hops == 1)

        network.makeContacts(ana, cal)
        #expect(ana.session.connectedIdentities.map(\.id) == [cal.id])
        #expect(cal.session.connectedIdentities.map(\.id) == [ana.id])
        #expect(ben.session.connectedIdentities.isEmpty)

        let dm = ana.session.directConversation(with: try #require(ana.session.identity(for: cal.id)))
        #expect(ana.session.sendChat("Meet at the pool?", in: dm.id) == .sent)
        #expect(cal.session.chat.messages.contains { $0.text == "Meet at the pool?" })
        #expect(!ben.session.chat.messages.contains { $0.text == "Meet at the pool?" })

        ana.games.hostLobby(.ticTacToe)
        let offer = try #require(cal.games.offers(for: .ticTacToe).first)
        cal.games.join(offer)
        cal.games.setReady(true)
        ana.games.startGame()
        ana.games.play(.ticTacToe(cell: 4))
        #expect(cal.games.snapshot == ana.games.snapshot)
        // Open games are advertised to everyone nearby, so Ben may see the offer (and its
        // withdrawal once the game starts). Everything private stays sealed: he can't open the
        // chat, the join, the moves or the board.
        let readableByBen = network.log.filter { $0.to == "Ben" }.map(\.envelope.kind)
        #expect(Set(readableByBen).isSubset(of: [.hello, .announce, .lobbyOffer, .leave]))
    }

    @Test("More than eight phones can all reach each other")
    func beyondEight() throws {
        let nodes = (0..<12).map { network.addNode("P\($0)") }
        // A line of twelve phones: each linked only to its neighbors, so the far ends are 11 phones apart...
        for (a, b) in zip(nodes, nodes.dropFirst()) { network.connect(a, b, befriend: false) }
        // ...which is past the hop limit, so they can't hear each other; phones within it can.
        let first = nodes[0]
        let withinReach = nodes[1...MeshPacket.maxTTL]
        for node in withinReach {
            #expect(first.session.discoveredPeople.contains { $0.id == node.id })
        }
        #expect(!first.session.discoveredPeople.contains { $0.id == nodes[11].id })

        // A tighter cluster of twelve: each phone linked to its next two, everyone becomes contacts with P0.
        let cluster = FakeNetwork()
        let members = (0..<12).map { cluster.addNode("C\($0)") }
        for index in members.indices {
            for step in 1...2 where index + step < members.count {
                cluster.connect(members[index], members[index + step], befriend: false)
            }
        }
        for member in members.dropFirst() { cluster.makeContacts(members[0], member) }
        #expect(members.map(\.session.rejectedEnvelopeCount) == Array(repeating: 0, count: 12))
        #expect(members.dropFirst().filter { !members[0].session.isContact($0.id) }.map(\.name) == [])
        #expect(members.dropFirst().filter { members[0].session.directory[$0.id] == nil }.map(\.name) == [])
        #expect(members[0].session.connectedIdentities.count == 11)
        #expect(members[0].session.sendChat("Hello, everyone!") == .sent)
        for member in members.dropFirst() {
            #expect(member.session.chat.messages.contains { $0.text == "Hello, everyone!" })
        }
    }

    @Test("When the phone in between leaves, the far contact goes away; when it's back, so are they")
    func relayLeaves() throws {
        let ana = network.addNode("Ana"), ben = network.addNode("Ben"), cal = network.addNode("Cal")
        network.connect(ana, ben, befriend: false)
        network.connect(ben, cal, befriend: false)
        network.makeContacts(ana, cal)
        network.disconnect(ana, ben)
        // Ana has no links left, so Cal is unreachable at once.
        #expect(ana.session.connectedIdentities.isEmpty)
        #expect(ana.session.awayIdentityIds == [cal.id])
        network.connect(ana, ben, befriend: false)
        #expect(ana.session.connectedIdentities.map(\.id) == [cal.id])
    }
}
