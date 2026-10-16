import CryptoKit
import Foundation
import Observation
import os

/// A contact (or someone heard on the mesh), by their mesh id.
struct PeerIdentity: Equatable, Hashable {
    let id: String
    var nickname: String

    var tag: String { Nickname.tag(for: id) }
    var labeledName: String { "\(nickname) #\(tag)" }
}

/// Owns the transport and runs the mesh. It's the single entry point for all inbound and
/// outbound traffic.
///
/// **How the mesh works** (see docs/decisions/mesh.md):
/// - **Links.** Phones link automatically to up to `MultipeerTransport.maxLinks` other
///   CruiseLAN phones in radio range. A link only carries traffic: it doesn't make two
///   people contacts, and nothing from a non-contact is ever shown.
/// - **Packets.** Everything travels as a signed `MeshPacket`. Each phone checks it
///   (signature, sender key, freshness, size), drops duplicates, rate-limits each sender,
///   and relays it to its other links until the hop limit runs out. Private content is
///   sealed for its recipients, so relays can't read it.
/// - **Directory.** Every phone floods a small signed `announce` every `announceInterval`,
///   so people several phones away can be found and sent a contact request.
/// - **Contacts.** Only people this user accepted (or who accepted this user) are
///   contacts. Chat, games, and notifications are only with contacts. A contact is
///   "connected" while they've been heard from recently (`reachableWindow`).
@Observable
final class SessionManager {
    /// A phone this one is (or could be) linked to directly.
    struct Link: Identifiable, Equatable {
        let key: PeerKey
        /// The advertised name, filtered for display.
        var displayName: String
        /// The name exactly as advertised, used to agree with the other phone on who invites.
        var advertisedName = ""
        var connection: PeerConnectionState
        var isNearby: Bool
        /// Whose phone it is, once its hello arrived.
        var identityId: String?
        var isBlocked = false

        var id: PeerKey { key }
    }

    /// Someone heard on the mesh, directly or through other phones.
    struct MeshPerson: Identifiable, Equatable {
        let id: String
        var nickname: String
        var agreementKey: Data
        var lastHeard: Date
        /// How many phones their last announcement passed through (0: linked to this phone).
        var hops: Int

        var identity: PeerIdentity { PeerIdentity(id: id, nickname: nickname) }
        var labeledName: String { identity.labeledName }
    }

    /// A contact request waiting for this user's answer.
    struct Invitation: Identifiable, Equatable {
        let id: UUID
        /// The requester's mesh id.
        let from: String
        let displayName: String
        let receivedAt: Date

        var tag: String { Nickname.tag(for: from) }
        var labeledName: String { "\(displayName) #\(tag)" }
    }

    enum ChatSendResult: Equatable {
        case sent
        case empty
        case noRecipients
        case filtered(ContentFilter.Reason)
    }

    /// Why a contact went away.
    enum DropReason: Equatable {
        /// Out of reach: out of range, or their app went to the background.
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

    // MARK: Limits

    /// Inbound packets allowed per link per `rateWindow` (a link carries other people's traffic too).
    static let linkRateLimit = 300
    /// Packets allowed per sender per `rateWindow`, at every phone. A flood from one
    /// phone stops at its first neighbor instead of crossing the whole mesh.
    static let originRateLimit = 60
    static let rateWindow: TimeInterval = 5
    /// Packet ids remembered for dropping duplicates. Packets older than
    /// `MeshPacket.freshness` are rejected anyway, so this only has to cover that window.
    private static let seenCapacity = 10_000
    /// How often each phone announces itself.
    static let announceInterval: TimeInterval = 20
    /// A contact heard from within this long counts as connected (more than two announcements).
    static let reachableWindow: TimeInterval = 50
    /// When a link to a contact drops, how long other paths get to show they're still reachable.
    static let dropGrace: TimeInterval = 8
    /// People heard within this long are listed as nearby.
    static let nearbyWindow: TimeInterval = 60
    /// Most people kept in the directory.
    static let maxDirectory = 300
    /// Unanswered contact requests expire after this long, on both phones.
    static let requestLifetime: TimeInterval = 2 * 60
    /// After this user declines someone's request, their next requests are ignored for this long.
    static let declineMute: TimeInterval = 10 * 60
    /// Most contact requests waiting for an answer; more are ignored.
    static let maxWaitingRequests = 5
    /// Messages held for one away contact; older ones are dropped.
    static let outboxLimit = 30
    static let outboxLifetime: TimeInterval = 4 * 60 * 60
    /// Someone who dropped longer ago than this is no longer shown or treated as "away"
    /// (long enough for a movie or a show), and what we kept about them is forgotten.
    static let awayLifetime: TimeInterval = 4 * 60 * 60
    /// Most contacts remembered at once.
    static let maxKnownIdentities = 64
    /// New groups one person may add us to per minute.
    static let groupCreationLimit = 5
    /// How long the phone that stayed waits for the returning phone to start a link before linking itself.
    static let stayedReconnectDelay: Double = 5
    /// A transport started this recently counts as "just came back" for choosing who links.
    /// The returning phone finds the other within a second or so of restarting.
    static let justStartedWindow: TimeInterval = 5
    /// Time for the "stepping away" message to leave before the transport is torn down.
    static let stepAwayGrace: Duration = .milliseconds(300)
    private static let logger = Logger(subsystem: "com.dannyguillory.cruiselan", category: "session")

    // MARK: State

    /// This phone's mesh identity (signing and key-agreement keys). Kept for a few hours
    /// (see `IdentityStore`) so a relaunch in the background can still receive nudges.
    @ObservationIgnored let meshIdentity: MeshIdentity
    /// Our mesh id: a fingerprint of our signing key.
    let localId: String
    let chat = ChatStore()
    let profile: ProfileStore
    let safety: SafetyStore
    let filter: ContentFilter

