import Foundation
import Testing
@testable import iso_cruise_app

/// Stands in for the online game service.
@MainActor
final class FakeCloudService: CloudGameService {
    var online = true
    var createResult: Result<CloudSeat, CloudError> = .success(CloudSeat(code: "ABCD1234", seat: "seat0", token: "t0", game: .ticTacToe, maxSeats: 2))
    var joinResult: Result<CloudSeat, CloudError> = .success(CloudSeat(code: "ABCD1234", seat: "seat1", token: "t1", game: .ticTacToe, maxSeats: 2))
    private(set) var created: [GameType] = []
    private(set) var createdOpen: [Bool] = []
    private(set) var joinedCodes: [String] = []
    private(set) var quickPlays: [(GameType, [String])] = []
    var listed: [OpenGame] = []
    private(set) var connections: [FakeRoomConnection] = []

    func checkHealth() async -> Bool { online }

    func createRoom(_ game: GameType, nickname: String, open: Bool) async throws(CloudError) -> CloudSeat {
        created.append(game)
        createdOpen.append(open)
        return try createResult.get()
    }

    func openGames() async -> [OpenGame]? { listed }

    func quickPlay(_ game: GameType, nickname: String, avoid: [String]) async throws(CloudError) -> CloudSeat {
        quickPlays.append((game, avoid))
        return try joinResult.get()
    }

    func joinRoom(code: String, nickname: String) async throws(CloudError) -> CloudSeat {
        joinedCodes.append(code)
        return try joinResult.get()
    }

    func openRoom(_ seat: CloudSeat, onEvent: @escaping (CloudRoomEvent) -> Void) -> any CloudRoomConnection {
        let connection = FakeRoomConnection(onEvent: onEvent)
        connections.append(connection)
        return connection
    }
}

@MainActor
final class FakeRoomConnection: CloudRoomConnection {
    private(set) var isConnected = false
    private(set) var sent: [CloudClientMessage] = []
    private(set) var closed = false
    private let onEvent: (CloudRoomEvent) -> Void

    init(onEvent: @escaping (CloudRoomEvent) -> Void) { self.onEvent = onEvent }

    /// Like the real connection: nothing goes out while disconnected.
    func send(_ message: CloudClientMessage) { if isConnected { sent.append(message) } }
    func reconnectNow() {}
    func close() { closed = true; isConnected = false }

    func connect() { isConnected = true; onEvent(.connected) }
    func drop() { isConnected = false; onEvent(.disconnected) }
    func deliver(_ message: CloudServerMessage) { onEvent(.message(message)) }
    func gone() { onEvent(.roomGone) }
    func removed() { onEvent(.removed) }

    var moves: [MoveRequestPayload] {
        sent.compactMap { if case .move(let request) = $0 { request } else { nil } }
    }
}

@MainActor
@Suite("Online games")
struct OnlineGamesTests {
    static func roster(
        phase: CloudRoster.Phase = .lobby,
        you: String = "seat0",
        organizer: String = "seat0",
        players: [(String, String, Bool)] = [("seat0", "Ann", true), ("seat1", "Bob", true)],
        votes: [String] = [],
        ended: String? = nil
    ) -> CloudServerMessage {
        .roster(CloudRoster(
            code: "ABCD1234", game: .ticTacToe, phase: phase, minSeats: 2, maxSeats: 2, organizer: organizer,
            endedMessage: ended, you: you,
            players: players.map { CloudRoster.Player(seat: $0.0, nickname: $0.1, connected: $0.2) },
            rematchVotes: votes
        ))
    }

    static func snapshot(_ revision: Int, board: [TicTacToeState.Mark?] = Array(repeating: nil, count: 9)) -> CloudServerMessage {
        var state = TicTacToeRules.newGame(players: ["seat0", "seat1"])
        for (index, mark) in board.enumerated() { state.board[index] = mark }
        return .snapshot(revision: revision, view: .ticTacToe(state))
    }

