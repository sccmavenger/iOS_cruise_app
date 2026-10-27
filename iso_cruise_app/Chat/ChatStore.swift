import Foundation
import Observation

/// In-memory chat history, split into conversations: "Everyone" (all connected people),
/// one-on-one chats, and groups. Nothing is persisted; history clears when the app quits.
@Observable
final class ChatStore {
    static let maxMessages = 2_000
    /// Most chats kept at once; the least recently active ones are dropped first.
    static let maxConversations = 64
    /// The built-in conversation with everyone you're connected to.
    static let everyoneId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    struct Conversation: Identifiable, Equatable {
        enum Kind: Equatable {
            case everyone, direct, group
        }

        let id: UUID
        let kind: Kind
        /// Optional group name.
        var name: String?
        /// Everyone in a direct chat or group, including the local user. Empty for "Everyone".
        var members: [ConversationMember]
        var lastActivity: Date

        var memberIds: Set<String> { Set(members.map(\.id)) }

        /// What travels with each message so other members know the conversation.
        var ref: ConversationRef? {
            switch kind {
            case .everyone: nil
            case .direct: ConversationRef(id: id, kind: .direct, name: nil, members: members)
            case .group: ConversationRef(id: id, kind: .group, name: name, members: members)
            }
        }
    }

    /// For a message sent while someone was away: what Bluetooth managed.
    enum DeliveryNote: Equatable {
        /// The whole message reached their phone over Bluetooth.
        case bluetooth
        /// Their phone showed a notification; the message itself follows when they're back.
        case notified
        /// Their phone didn't answer over Bluetooth (out of range, Bluetooth off, or the app was closed).
        case unreachable
    }

    struct Message: Identifiable, Equatable {
        enum Kind: Equatable {
            case text
            /// Connection notices such as "Alex joined".
            case system
        }

        let id: UUID
        let kind: Kind
        let senderId: String
        let senderName: String
        let text: String
        let date: Date
        let isLocal: Bool
        var conversationId: UUID = ChatStore.everyoneId
        /// Sent while everyone it's for was away; it goes out when they're back.
        var isHeld = false
        /// What happened over Bluetooth for someone who was away (see `DeliveryNote`).
        var deliveryNote: DeliveryNote?

        var senderTag: String { Nickname.tag(for: senderId) }
    }

    /// Every message, oldest first, across all conversations.
    private(set) var messages: [Message] = []
    private(set) var conversations: [UUID: Conversation] = [
        ChatStore.everyoneId: Conversation(id: ChatStore.everyoneId, kind: .everyone, members: [], lastActivity: .distantPast),
    ]
    private(set) var unread: [UUID: Int] = [:]

    /// The conversation on screen right now, if any. Its messages aren't counted as unread.
    var visibleConversationId: UUID? {
        didSet {
            if let visibleConversationId { unread[visibleConversationId] = nil }
        }
    }

    var totalUnread: Int { unread.values.reduce(0, +) }

    /// "Everyone" first, then the most recently active.
    var sortedConversations: [Conversation] {
        conversations.values.sorted { a, b in
            if a.kind == .everyone { return true }
            if b.kind == .everyone { return false }
            return a.lastActivity > b.lastActivity
        }
    }

    func conversation(_ id: UUID) -> Conversation? { conversations[id] }

    func messages(in conversationId: UUID) -> [Message] {
        messages.filter { $0.conversationId == conversationId }
    }

    func lastMessage(in conversationId: UUID) -> Message? {
        messages.last { $0.conversationId == conversationId && $0.kind == .text }
    }

    /// Name to show for a conversation.
    func title(of conversation: Conversation, localId: String) -> String {
        switch conversation.kind {
        case .everyone:
            return "Everyone"
        case .direct:
            return conversation.members.first { $0.id != localId }?.nickname ?? "Chat"
        case .group:
            if let name = conversation.name, !name.isEmpty { return name }
            let others = conversation.members.filter { $0.id != localId }.map(\.nickname)
            return others.formatted(.list(type: .and))
        }
    }

    // MARK: - Conversations

    /// The one-on-one chat with `other`, created if needed.
    @discardableResult
    func directConversation(local: ConversationMember, other: ConversationMember) -> Conversation {
        let id = ConversationRef.directId(local.id, other.id)
        if let existing = conversations[id] { return existing }
        makeRoom()
        let conversation = Conversation(id: id, kind: .direct, members: [local, other], lastActivity: .now)
        conversations[id] = conversation
        return conversation
    }

    /// A new group. `members` must include the local user.
    @discardableResult
    func createGroup(name: String?, members: [ConversationMember]) -> Conversation {
        makeRoom()
        let conversation = Conversation(id: UUID(), kind: .group, name: name, members: members, lastActivity: .now)
        conversations[conversation.id] = conversation
        return conversation
    }

