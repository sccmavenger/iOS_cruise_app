import CryptoKit
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
        /// The name exactly as advertised, used to agree with the other phone on who reconnects.
        var advertisedName = ""
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
        /// This phone's own app went to the background, so everyone dropped at once.
        case localSuspend
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
    static let outboxLifetime: TimeInterval = 4 * 60 * 60
    /// Someone who dropped longer ago than this is no longer shown or treated as "away"
    /// (long enough for a movie or a show), and what we kept about them is forgotten.
    static let awayLifetime: TimeInterval = 4 * 60 * 60
    /// Most people remembered at once; protects against a peer cycling through fake ids.
    static let maxKnownIdentities = 64
    /// New groups one person may add us to per minute.
    static let groupCreationLimit = 5
    /// How long a returning id has to prove itself before it's ignored.
    static let proofTimeout: Duration = .seconds(15)
    /// If the peer that should invite (see `reconnect`) hasn't after this long, invite anyway.
    static let reconnectFallback: Duration = .seconds(3)
    /// Time for the "stepping away" message to leave before the transport is torn down.
    static let stepAwayGrace: Duration = .milliseconds(300)
    private static let logger = Logger(subsystem: "com.dannyguillory.cruiselan", category: "session")

    /// Random identifier announced to peers. Not tied to the device or the user. Kept for
    /// a few hours (see `IdentityStore`) so a relaunch in the background can still receive nudges.
    let localId: String
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
    /// Known people whose app said it was going to the background (shown as "away").
    private(set) var steppedAwayIds: Set<String> = []

    /// Game-layer hooks, installed by `GameCoordinator`.
    @ObservationIgnored var onGameEnvelope: ((Envelope, PeerIdentity) -> Void)?
    @ObservationIgnored var onPeerDisconnected: ((PeerIdentity, DropReason) -> Void)?
    @ObservationIgnored var onPeerIdentified: ((PeerIdentity) -> Void)?
    /// A chat message from someone else passed the safety filter and was added to a conversation.
    @ObservationIgnored var onChatReceived: ((PeerIdentity, String, UUID) -> Void)?
    /// The local user sent a chat message (already filtered) in a conversation while these known people were away.
    @ObservationIgnored var onChatQueuedForAway: (([String], String, UUID) -> Void)?
    /// Someone known since launch reconnected (for example, after their app was in the background).
    @ObservationIgnored var onPeerReturned: ((PeerIdentity) -> Void)?
    /// The app came back to the foreground after `suspend()`.
    @ObservationIgnored var onResumed: (() -> Void)?

    @ObservationIgnored private let transport: any PeerTransport
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    /// Starts at the current time in milliseconds, so it keeps increasing across relaunches
    /// that reuse the same id (peers drop envelopes whose sequence goes backwards).
    @ObservationIgnored private var nextSequence: Int
    @ObservationIgnored private var seenIds: Set<UUID> = []
    @ObservationIgnored private var seenOrder: [UUID] = []
    /// Replay protection is per connection, so one peer can't poison another's sequence.
    @ObservationIgnored private var lastSequenceByKey: [PeerKey: Int] = [:]
    /// A hello from someone we've met before, waiting for their proof (see `ProofPayload`).
    @ObservationIgnored private var pendingHellos: [PeerKey: (identity: PeerIdentity, hello: HelloPayload)] = [:]
    /// The nonce we put in our hello on each connection.
    @ObservationIgnored private var helloNonces: [PeerKey: String] = [:]
    /// Device fingerprint each known identity connected from, so they can be blocked while away.
    @ObservationIgnored private var fingerprintByIdentity: [String: String] = [:]
    /// Connections this user approved (invited, accepted, or auto-reconnected). Only these become trusted.
    @ObservationIgnored private var approvedKeys: Set<PeerKey> = []
    @ObservationIgnored private var reconnectTasks: [PeerKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var groupCreations: [String: [Date]] = [:]
    /// After `stop()`, transport events still in flight belong to the old session; ignore them until `.started`.
    @ObservationIgnored private var discardingStaleEvents = false
    @ObservationIgnored private var transportRunning = false
    @ObservationIgnored private var identityCreatedAt: Date
    @ObservationIgnored private var recentArrivals: [PeerKey: [Date]] = [:]
    /// Filtered messages received per sender this session; drives auto-blocking.
    @ObservationIgnored private var filterStrikes: [String: Int] = [:]
    /// Chat this user sent while someone they'd connected with was away, by identity id.
    @ObservationIgnored private var outbox: [String: [(text: String, date: Date, conversation: ConversationRef?)]] = [:]
    /// Bluetooth nudge keys (see `HelloPayload.nudgeKey`). `issued` is what this device
    /// handed to a transport peer in its hello; once that peer's identity is known it
    /// becomes `inboundNudgeKeys` (they encrypt to us). `outboundNudgeKeys` are the keys
    /// peers handed us (we encrypt to them). Kept after a disconnect: that's when they're needed.
    @ObservationIgnored private var issuedNudgeKeys: [PeerKey: SymmetricKey] = [:]
    @ObservationIgnored private var inboundNudgeKeys: [String: SymmetricKey] = [:]
    @ObservationIgnored private var outboundNudgeKeys: [String: SymmetricKey] = [:]
    @ObservationIgnored private var stepAwayPending = false
    /// When each known person last dropped.
    private(set) var droppedAt: [String: Date] = [:]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let identityStore: IdentityStore?

    init(
        transport: any PeerTransport,
        profile: ProfileStore,
        safety: SafetyStore = SafetyStore(),
        filter: ContentFilter = .shared,
        trusted: TrustedPeersStore = TrustedPeersStore(),
        identity: IdentityStore? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        self.transport = transport
        self.profile = profile
        self.safety = safety
        self.filter = filter
        self.trusted = trusted
        self.identityStore = identity
        self.now = now
        nextSequence = Int(now().timeIntervalSince1970 * 1000)
        let saved = identity?.load()
        localId = saved?.localId ?? UUID().uuidString
        identityCreatedAt = saved?.createdAt ?? saved?.lastActive ?? now()
        if let saved {
            // Friends from a few minutes ago are "away" until they reconnect.
            for (id, nickname) in saved.known {
                knownIdentities[id] = PeerIdentity(id: id, nickname: nickname)
                droppedAt[id] = saved.lastActive
            }
            inboundNudgeKeys = saved.inboundKeys.mapValues { SymmetricKey(data: $0) }
            outboundNudgeKeys = saved.outboundKeys.mapValues { SymmetricKey(data: $0) }
        }
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
        let cutoff = now().addingTimeInterval(-Self.awayLifetime)
        return knownIdentities.keys.filter { id in
            !isConnected(id) && (droppedAt[id].map { $0 > cutoff } ?? true)
        }.sorted()
    }

    /// Chat is possible while anyone is connected, or held for someone who is away.
    var canChat: Bool {
        !connectedIdentities.isEmpty || !awayIdentityIds.isEmpty
    }

    /// Whether a message in this conversation can go anywhere right now (or be held for someone away).
    func canChat(in conversationId: UUID) -> Bool {
        guard let conversation = chat.conversation(conversationId) else { return false }
        if conversation.kind == .everyone { return canChat }
        let away = Set(awayIdentityIds)
        return conversation.members.contains { $0.id != localId && (isConnected($0.id) || away.contains($0.id)) }
    }

    /// Whether anyone in the conversation is connected (otherwise messages are held).
    func hasConnectedMembers(in conversationId: UUID) -> Bool {
        guard let conversation = chat.conversation(conversationId) else { return false }
        if conversation.kind == .everyone { return !connectedIdentities.isEmpty }
        return conversation.members.contains { $0.id != localId && isConnected($0.id) }
    }

    /// People you can start a chat with: connected now, or away but known.
    var reachableIdentities: [PeerIdentity] {
        let ids = Set(connectedIdentities.map(\.id)).union(awayIdentityIds)
        return ids.compactMap { identity(for: $0) ?? knownIdentities[$0] }.sorted { $0.nickname < $1.nickname }
    }

    /// The one-on-one chat with someone, created if needed.
    @discardableResult
    func directConversation(with other: PeerIdentity) -> ChatStore.Conversation {
        chat.directConversation(local: ConversationMember(id: localId, nickname: localIdentity.nickname),
                                other: ConversationMember(id: other.id, nickname: other.nickname))
    }

    /// A new group with the chosen people plus the local user. The name is filtered like a nickname.
    @discardableResult
    func createGroup(name rawName: String?, with others: [PeerIdentity]) -> ChatStore.Conversation {
        let trimmed = rawName?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ConversationRef.maxNameLength)
        let name = trimmed.flatMap { $0.isEmpty || !filter.check(String($0)).isAllowed ? nil : String($0) }
        let members = [ConversationMember(id: localId, nickname: localIdentity.nickname)]
            + others.prefix(ConversationRef.maxMembers - 1).map { ConversationMember(id: $0.id, nickname: $0.nickname) }
        return chat.createGroup(name: name, members: members)
    }

    /// Saves the identity, keys, and known people so a background relaunch can still receive nudges.
    private func persistIdentity() {
        identityStore?.save(IdentityStore.Snapshot(
            localId: localId,
            lastActive: now(),
            createdAt: identityCreatedAt,
            known: knownIdentities.mapValues(\.nickname),
            inboundKeys: inboundNudgeKeys.mapValues { $0.withUnsafeBytes { Data($0) } },
            outboundKeys: outboundNudgeKeys.mapValues { $0.withUnsafeBytes { Data($0) } }
        ))
    }

    /// Key for encrypting a Bluetooth nudge to `identityId`.
    func nudgeKey(sealingTo identityId: String) -> SymmetricKey? {
        outboundNudgeKeys[identityId]
    }

    /// Key for opening a Bluetooth nudge from `identityId`.
    func nudgeKey(openingFrom identityId: String) -> SymmetricKey? {
        inboundNudgeKeys[identityId]
    }

    var localIdentity: PeerIdentity {
        PeerIdentity(id: localId, nickname: profile.nickname ?? "Me")
    }

    // MARK: - Lifecycle

    func start() {
        guard let nickname = profile.nickname, !transportRunning else { return }
        transportRunning = true
        clearConnectionState()
        transport.start(displayName: nickname)
    }

    func stop() {
        transport.stop()
        transportRunning = false
        discardingStaleEvents = true
        clearConnectionState()
        status = .idle
    }

    private func clearConnectionState() {
        peers.removeAll()
        invitations.removeAll()
        reconnectTasks.values.forEach { $0.cancel() }
        reconnectTasks.removeAll()
        pendingHellos.removeAll()
        helloNonces.removeAll()
        issuedNudgeKeys.removeAll()
        lastSequenceByKey.removeAll()
        approvedKeys.removeAll()
        recentArrivals.removeAll()
    }

    /// iOS ends peer-to-peer sessions when an app goes to the background. Tear down
    /// cleanly so the game layer can mark people as away, then reconnect in `resume()`.
    func suspend() {
        guard status != .idle || transportRunning else { return }
        for (key, peer) in peers where peer.connection == .connected {
            handleStateChange(key: key, state: .notConnected, announce: false, reason: .localSuspend)
        }
        stop()
    }

    /// Going to the background: tells connected peers we're stepping away (so they show
    /// "away", keep the game paused, and nudge us), gives that a moment to send, then suspends.
    func stepAway() async {
        persistIdentity()
        guard status != .idle || transportRunning else { return }
        send(.presence(PresencePayload(away: true)))
        stepAwayPending = true
        try? await Task.sleep(for: Self.stepAwayGrace)
        // The user may already be back.
        guard stepAwayPending else { return }
        stepAwayPending = false
        suspend()
    }

    /// Restarts discovery after the app returns to the foreground; trusted peers reconnect on their own.
    func resume() {
        if stepAwayPending {
            // Back before we actually left: undo the "stepping away" we announced.
            stepAwayPending = false
            send(.presence(PresencePayload(away: false)))
        }
        persistIdentity()
        if !transportRunning { start() }
        onResumed?()
    }

    /// Restarts the transport so the new nickname is advertised. Peers are reported as
    /// dropped first so games pause instead of getting out of sync.
    func nicknameDidChange() {
        suspend()
        start()
        onResumed?()
    }

    // MARK: - User actions

    @discardableResult
    func invite(_ key: PeerKey) -> Bool {
        guard var peer = peers[key], peer.connection == .notConnected, !peer.isInvited, !peer.isBlocked,
              transport.invite(key)
        else { return false }
        peer.isInvited = true
        peers[key] = peer
        approvedKeys.insert(key)
        return true
    }

    func respond(to invitation: Invitation, accept: Bool) {
        invitations.removeAll { $0.id == invitation.id }
        if accept { approvedKeys.insert(invitation.from) }
        transport.respond(toInvitation: invitation.id, accept: accept)
    }

    func disconnectAll() {
        // An explicit disconnect also stops automatic reconnection and forgets the saved identity.
        trusted.forgetAll()
        identityStore?.clear()
        reconnectTasks.values.forEach { $0.cancel() }
        reconnectTasks.removeAll()
        transport.disconnectAll()
    }

    /// Sends a chat message to a conversation's members after running the safety filter.
    /// "Everyone" goes to all connected people; one-on-one chats and groups go only to their members.
    @discardableResult
    func sendChat(_ rawText: String, in conversationId: UUID = ChatStore.everyoneId) -> ChatSendResult {
        let text = String(rawText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(EnvelopeCodec.maxChatCharacters))
        guard !text.isEmpty else { return .empty }
        if case .blocked(let reason) = filter.check(text) { return .filtered(reason) }
        guard let conversation = chat.conversation(conversationId) else { return .noRecipients }
        let members: Set<String>? = conversation.kind == .everyone ? nil : conversation.memberIds.subtracting([localId])
        let away = awayIdentityIds.filter { members?.contains($0) ?? true }
        let ref = conversation.ref
        let envelope = send(.chat(ChatPayload(text: text, conversation: ref)), to: members.map { Array($0) })
        guard envelope != nil || !away.isEmpty else { return .noRecipients }
        // Hold a copy for members who are away; they get it when they reconnect.
        let cutoff = now().addingTimeInterval(-Self.outboxLifetime)
        for id in away {
            var held = (outbox[id] ?? []).filter { $0.date > cutoff }
            held.append((text, now(), ref))
            outbox[id] = Array(held.suffix(Self.outboxLimit))
        }
        if !away.isEmpty { onChatQueuedForAway?(away, text, conversationId) }
        chat.appendText(id: envelope?.id ?? UUID(), senderId: localId, senderName: localIdentity.nickname, text: text,
                        isLocal: true, conversationId: conversationId)
        return .sent
    }

    private func deliverOutbox(to identity: PeerIdentity) {
        guard let held = outbox.removeValue(forKey: identity.id) else { return }
        let cutoff = now().addingTimeInterval(-Self.outboxLifetime)
        for message in held where message.date > cutoff {
            send(.chat(ChatPayload(text: message.text, conversation: message.conversation)), to: [identity.id])
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
            safety.block(fingerprint: fingerprint, name: name, identityId: peer.identity?.id)
            trusted.forget(fingerprint)
        }
        peer.isBlocked = true
        peers[key] = peer
        invitations.removeAll { $0.from == key }
        reconnectTasks.removeValue(forKey: key)?.cancel()
        if let identity = peer.identity {
            forget(identity.id)
            chat.removeMessages(from: identity.id)
            persistIdentity()
            onPeerDisconnected?(identity, .blocked)
        }
        chat.appendSystem("You blocked \(name). You won't see their messages or invitations.")
    }

    /// Blocks someone by id, whether they're connected or away. Always succeeds: when they're
    /// away, the block is recorded by id and remembered device, and applies when they come back.
    func block(identityId: String) {
        if let key = peers.values.first(where: { $0.identity?.id == identityId })?.key {
            block(key)
            return
        }
        guard !safety.isBlocked(identityId: identityId) else { return }
        let identity = knownIdentities[identityId]
        let name = identity?.labeledName ?? chat.messages.last(where: { $0.senderId == identityId })?.senderName ?? "Someone"
        let fingerprint = fingerprintByIdentity[identityId]
        safety.block(fingerprint: fingerprint ?? "id:\(identityId)", name: name, identityId: identityId)
        trusted.forget(fingerprint)
        for (key, var peer) in peers where fingerprint != nil && transport.fingerprint(for: key) == fingerprint {
            peer.isBlocked = true
            peers[key] = peer
            invitations.removeAll { $0.from == key }
        }
        forget(identityId)
        chat.removeMessages(from: identityId)
        persistIdentity()
        if let identity { onPeerDisconnected?(identity, .blocked) }
        chat.appendSystem("You blocked \(name). You won't see their messages or invitations.")
    }

    /// Drops everything kept about a person: keys, held messages, away state.
    private func forget(_ identityId: String) {
        knownIdentities[identityId] = nil
        outbox[identityId] = nil
        inboundNudgeKeys[identityId] = nil
        outboundNudgeKeys[identityId] = nil
        steppedAwayIds.remove(identityId)
        droppedAt[identityId] = nil
        groupCreations[identityId] = nil
    }

    /// Forgets people who left long ago, and the oldest ones beyond the cap.
    private func pruneDeparted() {
        let cutoff = now().addingTimeInterval(-Self.awayLifetime)
        for (id, dropped) in droppedAt where dropped < cutoff && !isConnected(id) {
            forget(id)
        }
        let overflow = knownIdentities.count - Self.maxKnownIdentities
        if overflow > 0 {
            let oldest = knownIdentities.keys
                .filter { !isConnected($0) }
                .sorted { (droppedAt[$0] ?? .distantPast) < (droppedAt[$1] ?? .distantPast) }
                .prefix(overflow)
            oldest.forEach(forget)
        }
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
        let name = identity(for: identityId)?.labeledName ?? knownIdentities[identityId]?.labeledName ?? "Unknown"
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
            discardingStaleEvents = false
            status = .running(since: now())
            return
        case .startFailed(let message):
            status = .failed(message)
            return
        default:
            break
        }
        // Events queued by the transport we just stopped would create ghost peers.
        guard !discardingStaleEvents else { return }

        switch event {
        case .started, .startFailed:
            break

        case .peerFound(let key, let rawName):
            let name = filter.safeNickname(rawName)
            var peer = peers[key] ?? RemotePeer(key: key, displayName: name, connection: .notConnected, isNearby: true, isInvited: false)
            peer.displayName = name
            peer.advertisedName = rawName
            peer.isNearby = true
            peer.isBlocked = peer.isBlocked || safety.isBlocked(transport.fingerprint(for: key))
            peers[key] = peer
            if !peer.isBlocked, peer.connection == .notConnected, trusted.isTrusted(transport.fingerprint(for: key)) {
                scheduleReconnect(key)
            }

        case .peerLost(let key):
            guard var peer = peers[key] else { return }
            if peer.connection == .notConnected {
                peers[key] = nil
                reconnectTasks.removeValue(forKey: key)?.cancel()
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
            // (If they claim an id we know, they still have to prove it after connecting.)
            if trusted.isTrusted(transport.fingerprint(for: key)) {
                approvedKeys.insert(key)
                transport.respond(toInvitation: invitationId, accept: true)
                return
            }
            invitations.removeAll { $0.from == key }
            invitations.append(Invitation(id: invitationId, from: key, displayName: filter.safeNickname(rawName)))

        case .invitationExpired(let invitationId):
            invitations.removeAll { $0.id == invitationId }

        case .peerStateChanged(let key, let state):
            handleStateChange(key: key, state: state)

        case .received(let data, let key):
            handleIncoming(data, from: key)
        }
    }

    /// Reconnects to a trusted peer, retrying with backoff. Only one side invites at a time,
    /// chosen by comparing nicknames, so the two invitations don't collide; the other side
    /// accepts automatically and invites itself only if the first side doesn't.
    private func scheduleReconnect(_ key: PeerKey, attempt: Int = 0) {
        reconnectTasks.removeValue(forKey: key)?.cancel()
        guard attempt < 6, let peer = peers[key], !peer.isBlocked,
              trusted.isTrusted(transport.fingerprint(for: key))
        else { return }
        let mine = profile.nickname ?? "", theirs = peer.advertisedName
        let backoff: Double = attempt == 0 ? 0 : min(30, pow(2, Double(attempt)))
        let deferToThem: Double = mine < theirs ? 0 : (mine == theirs ? Double.random(in: 0.3...2) : 3)
        let delay = backoff + deferToThem
        if delay == 0 { invite(key) }
        reconnectTasks[key] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.peers[key]?.connection == .notConnected else { return }
                self.invite(key)
            }
            // If this attempt didn't connect, try again a bit later.
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.peers[key]?.connection == .notConnected else { return }
            if var peer = self.peers[key] {
                peer.isInvited = false
                self.peers[key] = peer
            }
            self.scheduleReconnect(key, attempt: attempt + 1)
        }
    }

    private func handleStateChange(key: PeerKey, state: PeerConnectionState, announce: Bool = true, reason: DropReason = .connectionLost) {
        var peer = peers[key] ?? RemotePeer(key: key, displayName: "Unknown", connection: state, isNearby: false, isInvited: false)
        // Connections can arrive without discovery (another member brought them into the
        // session), so check the block list here too.
        peer.isBlocked = peer.isBlocked || safety.isBlocked(transport.fingerprint(for: key))
        let previous = peer.connection
        peer.connection = state
        if state != .connecting { peer.isInvited = false }
        if state == .connecting || state == .connected { peer.didDisconnect = false }

        if state == .connected, previous != .connected {
            reconnectTasks.removeValue(forKey: key)?.cancel()
            lastSequenceByKey[key] = nil
            peers[key] = peer
            if !peer.isBlocked { sendHello(to: key) }
            return
        }

        // Leaving "connected" in any direction ends the bound identity.
        if previous == .connected, state != .connected {
            if let identity = peer.identity {
                if announce {
                    chat.appendSystem(steppedAwayIds.contains(identity.id)
                                      ? "\(identity.labeledName) stepped away"
                                      : "\(identity.labeledName) disconnected")
                }
                droppedAt[identity.id] = now()
                onPeerDisconnected?(identity, reason)
            }
            peer.identity = nil
            peer.didDisconnect = true
            recentArrivals[key] = nil
            pendingHellos[key] = nil
            lastSequenceByKey[key] = nil
            if reason != .localSuspend, !peer.isBlocked, state == .notConnected {
                peers[key] = peer
                scheduleReconnect(key)
            }
            pruneDeparted()
        }

        if state == .notConnected, !peer.isNearby, reconnectTasks[key] == nil {
            peers[key] = nil
        } else {
            peers[key] = peer
        }
    }

    private func sendHello(to key: PeerKey) {
        let nudgeKey = SymmetricKey(size: .bits256)
        issuedNudgeKeys[key] = nudgeKey
        let encodedKey = nudgeKey.withUnsafeBytes { Data($0).base64EncodedString() }
        let nonce = SymmetricKey(size: SymmetricKeySize(bitCount: 128)).withUnsafeBytes { Data($0).base64EncodedString() }
        helloNonces[key] = nonce
        let hello = HelloPayload(nickname: localIdentity.nickname, protocolVersion: Envelope.currentVersion, nudgeKey: encodedKey, nonce: nonce)
        sendDirect(.hello(hello), to: key)
    }

    /// Sends to one transport peer, whether or not their identity is bound yet.
    private func sendDirect(_ payload: Envelope.Payload, to key: PeerKey) {
        let envelope = Envelope(senderId: localId, sequence: makeSequence(), payload: payload)
        guard let data = try? EnvelopeCodec.encode(envelope) else { return }
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

        // Replay / duplicate protection, applied before any routing. Sequences are tracked per
        // connection, so nobody can push another peer's sequence out of reach.
        guard !seenIds.contains(envelope.id) else { return reject("duplicate id") }
        if let last = lastSequenceByKey[key], envelope.sequence <= last {
            return reject("stale sequence")
        }

        if case .hello(let hello) = envelope.payload {
            // An identity may be bound once per connection and never claimed by two peers.
            guard peer.identity == nil, pendingHellos[key] == nil,
                  envelope.senderId != localId,
                  !peers.values.contains(where: { $0.identity?.id == envelope.senderId }),
                  let nickname = Nickname.sanitize(hello.nickname)
            else { return reject("bad hello") }
            remember(envelope, from: key)
            if safety.isBlocked(identityId: envelope.senderId) {
                peer.isBlocked = true
                peers[key] = peer
                return
            }
            let identity = PeerIdentity(id: envelope.senderId, nickname: filter.safeNickname(nickname))
            // If they gave us a key last time, prove we're the same phone, using that old key.
            if let theirKey = outboundNudgeKeys[identity.id], let nonce = hello.nonce {
                let mac = HMAC<SHA256>.authenticationCode(for: ProofPayload.message(prover: localId, verifier: identity.id, nonce: nonce), using: theirKey)
                sendDirect(.proof(ProofPayload(mac: Data(mac).base64EncodedString())), to: key)
            }
            // Someone we've met claims to be back: they must prove it the same way before we
            // give them their held messages, their game seat, or their chats.
            if knownIdentities[identity.id] != nil, inboundNudgeKeys[identity.id] != nil {
                pendingHellos[key] = (identity, hello)
                Task { [weak self] in
                    try? await Task.sleep(for: Self.proofTimeout)
                    guard let self, self.pendingHellos[key]?.identity.id == identity.id else { return }
                    self.pendingHellos[key] = nil
                    self.reject("proof timed out")
                }
                return
            }
            bind(identity, hello: hello, on: key)
            return
        }

        if case .proof(let proof) = envelope.payload {
            guard let pending = pendingHellos[key], pending.identity.id == envelope.senderId else { return }
            remember(envelope, from: key)
            guard let ourKey = inboundNudgeKeys[pending.identity.id],
                  let nonce = helloNonces[key],
                  let mac = Data(base64Encoded: proof.mac),
                  HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: ProofPayload.message(prover: pending.identity.id, verifier: localId, nonce: nonce), using: ourKey)
            else {
                pendingHellos[key] = nil
                return reject("bad proof")
            }
            pendingHellos[key] = nil
            bind(pending.identity, hello: pending.hello, on: key)
            return
        }

        // Everything else must come from the identity bound to this transport peer.
        guard let identity = peer.identity, identity.id == envelope.senderId else {
            return reject("sender mismatch")
        }
        remember(envelope, from: key)

        switch envelope.payload {
        case .chat(let chatPayload):
            // Re-check on receipt: a modified sender could skip its own filter.
            guard filter.check(chatPayload.text).isAllowed else {
                let strikeKey = fingerprintByIdentity[identity.id] ?? identity.id
                let strikes = (filterStrikes[strikeKey] ?? 0) + 1
                filterStrikes[strikeKey] = strikes
                chat.appendSystem("A message from \(identity.labeledName) was hidden by the safety filter.")
                if strikes >= SafetyConfig.autoBlockThreshold {
                    block(key)
                }
                return
            }
            var conversationId = ChatStore.everyoneId
            if let ref = chatPayload.conversation {
                // Only members may write to a conversation, and only to one we're in.
                let ids = Set(ref.members.map(\.id))
                guard ids.contains(identity.id), ids.contains(localId) else { return reject("not a member") }
                if chat.conversation(ref.id) == nil, ref.kind == .group, !allowNewGroup(from: identity.id) {
                    return reject("too many new groups")
                }
                // Names relayed by another phone get the same cleaning and filtering as names we see directly.
                var safe = ref
                safe.members = ref.members.map { member in
                    let shown = knownIdentities[member.id]?.nickname
                        ?? (member.id == localId ? localIdentity.nickname
                            : filter.safeNickname(Nickname.sanitize(member.nickname) ?? "Player"))
                    return ConversationMember(id: member.id, nickname: shown)
                }
                safe.name = ref.name
                    .flatMap { Nickname.sanitize($0, maxCharacters: ConversationRef.maxNameLength) }
                    .flatMap { filter.check($0).isAllowed ? $0 : nil }
                guard chat.adopt(safe) else { return reject("conversation mismatch") }
                conversationId = ref.id
            }
            chat.appendText(id: envelope.id, senderId: identity.id, senderName: identity.nickname, text: chatPayload.text,
                            isLocal: false, conversationId: conversationId)
            onChatReceived?(identity, chatPayload.text, conversationId)
        case .heartbeat:
            break
        case .presence(let presence):
            if presence.away {
                steppedAwayIds.insert(identity.id)
            } else {
                steppedAwayIds.remove(identity.id)
            }
        case .hello, .proof:
            break
        default:
            onGameEnvelope?(envelope, identity)
        }
    }

    /// Binds a verified identity to a connection.
    private func bind(_ identity: PeerIdentity, hello: HelloPayload, on key: PeerKey) {
        guard var peer = peers[key] else { return }
        peer.identity = identity
        peers[key] = peer
        let returning = knownIdentities[identity.id] != nil
        knownIdentities[identity.id] = identity
        steppedAwayIds.remove(identity.id)
        droppedAt[identity.id] = nil
        if let fingerprint = transport.fingerprint(for: key) {
            fingerprintByIdentity[identity.id] = fingerprint
        }
        // Fresh keys for this connection replace the old ones (which were only needed for the proof).
        if let issued = issuedNudgeKeys.removeValue(forKey: key) {
            inboundNudgeKeys[identity.id] = issued
        }
        if let encoded = hello.nudgeKey, let raw = Data(base64Encoded: encoded), raw.count == 32 {
            outboundNudgeKeys[identity.id] = SymmetricKey(data: raw)
        }
        // Only connections this user approved become trusted for automatic reconnection,
        // not people another member brought into the session.
        if approvedKeys.contains(key) {
            trusted.trust(transport.fingerprint(for: key))
        }
        chat.updateNickname(identity.nickname, for: identity.id)
        chat.appendSystem(returning ? "\(identity.labeledName) is back" : "\(identity.labeledName) connected")
        pruneDeparted()
        persistIdentity()
        deliverOutbox(to: identity)
        if returning { onPeerReturned?(identity) }
        onPeerIdentified?(identity)
    }

    private func allowNewGroup(from identityId: String) -> Bool {
        let recent = (groupCreations[identityId] ?? []).filter { now().timeIntervalSince($0) < 60 }
        guard recent.count < Self.groupCreationLimit else {
            groupCreations[identityId] = recent
            return false
        }
        groupCreations[identityId] = recent + [now()]
        return true
    }

    private func remember(_ envelope: Envelope, from key: PeerKey) {
        lastSequenceByKey[key] = envelope.sequence
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