    /// One phone with online play available.
    @MainActor
    struct Setup {
        let network = FakeNetwork()
        let node: FakeNetwork.Node
        let cloud = FakeCloudService()
        let store = CloudRoomStore(service: "test.cloudroom.\(UUID().uuidString)")
        let games: GameCoordinator

        init(online: Bool = true) {
            node = network.addNode("Ann")
            cloud.online = online
            let cloud = cloud
            // Replaces the node's offline-only coordinator: the session now talks to this one.
            games = GameCoordinator(session: node.session, cloud: cloud, cloudStore: store, onlineAvailable: { await cloud.checkHealth() })
        }
    }

    /// Lets the coordinator's async work (creating or joining a room) finish.
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    @Test("With internet, hosting creates an online room; the phone's seat is its player id")
    func hostOnline() async {
        let s = Setup()
        s.games.hostLobby(.ticTacToe)
        await settle { s.games.lobby != nil }
        #expect(s.cloud.created == [.ticTacToe])
        #expect(s.games.lobby?.cloudCode == "ABCD1234")
        #expect(s.games.localId == "seat0")
        #expect(s.games.isHost)
        #expect(s.store.load()?.token == "t0", "the seat is remembered for a relaunch")
        s.store.clear()
    }

    @Test("Without internet, hosting stays on the phone, as in version 1")
    func hostOffline() async {
        let s = Setup(online: false)
        s.games.hostLobby(.ticTacToe)
        await settle { s.games.lobby != nil }
        #expect(s.cloud.created.isEmpty)
        #expect(s.games.lobby?.isOnline == false)
        #expect(s.games.localId == s.node.session.localId)
    }

    @Test("If the service fails at the last moment, the game is hosted on the phone instead, with a notice")
    func hostFallsBack() async {
        let s = Setup()
        s.cloud.createResult = .failure(.unreachable)
        s.games.hostLobby(.ticTacToe)
        await settle { s.games.lobby != nil }
        #expect(s.games.lobby?.isOnline == false)
        #expect(s.games.notice?.contains("hosted on your phone") == true)
    }

    @Test("The roster sets players, host and presence; the host can start once everyone is connected")
    func rosterAndStart() async throws {
        let s = Setup()
        s.games.hostLobby(.ticTacToe)
        await settle { s.games.lobby != nil }
        let connection = try #require(s.cloud.connections.first)
        connection.connect()
        connection.deliver(Self.roster(players: [("seat0", "Ann", true), ("seat1", "Bob", false)]))
        #expect(s.games.lobby?.players.map(\.nickname) == ["Ann", "Bob"])
        #expect(s.games.awayIds == ["seat1"])
        #expect(!s.games.canStart, "Bob hasn't connected yet")
        connection.deliver(Self.roster())
        #expect(s.games.canStart)
        s.games.startGame()
        #expect(connection.sent.contains(.start))
        connection.deliver(Self.roster(phase: .playing))
        connection.deliver(Self.snapshot(0))
        #expect(s.games.lobby?.phase == .playing)
        #expect(s.games.lobby?.seats == ["seat0", "seat1"])
        #expect(s.games.revision == 0)
        s.store.clear()
    }

    @Test("Moves go to the service with the current revision; refusals show the rules' message")
    func moves() async throws {
        let s = Setup()
        s.games.hostLobby(.ticTacToe)
        await settle { s.games.lobby != nil }
        let connection = try #require(s.cloud.connections.first)
        connection.connect()
        connection.deliver(Self.roster(phase: .playing))
        connection.deliver(Self.snapshot(3))
        s.games.play(.ticTacToe(cell: 4))
        let move = try #require(connection.moves.first)
        #expect(move.baseRevision == 3 && move.move == .ticTacToe(cell: 4))
        s.games.play(.ticTacToe(cell: 5))
        #expect(connection.moves.count == 1, "one move at a time")
        connection.deliver(.result(CloudMoveResult(moveId: move.moveId.uuidString, ok: false, revision: 3, error: "occupied", message: "That square is already taken.")))
        #expect(s.games.notice == "That square is already taken.")
        #expect(s.games.pendingMoveId == nil)
        s.games.play(.ticTacToe(cell: 0))
        let stale = try #require(connection.moves.last)
        connection.deliver(.result(CloudMoveResult(moveId: stale.moveId.uuidString, ok: false, revision: 3, error: "staleBoard", message: nil)))
        #expect(s.games.notice == MoveErrorMessage.staleBoard)
        s.store.clear()
    }

