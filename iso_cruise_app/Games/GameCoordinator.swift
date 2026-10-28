import Foundation
import Observation

/// Lobby management and host-authoritative match synchronization for every game.
///
/// Trust model:
/// - The host is the only device that validates moves and advances state. Clients send
///   `moveRequest`s and render whatever canonical, revisioned `stateSnapshot` the host sends.
/// - Every inbound message is checked against the sender's role (host vs. seated player)
///   and the current lobby/phase before it has any effect. `SessionManager` has already
///   verified that the sender id belongs to the transport peer it arrived from.
/// - If someone's connection drops mid-match (usually because their app went to the
///   background), the match pauses for up to `awayTimeout` and resumes when they're back.
///   The host resends the current state to a returning player. There is no host
///   migration: if the host never returns, the match ends.
///
/// Online games (version 2): when the internet is reachable, the online game service hosts
/// instead of a phone (see "Online" below and `server/game-worker`). The lobby, snapshot and
/// `play(_:)` surface is the same, so every game view works unchanged; ids are the room's
/// seat ids ("seat0", …) rather than mesh ids, and `localId` is this phone's seat.
@Observable
final class GameCoordinator {
    struct Offer: Identifiable, Equatable {
        let payload: LobbyOfferPayload
        let host: PeerIdentity

        var id: UUID { payload.lobbyId }
        var isFull: Bool { payload.seatsTaken >= payload.maxSeats }
    }

    enum Phase: Equatable {
        case lobby
        case playing
        case ended(String)
    }

    struct Lobby: Equatable {
        let id: UUID
        let gameType: GameType
        /// The host's id. Online, the organizer's seat (it moves if they leave the lobby).
        var hostId: String
        let maxSeats: Int
        var players: [LobbyPlayer]
        var phase: Phase = .lobby
        /// Seat order once the game starts.
        var seats: [String] = []
        /// Set when the online game service hosts this game: the invite code.
        var cloudCode: String? = nil
        /// Open: anyone can see and join it (online, in the service's list; offline, everyone
        /// nearby). Private: online only by code, offline only by direct invitation.
        var isOpen = true

        var isOnline: Bool { cloudCode != nil }

        func player(_ id: String) -> LobbyPlayer? { players.first { $0.id == id } }
        var isFull: Bool { players.count >= maxSeats }
    }

    /// How long a match waits for someone whose app went to the background.
    static let awayTimeout: Duration = .seconds(10 * 60)
    /// While someone is away, ask again this often for any nudge that hasn't been delivered.
    static let nudgeRetryInterval: Duration = .seconds(30)

    let session: SessionManager

    private(set) var offers: [UUID: Offer] = [:]
    private(set) var invitation: Offer?
    private(set) var lobby: Lobby?
    private(set) var joiningLobbyId: UUID?
    private(set) var snapshot: GameStateSnapshot?
    private(set) var revision = -1
    private(set) var pendingMoveId: UUID?
    private(set) var rematchVotes: Set<String> = []
    /// Players the host has sent a direct invitation to.
    private(set) var invitedIds: Set<String> = []
    /// Seated players whose connection dropped mid-match; the match is paused for them.
    private(set) var awayIds: Set<String> = []
    /// Players who dropped only because this phone's own app was in the background; we're
    /// reconnecting to them rather than waiting for them to come back.
    private(set) var reconnectingIds: Set<String> = []
    /// The pending move went to the away host's phone over Bluetooth; it shows when they're back.
    private(set) var relayedMoveDelivered = false
    /// Short-lived feedback such as "That square is already taken."
    var notice: String?

    /// The local player's turn just started (or they must answer a prompt).
    @ObservationIgnored var onTurnStarted: ((GameType) -> Void)?
    /// The match is waiting on someone who is away; the app can nudge their phone.
    @ObservationIgnored var onNudgeNeeded: ((_ playerId: String, GameType) -> Void)?
    /// The host invited someone who is away; the app can nudge their phone.
    @ObservationIgnored var onInviteAway: ((_ playerId: String, GameType) -> Void)?
    /// The host is away: deliver this move to the host's phone another way (Bluetooth).
    /// Call the completion with whether it arrived.
    @ObservationIgnored var onRelayMove: ((_ hostId: String, _ lobbyId: UUID, MoveRequestPayload, @escaping (Bool) -> Void) -> Void)?

    // Online: the seat this phone holds, and the room's live connection.
    private(set) var cloudSeat: CloudSeat?
    private(set) var isCloudConnected = false
    /// Creating or joining an online game is in progress.
    private(set) var isConnectingOnline = false
    /// What's in progress, in words: "Joining the game…", "Finding a game…", "Setting up your game…".
    private(set) var connectingMessage = ""
    @ObservationIgnored private let cloud: CloudGameService?
    @ObservationIgnored private let cloudStore: CloudRoomStore?
    @ObservationIgnored private let onlineAvailable: () async -> Bool
    @ObservationIgnored private var cloudConnection: (any CloudRoomConnection)?
    /// A move sent but not yet answered; re-sent with the same id after a reconnect.
    @ObservationIgnored private var pendingCloudMove: MoveRequestPayload?
    /// Online games this player was removed from: not shown again, and Quick Play avoids them.
    private(set) var removedFromCodes: Set<String> = []
    /// Players the host removed from this phone-hosted lobby; they can't rejoin it.
    @ObservationIgnored private var removedIds: Set<String> = []
    /// This phone's push address, given to the online game so it can notify us while the app
    /// isn't open (someone joined, the game started, our turn). Nil without notification permission.
    @ObservationIgnored var pushToken: (token: String, sandbox: Bool)? {
        didSet {
            guard pushToken?.token != oldValue?.token else { return }
            cloudConnection?.send(.push(token: pushToken?.token ?? "", sandbox: pushToken?.sandbox ?? false))
        }
    }
    /// The app is on screen. Off screen, the online game counts us as away and notifies us instead.
    @ObservationIgnored private var appIsActive = true

    // Host-only authoritative state.
    @ObservationIgnored private var authoritative: GameEngine.State?
    @ObservationIgnored private var seenMoveIds: Set<UUID> = []
    @ObservationIgnored private var awayTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var nudgeRetry: Task<Void, Never>?
    @ObservationIgnored private var nudgeRetryGeneration = 0
    /// This phone's own app is in the background: people look away, but nobody is nudged
    /// and no timeouts run until we're back.
    @ObservationIgnored private var suspendedLocally = false
    /// Revision of the last turn-changing move. Moves based on it stay valid even if
    /// Call One!/Catch! (which don't change whose turn it is) were applied since.
    @ObservationIgnored private var turnRevision = 0
    /// Hosts whose direct invitation was just declined, muted for a while.
    @ObservationIgnored private var declinedHosts: [String: Date] = [:]
    static let declineMute: TimeInterval = 2 * 60