    /// The conversation for a game match, keyed by the lobby id.
    ///
    /// Unlike `createGroup`, the id is supplied rather than minted, so **every player derives
    /// the same conversation** without having to agree on one over the network — the lobby id
    /// is already shared. Idempotent, so opening chat repeatedly during a match doesn't pile
    /// up duplicate groups.
    @discardableResult
    func matchConversation(id: UUID, name: String?, members: [ConversationMember]) -> Conversation {
        if let existing = conversations[id] { return existing }
        makeRoom()
        let conversation = Conversation(id: id, kind: .group, name: name, members: members, lastActivity: .now)
        conversations[id] = conversation
        return conversation
    }

    /// Learns a conversation from an incoming message. Returns `false` if it conflicts with
    /// one we already know (a group's members can't be changed by a later message).
    func adopt(_ ref: ConversationRef) -> Bool {
        if let existing = conversations[ref.id] {
            switch (existing.kind, ref.kind) {
            case (.direct, .direct): return true
            case (.group, .group): return existing.memberIds == Set(ref.members.map(\.id))
            default: return false
            }
        }
        let kind: Conversation.Kind = ref.kind == .direct ? .direct : .group
        makeRoom()
        conversations[ref.id] = Conversation(id: ref.id, kind: kind, name: ref.name, members: ref.members, lastActivity: .now)
        return true
    }

    func hasMessage(_ id: UUID) -> Bool {
        messages.contains { $0.id == id }
    }

    /// Records what Bluetooth managed for a held message. A message that arrived whole is no longer held.
    func setDeliveryNote(_ note: DeliveryNote, for messageId: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages[index].deliveryNote = note
        if note == .bluetooth { messages[index].isHeld = false }
    }

    /// A held message reached someone.
    func markDelivered(_ messageId: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }), messages[index].isHeld else { return }
        messages[index].isHeld = false
    }

    /// Keeps names in chat titles current when someone renames themselves.
    func updateNickname(_ nickname: String, for memberId: String) {
        for (id, conversation) in conversations where conversation.members.contains(where: { $0.id == memberId }) {
            conversations[id]?.members = conversation.members.map {
                $0.id == memberId ? ConversationMember(id: memberId, nickname: nickname) : $0
            }
        }
    }

    /// Removes a chat and its messages from this phone. It comes back if someone writes in it again.
    func delete(_ conversationId: UUID) {
        guard conversationId != Self.everyoneId else { return }
        conversations[conversationId] = nil
        unread[conversationId] = nil
        messages.removeAll { $0.conversationId == conversationId }
    }

    func markRead(_ conversationId: UUID) {
        unread[conversationId] = nil
    }

    // MARK: - Messages

    func appendText(id: UUID, senderId: String, senderName: String, text: String, isLocal: Bool,
                    conversationId: UUID = ChatStore.everyoneId, date: Date = .now, isHeld: Bool = false) {
        guard !messages.contains(where: { $0.id == id }), conversations[conversationId] != nil else { return }
        append(Message(id: id, kind: .text, senderId: senderId, senderName: senderName, text: text, date: date,
                       isLocal: isLocal, conversationId: conversationId, isHeld: isHeld))
        conversations[conversationId]?.lastActivity = date
        if !isLocal, visibleConversationId != conversationId {
            unread[conversationId, default: 0] += 1
        }
    }

    func appendSystem(_ text: String, date: Date = .now) {
        append(Message(id: UUID(), kind: .system, senderId: "", senderName: "", text: text, date: date, isLocal: false))
    }

    /// Removes everything a (now blocked) sender said, and the unread counts for it.
    func removeMessages(from senderId: String) {
        let removed = messages.filter { $0.kind == .text && $0.senderId == senderId }
        messages.removeAll { $0.kind == .text && $0.senderId == senderId }
        for message in removed where unread[message.conversationId] != nil {
            let left = unread[message.conversationId]! - 1
            unread[message.conversationId] = left > 0 ? left : nil
        }
    }

    /// Drops the least recently active chat when at the limit, preferring ones with nothing unread.
    private func makeRoom() {
        guard conversations.count >= Self.maxConversations else { return }
        let candidates = conversations.values.filter { $0.kind != .everyone }
            .sorted { ($0.unread(in: self) == 0 ? 0 : 1, $0.lastActivity) < ($1.unread(in: self) == 0 ? 0 : 1, $1.lastActivity) }
        if let oldest = candidates.first { delete(oldest.id) }
    }

    func clear() {
        messages.removeAll()
        unread.removeAll()
    }

    private func append(_ message: Message) {
        messages.append(message)
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }
}

private extension ChatStore.Conversation {
    func unread(in store: ChatStore) -> Int { store.unread[id] ?? 0 }
}