    @Test("A move made while disconnected is sent, with the same id, when the connection is back")
    func moveAfterReconnect() async throws {
        let s = Setup()
        s.games.hostLobby(.ticTacToe)
        await settle { s.games.lobby != nil }
        let connection = try #require(s.cloud.connections.first)
        connection.connect()
        connection.deliver(Self.roster(phase: .playing))
        connection.deliver(Self.snapshot(0))
        connection.drop()
        #expect(!s.games.isCloudConnected)
        s.games.play(.ticTacToe(cell: 4))
        #expect(connection.moves.isEmpty)
        let pending = try #require(s.games.pendingMoveId)
        connection.connect()
        #expect(connection.moves.map(\.moveId) == [pending])
        connection.deliver(Self.snapshot(1, board: [nil, nil, nil, nil, .x, nil, nil, nil, nil]))
        #expect(s.games.pendingMoveId == nil)
        #expect(s.games.revision == 1)
        s.store.clear()
    }

    @Test("Stale or duplicate snapshots are ignored")
    func staleSnapshots() async throws {
        let s = Setup()
        s.games.hostLobby(.ticTacToe)
        await settle { s.games.lobby != nil }
        let connection = try #require(s.cloud.connections.first)
        connection.connect()
        connection.deliver(Self.snapshot(2, board: [.x, nil, nil, nil, nil, nil, nil, nil, nil]))
        connection.deliver(Self.snapshot(1))
        connection.deliver(Self.snapshot(2))
        guard case .ticTacToe(let state) = s.games.snapshot else { Issue.record("no snapshot"); return }
        #expect(state.board[0] == .x && s.games.revision == 2)
        s.store.clear()
    }

    @Test("A nearby friend's online game is joined through the service, not the host's phone")
    func nearbyOfferJoinsOnline() async throws {
        let network = FakeNetwork()
        let host = network.addNode("Ann"), friend = network.addNode("Bob")
        let hostCloud = FakeCloudService(), friendCloud = FakeCloudService()
        let hostStore = CloudRoomStore(service: "test.cloudroom.\(UUID().uuidString)")
        let friendStore = CloudRoomStore(service: "test.cloudroom.\(UUID().uuidString)")
        let hostGames = GameCoordinator(session: host.session, cloud: hostCloud, cloudStore: hostStore, onlineAvailable: { true })
        let friendGames = GameCoordinator(session: friend.session, cloud: friendCloud, cloudStore: friendStore, onlineAvailable: { true })
        network.connect(host, friend)
        hostGames.hostLobby(.ticTacToe)
        await settle { hostGames.lobby != nil }
        let offer = try #require(friendGames.offers(for: .ticTacToe).first)
        #expect(offer.payload.cloudCode == "ABCD1234")
        friendGames.join(offer)
        await settle { friendGames.lobby != nil }
        #expect(friendCloud.joinedCodes == ["ABCD1234"])
        #expect(friendGames.localId == "seat1")
        #expect(!network.log.contains { if case .joinRequest = $0.envelope.payload { true } else { false } })
        hostStore.clear(); friendStore.clear()
    }

    @Test("Joining by code: a wrong code shows why")
    func joinByCodeErrors() async {
        let s = Setup()
        s.cloud.joinResult = .failure(.notFound)
        s.games.joinOnline(code: "ZZZZ9999")
        await settle { s.games.notice != nil }
        #expect(s.games.lobby == nil)
        #expect(s.games.notice == CloudError.notFound.message)
    }