    /// `cloud` is nil in builds and tests without online play; then every game is phone-hosted.
    init(
        session: SessionManager,
        cloud: CloudGameService? = nil,
        cloudStore: CloudRoomStore? = nil,
        onlineAvailable: @escaping () async -> Bool = { false }
    ) {
        self.session = session
        self.cloud = cloud
        self.cloudStore = cloudStore
        self.onlineAvailable = onlineAvailable
        session.onGameEnvelope = { [weak self] envelope, identity in
            self?.handle(envelope, from: identity)
        }
        session.onPeerDisconnected = { [weak self] identity, reason in
            self?.peerDisconnected(identity, reason: reason)
        }
        session.onPeerIdentified = { [weak self] identity in
            self?.peerIdentified(identity)
        }
        session.onResumed = { [weak self] in
            self?.sessionResumed()
        }
    }

    /// This phone's player id: its seat in an online game, its mesh id otherwise.
    var localId: String { cloudSeat?.seat ?? session.localId }
    var isHost: Bool { lobby?.hostId == localId }

    var openOffers: [Offer] {
        offers.values
            .filter { $0.payload.lobbyId != lobby?.id }
            .sorted { $0.host.nickname < $1.host.nickname }
    }

    func offers(for game: GameType) -> [Offer] {
        openOffers.filter { $0.payload.gameType == game }
    }

    /// Display name for a seated player id.
    func name(for playerId: String) -> String {
        if playerId == localId { return "You" }
        if let player = lobby?.player(playerId) { return player.nickname }
        return session.player(for: playerId)?.nickname ?? "Player"
    }

    /// It's the local player's move (or they must answer a prompt) in a running match.
    var isAwaitingMe: Bool {
        lobby?.phase == .playing && snapshot?.awaitingPlayerIds.contains(localId) == true
    }

    var isHostAway: Bool {
        guard let lobby, !isHost, !lobby.isOnline else { return false }
        return awayIds.contains(lobby.hostId)
    }

    var canStart: Bool {
        guard let lobby, isHost, lobby.phase == .lobby, lobby.gameType.isPlayable else { return false }
        if lobby.isOnline {
            // Online there's no "ready" step: everyone who's here and connected can start.
            return isCloudConnected && lobby.players.count >= lobby.gameType.minPlayers && awayIds.isEmpty
        }
        return lobby.players.count >= lobby.gameType.minPlayers
            && lobby.players.allSatisfy { $0.isHost || $0.isReady }
            && lobby.players.allSatisfy { !awayIds.contains($0.id) }
    }

    /// What the board shows while a move is on its way.
    var pendingMoveStatus: String {
        if relayedMoveDelivered, let hostId = lobby?.hostId { return "Move sent to \(name(for: hostId))'s phone" }
        return "Sending move…"
    }

    // MARK: - Local actions

    /// Hosts online when the internet is reachable, and on this phone otherwise.
    /// `open` (the default): anyone can see and join. Otherwise it's private.
    func hostLobby(_ gameType: GameType, open: Bool = true) {
        guard lobby == nil, joiningLobbyId == nil, !isConnectingOnline else {
            notice = "Finish or leave your current game first."
            return
        }
        guard gameType.isPlayable else { return }
        guard let cloud else { return hostOnThisPhone(gameType, open: open) }
        isConnectingOnline = true
        connectingMessage = "Setting up your game…"
        Task {
            defer { isConnectingOnline = false }
            guard await onlineAvailable() else { return hostOnThisPhone(gameType, open: open) }
            do throws(CloudError) {
                enterCloudRoom(try await cloud.createRoom(gameType, nickname: session.localIdentity.nickname, open: open))
            } catch {
                // The service is unreachable after all: play on this phone rather than not at all.
                hostOnThisPhone(gameType, open: open)
                notice = "Couldn't reach the online game service, so this game is hosted on your phone. Players need to be connected nearby."
            }
        }
    }

    /// Joins an online game by its invite code, from anywhere.
    func joinOnline(code: String) {
        guard lobby == nil, joiningLobbyId == nil, !isConnectingOnline else {
            notice = "Finish or leave your current game first."
            return
        }
        guard let cloud else { return }
        isConnectingOnline = true
        connectingMessage = "Joining the game…"
        Task {
            defer { isConnectingOnline = false }
            do throws(CloudError) {
                enterCloudRoom(try await cloud.joinRoom(code: code, nickname: session.localIdentity.nickname))
            } catch {
                notice = error.message
            }
        }
    }

    /// Puts the player in a game as fast as possible: online, the open game that's waited
    /// longest (or a new open one); offline, an open game nearby (or a new open one).
    func quickPlay(_ gameType: GameType) {
        guard lobby == nil, joiningLobbyId == nil, !isConnectingOnline else {
            notice = "Finish or leave your current game first."
            return
        }
        let nearby = { [weak self] in
            guard let self else { return }
            if let offer = self.offers(for: gameType).first(where: { !$0.isFull && $0.payload.cloudCode == nil }) {
                self.join(offer)
            } else {
                self.hostOnThisPhone(gameType, open: true)
            }
        }
        guard let cloud else { return nearby() }
        isConnectingOnline = true
        connectingMessage = "Finding a game…"
        Task {
            defer { isConnectingOnline = false }
            guard await onlineAvailable() else { return nearby() }
            do throws(CloudError) {
                enterCloudRoom(try await cloud.quickPlay(gameType, nickname: session.localIdentity.nickname, avoid: Array(removedFromCodes)))
            } catch {
                notice = error.message
            }
        }
    }

    /// The host removes someone from the lobby before the game starts. They can't rejoin it.
    func removePlayer(_ playerId: String) {
        guard isHost, var lobby, lobby.phase == .lobby, playerId != localId, lobby.player(playerId) != nil else { return }
        if lobby.isOnline {
            cloudConnection?.send(.kick(seat: playerId))
            return
        }
        lobby.players.removeAll { $0.id == playerId }
        removedIds.insert(playerId)
        self.lobby = lobby
        broadcastRoster()
        // The removed player gets a roster without them, which their phone reads as "removed".
        let roster = LobbyRosterPayload(lobbyId: lobby.id, gameType: lobby.gameType, maxSeats: lobby.maxSeats, players: lobby.players)
        session.send(.joinAccept(roster), sessionId: lobby.id, to: [playerId])
        broadcastOffer()
    }