    private(set) var links: [PeerKey: Link] = [:]
    /// Everyone heard on the mesh recently, by id.
    private(set) var directory: [String: MeshPerson] = [:]
    /// Contacts: people this user connected with (accepted, or who accepted us), by id.
    private(set) var knownIdentities: [String: PeerIdentity] = [:]
    /// Contacts heard from recently: "connected".
    private(set) var reachableIds: Set<String> = []
    /// Contact requests waiting for this user's answer.
    private(set) var invitations: [Invitation] = []
    /// Contact requests this user sent, by id, with when they were sent.
    private(set) var outgoingRequests: [String: Date] = [:]
    private(set) var status: Status = .idle
    /// Count of inbound packets dropped by validation, surfaced for diagnostics.
    private(set) var rejectedEnvelopeCount = 0
    /// Contacts whose app said it was going to the background (shown as "away").
    private(set) var steppedAwayIds: Set<String> = []
    /// When each contact last dropped.
    private(set) var droppedAt: [String: Date] = [:]

    /// Game-layer hooks, installed by `GameCoordinator`.
    @ObservationIgnored var onGameEnvelope: ((Envelope, PeerIdentity) -> Void)?
    @ObservationIgnored var onPeerDisconnected: ((PeerIdentity, DropReason) -> Void)?
    @ObservationIgnored var onPeerIdentified: ((PeerIdentity) -> Void)?
    /// A chat message from a contact passed the safety filter and was added to a conversation.
    @ObservationIgnored var onChatReceived: ((PeerIdentity, String, UUID) -> Void)?
    /// The local user sent a chat message (already filtered) in a conversation while these contacts were away.
    @ObservationIgnored var onChatQueuedForAway: (([String], String, UUID) -> Void)?
    /// A contact reconnected (for example, after their app was in the background).
    @ObservationIgnored var onPeerReturned: ((PeerIdentity) -> Void)?
    /// The app came back to the foreground after `suspend()`.
    @ObservationIgnored var onResumed: (() -> Void)?
    /// Someone asked to connect (used to notify while the app isn't on screen).
    @ObservationIgnored var onContactRequest: ((Invitation) -> Void)?

    @ObservationIgnored private let transport: any PeerTransport
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Starts at the current time in milliseconds, so it keeps increasing across relaunches.
    @ObservationIgnored private var nextSequence: Int
    @ObservationIgnored private var seenPackets: Set<UUID> = []
    /// Highest hop budget each recent packet was relayed with (see the duplicate handling in `handleIncoming`).
    @ObservationIgnored private var relayedTTL: [UUID: Int] = [:]
    @ObservationIgnored private var seenOrder: [UUID] = []
    @ObservationIgnored private var linkArrivals: [PeerKey: [Date]] = [:]
    @ObservationIgnored private var originArrivals: [String: [Date]] = [:]
    /// Latest announcement packet from each person, replayed to new links so they learn the mesh quickly.
    @ObservationIgnored private var lastAnnounce: [String: (data: MeshPacket, receivedAt: Date)] = [:]
    @ObservationIgnored private var lastAnnouncedAt: Date = .distantPast
    @ObservationIgnored private var nextAnnounceDelay: TimeInterval = SessionManager.announceInterval
    /// `sentAt` of each contact's "stepping away" message, so older packets don't undo it.
    @ObservationIgnored private var steppedAwayAt: [String: Int64] = [:]
    /// Device fingerprint each identity linked from, so a block also refuses their phone's link.
    @ObservationIgnored private var fingerprintByIdentity: [String: String] = [:]
    @ObservationIgnored private var linkTasks: [PeerKey: Task<Void, Never>] = [:]
    /// People whose contact request this user declined, until when they're muted.
    @ObservationIgnored private var declinedUntil: [String: Date] = [:]
    @ObservationIgnored private var groupCreations: [String: [Date]] = [:]
    /// Filtered messages received per sender this session; drives auto-blocking.
    @ObservationIgnored private var filterStrikes: [String: Int] = [:]
    /// Chat this user sent while a contact was away, by identity id.
    @ObservationIgnored private var outbox: [String: [(text: String, date: Date, conversation: ConversationRef?, messageId: UUID)]] = [:]
    /// Bluetooth nudge keys. `inbound`: the key we gave each contact (they encrypt to us).
    /// `outbound`: the key each contact gave us (we encrypt to them).
    @ObservationIgnored private var inboundNudgeKeys: [String: SymmetricKey] = [:]
    @ObservationIgnored private var outboundNudgeKeys: [String: SymmetricKey] = [:]
    /// A key that arrived just before its sender became a contact (the two phones finish
    /// connecting a moment apart). Applied if they become a contact soon after.
    @ObservationIgnored private var earlyNudgeKeys: [String: (key: SymmetricKey, at: Date)] = [:]
    /// After `stop()`, transport events still in flight belong to the old run; ignore them until `.started`.
    @ObservationIgnored private var discardingStaleEvents = false
    @ObservationIgnored private var transportRunning = false
    @ObservationIgnored private var stepAwayPending = false
    @ObservationIgnored private var identityCreatedAt: Date
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let identityStore: IdentityStore?

