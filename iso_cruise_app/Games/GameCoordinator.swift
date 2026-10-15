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
/// - If the host disappears, the match ends; there is no host migration.
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
    /// Short-lived feedback such as "That square is already taken."
    var notice: String?

    // Host-only authoritative state.
    @ObservationIgnored private var authoritative: GameEngine.State?
    @ObservationIgnored private var seenMoveIds: Set<UUID> = []

    init(session: SessionManager) {
        self.session = session
        session.onGameEnvelope = { [weak self] envelope, identity in
            self?.handle(envelope, from: identity)
        }
        session.onPeerDisconnected = { [weak self] identity in
            self?.peerDisconnected(identity)
        }
        session.onPeerIdentified = { [weak self] identity in
            self?.peerIdentified(identity)
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

    var canStart: Bool {
        guard let lobby, isHost, lobby.phase == .lobby, lobby.gameType.isPlayable else { return false }
        return lobby.players.count >= lobby.gameType.minPlayers
            && lobby.players.allSatisfy { $0.isHost || $0.isReady }
    }

    // MARK: - Local actions

    func hostLobby(_ gameType: GameType) {
        guard lobby == nil, gameType.isPlayable else { return }
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

    /// Sends a direct invitation to one connected peer.
    func invite(_ identity: PeerIdentity) {
        guard let lobby, isHost, lobby.phase == .lobby, !lobby.isFull, lobby.player(identity.id) == nil else { return }
        invitedIds.insert(identity.id)
        session.send(.lobbyOffer(offerPayload(for: lobby, invitedPlayerId: identity.id)), sessionId: lobby.id, to: [identity.id])
    }

    func join(_ offer: Offer) {
        guard lobby == nil, !offer.isFull else { return }
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

        let others = otherMembers
        session.send(.startGame(StartGamePayload(lobbyId: lobby.id, gameType: lobby.gameType, seats: lobby.seats)), sessionId: lobby.id, to: others)
        withdrawOffer(from: session.connectedIdentities.map(\.id).filter { !others.contains($0) })
        commit(state, revision: 0)
    }

    func play(_ move: GameMove) {
        guard let lobby, lobby.phase == .playing, pendingMoveId == nil else { return }
        let request = MoveRequestPayload(moveId: UUID(), baseRevision: revision, move: move)
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

    /// Clears an ended match so the user can return to the Games list.
    func dismissEndedMatch() {
        guard case .ended = lobby?.phase else { return }
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
        case .hello, .chat, .heartbeat, .error:
            break
        }
    }

    private func receiveOffer(_ offer: LobbyOfferPayload, from identity: PeerIdentity) {
        // The advertised host must be the sender; ignore offers we can't play.
        guard offer.gameType.isPlayable else { return }
        let named = Offer(payload: offer, host: identity)
        switch offer.invitedPlayerId {
        case nil:
            offers[offer.lobbyId] = named
        case localId?:
            offers[offer.lobbyId] = named
            if lobby == nil, joiningLobbyId == nil, invitation == nil {
                invitation = named
            } else if invitation?.id != offer.lobbyId {
                session.send(.joinReject(JoinRejectPayload(lobbyId: offer.lobbyId, reason: .declined)), sessionId: offer.lobbyId, to: [identity.id])
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
            broadcastRoster()
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
        // Names relayed by the host get the same safety filtering as names we see directly.
        let players = roster.players.map { player in
            var safe = player
            safe.nickname = session.filter.safeNickname(player.nickname)
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
        if isHost, lobby?.id == reject.lobbyId, reject.reason == .declined {
            invitedIds.remove(identity.id)
            notice = "\(identity.nickname) declined your invitation."
            return
        }
        guard joiningLobbyId == reject.lobbyId, offers[reject.lobbyId]?.host.id == identity.id else { return }
        joiningLobbyId = nil
        notice = switch reject.reason {
        case .lobbyFull: "That game is full."
        case .alreadyStarted: "That game has already started."
        case .notFound, .declined: "That game is no longer available."
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
        guard let lobby, !isHost, sessionId == lobby.id, lobby.hostId == identity.id,
              lobby.phase == .playing,
              payload.state.gameType == lobby.gameType,
              Set(payload.state.playerIds) == Set(lobby.seats),
              Self.isAddressedToMe(payload.state, localId: localId),
              payload.revision > revision // ignore stale or duplicate revisions
        else { return }
        let wasFinished = snapshot?.isFinished ?? false
        snapshot = payload.state
        revision = payload.revision
        pendingMoveId = nil
        if wasFinished, !payload.state.isFinished { rematchVotes = [] }
    }

    private func receiveEvent(_ event: GameEventPayload, sessionId: UUID?, from identity: PeerIdentity) {
        guard var lobby, sessionId == lobby.id, lobby.hostId == identity.id else { return }
        switch event.event {
        case .moveRejected:
            pendingMoveId = nil
            notice = event.message
        case .matchEnded, .hostEnded:
            lobby.phase = .ended(event.message)
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

    private func peerDisconnected(_ identity: PeerIdentity) {
        offers = offers.filter { $0.value.host.id != identity.id }
        if invitation?.host.id == identity.id { invitation = nil }
        if let joining = joiningLobbyId, offers[joining] == nil {
            joiningLobbyId = nil
        }
        invitedIds.remove(identity.id)
        memberLeft(identity, reason: "\(identity.nickname) disconnected.")
    }

    private func peerIdentified(_ identity: PeerIdentity) {
        // Let newly connected peers see an open lobby.
        guard let lobby, isHost, lobby.phase == .lobby, !lobby.isFull else { return }
        session.send(.lobbyOffer(offerPayload(for: lobby, invitedPlayerId: nil)), sessionId: lobby.id, to: [identity.id])
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
        // Call One!/Catch! race against turns by design, so they skip the revision check;
        // the host applies whichever arrives first.
        guard request.baseRevision == revision || GameEngine.isTurnIndependent(request.move) else {
            return rejectMove(MoveErrorMessage.staleBoard, to: playerId)
        }
        do {
            let next = try GameEngine.apply(request.move, by: playerId, to: state)
            commit(next, revision: revision + 1)
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
    }

    /// Stores a new authoritative state and sends each seated player their projection.
    private func commit(_ state: GameEngine.State, revision newRevision: Int) {
        guard let lobby else { return }
        authoritative = state
        revision = newRevision
        snapshot = GameEngine.projection(of: state, for: localId)
        if !state.isFinished { rematchVotes = [] }
        for playerId in lobby.seats where playerId != localId {
            let view = GameEngine.projection(of: state, for: playerId)
            session.send(.stateSnapshot(StateSnapshotPayload(revision: newRevision, state: view)), sessionId: lobby.id, to: [playerId])
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