    private func hostOnThisPhone(_ gameType: GameType, open: Bool = true) {
        guard lobby == nil else { return }
        let me = session.localIdentity
        lobby = Lobby(
            id: UUID(),
            gameType: gameType,
            hostId: me.id,
            maxSeats: gameType.maxPlayers,
            players: [LobbyPlayer(id: me.id, nickname: me.nickname, isReady: true, isHost: true)],
            isOpen: open
        )
        invitedIds = []
        broadcastOffer()
    }

    /// Invites one person. Connected people get the invitation now; someone who is away
    /// gets a notification, and the invitation when they reconnect.
    func invite(_ identity: PeerIdentity) {
        guard let lobby, isHost, lobby.phase == .lobby, !lobby.isFull, lobby.player(identity.id) == nil else { return }
        invitedIds.insert(identity.id)
        if session.isPlayerReachable(identity.id) {
            session.send(.lobbyOffer(offerPayload(for: lobby, invitedPlayerId: identity.id)), sessionId: lobby.id, to: [identity.id])
        } else {
            onInviteAway?(identity.id, lobby.gameType)
        }
    }

    func join(_ offer: Offer) {
        guard lobby == nil else {
            notice = "Finish or leave your current game first."
            return
        }
        guard !offer.isFull else { return }
        // A nearby friend's game that's hosted online: join it through the service.
        if let code = offer.payload.cloudCode { return joinOnline(code: code) }
        joiningLobbyId = offer.id
        let sent = session.send(.joinRequest(LobbyRefPayload(lobbyId: offer.id)), sessionId: offer.id, to: [offer.host.id])
        if sent == nil {
            joiningLobbyId = nil
            notice = "Couldn't reach \(offer.host.nickname)."
        }
    }

    func respondToInvitation(accept: Bool) {
        guard let invitation else { return }
        self.invitation = nil
        if accept {
            join(invitation)
        } else {
            declinedHosts[invitation.host.id] = .now
            session.send(
                .joinReject(JoinRejectPayload(lobbyId: invitation.id, reason: .declined)),
                sessionId: invitation.id,
                to: [invitation.host.id]
            )
        }
    }

    func setReady(_ ready: Bool) {
        guard let lobby, !isHost, lobby.phase == .lobby, !lobby.isOnline else { return }
        session.send(.ready(ReadyPayload(lobbyId: lobby.id, isReady: ready)), sessionId: lobby.id, to: [lobby.hostId])
    }

    func startGame() {
        if lobby?.isOnline == true {
            if canStart { cloudConnection?.send(.start) }
            return
        }
        guard canStart, var lobby, let state = GameEngine.newGame(lobby.gameType, seats: lobby.players.map(\.id)) else { return }
        lobby.seats = lobby.players.map(\.id)
        lobby.phase = .playing
        self.lobby = lobby
        seenMoveIds = []
        rematchVotes = []
        turnRevision = 0

        let others = otherMembers
        session.send(.startGame(StartGamePayload(lobbyId: lobby.id, gameType: lobby.gameType, seats: lobby.seats)), sessionId: lobby.id, to: others)
        withdrawOffer(from: session.nearbyPlayers.map(\.id).filter { !others.contains($0) })
        commit(state, revision: 0)
    }

    func play(_ move: GameMove) {
        guard let lobby, lobby.phase == .playing, pendingMoveId == nil else { return }
        let request = MoveRequestPayload(moveId: UUID(), baseRevision: revision, move: move)
        if lobby.isOnline {
            // Sent now if connected, otherwise as soon as the connection is back.
            pendingMoveId = request.moveId
            pendingCloudMove = request
            cloudConnection?.send(.move(request))
            return
        }
        if isHostAway {
            relayToAwayHost(request, in: lobby)
            return
        }
        if isHost {
            hostHandleMove(request, from: localId)
        } else {
            pendingMoveId = request.moveId
            if session.send(.moveRequest(request), sessionId: lobby.id, to: [lobby.hostId]) == nil {
                pendingMoveId = nil
                notice = "Couldn't reach the host."
            }
        }
    }

    /// The host's app is in the background. Its game state is still in memory, so send the
    /// move to its phone over Bluetooth; iOS wakes the app to apply it and tell the host
    /// it's their turn. The result arrives here when the host is back.
    private func relayToAwayHost(_ request: MoveRequestPayload, in lobby: Lobby) {
        let hostName = name(for: lobby.hostId)
        guard let onRelayMove else {
            notice = "\(hostName) stepped away. Your move can be made when they're back."
            return
        }
        pendingMoveId = request.moveId
        relayedMoveDelivered = false
        onRelayMove(lobby.hostId, lobby.id, request) { [weak self] delivered in
            guard let self, self.pendingMoveId == request.moveId else { return }
            if delivered {
                self.relayedMoveDelivered = true
            } else {
                self.pendingMoveId = nil
                self.notice = "Couldn't reach \(hostName)'s phone. Move closer and try again, or wait until they're back."
            }
        }
    }

    /// A move that arrived over Bluetooth while this host's app was in the background.
    /// It goes through exactly the same checks as any other move.
    /// Returns whether this phone is hosting that game (so the sender learns if it arrived somewhere useful).
    @discardableResult
    func receiveRelayedMove(_ request: MoveRequestPayload, lobbyId: UUID, from playerId: String) -> Bool {
        guard isHost, let lobby, lobby.id == lobbyId, lobby.phase == .playing, lobby.seats.contains(playerId) else { return false }
        hostHandleMove(request, from: playerId)
        return true
    }

    func requestRematch() {
        guard let lobby, lobby.phase == .playing, snapshot?.isFinished == true else { return }
        rematchVotes.insert(localId)
        if lobby.isOnline {
            cloudConnection?.send(.rematch)
            return
        }
        session.send(.rematchRequest(LobbyRefPayload(lobbyId: lobby.id)), sessionId: lobby.id, to: otherMembers)
        if isHost { startRematchIfAgreed() }
    }

    func leave() {
        guard let lobby else { return }
        if lobby.isOnline {
            leaveCloudRoom(tellServer: true)
            return resetMatch()
        }
        var recipients = otherMembers
        if isHost {
            // Withdraw the public offer from everyone, not just members.
            recipients = session.nearbyPlayers.map(\.id)
        }
        session.send(.leave(LeavePayload(lobbyId: lobby.id)), sessionId: lobby.id, to: recipients)
        resetMatch()
    }