    init(
        transport: any PeerTransport,
        profile: ProfileStore,
        safety: SafetyStore = SafetyStore(),
        filter: ContentFilter = .shared,
        identity: IdentityStore? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        self.transport = transport
        self.profile = profile
        self.safety = safety
        self.filter = filter
        self.identityStore = identity
        self.now = now
        nextSequence = Int(now().timeIntervalSince1970 * 1000)
        let saved = identity?.load()
        let restored = saved.flatMap { snapshot in
            snapshot.signingKey.flatMap { signing in
                snapshot.agreementKey.flatMap { MeshIdentity(signing: signing, agreement: $0) }
            }
        }
        // Without both saved keys (or from an older build), start over with a new identity.
        let usable = restored.flatMap { $0.id == saved?.localId ? $0 : nil }
        meshIdentity = usable ?? MeshIdentity()
        localId = meshIdentity.id
        identityCreatedAt = usable != nil ? (saved?.createdAt ?? saved?.lastActive ?? now()) : now()
        if usable != nil, let saved {
            // Contacts from a few minutes ago are "away" until they're heard from again.
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

    /// Contacts reachable now.
    var connectedIdentities: [PeerIdentity] {
        reachableIds.compactMap { knownIdentities[$0] }.sorted { $0.nickname < $1.nickname }
    }

    /// A connected contact, by id.
    func identity(for id: String) -> PeerIdentity? {
        reachableIds.contains(id) ? knownIdentities[id] : nil
    }

    func isConnected(_ identityId: String) -> Bool {
        reachableIds.contains(identityId)
    }

    func isContact(_ identityId: String) -> Bool {
        knownIdentities[identityId] != nil
    }

    /// Contacts who aren't reachable right now (away).
    var awayIdentityIds: [String] {
        let cutoff = now().addingTimeInterval(-Self.awayLifetime)
        return knownIdentities.keys.filter { id in
            !isConnected(id) && (droppedAt[id].map { $0 > cutoff } ?? true)
        }.sorted()
    }

    /// People heard on the mesh recently who aren't contacts: who can be sent a request.
    var discoveredPeople: [MeshPerson] {
        let cutoff = now().addingTimeInterval(-Self.nearbyWindow)
        let requesting = Set(invitations.map(\.from))
        return directory.values.filter { person in
            person.lastHeard > cutoff && !isContact(person.id) && !requesting.contains(person.id)
                && !safety.isBlocked(identityId: person.id)
        }.sorted { ($0.hops, $0.nickname) < ($1.hops, $1.nickname) }
    }

    /// Phones linked to this one right now (radio neighbors, contacts or not).
    var linkedCount: Int {
        links.values.filter { $0.connection == .connected }.count
    }

    /// Whether this user is waiting for an answer to a request sent to `identityId`.
    func isRequested(_ identityId: String) -> Bool {
        outgoingRequests[identityId].map { now().timeIntervalSince($0) < Self.requestLifetime } ?? false
    }

    /// Chat is possible while any contact is connected, or held for one who is away.
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
        return ids.compactMap { knownIdentities[$0] }.sorted { $0.nickname < $1.nickname }
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

    /// Saves the identity, keys, and contacts so a background relaunch can still receive nudges.
    private func persistIdentity() {
        identityStore?.save(IdentityStore.Snapshot(
            localId: localId,
            lastActive: now(),
            createdAt: identityCreatedAt,
            signingKey: meshIdentity.signingKey.rawRepresentation,
            agreementKey: meshIdentity.agreementKey.rawRepresentation,
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
        clearLinkState()
        transport.start(displayName: nickname)
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.tick()
            }
        }
    }

    func stop() {
        transport.stop()
        tickTask?.cancel()
        tickTask = nil
        transportRunning = false
        discardingStaleEvents = true
        clearLinkState()
        status = .idle
    }

    private func clearLinkState() {
        links.removeAll()
        linkTasks.values.forEach { $0.cancel() }
        linkTasks.removeAll()
        linkArrivals.removeAll()
    }

    /// Whether discovery is stopped because the app went to the background (see `suspend()`).
    var isSuspended: Bool { !transportRunning && profile.nickname != nil }

    /// iOS ends peer-to-peer links when an app goes to the background. Tear down cleanly so
    /// the game layer can mark people as away, then reconnect in `resume()`.
    func suspend() {
        guard status != .idle || transportRunning else { return }
        let lost = reachableIds
        reachableIds = []
        for id in lost {
            droppedAt[id] = now()
            if let identity = knownIdentities[id] { onPeerDisconnected?(identity, .localSuspend) }
        }
        stop()
    }

    /// Going to the background: tells contacts we're stepping away (so they show "away",
    /// keep the game paused, and nudge us), gives that a moment to send, then suspends.
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

    /// Restarts discovery after the app returns to the foreground; links and contacts come back on their own.
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

    /// Restarts the transport so the new nickname is advertised. Contacts are reported as
    /// dropped first so games pause instead of getting out of sync.
    func nicknameDidChange() {
        suspend()
        start()
        onResumed?()
    }

    // MARK: - Contacts

    /// Asks someone on the mesh to connect. They see it under People › Requests.
    @discardableResult
    func requestContact(_ identityId: String) -> Bool {
        guard identityId != localId, !isContact(identityId), !safety.isBlocked(identityId: identityId),
              let person = directory[identityId]
        else { return false }
        // They already asked us: asking back is the same as accepting.
        if let theirs = invitations.first(where: { $0.from == identityId }) {
            respond(to: theirs, accept: true)
            return true
        }
        let envelope = makeEnvelope(.contactRequest(ContactPayload(nickname: localIdentity.nickname)))
        guard sendSealed(envelope, to: [(person.id, person.agreementKey)]) else { return false }
        outgoingRequests[identityId] = now()
        return true
    }

    func respond(to invitation: Invitation, accept: Bool) {
        invitations.removeAll { $0.id == invitation.id }
        if accept {
            guard let person = directory[invitation.from] else { return }
            let envelope = makeEnvelope(.contactAccept(ContactPayload(nickname: localIdentity.nickname)))
            _ = sendSealed(envelope, to: [(person.id, person.agreementKey)])
            addContact(person.identity)
        } else {
            declinedUntil[invitation.from] = now().addingTimeInterval(Self.declineMute)
        }
    }

    private func addContact(_ identity: PeerIdentity) {
        outgoingRequests[identity.id] = nil
        let isNew = knownIdentities[identity.id] == nil
        knownIdentities[identity.id] = identity
        if inboundNudgeKeys[identity.id] == nil {
            inboundNudgeKeys[identity.id] = SymmetricKey(size: .bits256)
        }
        if let early = earlyNudgeKeys.removeValue(forKey: identity.id), now().timeIntervalSince(early.at) < Self.requestLifetime {
            outboundNudgeKeys[identity.id] = early.key
        }
        if isNew { droppedAt[identity.id] = nil }
        pruneDeparted()
        persistIdentity()
        refreshReachability()
    }

    /// "Disconnect from Everyone": ends every contact (they're told), and forgets the saved identity.
    func disconnectAll() {
        let everyone = Array(knownIdentities.keys)
        if !everyone.isEmpty { send(.contactEnd(EmptyPayload()), to: everyone) }
        for id in everyone { removeContact(id, announce: false) }
        outgoingRequests.removeAll()
        identityStore?.clear()
        chat.appendSystem("You disconnected from everyone.")
    }

    private func removeContact(_ identityId: String, announce: Bool) {
        let wasReachable = reachableIds.remove(identityId) != nil
        let identity = knownIdentities[identityId]
        forget(identityId)
        persistIdentity()
        if let identity {
            if announce { chat.appendSystem("\(identity.labeledName) disconnected") }
            if wasReachable { onPeerDisconnected?(identity, .connectionLost) }
        }
    }

    // MARK: - Chat

    /// Sends a chat message to a conversation's members after running the safety filter.
    /// "Everyone" goes to all connected contacts; one-on-one chats and groups go only to their members.
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
        // Hold a copy for members who are away; they get it when they're back.
        let messageId = envelope?.id ?? UUID()
        let cutoff = now().addingTimeInterval(-Self.outboxLifetime)
        for id in away {
            var held = (outbox[id] ?? []).filter { $0.date > cutoff }
            held.append((text, now(), ref, messageId))
            outbox[id] = Array(held.suffix(Self.outboxLimit))
        }
        if !away.isEmpty { onChatQueuedForAway?(away, text, conversationId) }
        chat.appendText(id: messageId, senderId: localId, senderName: localIdentity.nickname, text: text,
                        isLocal: true, conversationId: conversationId, isHeld: envelope == nil)
        return .sent
    }

    private func deliverOutbox(to identity: PeerIdentity) {
        guard let held = outbox.removeValue(forKey: identity.id) else { return }
        let cutoff = now().addingTimeInterval(-Self.outboxLifetime)
        for message in held where message.date > cutoff {
            if send(.chat(ChatPayload(text: message.text, conversation: message.conversation)), to: [identity.id]) != nil {
                chat.markDelivered(message.messageId)
            }
        }
    }

    // MARK: - Blocking

    /// Blocks someone, whether they're connected, away, or just on the mesh: their packets
    /// are dropped (not even relayed), their requests ignored, their phone's link refused,
    /// and their past messages removed. Remembered by id and by device.
    func block(identityId: String) {
        guard !safety.isBlocked(identityId: identityId) else { return }
        let identity = knownIdentities[identityId] ?? directory[identityId]?.identity
        let name = identity?.labeledName ?? chat.messages.last(where: { $0.senderId == identityId })?.senderName ?? "Someone"
        let fingerprint = fingerprintByIdentity[identityId]
        safety.block(fingerprint: fingerprint ?? "id:\(identityId)", name: name, identityId: identityId)
        for (key, var link) in links where link.identityId == identityId || (fingerprint != nil && transport.fingerprint(for: key) == fingerprint) {
            link.isBlocked = true
            links[key] = link
            linkTasks.removeValue(forKey: key)?.cancel()
        }
        let wasReachable = reachableIds.remove(identityId) != nil
        invitations.removeAll { $0.from == identityId }
        outgoingRequests[identityId] = nil
        directory[identityId] = nil
        forget(identityId)
        chat.removeMessages(from: identityId)
        persistIdentity()
        _ = wasReachable
        if let identity { onPeerDisconnected?(identity, .blocked) }
        chat.appendSystem("You blocked \(name). You won't see their messages or requests.")
    }

    /// Drops everything kept about a person: contact, keys, held messages, away state.
    private func forget(_ identityId: String) {
        knownIdentities[identityId] = nil
        reachableIds.remove(identityId)
        outbox[identityId] = nil
        inboundNudgeKeys[identityId] = nil
        outboundNudgeKeys[identityId] = nil
        steppedAwayIds.remove(identityId)
        steppedAwayAt[identityId] = nil
        droppedAt[identityId] = nil
        groupCreations[identityId] = nil
    }

    /// Forgets contacts who left long ago, and the oldest ones beyond the cap.
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
        for (key, var link) in links where transport.fingerprint(for: key) == person.fingerprint || link.identityId == person.identityId {
            link.isBlocked = false
            links[key] = link
        }
    }

