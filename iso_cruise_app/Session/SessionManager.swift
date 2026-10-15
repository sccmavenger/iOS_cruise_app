import Foundation
import Observation
import os

/// A connected peer whose identity has been bound via the `hello` handshake.
struct PeerIdentity: Equatable, Hashable {
    let id: String
    var nickname: String

    var tag: String { Nickname.tag(for: id) }
    var labeledName: String { "\(nickname) #\(tag)" }
}

/// Owns the transport and is the single entry point for all inbound and outbound envelopes.
///
/// Responsibilities:
/// - peer discovery / invitation / connection bookkeeping for the UI
/// - binding each transport peer to exactly one announced identity
/// - rejecting malformed, spoofed, replayed, or flooding traffic
/// - routing chat to `ChatStore` and everything else to the game layer
@Observable
final class SessionManager {
    struct RemotePeer: Identifiable, Equatable {
        let key: PeerKey
        var displayName: String
        var connection: PeerConnectionState
        var isNearby: Bool
        var isInvited: Bool
        var identity: PeerIdentity?
        /// Set after a connected peer drops, so stray late packets can't revive it.
        var didDisconnect = false
        /// Blocked by this user: hidden from lists, traffic ignored, never sent to.
        var isBlocked = false

        var id: PeerKey { key }
        var shownName: String { identity?.labeledName ?? displayName }
    }

    struct Invitation: Identifiable, Equatable {
        let id: UUID
        let from: PeerKey
        let displayName: String
    }

    enum ChatSendResult: Equatable {
        case sent
        case empty
        case noRecipients
        case filtered(ContentFilter.Reason)
    }

    /// Why a connected peer went away.
    enum DropReason: Equatable {
        /// The link dropped: out of range, or their app went to the background.
        case connectionLost
        /// This user blocked them.
        case blocked
    }

    enum Status: Equatable {
        case idle
        case running(since: Date)
        case failed(String)
    }

    /// Per-peer inbound budget: at most this many envelopes per `rateWindow`.
    static let rateLimit = 40
    static let rateWindow: TimeInterval = 5
    private static let seenIdCapacity = 2_000
    /// Messages held for one away person; older ones are dropped.
    static let outboxLimit = 30
    static let outboxLifetime: TimeInterval = 15 * 60
    /// If the peer that should invite (see `reconnect`) hasn't after this long, invite anyway.
    static let reconnectFallback: Duration = .seconds(6)
    private static let logger = Logger(subsystem: "com.dannyguillory.cruiselan", category: "session")

    /// Random per-launch identifier announced to peers. Not tied to the device or the user.
    let localId = UUID().uuidString
    let chat = ChatStore()
    let profile: ProfileStore
    let safety: SafetyStore
    let filter: ContentFilter
    let trusted: TrustedPeersStore

    private(set) var peers: [PeerKey: RemotePeer] = [:]
    private(set) var invitations: [Invitation] = []
    private(set) var status: Status = .idle
    /// Count of inbound envelopes dropped by validation, surfaced for diagnostics.
    private(set) var rejectedEnvelopeCount = 0
    /// Everyone who completed the handshake since launch, even if they've since dropped.
    /// Used to recognize people who are away (app in the background) and may be nudged.
    private(set) var knownIdentities: [String: PeerIdentity] = [:]

    /// Game-layer hooks, installed by `GameCoordinator`.
    @ObservationIgnored var onGameEnvelope: ((Envelope, PeerIdentity) -> Void)?
    @ObservationIgnored var onPeerDisconnected: ((PeerIdentity, DropReason) -> Void)?
    @ObservationIgnored var onPeerIdentified: ((PeerIdentity) -> Void)?
    /// A chat message from someone else passed the safety filter and was added to the chat.
    @ObservationIgnored var onChatReceived: ((PeerIdentity, String) -> Void)?
    /// The local user sent a chat message while these known people were away.
    @ObservationIgnored var onChatQueuedForAway: (([String]) -> Void)?