    /// Clears an ended match so the user can return to the Games list. A guest tells the
    /// host, in case the host still thinks the game is on.
    func dismissEndedMatch() {
        guard let lobby, case .ended = lobby.phase else { return }
        if lobby.isOnline { return resetMatch() }
        if !isHost {
            session.send(.leave(LeavePayload(lobbyId: lobby.id)), sessionId: lobby.id, to: [lobby.hostId])
        }
        resetMatch()
    }

    // MARK: - Inbound

    func handle(_ envelope: Envelope, from identity: PeerIdentity) {
        switch envelope.payload {
        case .lobbyOffer(let offer):
            receiveOffer(offer, from: identity)
        case .joinRequest(let ref):
            hostReceiveJoin(ref, from: identity)
        case .joinAccept(let roster):
            receiveRoster(roster, from: identity)
        case .joinReject(let reject):
            receiveReject(reject, from: identity)
        case .ready(let ready):
            hostReceiveReady(ready, from: identity)
        case .startGame(let start):
            receiveStart(start, from: identity)
        case .moveRequest(let request):
            guard isHost, envelope.sessionId == lobby?.id else { return }
            hostHandleMove(request, from: identity.id)
        case .stateSnapshot(let snapshot):
            receiveSnapshot(snapshot, sessionId: envelope.sessionId, from: identity)
        case .gameEvent(let event):
            receiveEvent(event, sessionId: envelope.sessionId, from: identity)
        case .rematchRequest(let ref):
            receiveRematchVote(ref, from: identity)
        case .leave(let leave):
            receiveLeave(leave, from: identity)
        case .hello, .chat, .heartbeat, .error, .presence, .announce, .contactRequest, .contactAccept, .keys, .contactEnd:
            break
        }
    }

    private func receiveOffer(_ offer: LobbyOfferPayload, from identity: PeerIdentity) {
        // The advertised host must be the sender; ignore offers we can't play.
        guard offer.gameType.isPlayable else { return }
        let named = Offer(payload: offer, host: identity)
        // One open game per host: a host advertising many games at once would flood the list.
        offers = offers.filter { $0.value.host.id != identity.id || $0.key == offer.lobbyId }
        switch offer.invitedPlayerId {
        case nil:
            offers[offer.lobbyId] = named
        case localId? where !session.isContact(identity.id):
            // From someone nearby who isn't a contact: it shows in the list, but never pops up,
            // so a crowd of strangers can't flood anyone with invitations.
            offers[offer.lobbyId] = named
        case localId?:
            offers[offer.lobbyId] = named
            // A host whose invitation was just declined can't keep popping it up.
            if let declined = declinedHosts[identity.id], Date.now.timeIntervalSince(declined) < Self.declineMute { return }
            // A finished game still on screen shouldn't block new invitations.
            if case .ended = lobby?.phase { resetMatch() }
            if lobby == nil, joiningLobbyId == nil, invitation == nil {
                invitation = named
            } else if invitation?.id != offer.lobbyId {
                session.send(.joinReject(JoinRejectPayload(lobbyId: offer.lobbyId, reason: .busy)), sessionId: offer.lobbyId, to: [identity.id])
            }
        default:
            break
        }
    }

    private func hostReceiveJoin(_ ref: LobbyRefPayload, from identity: PeerIdentity) {
        // Online games are joined through the service; an older app asking here can't join.
        guard isHost, var lobby, lobby.id == ref.lobbyId, !lobby.isOnline else {
            session.send(.joinReject(JoinRejectPayload(lobbyId: ref.lobbyId, reason: .notFound)), sessionId: ref.lobbyId, to: [identity.id])
            return
        }
        // Someone the host removed can't come back to this lobby.
        if removedIds.contains(identity.id) {
            session.send(.joinReject(JoinRejectPayload(lobbyId: ref.lobbyId, reason: .notFound)), sessionId: ref.lobbyId, to: [identity.id])
            return
        }
        if lobby.player(identity.id) != nil {
            // A member asking again: a lost roster, or a returning player who needs catching up.
            if case .ended(let message) = lobby.phase {
                session.send(.gameEvent(GameEventPayload(event: .matchEnded, message: message)), sessionId: lobby.id, to: [identity.id])
                return
            }
            broadcastRoster()
            resync(identity.id)
            return
        }
        guard lobby.phase == .lobby else {
            session.send(.joinReject(JoinRejectPayload(lobbyId: ref.lobbyId, reason: .alreadyStarted)), sessionId: ref.lobbyId, to: [identity.id])
            return
        }
        guard !lobby.isFull else {
            session.send(.joinReject(JoinRejectPayload(lobbyId: ref.lobbyId, reason: .lobbyFull)), sessionId: ref.lobbyId, to: [identity.id])
            return
        }
        lobby.players.append(LobbyPlayer(id: identity.id, nickname: identity.nickname, isReady: false, isHost: false))
        self.lobby = lobby
        invitedIds.remove(identity.id)
        broadcastRoster()
        broadcastOffer()
    }

    private func receiveRoster(_ roster: LobbyRosterPayload, from identity: PeerIdentity) {
        // Only accept rosters from the lobby's host, for a lobby we joined or are joining.
        guard roster.players.contains(where: { $0.id == identity.id && $0.isHost }),
              roster.players.filter(\.isHost).count == 1,
              (joiningLobbyId == roster.lobbyId && offers[roster.lobbyId]?.host.id == identity.id)
                || (lobby?.id == roster.lobbyId && lobby?.hostId == identity.id)
        else { return }

        guard roster.players.contains(where: { $0.id == localId }) else {
            if lobby?.id == roster.lobbyId {
                resetMatch()
                notice = "You were removed from the lobby."
            }
            return
        }

        joiningLobbyId = nil
        invitation = nil
        offers[roster.lobbyId] = nil
        // Names relayed by the host get the same cleaning and filtering as names we see directly.
        let players = roster.players.map { player in
            var safe = player
            safe.nickname = session.filter.safeNickname(Nickname.sanitize(player.nickname) ?? "Player")
            return safe
        }
        if var current = lobby, current.id == roster.lobbyId {
            current.players = players
            lobby = current
        } else {
            lobby = Lobby(id: roster.lobbyId, gameType: roster.gameType, hostId: identity.id, maxSeats: roster.maxSeats, players: players)
            snapshot = nil
            revision = -1
        }
    }