    /// Plain-text report body for the Mail composer. Contains only what's on screen.
    func reportBody(about identityId: String, message: String?, reason: String) -> String {
        let name = knownIdentities[identityId]?.labeledName ?? directory[identityId]?.labeledName ?? "Unknown"
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

    // MARK: - Sending

    /// Seals a payload for contacts and sends it into the mesh. `recipients` are identity
    /// ids; `nil` means every connected contact. Only connected contacts are sent to.
    @discardableResult
    func send(_ payload: Envelope.Payload, sessionId: UUID? = nil, to recipients: [String]? = nil) -> Envelope? {
        let ids = (recipients.map(Set.init) ?? reachableIds).filter { reachableIds.contains($0) || payload.kind == .contactEnd }
        let targets = ids.compactMap { id in directory[id].map { (id: id, agreementKey: $0.agreementKey) } }
        guard !targets.isEmpty else { return nil }
        let envelope = makeEnvelope(payload, sessionId: sessionId)
        return sendSealed(envelope, to: targets) ? envelope : nil
    }

    private func makeEnvelope(_ payload: Envelope.Payload, sessionId: UUID? = nil) -> Envelope {
        nextSequence += 1
        return Envelope(sessionId: sessionId, senderId: localId, sequence: nextSequence, payload: payload)
    }

    /// Seals and floods one envelope to up to `MeshPacket.maxRecipients` people.
    private func sendSealed(_ envelope: Envelope, to recipients: [(id: String, agreementKey: Data)]) -> Bool {
        var sent = false
        for start in stride(from: 0, to: recipients.count, by: MeshPacket.maxRecipients) {
            let chunk = Array(recipients[start..<min(start + MeshPacket.maxRecipients, recipients.count)])
            // Each chunk needs its own packet id; the envelope id names the first.
            var copy = envelope
            if start > 0 { copy.id = UUID() }
            guard let packet = try? MeshPacket.sealed(copy, to: chunk, from: meshIdentity, ttl: MeshPacket.maxTTL, now: now()) else {
                Self.logger.error("Seal failed for \(envelope.kind.rawValue, privacy: .public)")
                continue
            }
            sent = flood(packet, except: nil) || sent
        }
        return sent
    }

    /// Sends a packet to every connected link except `except`. Returns whether any link took it.
    @discardableResult
    private func flood(_ packet: MeshPacket, except: PeerKey?) -> Bool {
        remember(packet.id)
        let keys = links.values.filter { $0.connection == .connected && !$0.isBlocked && $0.key != except }.map(\.key)
        guard !keys.isEmpty, let data = try? packet.encoded() else { return false }
        do {
            try transport.send(data, to: keys)
            return true
        } catch {
            return false
        }
    }

    /// Sends our signed announcement to the mesh (or only to one new link).
    private func announce(to key: PeerKey? = nil) {
        guard let nickname = profile.nickname else { return }
        let envelope = makeEnvelope(.announce(AnnouncePayload(nickname: nickname)))
        guard let packet = try? MeshPacket.broadcast(envelope, from: meshIdentity, ttl: MeshPacket.maxTTL, now: now()),
              let data = try? packet.encoded()
        else { return }
        remember(packet.id)
        if let key {
            try? transport.send(data, to: [key])
        } else {
            lastAnnouncedAt = now()
            nextAnnounceDelay = Self.announceInterval * Double.random(in: 0.85...1.15)
            flood(packet, except: nil)
        }
    }

    /// Announces to the whole mesh unless we just did; then only to `key`, if given.
    private func announceSoon(orTo key: PeerKey? = nil) {
        if now().timeIntervalSince(lastAnnouncedAt) > 2 {
            announce()
        } else if let key {
            announce(to: key)
        }
    }

    // MARK: - Periodic work

    /// Runs every few seconds while discovery is on: announce, refresh who's connected,
    /// expire requests, and forget stale people. Internal so tests can drive it.
    func tick() {
        guard transportRunning else { return }
        if now().timeIntervalSince(lastAnnouncedAt) >= nextAnnounceDelay { announce() }
        let current = now()
        invitations.removeAll { current.timeIntervalSince($0.receivedAt) > Self.requestLifetime }
        outgoingRequests = outgoingRequests.filter { current.timeIntervalSince($0.value) < Self.requestLifetime }
        declinedUntil = declinedUntil.filter { $0.value > current }
        earlyNudgeKeys = earlyNudgeKeys.filter { current.timeIntervalSince($0.value.at) < Self.requestLifetime }
        let directoryCutoff = current.addingTimeInterval(-MeshPacket.freshness)
        directory = directory.filter { $0.value.lastHeard > directoryCutoff || isContact($0.key) }
        lastAnnounce = lastAnnounce.filter { $0.value.receivedAt > directoryCutoff }
        refreshReachability()
        pruneDeparted()
    }

    /// Recomputes which contacts are connected and reports the changes.
    private func refreshReachability() {
        let cutoff = now().addingTimeInterval(-Self.reachableWindow)
        var next = Set<String>()
        if transportRunning {
            for id in knownIdentities.keys where !steppedAwayIds.contains(id) {
                if let heard = directory[id]?.lastHeard, heard > cutoff { next.insert(id) }
            }
        }
        let lost = reachableIds.subtracting(next)
        let gained = next.subtracting(reachableIds)
        guard !lost.isEmpty || !gained.isEmpty else { return }
        reachableIds = next
        for id in lost.sorted() {
            guard let identity = knownIdentities[id] else { continue }
            droppedAt[id] = now()
            DebugTrace.log("session contact lost \(identity.nickname)")
            chat.appendSystem(steppedAwayIds.contains(id) ? "\(identity.labeledName) stepped away" : "\(identity.labeledName) disconnected")
            onPeerDisconnected?(identity, .connectionLost)
        }
        for id in gained.sorted() {
            guard let identity = knownIdentities[id] else { continue }
            let returning = droppedAt[id] != nil
            droppedAt[id] = nil
            DebugTrace.log("session contact reachable \(identity.nickname) hops=\(directory[id]?.hops ?? -1) returning=\(returning)")
            chat.updateNickname(identity.nickname, for: id)
            chat.appendSystem(returning ? "\(identity.labeledName) is back" : "\(identity.labeledName) connected")
            // Give them our Bluetooth key each time (they may have restarted).
            if let key = inboundNudgeKeys[id] {
                send(.keys(KeysPayload(nudgeKey: key.withUnsafeBytes { Data($0) }.base64EncodedString())), to: [id])
            }
            deliverOutbox(to: identity)
            // They just came into reach: answer, so they see us right away too.
            announceSoon()
            if returning { onPeerReturned?(identity) }
            onPeerIdentified?(identity)
            if let text = DebugTrace.autoChat {
                sendChat("\(text) (\(now().formatted(date: .omitted, time: .standard)))", in: directConversation(with: identity).id)
            }
        }
        persistIdentity()
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
        // Events queued by the transport we just stopped would create ghost links.
        guard !discardingStaleEvents else { return }

        switch event {
        case .started, .startFailed:
            break

        case .peerFound(let key, let rawName):
            var link = links[key] ?? Link(key: key, displayName: filter.safeNickname(rawName), connection: .notConnected, isNearby: true)
            link.displayName = filter.safeNickname(rawName)
            link.advertisedName = rawName
            link.isNearby = true
            link.isBlocked = link.isBlocked || safety.isBlocked(transport.fingerprint(for: key))
            links[key] = link
            if shouldLink(link) { scheduleLink(key) }

        case .peerLost(let key):
            guard var link = links[key] else { return }
            if link.connection == .notConnected {
                links[key] = nil
                linkTasks.removeValue(forKey: key)?.cancel()
            } else {
                link.isNearby = false
                links[key] = link
            }

        case .invitationReceived(let invitationId, let key, let rawName):
            // Link requests are answered automatically: a link only relays traffic. Who you
            // talk to is decided by contact requests, which this user answers.
            let blocked = links[key]?.isBlocked == true || safety.isBlocked(transport.fingerprint(for: key))
            let allowed = !blocked && DebugTrace.linkAllowed(with: rawName)
            if allowed, links[key] == nil {
                links[key] = Link(key: key, displayName: filter.safeNickname(rawName), advertisedName: rawName, connection: .notConnected, isNearby: false)
            }
            transport.respond(toInvitation: invitationId, accept: allowed)

        case .invitationExpired:
            break

        case .peerStateChanged(let key, let state):
            handleStateChange(key: key, state: state)

        case .received(let data, let key):
            handleIncoming(data, from: key)
        }
    }

    private func shouldLink(_ link: Link) -> Bool {
        guard !link.isBlocked, link.connection == .notConnected, DebugTrace.linkAllowed(with: link.advertisedName) else { return false }
        let active = links.values.filter { $0.connection != .notConnected }.count
        return active < MultipeerTransport.maxLinks
    }

    /// Whether discovery restarted moments ago (this phone just opened or came back to the app).
    private var justStarted: Bool {
        guard case .running(let since) = status else { return true }
        return now().timeIntervalSince(since) < Self.justStartedWindow
    }

    /// Links to a phone found nearby, retrying with backoff. Only one side invites at a time,
    /// so the two invitations don't collide: the phone that just came back goes first (in
    /// testing, invitations from the phone that stayed often stalled), and between two phones
    /// in the same situation, comparing nicknames picks one. The other side accepts
    /// automatically and invites itself only if the first side doesn't.
    private func scheduleLink(_ key: PeerKey, attempt: Int = 0) {
        linkTasks.removeValue(forKey: key)?.cancel()
        guard attempt < 20, let link = links[key], shouldLink(link) else { return }
        let mine = profile.nickname ?? "", theirs = link.advertisedName
        let backoff: Double = attempt == 0 ? 0 : min(30, pow(2, Double(min(attempt, 5))))
        let tieBreak: Double = mine < theirs ? 0 : (mine == theirs ? Double.random(in: 0.3...2) : 3)
        let delay = backoff + (justStarted ? tieBreak : Self.stayedReconnectDelay + tieBreak)
        linkTasks[key] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            if let link = self.links[key], link.connection == .notConnected, self.shouldLink(link) {
                _ = self.transport.invite(key)
            }
            // If this attempt didn't link, try again a bit later.
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let current = self.links[key], current.connection != .connected, current.isNearby else { return }
            self.scheduleLink(key, attempt: attempt + 1)
        }
    }