    @ObservationIgnored private let transport: any PeerTransport
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var nextSequence = 0
    @ObservationIgnored private var seenIds: Set<UUID> = []
    @ObservationIgnored private var seenOrder: [UUID] = []
    @ObservationIgnored private var lastSequenceBySender: [String: Int] = [:]
    @ObservationIgnored private var recentArrivals: [PeerKey: [Date]] = [:]
    /// Filtered messages received per sender this session; drives auto-blocking.
    @ObservationIgnored private var filterStrikes: [String: Int] = [:]
    /// Chat this user sent while someone they'd connected with was away, by identity id.
    @ObservationIgnored private var outbox: [String: [(text: String, date: Date)]] = [:]
    @ObservationIgnored private let now: () -> Date

    init(
        transport: any PeerTransport,
        profile: ProfileStore,
        safety: SafetyStore = SafetyStore(),
        filter: ContentFilter = .shared,
        trusted: TrustedPeersStore = TrustedPeersStore(),
        now: @escaping () -> Date = { .now }
    ) {
        self.transport = transport
        self.profile = profile
        self.safety = safety
        self.filter = filter
        self.trusted = trusted
        self.now = now
        eventTask = Task { [weak self, events = transport.events] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    // MARK: - Derived state

    var connectedPeers: [RemotePeer] {
        peers.values.filter { $0.connection == .connected && !$0.isBlocked }.sorted { $0.shownName < $1.shownName }
    }

    var nearbyPeers: [RemotePeer] {
        peers.values.filter { $0.connection != .connected && $0.isNearby && !$0.isBlocked }.sorted { $0.displayName < $1.displayName }
    }

    /// Identities of connected peers that completed the handshake.
    var connectedIdentities: [PeerIdentity] {
        connectedPeers.compactMap(\.identity)
    }

    func identity(for id: String) -> PeerIdentity? {
        peers.values.first { $0.identity?.id == id }?.identity
    }

    func isConnected(_ identityId: String) -> Bool {
        connectedIdentities.contains { $0.id == identityId }
    }

    /// People this user has connected with since launch who aren't connected right now.
    var awayIdentityIds: [String] {
        knownIdentities.keys.filter { !isConnected($0) }.sorted()
    }

    var localIdentity: PeerIdentity {
        PeerIdentity(id: localId, nickname: profile.nickname ?? "Me")
    }

    // MARK: - Lifecycle

    func start() {
        guard let nickname = profile.nickname else { return }
        peers.removeAll()
        invitations.removeAll()
        transport.start(displayName: nickname)
    }

    func stop() {
        transport.stop()
        peers.removeAll()
        invitations.removeAll()
        status = .idle
    }

    /// iOS ends peer-to-peer sessions when an app goes to the background. Tear down
    /// cleanly so the game layer can mark people as away, then reconnect in `resume()`.
    func suspend() {
        guard status != .idle else { return }
        for (key, peer) in peers where peer.connection == .connected {
            handleStateChange(key: key, state: .notConnected, announce: false)
        }
        stop()
    }

    /// Restarts discovery after the app returns to the foreground; trusted peers reconnect on their own.
    func resume() {
        guard status == .idle else { return }
        start()
    }

    /// Restarts the transport so the new nickname is advertised.
    func nicknameDidChange() {
        stop()
        start()
    }

    // MARK: - User actions

    func invite(_ key: PeerKey) {
        guard var peer = peers[key], peer.connection == .notConnected else { return }
        peer.isInvited = true
        peers[key] = peer
        transport.invite(key)
    }

    func respond(to invitation: Invitation, accept: Bool) {
        invitations.removeAll { $0.id == invitation.id }
        transport.respond(toInvitation: invitation.id, accept: accept)
    }

    func disconnectAll() {
        // An explicit disconnect also stops automatic reconnection.
        trusted.forgetAll()
        transport.disconnectAll()
    }

    /// Sends a chat message to every connected peer after running the safety filter.
    @discardableResult
    func sendChat(_ rawText: String) -> ChatSendResult {
        let text = String(rawText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(EnvelopeCodec.maxChatCharacters))
        guard !text.isEmpty else { return .empty }
        if case .blocked(let reason) = filter.check(text) { return .filtered(reason) }
        let away = awayIdentityIds
        let envelope = send(.chat(ChatPayload(text: text)))
        guard envelope != nil || !away.isEmpty else { return .noRecipients }
        // Hold a copy for people who are away; they get it when they reconnect.
        let cutoff = now().addingTimeInterval(-Self.outboxLifetime)
        for id in away {
            var held = (outbox[id] ?? []).filter { $0.date > cutoff }
            held.append((text, now()))
            outbox[id] = Array(held.suffix(Self.outboxLimit))
        }
        if !away.isEmpty { onChatQueuedForAway?(away) }
        chat.appendText(id: envelope?.id ?? UUID(), senderId: localId, senderName: localIdentity.nickname, text: text, isLocal: true)
        return .sent
    }

    private func deliverOutbox(to identity: PeerIdentity) {
        guard let held = outbox.removeValue(forKey: identity.id) else { return }
        let cutoff = now().addingTimeInterval(-Self.outboxLifetime)
        for message in held where message.date > cutoff {
            send(.chat(ChatPayload(text: message.text)), to: [identity.id])
        }
    }

    // MARK: - Blocking

    /// Blocks a peer on this device: their traffic is ignored, they disappear from lists,
    /// their invitations are declined automatically, and their past messages are removed.
    /// Remembered across launches by device fingerprint.
    func block(_ key: PeerKey) {
        guard var peer = peers[key], !peer.isBlocked else { return }
        let name = peer.identity?.labeledName ?? peer.displayName
        if let fingerprint = transport.fingerprint(for: key) {
            safety.block(fingerprint: fingerprint, name: name)
            trusted.forget(fingerprint)
        }
        peer.isBlocked = true
        peers[key] = peer
        invitations.removeAll { $0.from == key }
        if let identity = peer.identity {
            knownIdentities[identity.id] = nil
            outbox[identity.id] = nil
            chat.removeMessages(from: identity.id)
            onPeerDisconnected?(identity, .blocked)
        }
        chat.appendSystem("You blocked \(name). You won't see their messages or invitations.")
    }

    func block(identityId: String) {
        guard let key = peers.values.first(where: { $0.identity?.id == identityId })?.key else { return }
        block(key)
    }

    func unblock(_ person: SafetyStore.BlockedPerson) {
        safety.unblock(person)
        for (key, var peer) in peers where transport.fingerprint(for: key) == person.fingerprint {
            peer.isBlocked = false
            peers[key] = peer
        }
    }

    /// Plain-text report body for the Mail composer. Contains only what's on screen.
    func reportBody(about identityId: String, message: String?, reason: String) -> String {
        let name = identity(for: identityId)?.labeledName ?? "Unknown"
        var lines = [
            "CruiseLAN safety report",
            "Reason: \(reason)",
            "Person: \(name)",
            "Reported by: \(localIdentity.labeledName)",
            "Time: \(now().formatted(date: .abbreviated, time: .shortened))",
            "App version: \(Bundle.main.versionString)",
        ]
        if let message { lines.append("Message: \"\(message)\"") }
        return lines.joined(separator: "\n")
    }

    /// Wraps a payload in an envelope and sends it. `recipients` are identity ids; `nil` means all connected peers.
    @discardableResult
    func send(_ payload: Envelope.Payload, sessionId: UUID? = nil, to recipients: [String]? = nil) -> Envelope? {
        let envelope = Envelope(sessionId: sessionId, senderId: localId, sequence: makeSequence(), payload: payload)
        let keys: [PeerKey] = connectedPeers.compactMap { peer in
            guard let recipients else { return peer.key }
            guard let id = peer.identity?.id, recipients.contains(id) else { return nil }
            return peer.key
        }
        guard !keys.isEmpty else { return nil }
        do {
            let data = try EnvelopeCodec.encode(envelope)
            try transport.send(data, to: keys)
            return envelope
        } catch {
            Self.logger.error("Send failed for \(envelope.kind.rawValue, privacy: .public)")
            return nil
        }
    }

    private func makeSequence() -> Int {
        nextSequence += 1
        return nextSequence
    }

    // MARK: - Transport events

    func handle(_ event: TransportEvent) {
        switch event {
        case .started:
            status = .running(since: now())

        case .startFailed(let message):
            status = .failed(message)

        case .peerFound(let key, let rawName):
            let name = filter.safeNickname(rawName)
            var peer = peers[key] ?? RemotePeer(key: key, displayName: name, connection: .notConnected, isNearby: true, isInvited: false)
            peer.displayName = name
            peer.isNearby = true
            peer.isBlocked = peer.isBlocked || safety.isBlocked(transport.fingerprint(for: key))
            peers[key] = peer
            if !peer.isBlocked, peer.connection == .notConnected, trusted.isTrusted(transport.fingerprint(for: key)) {
                reconnect(key, peerName: rawName)
            }

        case .peerLost(let key):
            guard var peer = peers[key] else { return }
            if peer.connection == .notConnected {
                peers[key] = nil
            } else {
                peer.isNearby = false
                peers[key] = peer
            }

        case .invitationReceived(let invitationId, let key, let rawName):
            if peers[key]?.isBlocked == true || safety.isBlocked(transport.fingerprint(for: key)) {
                transport.respond(toInvitation: invitationId, accept: false)
                return
            }
            // Someone this user already accepted is coming back: no need to ask again.
            if trusted.isTrusted(transport.fingerprint(for: key)) {
                transport.respond(toInvitation: invitationId, accept: true)
                return
            }
            invitations.append(Invitation(id: invitationId, from: key, displayName: filter.safeNickname(rawName)))

        case .invitationExpired(let invitationId):
            invitations.removeAll { $0.id == invitationId }

        case .peerStateChanged(let key, let state):
            handleStateChange(key: key, state: state)

        case .received(let data, let key):
            handleIncoming(data, from: key)
        }
    }

    /// Re-invites a trusted peer. Only one side invites, chosen by comparing nicknames, so
    /// the two invitations don't collide; the other side accepts automatically. If the
    /// expected inviter doesn't (for example, it hasn't spotted us yet), invite after a pause.
    private func reconnect(_ key: PeerKey, peerName: String) {
        let mine = profile.nickname ?? ""
        if mine < peerName {
            invite(key)
            return
        }
        let delay: Duration = mine == peerName ? .milliseconds(Int.random(in: 300...2_000)) : Self.reconnectFallback
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, let peer = self.peers[key], peer.connection == .notConnected, peer.isNearby, !peer.isBlocked else { return }
            self.invite(key)
        }
    }

    private func handleStateChange(key: PeerKey, state: PeerConnectionState, announce: Bool = true) {
        var peer = peers[key] ?? RemotePeer(key: key, displayName: "Unknown", connection: state, isNearby: false, isInvited: false)
        let previous = peer.connection
        peer.connection = state
        if state != .connecting { peer.isInvited = false }
        if state == .connecting || state == .connected { peer.didDisconnect = false }

        if state == .connected, previous != .connected {
            peers[key] = peer
            sendHello(to: key)
            return
        }

        if state == .notConnected, previous == .connected {
            if let identity = peer.identity {
                if announce { chat.appendSystem("\(identity.labeledName) disconnected") }
                onPeerDisconnected?(identity, .connectionLost)
            }
            peer.identity = nil
            peer.didDisconnect = true
            recentArrivals[key] = nil
        }

        if state == .notConnected, !peer.isNearby {
            peers[key] = nil
        } else {
            peers[key] = peer
        }
    }

    private func sendHello(to key: PeerKey) {
        let hello = Envelope(
            senderId: localId,
            sequence: makeSequence(),
            payload: .hello(HelloPayload(nickname: localIdentity.nickname, protocolVersion: Envelope.currentVersion))
        )
        guard let data = try? EnvelopeCodec.encode(hello) else { return }
        try? transport.send(data, to: [key])
    }

    // MARK: - Inbound validation

    private func handleIncoming(_ data: Data, from key: PeerKey) {
        // The transport only delivers data from peers inside the session, but its
        // "connected" callback can trail the peer's first message (typically `hello`).
        // Treat arriving data as proof of connection so that first message isn't lost.
        if let existing = peers[key] {
            if existing.connection != .connected, !existing.didDisconnect {
                handleStateChange(key: key, state: .connected)
            }
        } else {
            handleStateChange(key: key, state: .connected)
        }
        guard var peer = peers[key], peer.connection == .connected else { return reject("unknown peer") }
        guard !peer.isBlocked else { return }
        guard allowArrival(from: key) else { return reject("rate limited") }

        let envelope: Envelope
        do {
            envelope = try EnvelopeCodec.decode(data)
        } catch {
            return reject("decode failed")
        }

        // Replay / duplicate protection, applied before any routing.
        guard !seenIds.contains(envelope.id) else { return reject("duplicate id") }
        if let last = lastSequenceBySender[envelope.senderId], envelope.sequence <= last {
            return reject("stale sequence")
        }

        if case .hello(let hello) = envelope.payload {
            // An identity may be bound once per connection and never claimed by two peers.
            guard peer.identity == nil,
                  envelope.senderId != localId,
                  !peers.values.contains(where: { $0.identity?.id == envelope.senderId }),
                  let nickname = Nickname.sanitize(hello.nickname)
            else { return reject("bad hello") }
            remember(envelope)
            let identity = PeerIdentity(id: envelope.senderId, nickname: filter.safeNickname(nickname))
            peer.identity = identity
            peers[key] = peer
            let returning = knownIdentities[identity.id] != nil
            knownIdentities[identity.id] = identity
            trusted.trust(transport.fingerprint(for: key))
            chat.appendSystem(returning ? "\(identity.labeledName) is back" : "\(identity.labeledName) connected")
            deliverOutbox(to: identity)
            onPeerIdentified?(identity)
            return
        }

        // Everything else must come from the identity bound to this transport peer.
        guard let identity = peer.identity, identity.id == envelope.senderId else {
            return reject("sender mismatch")
        }
        remember(envelope)

        switch envelope.payload {
        case .chat(let chatPayload):
            // Re-check on receipt: a modified sender could skip its own filter.
            guard filter.check(chatPayload.text).isAllowed else {
                let strikes = (filterStrikes[identity.id] ?? 0) + 1
                filterStrikes[identity.id] = strikes
                chat.appendSystem("A message from \(identity.labeledName) was hidden by the safety filter.")
                if strikes >= SafetyConfig.autoBlockThreshold {
                    block(key)
                }
                return
            }
            chat.appendText(id: envelope.id, senderId: identity.id, senderName: identity.nickname, text: chatPayload.text, isLocal: false)
            onChatReceived?(identity, chatPayload.text)
        case .heartbeat:
            break
        case .hello:
            break
        default:
            onGameEnvelope?(envelope, identity)
        }
    }

    private func remember(_ envelope: Envelope) {
        lastSequenceBySender[envelope.senderId] = envelope.sequence
        seenIds.insert(envelope.id)
        seenOrder.append(envelope.id)
        if seenOrder.count > Self.seenIdCapacity {
            seenIds.remove(seenOrder.removeFirst())
        }
    }

    private func allowArrival(from key: PeerKey) -> Bool {
        let current = now()
        var arrivals = (recentArrivals[key] ?? []).filter { current.timeIntervalSince($0) < Self.rateWindow }
        guard arrivals.count < Self.rateLimit else {
            recentArrivals[key] = arrivals
            return false
        }
        arrivals.append(current)
        recentArrivals[key] = arrivals
        return true
    }

    private func reject(_ reason: StaticString) {
        rejectedEnvelopeCount += 1
        Self.logger.notice("Rejected inbound envelope: \(reason, privacy: .public)")
    }
}