    @Test("Leaving tells the service, forgets the seat, and returns to the Games list")
    func leave() async throws {
        let s = Setup()
        s.games.hostLobby(.ticTacToe)
        await settle { s.games.lobby != nil }
        let connection = try #require(s.cloud.connections.first)
        connection.connect()
        s.games.leave()
        #expect(connection.sent.contains(.leave))
        #expect(s.games.lobby == nil && s.games.cloudSeat == nil)
        #expect(s.store.load() == nil)
        #expect(s.games.localId == s.node.session.localId)
    }

    @Test("Someone else leaving mid-game ends it with the server's reason")
    func endedByServer() async throws {
        let s = Setup()
        s.games.hostLobby(.ticTacToe)
        await settle { s.games.lobby != nil }
        let connection = try #require(s.cloud.connections.first)
        connection.connect()
        connection.deliver(Self.snapshot(0))
        connection.deliver(Self.roster(phase: .ended, players: [("seat0", "Ann", true)], ended: "Bob left the game. The match has ended."))
        #expect(s.games.lobby?.phase == .ended("Bob left the game. The match has ended."))
        #expect(s.store.load() == nil, "an ended game isn't restored after a relaunch")
    }

    @Test("An expired room ends the game on this phone too")
    func roomGone() async throws {
        let s = Setup()
        s.games.hostLobby(.ticTacToe)
        await settle { s.games.lobby != nil }
        let connection = try #require(s.cloud.connections.first)
        connection.gone()
        #expect(s.games.lobby?.phase == .ended("This online game has ended."))
        #expect(s.store.load() == nil)
    }

    @Test("After a relaunch, the phone goes back to its online game")
    func restore() async throws {
        let s = Setup()
        s.store.save(CloudSeat(code: "WXYZ5678", seat: "seat1", token: "secret", game: .connectFour, maxSeats: 2))
        s.games.restoreOnlineGame()
        #expect(s.games.lobby?.cloudCode == "WXYZ5678")
        #expect(s.games.lobby?.gameType == .connectFour)
        #expect(s.games.localId == "seat1")
        #expect(s.cloud.connections.count == 1)
        s.store.clear()
    }

    @Test("Rematch votes go to the service and come back in the roster")
    func rematch() async throws {
        let s = Setup()
        s.games.hostLobby(.ticTacToe)
        await settle { s.games.lobby != nil }
        let connection = try #require(s.cloud.connections.first)
        connection.connect()
        connection.deliver(Self.roster(phase: .playing))
        connection.deliver(Self.snapshot(5, board: [.x, .x, .x, .o, .o, nil, nil, nil, nil]))
        // The rules decide it's over; the test board is a finished X win.
        guard case .ticTacToe(var state) = s.games.snapshot else { Issue.record("no snapshot"); return }
        state.outcome = .win(.x, line: [0, 1, 2])
        connection.deliver(.snapshot(revision: 6, view: .ticTacToe(state)))
        s.games.requestRematch()
        #expect(connection.sent.contains(.rematch))
        connection.deliver(Self.roster(phase: .playing, votes: ["seat0", "seat1"]))
        #expect(s.games.rematchVotes == ["seat0", "seat1"])
        s.store.clear()
    }