    private func handleStateChange(key: PeerKey, state: PeerConnectionState, reason: DropReason = .connectionLost) {
        var link = links[key] ?? Link(key: key, displayName: "Unknown", connection: state, isNearby: false)
        link.isBlocked = link.isBlocked || safety.isBlocked(transport.fingerprint(for: key))
        let previous = link.connection
        link.connection = state
        DebugTrace.log("session link \(link.displayName) \(previous) -> \(state)")

        if state == .connected, previous != .connected {
            linkTasks.removeValue(forKey: key)?.cancel()
            links[key] = link
            guard !link.isBlocked else { return }
            sendHello(to: key)
            // A new link can join two parts of the mesh: tell everyone we're here (contacts
            // on the other side answer, see `refreshReachability`), and bring the new neighbor
            // up to date on who's around.
            announceSoon(orTo: key)
            let fresh = now().addingTimeInterval(-Self.reachableWindow)
            for (packet, receivedAt) in lastAnnounce.values where receivedAt > fresh {
                var onward = packet
                onward.ttl = max(1, packet.ttl - 1)
                if let data = try? onward.encoded() { try? transport.send(data, to: [key]) }
            }
            return
        }

        if previous == .connected, state != .connected {
            linkArrivals[key] = nil
            link.identityId = nil
            links[key] = link
            // Any contact may have been reached through this link. With no links left, nobody
            // can be reached: they're all gone now. Otherwise each gets a moment to show they're
            // still reachable another way: we ask, and they answer with an announcement.
            let otherLinks = links.values.contains { $0.key != key && $0.connection == .connected }
            let graceStart = now().addingTimeInterval(-(Self.reachableWindow - (otherLinks ? Self.dropGrace : 0)))
            for id in reachableIds {
                if var person = directory[id], person.lastHeard > graceStart {
                    person.lastHeard = graceStart
                    directory[id] = person
                }
            }
            if otherLinks {
                send(.heartbeat(EmptyPayload()))
            } else {
                refreshReachability()
            }
        }

        if state == .notConnected, !link.isNearby {
            links[key] = nil
            linkTasks.removeValue(forKey: key)?.cancel()
        } else {
            links[key] = link
            if state == .notConnected, previous != .notConnected, shouldLink(link) { scheduleLink(key, attempt: 1) }
        }
    }

