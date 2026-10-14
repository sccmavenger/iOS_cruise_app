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
            let profile = ProfileStore(defaults: UserDefaults(suiteName: "net-\(UUID().uuidString)")!)
            profile.setNickname(name)
            session = SessionManager(transport: transport, profile: profile)
            games = GameCoordinator(session: session)
            transport.network = network
            transport.owner = self
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
        func invite(_ peer: PeerKey) {}
        func respond(toInvitation invitationId: UUID, accept: Bool) {}
        func disconnectAll() {}
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

    func connect(_ a: Node, _ b: Node) {
        let keyForB = PeerKey(), keyForA = PeerKey()
        a.keys[ObjectIdentifier(b)] = keyForB
        b.keys[ObjectIdentifier(a)] = keyForA
        a.session.handle(.peerFound(keyForB, displayName: b.name))
        b.session.handle(.peerFound(keyForA, displayName: a.name))
        a.session.handle(.peerStateChanged(keyForB, .connected))
        b.session.handle(.peerStateChanged(keyForA, .connected))
    }

    func disconnect(_ a: Node, _ b: Node) {
        guard let keyForB = a.keys[ObjectIdentifier(b)], let keyForA = b.keys[ObjectIdentifier(a)] else { return }
        a.session.handle(.peerStateChanged(keyForB, .notConnected))
        b.session.handle(.peerStateChanged(keyForA, .notConnected))
    }

    fileprivate func deliver(_ data: Data, from sender: Node, toKey key: PeerKey) {
        guard let receiver = nodes.first(where: { sender.keys[ObjectIdentifier($0)] == key }),
              let senderKey = receiver.keys[ObjectIdentifier(sender)]
        else { return }
        if let envelope = try? EnvelopeCodec.decode(data) {
            log.append((sender.name, receiver.name, envelope))
        }
        if let interceptor, !interceptor(data, sender, receiver) { return }
        receiver.session.handle(.received(data, from: senderKey))
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
        network.inject(try EnvelopeCodec.encode(forged), from: guest, to: host)
        #expect(host.games.revision == 0)
        #expect(host.session.rejectedEnvelopeCount == 1)
    }

    @Test("Host disconnecting ends the match with an explanation")
    func hostDisconnect() throws {
        _ = try startTicTacToe()
        network.disconnect(host, guest)
        guard case .ended(let reason) = guest.games.lobby?.phase else {
            Issue.record("Expected ended phase")
            return
        }
        #expect(reason.contains("host"))
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

        host.games.invite(guestIdentity)
        guest.games.respondToInvitation(accept: true)
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

    @Test("Public broadcasts contain only lobby metadata")
    func noUnexpectedBroadcastContent() throws {
        _ = try startTicTacToe()
        let kinds = Set(network.log.map(\.envelope.kind))
        #expect(kinds.isSubset(of: [.hello, .lobbyOffer, .joinRequest, .joinAccept, .ready, .startGame, .stateSnapshot, .leave]))
    }
}