    private func receiveReject(_ reject: JoinRejectPayload, from identity: PeerIdentity) {
        if isHost, lobby?.id == reject.lobbyId, reject.reason == .declined || reject.reason == .busy {
            invitedIds.remove(identity.id)
            notice = reject.reason == .busy
                ? "\(identity.nickname) is in another game right now."
                : "\(identity.nickname) declined your invitation."
            return
        }
        // We asked our host to catch us up after being away, but the game is gone.
        if var lobby, !isHost, lobby.id == reject.lobbyId, lobby.hostId == identity.id, reject.reason == .notFound {
            lobby.phase = .ended("\(identity.nickname) isn't running this game anymore.")
            self.lobby = lobby
            pendingMoveId = nil
            return
        }
        guard joiningLobbyId == reject.lobbyId, offers[reject.lobbyId]?.host.id == identity.id else { return }
        joiningLobbyId = nil
        notice = switch reject.reason {
        case .lobbyFull: "That game is full."
        case .alreadyStarted: "That game has already started."
        case .notFound, .declined, .busy: "That game is no longer available."
        }
        if reject.reason != .lobbyFull { offers[reject.lobbyId] = nil }
    }

    private func hostReceiveReady(_ ready: ReadyPayload, from identity: PeerIdentity) {
        guard isHost, var lobby, lobby.id == ready.lobbyId, lobby.phase == .lobby,
              let index = lobby.players.firstIndex(where: { $0.id == identity.id })
        else { return }
        lobby.players[index].isReady = ready.isReady
        self.lobby = lobby
        broadcastRoster()
    }

    private func receiveStart(_ start: StartGamePayload, from identity: PeerIdentity) {
        guard var lobby, !isHost, lobby.id == start.lobbyId, lobby.hostId == identity.id,
              lobby.phase == .lobby, start.gameType == lobby.gameType, start.seats.contains(localId)
        else { return }
        lobby.seats = start.seats
        lobby.phase = .playing
        self.lobby = lobby
        snapshot = nil
        revision = -1
        rematchVotes = []
    }

    private func receiveSnapshot(_ payload: StateSnapshotPayload, sessionId: UUID?, from identity: PeerIdentity) {
        // The host's "start" message was lost (for example, we dropped just then); the first
        // snapshot that seats us starts the match here too.
        if var waiting = lobby, !isHost, waiting.phase == .lobby, sessionId == waiting.id, waiting.hostId == identity.id,
           payload.state.gameType == waiting.gameType, payload.state.playerIds.contains(localId) {
            waiting.seats = payload.state.playerIds
            waiting.phase = .playing
            lobby = waiting
            snapshot = nil
            revision = -1
        }
        guard let lobby, !isHost, sessionId == lobby.id, lobby.hostId == identity.id,
              lobby.phase == .playing,
              payload.state.gameType == lobby.gameType,
              Set(payload.state.playerIds) == Set(lobby.seats),
              Self.isAddressedToMe(payload.state, localId: localId),
              payload.revision > revision // ignore stale or duplicate revisions
        else { return }
        let previous = snapshot
        snapshot = payload.state
        revision = payload.revision
        pendingMoveId = nil
        relayedMoveDelivered = false
        if previous?.isFinished == true, !payload.state.isFinished { rematchVotes = [] }
        snapshotDidChange(from: previous)
    }

    private func receiveEvent(_ event: GameEventPayload, sessionId: UUID?, from identity: PeerIdentity) {
        guard var lobby, sessionId == lobby.id, lobby.hostId == identity.id else { return }
        // Text from the host is shown to the user, so it gets the same filter as chat.
        let message = session.filter.check(event.message).isAllowed ? event.message : "The game ended."
        switch event.event {
        case .moveRejected:
            pendingMoveId = nil
            notice = session.filter.check(event.message).isAllowed ? event.message : "That move wasn't accepted."
        case .matchEnded, .hostEnded:
            lobby.phase = .ended(message)
            self.lobby = lobby
            pendingMoveId = nil
        }
    }

    private func receiveRematchVote(_ ref: LobbyRefPayload, from identity: PeerIdentity) {
        guard let lobby, lobby.id == ref.lobbyId, lobby.phase == .playing, lobby.seats.contains(identity.id) else { return }
        rematchVotes.insert(identity.id)
        if isHost { startRematchIfAgreed() }
    }

    private func receiveLeave(_ leave: LeavePayload, from identity: PeerIdentity) {
        if let lobbyId = leave.lobbyId, offers[lobbyId]?.host.id == identity.id {
            offers[lobbyId] = nil
            if invitation?.id == lobbyId { invitation = nil }
            if joiningLobbyId == lobbyId {
                joiningLobbyId = nil
                notice = "That game is no longer available."
            }
        }
        guard let lobby, leave.lobbyId == lobby.id else { return }
        memberLeft(identity, reason: "\(identity.nickname) left the game.")
    }

    // MARK: - Connection changes

    private func peerDisconnected(_ identity: PeerIdentity, reason: SessionManager.DropReason) {
        offers = offers.filter { $0.value.host.id != identity.id }
        if invitation?.host.id == identity.id { invitation = nil }
        if let joining = joiningLobbyId, offers[joining] == nil {
            joiningLobbyId = nil
        }
        if reason == .blocked { invitedIds.remove(identity.id) }
        // A dropped link is usually an app switch: pause instead of ending, in the lobby too.
        if reason != .blocked, let lobby, lobby.player(identity.id) != nil {
            switch lobby.phase {
            case .lobby, .playing:
                markAway(identity, quietly: reason == .localSuspend)
                return
            case .ended:
                break
            }
        }
        memberLeft(identity, reason: "\(identity.nickname) disconnected.")
    }

    /// `quietly`: our own app is going to the background, so don't nudge or start timeouts.
    private func markAway(_ identity: PeerIdentity, quietly: Bool = false) {
        awayIds.insert(identity.id)
        // A move sent to an absent host may have been lost; let the player send it again later.
        if identity.id == lobby?.hostId, !relayedMoveDelivered { pendingMoveId = nil }
        if quietly {
            suspendedLocally = true
            reconnectingIds.insert(identity.id)
            return
        }
        startAwayTimer(for: identity)
        requestNudgesIfNeeded()
        startNudgeRetries()
    }

    private func startAwayTimer(for identity: PeerIdentity) {
        awayTimers[identity.id]?.cancel()
        awayTimers[identity.id] = Task { [weak self] in
            try? await Task.sleep(for: Self.awayTimeout)
            guard !Task.isCancelled else { return }
            self?.awayTimedOut(identity)
        }
    }

