import Foundation
import Observation

/// In-memory chat history. Nothing is persisted; history clears when the app quits.
@Observable
final class ChatStore {
    static let maxMessages = 500

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

        var senderTag: String { Nickname.tag(for: senderId) }
    }

    private(set) var messages: [Message] = []

    func appendText(id: UUID, senderId: String, senderName: String, text: String, isLocal: Bool, date: Date = .now) {
        guard !messages.contains(where: { $0.id == id }) else { return }
        append(Message(id: id, kind: .text, senderId: senderId, senderName: senderName, text: text, date: date, isLocal: isLocal))
    }

    func appendSystem(_ text: String, date: Date = .now) {
        append(Message(id: UUID(), kind: .system, senderId: "", senderName: "", text: text, date: date, isLocal: false))
    }

    func clear() {
        messages.removeAll()
    }

    private func append(_ message: Message) {
        messages.append(message)
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }
}