    @Test("Protocol: server messages decode and moves encode the way the server expects")
    func wireFormat() throws {
        let roster = #"{"type":"roster","protocol":1,"code":"ABCD1234","game":"spades","phase":"lobby","minSeats":4,"maxSeats":4,"organizer":"seat0","endedMessage":null,"you":"seat2","players":[{"seat":"seat0","nickname":"Ann","connected":true}],"rematchVotes":[]}"#
        guard case .roster(let decoded) = try JSONDecoder().decode(CloudServerMessage.self, from: Data(roster.utf8)) else { Issue.record("roster"); return }
        #expect(decoded.game == .spades && decoded.you == "seat2" && decoded.players.first?.connected == true)

        let result = #"{"type":"result","moveId":"m1","ok":false,"error":"notYourTurn","message":"It's not your turn.","revision":3}"#
        #expect(try JSONDecoder().decode(CloudServerMessage.self, from: Data(result.utf8)) == .result(CloudMoveResult(moveId: "m1", ok: false, revision: 3, error: "notYourTurn", message: "It's not your turn.")))
        #expect(try JSONDecoder().decode(CloudServerMessage.self, from: Data(#"{"type":"pong","t":1}"#.utf8)) == .other)

        let id = UUID()
        let data = try JSONEncoder().encode(CloudClientMessage.move(MoveRequestPayload(moveId: id, baseRevision: 7, move: .spades(.bid(tricks: 3)))))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "move")
        #expect(object["moveId"] as? String == id.uuidString)
        #expect(object["baseRevision"] as? Int == 7)
        let move = try #require(object["move"] as? [String: Any])
        #expect(((move["spades"] as? [String: Any])?["_0"] as? [String: Any])?["bid"] != nil, "same shape the Swift rules on the server decode")
    }

    @Test("Offers carrying a malformed online code are rejected at decode time")
    func offerValidation() throws {
        func envelope(_ code: String?) -> Envelope {
            Envelope(senderId: "peer-1", sequence: 1, payload: .lobbyOffer(LobbyOfferPayload(lobbyId: UUID(), gameType: .ticTacToe, hostNickname: "Ann", maxSeats: 2, seatsTaken: 1, cloudCode: code)))
        }
        #expect((try? EnvelopeCodec.validate(envelope("ABCD1234"))) != nil)
        #expect((try? EnvelopeCodec.validate(envelope(nil))) != nil)
        #expect((try? EnvelopeCodec.validate(envelope("abcd1234"))) == nil)
        #expect((try? EnvelopeCodec.validate(envelope("ABC"))) == nil)
    }

    @Test("Hosting is open by default and private on request")
    func openByDefault() async {
        let s = Setup()
        s.games.hostLobby(.ticTacToe)
        await settle { s.games.lobby != nil }
        s.games.leave()
        s.games.hostLobby(.ticTacToe, open: false)
        await settle { s.games.lobby != nil }
        #expect(s.cloud.createdOpen == [true, false])
        s.store.clear()
    }

    @Test("Quick Play online asks the service for a seat, avoiding games the player was removed from")
    func quickPlayOnline() async throws {
        let s = Setup()
        s.games.joinOnline(code: "ABCD1234")
        await settle { s.games.lobby != nil }
        let connection = try #require(s.cloud.connections.first)
        connection.removed()
        #expect(s.games.lobby?.phase == .ended("The host removed you from this game."))
        #expect(s.games.removedFromCodes == ["ABCD1234"])
        #expect(s.store.load() == nil)
        s.games.dismissEndedMatch()
        s.games.quickPlay(.ticTacToe)
        await settle { s.games.lobby != nil }
        #expect(s.cloud.quickPlays.first?.0 == .ticTacToe)
        #expect(s.cloud.quickPlays.first?.1 == ["ABCD1234"])
        s.store.clear()
    }

    @Test("The online host's Remove sends a kick for that seat")
    func onlineRemove() async throws {
        let s = Setup()
        s.games.hostLobby(.ticTacToe)
        await settle { s.games.lobby != nil }
        let connection = try #require(s.cloud.connections.first)
        connection.connect()
        connection.deliver(Self.roster())
        s.games.removePlayer("seat1")
        #expect(connection.sent.contains(.kick(seat: "seat1")))
        s.store.clear()
    }

    @Test("Open games list: other titles, full games and removed games are left out; names are filtered")
    func openGamesFilter() async {
        let cloud = FakeCloudService()
        cloud.listed = [
            OpenGame(code: "AAAA1111", game: .ticTacToe, host: "Ann", seats: 1, maxSeats: 2),
            OpenGame(code: "BBBB2222", game: .chess, host: "Bob", seats: 1, maxSeats: 2),
            OpenGame(code: "CCCC3333", game: .ticTacToe, host: "Cat", seats: 2, maxSeats: 2),
            OpenGame(code: "DDDD4444", game: .ticTacToe, host: "Dan", seats: 1, maxSeats: 2),
        ]
        let list = OpenGamesList(service: cloud)
        await list.refresh()
        #expect(list.games(for: .ticTacToe, excluding: ["DDDD4444"]).map(\.code) == ["AAAA1111"])
    }
}
