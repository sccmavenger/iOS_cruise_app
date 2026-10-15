import Foundation

/// Connects the session, the games, notifications, and the Bluetooth `NudgeService`.
///
/// Outgoing: seals nudges with the per-pair key and sends them to people who are away:
/// chat previews, "your turn", and moves for an away host. Topics are retried by the
/// caller until delivered, then not repeated for a while.
///
/// Incoming: opens each write (rejecting anything not sealed by a known, unblocked
/// person), drops replays, and turns it into a notification or a move for the host.
final class NudgeRouter {
    private let session: SessionManager
    private let games: GameCoordinator
    private let notifications: NotificationManager
    private let nudges: NudgeService

    private var delivered = Nudge.RateLimiter(interval: Nudge.deliveredInterval)
    private var received = Nudge.RateLimiter(interval: Nudge.receiveInterval)
    private var replay = Nudge.ReplayGuard()
    /// "person|topic" pairs with a delivery in progress, so retries don't pile up.
    private var inFlight: Set<String> = []

    init(session: SessionManager, games: GameCoordinator, notifications: NotificationManager, nudges: NudgeService) {
        self.session = session
        self.games = games
        self.notifications = notifications
        self.nudges = nudges

        session.onChatReceived = { [notifications] identity, text in
            notifications.chatReceived(from: identity, text: text)
        }
        session.onChatQueuedForAway = { [weak self] ids, text in
            for id in ids { self?.send(.chat(preview: Nudge.preview(of: text)), to: id) }
        }
        session.onPeerReturned = { [weak self] identity in
            self?.delivered.forget(identity.id)
        }
        games.onTurnStarted = { [notifications] game in
            notifications.turnStarted(in: game)
        }
        games.onNudgeNeeded = { [weak self] playerId, game in
            self?.send(.turn(game), to: playerId)
        }
        games.onRelayMove = { [weak self] hostId, lobbyId, request, completion in
            guard let self else { return completion(false) }
            self.send(.move(lobbyId: lobbyId, request: request), to: hostId, completion: completion)
        }
        nudges.onReceive = { [weak self] data in
            self?.receive(data)
        }
    }

    /// Starts advertising this phone's doorbell (asks for Bluetooth permission the first time).
    func start() {
        nudges.start(localId: session.localId)
    }

    // MARK: - Outgoing

    func send(_ kind: Nudge.Kind, to personId: String, completion: ((Bool) -> Void)? = nil) {
        let topic = kind.topic
        if let topic {
            let interval = topic == "chat" ? Nudge.chatDeliveredInterval : Nudge.deliveredInterval
            guard delivered.isAllowed(personId, topic, at: .now, interval: interval),
                  inFlight.insert("\(personId)|\(topic)").inserted
            else { completion?(false); return }
        }
        guard let key = session.nudgeKey(sealingTo: personId),
              let data = Nudge.seal(Nudge.Message(id: UUID(), sentAt: .now, kind: kind), from: session.localId, key: key)
        else {
            if let topic { inFlight.remove("\(personId)|\(topic)") }
            completion?(false)
            return
        }
        nudges.send(data, to: personId) { [weak self] ok in
            if let self, let topic {
                self.inFlight.remove("\(personId)|\(topic)")
                if ok { self.delivered.record(personId, topic, at: .now) }
            }
            completion?(ok)
        }
    }

    // MARK: - Incoming

    func receive(_ data: Data) {
        guard let (from, message) = Nudge.open(data, key: { [session] in session.nudgeKey(openingFrom: $0) }),
              replay.isNew(message.id),
              let sender = session.knownIdentities[from]
        else { return }

        switch message.kind {
        case .chat(let preview):
            // If they're connected, the real message arrives over the session instead.
            guard !session.isConnected(from), received.allow(from, "chat", at: .now) else { return }
            // Filtered again here, like every message this phone shows.
            let safePreview = preview.flatMap { session.filter.check($0).isAllowed ? $0 : nil }
            notifications.chatNudgeReceived(from: sender, preview: safePreview)
        case .turn(let game):
            guard !session.isConnected(from), received.allow(from, "turn-\(game.rawValue)", at: .now) else { return }
            notifications.turnNudgeReceived(in: game, from: sender)
        case .move(let lobbyId, let request):
            games.receiveRelayedMove(request, lobbyId: lobbyId, from: from)
        }
    }
}
