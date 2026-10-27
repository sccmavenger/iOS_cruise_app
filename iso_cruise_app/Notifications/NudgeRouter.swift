import Foundation

/// Connects the session, the games, notifications, and the Bluetooth `NudgeService`.
///
/// Outgoing: seals nudges with the per-pair key and sends them to people who are away:
/// chat previews, "your turn", game invites, and moves for an away host. Topics are retried by the
/// caller until delivered, then not repeated for a while.
///
/// Incoming: opens each write (rejecting anything not sealed by a known, unblocked
/// person), drops replays, and turns it into a notification or a move for the host.
final class NudgeRouter {
    private let session: SessionManager
    private let games: GameCoordinator
    private let notifications: NotificationManager
    private let nudges: NudgeService

    /// Exposed so `NetworkPathProbe` can read Bluetooth power state without creating a
    /// second `CBManager`.
    var service: NudgeService { nudges }

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

        session.onChatReceived = { [weak self] identity, text, conversationId in
            // With chat switched off there's nowhere to read it, so no badge or banner.
            guard let self, AppFeatures.chatEnabled else { return }
            self.notifications.setBadge(self.session.chat.totalUnread)
            // No banner for the conversation that's on screen, or while the chat list is showing.
            guard self.session.chat.visibleConversationId != conversationId,
                  !(self.notifications.isAppActive && self.notifications.isChatListOnScreen)
            else { return }
            self.notifications.chatReceived(title: self.title(for: identity, in: conversationId), text: text, conversationId: conversationId)
        }
        session.onChatQueuedForAway = { [weak self] ids, text, conversationId, messageId in
            self?.sendChat(text, messageId: messageId, conversationId: conversationId, to: ids)
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
        games.onInviteAway = { [weak self] playerId, game in
            self?.send(.invite(game), to: playerId)
        }
        games.onRelayMove = { [weak self] hostId, lobbyId, request, completion in
            guard let self else { return completion(false) }
            self.send(.move(lobbyId: lobbyId, request: request), to: hostId, completion: completion)
        }
        nudges.onReceive = { [weak self] data in
            self?.receive(data) ?? false
        }
    }

    /// Starts advertising this phone's doorbell (asks for Bluetooth permission the first time).
    func start() {
        nudges.start(localId: session.localId)
    }

    /// The app is leaving the foreground: sends in progress can't finish, so report them as failed.
    func appWillBackground() {
        nudges.failQueued()
    }

    // MARK: - Outgoing

    /// Sends a chat message to people who are away: the whole message if it fits in one
    /// Bluetooth write (it lands in their chat right away), otherwise a notification preview.
    /// When every attempt has finished, the message in this phone's chat says what happened.
    private func sendChat(_ text: String, messageId: UUID, conversationId: UUID, to ids: [String]) {
        let wireConversation = conversationId == ChatStore.everyoneId ? nil : conversationId
        var results: [(whole: Bool, ok: Bool)] = []
        let finish = { [weak self] in
            guard let self, results.count == ids.count else { return }
            let note: ChatStore.DeliveryNote
            if results.allSatisfy({ $0.ok && $0.whole }) {
                note = .bluetooth
            } else if results.contains(where: \.ok) {
                note = .notified
            } else {
                note = .unreachable
            }
            self.session.chat.setDeliveryNote(note, for: messageId)
        }
        for person in ids {
            let whole = Nudge.Kind.message(id: messageId, text: text, conversationId: wireConversation)
            let fits = session.nudgeKey(sealingTo: person).flatMap {
                Nudge.seal(Nudge.Message(id: UUID(), sentAt: .now, kind: whole), from: session.localId, key: $0)
            } != nil
            let kind = fits ? whole : .chat(preview: Nudge.preview(of: text), conversationId: wireConversation)
            send(kind, to: person) { ok in
                results.append((fits, ok))
                finish()
            }
        }
    }

    func send(_ kind: Nudge.Kind, to personId: String, completion: ((Bool) -> Void)? = nil) {
        let topic = kind.topic
        if let topic {
            let interval = topic.hasPrefix("chat") ? Nudge.chatDeliveredInterval : Nudge.deliveredInterval
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

    /// "Mia" for one-on-one and Everyone chats, "Mia · Pool Crew" for groups.
    private func title(for sender: PeerIdentity, in conversationId: UUID) -> String {
        guard let conversation = session.chat.conversation(conversationId), conversation.kind == .group else {
            return sender.nickname
        }
        return "\(sender.nickname) · \(session.chat.title(of: conversation, localId: session.localId))"
    }

    // MARK: - Incoming

    /// Handles one incoming write. Returns `false` if it was rejected, so the sender's phone
    /// learns the nudge didn't land (rather than thinking it was delivered).
    @discardableResult
    func receive(_ data: Data) -> Bool {
        let keys = Dictionary(uniqueKeysWithValues: session.knownIdentities.keys.compactMap { id in
            session.nudgeKey(openingFrom: id).map { (id, $0) }
        })
        guard let (from, message) = Nudge.open(data, keys: keys),
              replay.isNew(message.id),
              let sender = session.knownIdentities[from]
        else { return false }

        switch message.kind {
        case .message(let id, let text, let conversationId):
            // Filed in the chat now; filtered and checked like a message from the mesh.
            guard let target = session.receiveBluetoothChat(id: id, text: text, conversationId: conversationId, from: from) else {
                // A group we don't know yet: still let them know something arrived.
                if conversationId != nil, session.filter.check(text).isAllowed {
                    notifications.chatNudgeReceived(title: sender.nickname, preview: Nudge.preview(of: text), conversationId: nil)
                }
                return true
            }
            notifications.setBadge(session.chat.totalUnread)
            if notifications.isAppActive, session.chat.visibleConversationId == target { return true }
            notifications.chatReceived(title: title(for: sender, in: target), text: text, conversationId: target)
        case .chat(let preview, let conversationId):
            // If they're connected, the real message arrives over the session instead.
            guard !session.isConnected(from) else { return true }
            guard received.allow(from, message.kind.topic ?? "chat", at: .now) else { return true }
            // Filtered again here, like every message this phone shows.
            let safePreview = preview.flatMap { session.filter.check($0).isAllowed ? $0 : nil }
            // nil is "Everyone". A conversation we don't know yet (a brand-new group) opens the
            // chat list; the real message lands in the right place when they reconnect.
            let target = conversationId.flatMap { session.chat.conversation($0)?.id }
                ?? (conversationId == nil ? ChatStore.everyoneId : nil)
            // No banner for the chat that's open right now.
            if let target, notifications.isAppActive, session.chat.visibleConversationId == target { return true }
            notifications.chatNudgeReceived(title: target.map { title(for: sender, in: $0) } ?? sender.nickname,
                                            preview: safePreview, conversationId: target)
        case .turn(let game):
            guard !session.isConnected(from), received.allow(from, "turn-\(game.rawValue)", at: .now) else { return true }
            notifications.turnNudgeReceived(in: game, from: sender)
        case .invite(let game):
            guard received.allow(from, "invite-\(game.rawValue)", at: .now) else { return true }
            notifications.inviteNudgeReceived(to: game, from: sender)
        case .move(let lobbyId, let request):
            return games.receiveRelayedMove(request, lobbyId: lobbyId, from: from)
        }
        return true
    }
}
