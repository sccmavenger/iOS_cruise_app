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
        let hostId: String
        let maxSeats: Int
        var players: [LobbyPlayer]
        var phase: Phase = .lobby
        /// Seat order once the game starts.
        var seats: [String] = []

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

    init(session: SessionManager) {
        self.session = session
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

    var localId: String { session.localId }
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
        return session.identity(for: playerId)?.nickname ?? "Player"
    }

    /// It's the local player's move (or they must answer a prompt) in a running match.
    var isAwaitingMe: Bool {
        lobby?.phase == .playing && snapshot?.awaitingPlayerIds.contains(localId) == true
    }

    var isHostAway: Bool {
        guard let lobby, !isHost else { return false }
        return awayIds.contains(lobby.hostId)
    }

    var canStart: Bool {
        guard let lobby, isHost, lobby.phase == .lobby, lobby.gameType.isPlayable else { return false }
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

    func hostLobby(_ gameType: GameType) {
        guard lobby == nil, joiningLobbyId == nil else {
            notice = "Finish or leave your current game first."
            return
        }
        guard gameType.isPlayable else { return }
        let me = session.localIdentity
        lobby = Lobby(
            id: UUID(),
            gameType: gameType,
            hostId: me.id,
            maxSeats: gameType.maxPlayers,
            players: [LobbyPlayer(id: me.id, nickname: me.nickname, isReady: true, isHost: true)]
        )
        invitedIds = []
        broadcastOffer()
    }

    /// Invites one person. Connected people get the invitation now; someone who is away
    /// gets a notification, and the invitation when they reconnect.
    func invite(_ identity: PeerIdentity) {
        guard let lobby, isHost, lobby.phase == .lobby, !lobby.isFull, lobby.player(identity.id) == nil else { return }
        invitedIds.insert(identity.id)
        if session.isConnected(identity.id) {
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
        guard let lobby, !isHost, lobby.phase == .lobby else { return }
        session.send(.ready(ReadyPayload(lobbyId: lobby.id, isReady: ready)), sessionId: lobby.id, to: [lobby.hostId])
    }

    func startGame() {
        guard canStart, var lobby, let state = GameEngine.newGame(lobby.gameType, seats: lobby.players.map(\.id)) else { return }
        lobby.seats = lobby.players.map(\.id)
        lobby.phase = .playing
        self.lobby = lobby
        seenMoveIds = []
        rematchVotes = []
        turnRevision = 0

        let others = otherMembers
        session.send(.startGame(StartGamePayload(lobbyId: lobby.id, gameType: lobby.gameType, seats: lobby.seats)), sessionId: lobby.id, to: others)
        withdrawOffer(from: session.connectedIdentities.map(\.id).filter { !others.contains($0) })
        commit(state, revision: 0)
    }

    func play(_ move: GameMove) {
        guard let lobby, lobby.phase == .playing, pendingMoveId == nil else { return }
        let request = MoveRequestPayload(moveId: UUID(), baseRevision: revision, move: move)
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
        session.send(.rematchRequest(LobbyRefPayload(lobbyId: lobby.id)), sessionId: lobby.id, to: otherMembers)
        if isHost { startRematchIfAgreed() }
    }

    func leave() {
        guard let lobby else { return }
        var recipients = otherMembers
        if isHost {
            // Withdraw the public offer from everyone, not just members.
            recipients = session.connectedIdentities.map(\.id)
        }
        session.send(.leave(LeavePayload(lobbyId: lobby.id)), sessionId: lobby.id, to: recipients)
        resetMatch()
    }

    /// Clears an ended match so the user can return to the Games list. A guest tells the
    /// host, in case the host still thinks the game is on.
    func dismissEndedMatch() {
        guard let lobby, case .ended = lobby.phase else { return }
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
        case .hello, .chat, .heartbeat, .error, .presence, .proof:
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
        guard isHost, var lobby, lobby.id == ref.lobbyId else {
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
        guard suspendedLocally else { return }
        suspendedLocally = false
        let ids = awayIds
        for id in ids where awayTimers[id] == nil {
            let nickname = lobby?.player(id)?.nickname ?? session.knownIdentities[id]?.nickname ?? "Player"
            startAwayTimer(for: PeerIdentity(id: id, nickname: nickname))
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !self.awayIds.isEmpty else { return }
            self.requestNudgesIfNeeded()
            self.startNudgeRetries()
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
        guard let lobby, isHost, lobby.phase == .lobby, !lobby.isFull, lobby.player(identity.id) == nil else { return }
        let invited = invitedIds.contains(identity.id) ? identity.id : nil
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
        guard !suspendedLocally, let lobby, lobby.phase == .playing, let snapshot else { return }
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
            invitedPlayerId: invitedPlayerId
        )
    }

    /// Advertises the lobby to every connected peer who isn't already in it.
    private func broadcastOffer() {
        guard let lobby, isHost, lobby.phase == .lobby else { return }
        let outsiders = session.connectedIdentities.map(\.id).filter { lobby.player($0) == nil }
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
        awayTimers.values.forEach { $0.cancel() }
        awayTimers = [:]
        nudgeRetry?.cancel()
        nudgeRetry = nil
        relayedMoveDelivered = false
        turnRevision = 0
    }
}

extension GameCoordinator {
    /// Hidden-information snapshots must be this player's own view.
    static func isAddressedToMe(_ snapshot: GameStateSnapshot, localId: String) -> Bool {
        if case .colorMatch(let table) = snapshot { return table.viewer == localId }
        return true
    }
}

enum MoveErrorMessage {
    static let staleBoard = "The board changed before your move arrived. Try again."
}