    private func sendHello(to key: PeerKey) {
        guard let nickname = profile.nickname else { return }
        let envelope = makeEnvelope(.hello(HelloPayload(nickname: nickname, protocolVersion: Envelope.currentVersion)))
        guard let packet = try? MeshPacket.broadcast(envelope, from: meshIdentity, ttl: 0, now: now()),
              let data = try? packet.encoded()
        else { return }
        try? transport.send(data, to: [key])
    }

    // MARK: - Inbound

    private func handleIncoming(_ data: Data, from key: PeerKey) {
        // The transport only delivers data from linked phones, but its "connected" callback
        // can trail the first packet (typically the hello). Treat data as proof of the link.
        if links[key]?.connection != .connected { handleStateChange(key: key, state: .connected) }
        guard let link = links[key], !link.isBlocked else { return }
        guard allow(&linkArrivals[key, default: []], limit: Self.linkRateLimit) else { return reject("link rate limited") }

        let packet: MeshPacket
        do {
            packet = try MeshPacket.decode(data)
            try packet.verify(now: now())
        } catch {
            return reject("bad packet")
        }
        guard !seenPackets.contains(packet.id) else {
            // A copy that came a shorter way (more hops left) than the one we relayed: relay it
            // again so it still reaches as far as it should. Otherwise a slow long path could
            // cut a message short.
            if packet.ttl > 1, packet.ttl > (relayedTTL[packet.id] ?? Int.max), packet.origin != localId,
               !safety.isBlocked(identityId: packet.origin) {
                var onward = packet
                onward.ttl -= 1
                relayedTTL[packet.id] = packet.ttl
                flood(onward, except: key)
            }
            // An announcement we've seen, arriving again on another link (a neighbor bringing
            // us up to date): not news, but it shows its sender is reachable this way too.
            if packet.isBroadcast, packet.ttl > 0, directory[packet.origin] != nil {
                heard(packet, hops: MeshPacket.maxTTL - packet.ttl)
                refreshReachability()
            }
            return
        }
        remember(packet.id)
        // Recorded even when it isn't relayed (last hop), so a later copy with hops to spare is.
        relayedTTL[packet.id] = packet.ttl
        guard packet.origin != localId else { return }
        // Blocked people's traffic is dropped here, not even relayed.
        guard !safety.isBlocked(identityId: packet.origin) else { return }
        guard allow(&originArrivals[packet.origin, default: []], limit: Self.originRateLimit) else { return reject("sender rate limited") }

        // A link hello: who's on the other end of this link. Never relayed.
        if packet.ttl == 0 {
            guard packet.isBroadcast, let envelope = try? packet.open(as: meshIdentity),
                  case .hello(let hello) = envelope.payload, let nickname = Nickname.sanitize(hello.nickname)
            else { return reject("bad hello") }
            bindLink(key, to: packet, nickname: nickname)
            return
        }

        // Relay onward first, so a slow or rejected local step never holds others up.
        if packet.ttl > 1 {
            var onward = packet
            onward.ttl -= 1
            flood(onward, except: key)
        }
        let hops = MeshPacket.maxTTL - packet.ttl
        heard(packet, hops: hops)

        if packet.isBroadcast {
            guard let envelope = try? packet.open(as: meshIdentity), case .announce(let announce) = envelope.payload,
                  let nickname = Nickname.sanitize(announce.nickname)
            else { return reject("bad broadcast") }
            updateDirectory(packet, nickname: nickname, hops: hops)
            lastAnnounce[packet.origin] = (packet, now())
            refreshReachability()
            return
        }

        let envelope: Envelope
        do {
            envelope = try packet.open(as: meshIdentity)
        } catch .notForMe {
            return
        } catch {
            return reject("bad sealed packet")
        }
        route(envelope, in: packet)
    }