    /// Back in the foreground. People who reconnect within a few seconds were never really
    /// away; for anyone still missing, start the usual timeout and nudges.
    private func sessionResumed() {
        // Back from the background: the online room's socket probably died meanwhile.
        cloudConnection?.reconnectNow()
        guard suspendedLocally else { return }
        suspendedLocally = false
        let ids = awayIds
        for id in ids where awayTimers[id] == nil {
            let nickname = lobby?.player(id)?.nickname ?? session.knownIdentities[id]?.nickname ?? session.player(for: id)?.nickname ?? "Player"
            startAwayTimer(for: PeerIdentity(id: id, nickname: nickname))
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !self.awayIds.isEmpty else { return }
            self.requestNudgesIfNeeded()
            self.startNudgeRetries()
            // Still missing after a while: they really are away, not just reconnecting.
            try? await Task.sleep(for: .seconds(25))
            self.reconnectingIds.removeAll()
        }
    }

    /// Nudges can miss (out of range for a moment); keep asking while someone is away.
    /// The router doesn't repeat a nudge that was already delivered.
    private func startNudgeRetries() {
        guard nudgeRetry == nil else { return }
        nudgeRetryGeneration += 1
        let generation = nudgeRetryGeneration
        nudgeRetry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.nudgeRetryInterval)
                guard let self, !self.awayIds.isEmpty, self.lobby?.phase == .playing else { break }
                self.requestNudgesIfNeeded()
            }
            // Only clear our own handle; a newer loop may have replaced it.
            if let self, self.nudgeRetryGeneration == generation { self.nudgeRetry = nil }
        }
    }

    /// Ends the match for someone who didn't come back in time. Internal for tests.
    func awayTimedOut(_ identity: PeerIdentity) {
        guard awayIds.remove(identity.id) != nil else { return }
        awayTimers.removeValue(forKey: identity.id)?.cancel()
        memberLeft(identity, reason: "\(identity.nickname) didn't come back.")
    }

    private func peerIdentified(_ identity: PeerIdentity) {
        reconnectingIds.remove(identity.id)
        if awayIds.remove(identity.id) != nil {
            awayTimers.removeValue(forKey: identity.id)?.cancel()
            if isHost {
                if lobby?.phase == .lobby { broadcastRoster() }
                resync(identity.id)
            } else if let lobby, identity.id == lobby.hostId {
                // A move relayed while the host was away has been applied (or rejected) by now;
                // the catch-up snapshot shows which.
                pendingMoveId = nil
                relayedMoveDelivered = false
                // Ask explicitly too, in case the host's resend arrived before we recognized it.
                session.send(.joinRequest(LobbyRefPayload(lobbyId: lobby.id)), sessionId: lobby.id, to: [identity.id])
                // A rematch vote cast while the host was away never reached them.
                if rematchVotes.contains(localId) {
                    session.send(.rematchRequest(LobbyRefPayload(lobbyId: lobby.id)), sessionId: lobby.id, to: [identity.id])
                }
            }
        }
        // Let newly connected peers see an open lobby, and repeat an invitation sent while they were away.
        guard let lobby, isHost, lobby.phase == .lobby, !lobby.isFull, lobby.player(identity.id) == nil,
              !removedIds.contains(identity.id) else { return }
        let invited = invitedIds.contains(identity.id) ? identity.id : nil
        // A private lobby is only offered to people who were invited.
        guard lobby.isOpen || invited != nil else { return }
        session.send(.lobbyOffer(offerPayload(for: lobby, invitedPlayerId: invited)), sessionId: lobby.id, to: [identity.id])
    }

    /// Handles a member leaving or dropping, from either side of the host relationship.
    private func memberLeft(_ identity: PeerIdentity, reason: String) {
        guard var lobby, lobby.player(identity.id) != nil else { return }

        if identity.id == lobby.hostId {
            // No host migration: the match is over.
            switch lobby.phase {
            case .ended:
                return
            case .lobby, .playing:
                lobby.phase = .ended("\(reason) The host has gone, so this game has ended.")
                self.lobby = lobby
                pendingMoveId = nil
            }
            return
        }

        guard isHost else { return }
        switch lobby.phase {
        case .lobby:
            lobby.players.removeAll { $0.id == identity.id }
            self.lobby = lobby
            broadcastRoster()
            broadcastOffer()
        case .playing:
            if lobby.seats.contains(identity.id) {
                let message = "\(reason) The match has ended."
                session.send(.gameEvent(GameEventPayload(event: .matchEnded, message: message)), sessionId: lobby.id, to: otherMembers.filter { $0 != identity.id })
                lobby.phase = .ended(message)
                self.lobby = lobby
            }
        case .ended:
            break
        }
    }

    // MARK: - Host authority

    private func hostHandleMove(_ request: MoveRequestPayload, from playerId: String) {
        guard isHost, let lobby, lobby.phase == .playing, let state = authoritative, lobby.seats.contains(playerId) else { return }
        // Exactly-once: a repeated move id is dropped silently.
        guard seenMoveIds.insert(request.moveId).inserted else { return }
        // Call One!/Catch! race against turns by design, so they skip the revision check, and
        // a move based on the latest turn stays valid even if one of those landed meanwhile.
        let turnIndependent = GameEngine.isTurnIndependent(request.move)
        // A board nobody has seen yet can't be the basis of a move: a modified app claiming a
        // future revision would otherwise skip the check below.
        guard (0...revision).contains(request.baseRevision) else {
            return rejectMove(MoveErrorMessage.staleBoard, to: playerId)
        }
        guard request.baseRevision == revision || request.baseRevision >= turnRevision || turnIndependent else {
            return rejectMove(MoveErrorMessage.staleBoard, to: playerId)
        }
        do {
            let next = try GameEngine.apply(request.move, by: playerId, to: state)
            commit(next, revision: revision + 1)
            if !turnIndependent { turnRevision = revision }
        } catch {
            rejectMove(error.message, to: playerId)
        }
    }

    private func rejectMove(_ message: String, to playerId: String) {
        if playerId == localId {
            notice = message
        } else if let lobby {
            session.send(.gameEvent(GameEventPayload(event: .moveRejected, message: message)), sessionId: lobby.id, to: [playerId])
        }
    }

    private func startRematchIfAgreed() {
        guard isHost, let lobby, let state = authoritative, state.isFinished,
              Set(lobby.seats).isSubset(of: rematchVotes)
        else { return }
        rematchVotes = []
        seenMoveIds = []
        commit(GameEngine.rematch(from: state), revision: revision + 1)
        turnRevision = revision
    }

    /// Stores a new authoritative state and sends each seated player their projection.
    /// Players who are away miss the send and get `resync` when they return.
    private func commit(_ state: GameEngine.State, revision newRevision: Int) {
        guard let lobby else { return }
        let previous = snapshot
        authoritative = state
        revision = newRevision
        snapshot = GameEngine.projection(of: state, for: localId)
        if !state.isFinished { rematchVotes = [] }
        for playerId in lobby.seats where playerId != localId && !awayIds.contains(playerId) {
            sendSnapshot(of: state, to: playerId)
        }
        snapshotDidChange(from: previous)
    }

    private func sendSnapshot(of state: GameEngine.State, to playerId: String) {
        guard let lobby else { return }
        let view = GameEngine.projection(of: state, for: playerId)
        session.send(.stateSnapshot(StateSnapshotPayload(revision: revision, state: view)), sessionId: lobby.id, to: [playerId])
    }

    /// Catches a returning player up on everything they missed.
    private func resync(_ playerId: String) {
        guard isHost, let lobby, lobby.phase == .playing, lobby.seats.contains(playerId), let state = authoritative else { return }
        sendSnapshot(of: state, to: playerId)
        // Votes are attributed to their sender, so the host can only repeat its own.
        if rematchVotes.contains(localId) {
            session.send(.rematchRequest(LobbyRefPayload(lobbyId: lobby.id)), sessionId: lobby.id, to: [playerId])
        }
    }

    // MARK: - Turn tracking

    private func snapshotDidChange(from previous: GameStateSnapshot?) {
        guard let lobby, let snapshot else { return }
        let wasMine = previous?.awaitingPlayerIds.contains(localId) ?? false
        if !wasMine, snapshot.awaitingPlayerIds.contains(localId) {
            onTurnStarted?(lobby.gameType)
        }
        requestNudgesIfNeeded()
    }

    /// Asks the app to nudge anyone the match is waiting on who is away. Every device that
    /// notices asks; the nudge service and the receiving phone both rate-limit.
    private func requestNudgesIfNeeded() {
        // Bluetooth nudges reach nearby phones by mesh id; online seats have none.
        guard !suspendedLocally, let lobby, lobby.phase == .playing, !lobby.isOnline, let snapshot else { return }
        for playerId in snapshot.awaitingPlayerIds.intersection(awayIds) where playerId != localId {
            onNudgeNeeded?(playerId, lobby.gameType)
        }
    }

    // MARK: - Host broadcasting

    private var otherMembers: [String] {
        lobby?.players.map(\.id).filter { $0 != localId } ?? []
    }

    private func offerPayload(for lobby: Lobby, invitedPlayerId: String?) -> LobbyOfferPayload {
        LobbyOfferPayload(
            lobbyId: lobby.id,
            gameType: lobby.gameType,
            hostNickname: session.localIdentity.nickname,
            maxSeats: lobby.maxSeats,
            seatsTaken: lobby.players.count,
            invitedPlayerId: invitedPlayerId,
            cloudCode: lobby.cloudCode
        )
    }

    /// Advertises the lobby to every connected peer who isn't already in it.
    private func broadcastOffer() {
        guard let lobby, isHost, lobby.phase == .lobby, lobby.isOpen else { return }
        let outsiders = session.nearbyPlayers.map(\.id).filter { lobby.player($0) == nil && !removedIds.contains($0) }
        guard !outsiders.isEmpty else { return }
        session.send(.lobbyOffer(offerPayload(for: lobby, invitedPlayerId: nil)), sessionId: lobby.id, to: outsiders)
    }

    private func withdrawOffer(from recipients: [String]) {
        guard let lobby, !recipients.isEmpty else { return }
        session.send(.leave(LeavePayload(lobbyId: lobby.id)), sessionId: lobby.id, to: recipients)
    }

    private func broadcastRoster() {
        guard let lobby, isHost else { return }
        let roster = LobbyRosterPayload(lobbyId: lobby.id, gameType: lobby.gameType, maxSeats: lobby.maxSeats, players: lobby.players)
        session.send(.joinAccept(roster), sessionId: lobby.id, to: otherMembers)
    }

    private func resetMatch() {
        leaveCloudRoom(tellServer: false)
        // A lobby we were part of is never joinable again.
        if let id = lobby?.id { offers[id] = nil }
        lobby = nil
        snapshot = nil
        authoritative = nil
        revision = -1
        pendingMoveId = nil
        rematchVotes = []
        seenMoveIds = []
        invitedIds = []
        joiningLobbyId = nil
        awayIds = []
        reconnectingIds = []
        awayTimers.values.forEach { $0.cancel() }
        awayTimers = [:]
        nudgeRetry?.cancel()
        nudgeRetry = nil
        relayedMoveDelivered = false
        turnRevision = 0
        removedIds = []
    }

    // MARK: - Online

    /// After a relaunch, goes back to the online game this phone was in.
    func restoreOnlineGame() {
        // An invite link may already be joining another game; that one wins.
        guard lobby == nil, !isConnectingOnline, joiningLobbyId == nil, cloud != nil, let seat = cloudStore?.load() else { return }
        enterCloudRoom(seat)
    }

    private func enterCloudRoom(_ seat: CloudSeat) {
        guard lobby == nil, let cloud else { return }
        // Joining a new game gives up any older one still saved (say, an invite was opened
        // instead of returning to it), so nobody is left waiting for a player who moved on.
        if let old = cloudStore?.load(), old.code != seat.code {
            Task { await cloud.leaveRoom(old) }
        }
        cloudStore?.save(seat)
        cloudSeat = seat
        let me = session.localIdentity
        // A placeholder until the server's roster arrives a moment later.
        lobby = Lobby(
            id: UUID(),
            gameType: seat.game,
            hostId: seat.seat == "seat0" ? seat.seat : "",
            maxSeats: seat.maxSeats,
            players: [LobbyPlayer(id: seat.seat, nickname: me.nickname, isReady: true, isHost: seat.seat == "seat0")],
            cloudCode: seat.code
        )
        snapshot = nil
        revision = -1
        invitedIds = []
        cloudConnection = cloud.openRoom(seat) { [weak self] event in
            self?.handleCloud(event)
        }
        // Nearby friends see it in their list too, and join it through the service.
        broadcastOffer()
    }

    /// Ends this phone's part in the online room. `tellServer`: the player chose to leave, so
    /// the seat is given up (mid-game that ends the match for everyone, like a phone host).
    private func leaveCloudRoom(tellServer: Bool) {
        guard let connection = cloudConnection else {
            if cloudSeat != nil { cloudStore?.clear() }
            cloudSeat = nil
            return
        }
        if tellServer {
            // Over HTTPS too, so leaving isn't lost when the socket is down or reconnecting.
            if let seat = cloudSeat, let cloud { Task { await cloud.leaveRoom(seat) } }
            connection.send(.leave)
            // Give the message a moment to go out before the socket closes.
            Task {
                try? await Task.sleep(for: .seconds(2))
                connection.close()
            }
        } else {
            connection.close()
        }
        if tellServer || isEnded { cloudStore?.clear() }
        cloudConnection = nil
        cloudSeat = nil
        isCloudConnected = false
        pendingCloudMove = nil
    }

    private var isEnded: Bool {
        if case .ended = lobby?.phase { return true }
        return false
    }

    /// The app came on screen or left it. Off screen, the online game's server notifies us
    /// (instead of assuming we're watching) until we're back.
    func appVisibilityChanged(active: Bool) {
        guard active != appIsActive else { return }
        appIsActive = active
        cloudConnection?.send(active ? .here : .away)
    }

    /// Internal for tests.
    func handleCloud(_ event: CloudRoomEvent) {
        guard lobby?.isOnline == true else { return }
        switch event {
        case .connected:
            isCloudConnected = true
            // A fresh connection starts "here" with no push address; bring the server up to date.
            if let pushToken { cloudConnection?.send(.push(token: pushToken.token, sandbox: pushToken.sandbox)) }
            DebugTrace.log("push: connected; token \(pushToken == nil ? "none" : "sent"), app \(appIsActive ? "on screen" : "away")")
            if !appIsActive { cloudConnection?.send(.away) }
            // A move whose answer was lost with the old connection: the same id is safe to resend.
            if let pendingCloudMove { cloudConnection?.send(.move(pendingCloudMove)) }
        case .disconnected:
            isCloudConnected = false
        case .removed:
            if let code = lobby?.cloudCode { removedFromCodes.insert(code) }
            isCloudConnected = false
            cloudStore?.clear()
            cloudConnection = nil
            pendingMoveId = nil
            pendingCloudMove = nil
            if var lobby {
                lobby.phase = .ended("The host removed you from this game.")
                self.lobby = lobby
            }
        case .roomGone:
            isCloudConnected = false
            cloudStore?.clear()
            cloudConnection = nil
            pendingMoveId = nil
            pendingCloudMove = nil
            if var lobby, !isEnded {
                lobby.phase = .ended("This online game has ended.")
                self.lobby = lobby
            }
        case .message(.roster(let roster)):
            receiveCloudRoster(roster)
        case .message(.snapshot(let revision, let view)):
            receiveCloudSnapshot(view, revision: revision)
        case .message(.result(let result)):
            guard result.moveId == pendingMoveId?.uuidString else { return }
            pendingMoveId = nil
            pendingCloudMove = nil
            if !result.ok {
                notice = result.error == "staleBoard" ? MoveErrorMessage.staleBoard : (result.message ?? "That move wasn't accepted.")
            }
        case .message(.error(let error)):
            switch error {
            case "notEnoughPlayers": notice = "Waiting for more players to join."
            case "notAllowed": notice = "Only the host can start the game."
            default: break
            }
        case .message(.other):
            break
        }
    }

    private func receiveCloudRoster(_ roster: CloudRoster) {
        guard var lobby, lobby.cloudCode == roster.code, roster.you == localId else { return }
        let wasLobby = lobby.phase == .lobby, wasHost = isHost
        lobby.hostId = roster.organizer
        lobby.isOpen = roster.open ?? false
        // Names from the server get the same cleaning and filtering as names seen nearby.
        lobby.players = roster.players.map { player in
            let nickname = player.seat == localId
                ? session.localIdentity.nickname
                : session.filter.safeNickname(Nickname.sanitize(player.nickname) ?? "Player")
            return LobbyPlayer(id: player.seat, nickname: nickname, isReady: true, isHost: player.seat == roster.organizer)
        }
        awayIds = Set(roster.players.filter { !$0.connected && $0.seat != localId }.map(\.seat))
        rematchVotes = Set(roster.rematchVotes)
        switch roster.phase {
        case .lobby:
            break
        case .playing:
            if lobby.phase == .lobby {
                lobby.phase = .playing
                lobby.seats = lobby.players.map(\.id)
            }
        case .ended:
            let message = roster.endedMessage.map { session.filter.check($0).isAllowed ? $0 : "The game ended." } ?? "The game ended."
            lobby.phase = .ended(message)
            pendingMoveId = nil
            pendingCloudMove = nil
            cloudStore?.clear()
        }
        self.lobby = lobby
        if lobby.phase == .lobby {
            if isHost { broadcastOffer() }
        } else if wasLobby, wasHost || isHost {
            // Started or over: take it off nearby friends' lists.
            withdrawOffer(from: session.nearbyPlayers.map(\.id))
        }
    }

    private func receiveCloudSnapshot(_ view: GameStateSnapshot, revision newRevision: Int) {
        // The same structural checks as a snapshot from a phone host, so even a broken or
        // impersonated server can't hand the game screens a board they'd crash on.
        guard var lobby, newRevision > revision, view.gameType == lobby.gameType, view.isStructurallyValid,
              view.playerIds.contains(localId), Self.isAddressedToMe(view, localId: localId)
        else { return }
        if lobby.phase == .lobby { lobby.phase = .playing }
        lobby.seats = view.playerIds
        self.lobby = lobby
        let previous = snapshot
        snapshot = view
        revision = newRevision
        // A pending move stays pending until its own result arrives: someone else's move (say a
        // Call One! racing ours) mustn't clear it, or a refusal would go unexplained and the
        // move wouldn't be resent after a reconnect.
        if previous?.isFinished == true, !view.isFinished { rematchVotes = [] }
        // The first state after joining or a relaunch isn't news: the game screen is opening
        // anyway, so it doesn't announce "your turn" (that arrived as a banner on top of it).
        if previous != nil { snapshotDidChange(from: previous) }
    }
}

extension GameCoordinator {
    /// Hidden-information snapshots must be this player's own view.
    /// The chat for the match in progress: the people at this table, and nobody else.
    ///
    /// Nil when there's no lobby, or nobody else has joined yet — the caller falls back to
    /// the conversation list. See `SessionManager.matchConversation(lobbyId:named:players:)`.
    @discardableResult
    func matchConversation() -> ChatStore.Conversation? {
        // Online seats aren't mesh contacts, so there's no table chat for them.
        guard let lobby, !lobby.isOnline else { return nil }
        let players = lobby.players.map { PeerIdentity(id: $0.id, nickname: $0.nickname) }
        return session.matchConversation(lobbyId: lobby.id, named: lobby.gameType.displayName, players: players)
    }

    static func isAddressedToMe(_ snapshot: GameStateSnapshot, localId: String) -> Bool {
        if case .colorMatch(let table) = snapshot { return table.viewer == localId }
        return true
    }
}

enum MoveErrorMessage {
    static let staleBoard = "The board changed before your move arrived. Try again."
}