    /// Records who's on the other end of a link.
    private func bindLink(_ key: PeerKey, to packet: MeshPacket, nickname: String) {
        guard var link = links[key] else { return }
        link.identityId = packet.origin
        links[key] = link
        if let fingerprint = transport.fingerprint(for: key) {
            fingerprintByIdentity[packet.origin] = fingerprint
        }
        updateDirectory(packet, nickname: nickname, hops: 0)
        refreshReachability()
    }

    /// Any verified packet from someone shows they were reachable when they sent it.
    private func heard(_ packet: MeshPacket, hops: Int) {
        let id = packet.origin
        // When they sent it (by their clock, never later than ours), not when it got here:
        // a packet that waited at a relay doesn't make them look more present than they are.
        let sentAt = min(Date(timeIntervalSince1970: Double(packet.sentAt) / 1000), now())
        if var person = directory[id] {
            person.lastHeard = max(person.lastHeard, sentAt)
            person.agreementKey = packet.originAgreementKey
            directory[id] = person
        } else if let contact = knownIdentities[id] {
            directory[id] = MeshPerson(id: id, nickname: contact.nickname, agreementKey: packet.originAgreementKey, lastHeard: sentAt, hops: hops)
        }
        // Anything they sent after saying "stepping away" means they're back.
        if let awayAt = steppedAwayAt[id], packet.sentAt > awayAt {
            steppedAwayAt[id] = nil
            steppedAwayIds.remove(id)
        }
    }

    private func updateDirectory(_ packet: MeshPacket, nickname: String, hops: Int) {
        let shown = filter.safeNickname(nickname)
        let sentAt = min(Date(timeIntervalSince1970: Double(packet.sentAt) / 1000), now())
        let previous = directory[packet.origin]
        // The first copy of each announcement usually came the shortest way (later copies are
        // duplicates), so its hop count is the current distance.
        directory[packet.origin] = MeshPerson(id: packet.origin, nickname: shown, agreementKey: packet.originAgreementKey,
                                              lastHeard: max(previous?.lastHeard ?? sentAt, sentAt), hops: hops)
        if var contact = knownIdentities[packet.origin], contact.nickname != shown {
            contact.nickname = shown
            knownIdentities[packet.origin] = contact
            chat.updateNickname(shown, for: packet.origin)
        }
        // Debug-only scripted tests: become contacts with the named test devices without tapping.
        if DebugTrace.autoConnects(with: nickname), !isContact(packet.origin), !isRequested(packet.origin),
           (profile.nickname ?? "") < nickname {
            requestContact(packet.origin)
        }
        if directory.count > Self.maxDirectory {
            let oldest = directory.values.filter { !isContact($0.id) }.sorted { $0.lastHeard < $1.lastHeard }
            for person in oldest.prefix(directory.count - Self.maxDirectory) { directory[person.id] = nil }
        }
    }

    /// Handles a sealed envelope addressed to this phone.
    private func route(_ envelope: Envelope, in packet: MeshPacket) {
        let origin = packet.origin
        switch envelope.payload {
        case .contactRequest(let contact):
            receiveContactRequest(from: origin, nickname: contact.nickname, packet: packet)
            return
        case .contactAccept(let contact):
            // Only an answer to a request this user actually sent makes someone a contact.
            guard isRequested(origin) || isContact(origin) else { return reject("unrequested accept") }
            if directory[origin] == nil {
                directory[origin] = MeshPerson(id: origin, nickname: filter.safeNickname(contact.nickname),
                                               agreementKey: packet.originAgreementKey, lastHeard: now(), hops: MeshPacket.maxTTL)
            }
            addContact(PeerIdentity(id: origin, nickname: directory[origin]?.nickname ?? filter.safeNickname(contact.nickname)))
            return
        case .keys(let keys) where !isContact(origin):
            if let raw = Data(base64Encoded: keys.nudgeKey), raw.count == 32, earlyNudgeKeys.count < Self.maxWaitingRequests * 4 {
                earlyNudgeKeys[origin] = (SymmetricKey(data: raw), now())
            }
            return
        default:
            break
        }

        // Everything else only from contacts.
        guard let identity = knownIdentities[origin] else { return reject("not a contact") }
        refreshReachability()

        switch envelope.payload {
        case .chat(let chatPayload):
            // Re-check on receipt: a modified sender could skip its own filter.
            guard filter.check(chatPayload.text).isAllowed else {
                let strikes = (filterStrikes[origin] ?? 0) + 1
                filterStrikes[origin] = strikes
                chat.appendSystem("A message from \(identity.labeledName) was hidden by the safety filter.")
                if strikes >= SafetyConfig.autoBlockThreshold {
                    block(identityId: origin)
                }
                return
            }
            var conversationId = ChatStore.everyoneId
            if let ref = chatPayload.conversation {
                // Only members may write to a conversation, and only to one we're in.
                let ids = Set(ref.members.map(\.id))
                guard ids.contains(origin), ids.contains(localId) else { return reject("not a member") }
                if chat.conversation(ref.id) == nil, ref.kind == .group, !allowNewGroup(from: origin) {
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
            chat.appendText(id: envelope.id, senderId: origin, senderName: identity.nickname, text: chatPayload.text,
                            isLocal: false, conversationId: conversationId)
            DebugTrace.log("session chat from \(identity.nickname) hops=\(MeshPacket.maxTTL - packet.ttl): \(chatPayload.text)")
            onChatReceived?(identity, chatPayload.text, conversationId)
        case .presence(let presence):
            if presence.away {
                steppedAwayIds.insert(origin)
                steppedAwayAt[origin] = packet.sentAt
            } else {
                steppedAwayIds.remove(origin)
                steppedAwayAt[origin] = nil
            }
            refreshReachability()
        case .keys(let keys):
            if let raw = Data(base64Encoded: keys.nudgeKey), raw.count == 32 {
                outboundNudgeKeys[origin] = SymmetricKey(data: raw)
                persistIdentity()
            }
        case .heartbeat:
            // A contact lost its direct link to us and is checking we're still reachable.
            if now().timeIntervalSince(lastAnnouncedAt) > 2 { announce() }
        case .contactEnd:
            removeContact(origin, announce: true)
        case .hello, .announce, .contactRequest, .contactAccept:
            break
        default:
            guard isConnected(origin) else { return }
            onGameEnvelope?(envelope, identity)
        }
    }

    private func receiveContactRequest(from origin: String, nickname rawNickname: String, packet: MeshPacket) {
        let nickname = filter.safeNickname(rawNickname)
        if directory[origin] == nil {
            directory[origin] = MeshPerson(id: origin, nickname: nickname, agreementKey: packet.originAgreementKey,
                                           lastHeard: now(), hops: MeshPacket.maxTTL - packet.ttl)
        }
        // Already contacts (they restarted and lost us), or we asked them too: connect.
        if isContact(origin) || isRequested(origin) {
            let accept = makeEnvelope(.contactAccept(ContactPayload(nickname: localIdentity.nickname)))
            _ = sendSealed(accept, to: [(origin, packet.originAgreementKey)])
            addContact(PeerIdentity(id: origin, nickname: nickname))
            return
        }
        // Requests wait quietly in People (no pop-up), so a crowd can't flood the screen.
        // Someone this user just declined, or one request too many, is ignored.
        let muted = declinedUntil[origin].map { $0 > now() } ?? false
        invitations.removeAll { $0.from == origin }
        if DebugTrace.autoConnects(with: rawNickname) {
            let accept = makeEnvelope(.contactAccept(ContactPayload(nickname: localIdentity.nickname)))
            _ = sendSealed(accept, to: [(origin, packet.originAgreementKey)])
            addContact(PeerIdentity(id: origin, nickname: nickname))
            return
        }
        guard !muted, invitations.count < Self.maxWaitingRequests else { return }
        let invitation = Invitation(id: UUID(), from: origin, displayName: nickname, receivedAt: now())
        invitations.append(invitation)
        onContactRequest?(invitation)
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

    private func remember(_ packetId: UUID) {
        guard seenPackets.insert(packetId).inserted else { return }
        seenOrder.append(packetId)
        if seenOrder.count > Self.seenCapacity {
            let oldest = seenOrder.removeFirst()
            seenPackets.remove(oldest)
            relayedTTL[oldest] = nil
        }
    }

    /// Sliding-window rate limit over `arrivals`.
    private func allow(_ arrivals: inout [Date], limit: Int) -> Bool {
        let current = now()
        arrivals.removeAll { current.timeIntervalSince($0) >= Self.rateWindow }
        guard arrivals.count < limit else { return false }
        arrivals.append(current)
        return true
    }

    private func reject(_ reason: StaticString) {
        rejectedEnvelopeCount += 1
        DebugTrace.log("session reject \(reason)")
        Self.logger.notice("Rejected inbound packet: \(reason, privacy: .public)")
    }
}
