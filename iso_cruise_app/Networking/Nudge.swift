import CryptoKit
import Foundation

/// A small Bluetooth message that reaches a nearby friend's phone while CruiseLAN is in
/// the background (or the phone is locked). iOS ends peer-to-peer Wi-Fi sessions in the
/// background, but wakes a Bluetooth peripheral app for incoming writes, so the app can
/// post a notification or, for the game host, apply a move.
///
/// Security:
/// - Every nudge is sealed with ChaChaPoly using a key that only the two phones share.
///   The recipient generated it for this one sender and sent it inside its `hello` over
///   the encrypted peer-to-peer link. Nobody else can read a nudge or forge one, and a
///   tampered nudge fails to open.
/// - Each message has an id and a timestamp. Old or repeated messages are dropped.
/// - Nothing outside the sealed box says who sent it: the receiver tries the few keys it
///   holds, so a nudge on the air can't be linked to a person.
/// - A phone advertises a service UUID derived from its per-launch CruiseLAN id, shared
///   only with people it has connected with. It changes every launch.
nonisolated enum Nudge {
    enum Kind: Codable, Equatable, Sendable {
        /// A chat message. `preview` is the start of the text, already filtered by the sender.
        /// `conversationId` is nil for "Everyone".
        case chat(preview: String?, conversationId: UUID?)
        case turn(GameType)
        /// An invitation to a game the sender is hosting.
        case invite(GameType)
        /// A move for the host to apply while it's in the background.
        case move(lobbyId: UUID, request: MoveRequestPayload)

        /// Repeats of the same topic are rate-limited; every move is distinct.
        var topic: String? {
            switch self {
            case .chat(_, let conversationId): "chat-\(conversationId?.uuidString ?? "everyone")"
            case .turn(let game): "turn-\(game.rawValue)"
            case .invite(let game): "invite-\(game.rawValue)"
            case .move: nil
            }
        }
    }

    /// What's sealed inside a nudge.
    struct Message: Codable, Equatable, Sendable {
        var id: UUID
        var sentAt: Date
        var kind: Kind
    }

    static let version = 3
    /// Largest single write iOS sends with response between iPhones.
    static let maxPayloadBytes = 512
    static let maxPreviewBytes = 120
    /// Nudges older than this (or from the future by more than this) are dropped.
    static let maxAge: TimeInterval = 2 * 60
    /// Fixed characteristic that receives nudges inside each phone's service.
    static let characteristicUUIDString = "6E1D5A2C-3F4B-4C8E-9A7D-2B1F0C9E8D71"
    /// After a nudge on a topic is delivered, don't repeat it for this long.
    static let deliveredInterval: TimeInterval = 10 * 60
    static let chatDeliveredInterval: TimeInterval = 45
    /// Minimum time between two notifications on the same topic from the same person.
    static let receiveInterval: TimeInterval = 30

    /// The Bluetooth service UUID a phone advertises, derived from its CruiseLAN id.
    static func serviceUUIDString(for identityId: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("cruiselan.nudge.v1|\(identityId)".utf8)).prefix(16))
        // Mark it as a version 4 (random), RFC 4122 variant UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }

    /// Shortens chat text to a notification preview without splitting a character.
    static func preview(of text: String) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + character.utf8.count <= maxPreviewBytes else { return result + "…" }
            result.append(character)
        }
        return result
    }

    /// Wire format: [version: 1 byte][ChaChaPoly combined box: nonce + ciphertext + tag].
    /// `senderId` isn't on the wire; the key that opens the box identifies the sender.
    static func seal(_ message: Message, from senderId: String, key: SymmetricKey) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let plain = try? encoder.encode(message),
              let box = try? ChaChaPoly.seal(plain, using: key).combined
        else { return nil }
        let data = Data([UInt8(version)]) + box
        return data.count <= maxPayloadBytes ? data : nil
    }

    /// Opens untrusted bytes from the air with whichever of `keys` (person id → the key we
    /// gave them) fits. Returns `nil` for anything malformed, unauthenticated, or too old.
    static func open(_ data: Data, now: Date = .now, keys: [String: SymmetricKey]) -> (from: String, message: Message)? {
        let bytes = [UInt8](data)
        // 1 version byte + 12-byte nonce + 16-byte tag at minimum.
        guard bytes.count <= maxPayloadBytes, bytes.count > 29, Int(bytes[0]) == version,
              let box = try? ChaChaPoly.SealedBox(combined: Data(bytes[1...]))
        else { return nil }
        guard let (from, plain) = keys.lazy.compactMap({ id, key in (try? ChaChaPoly.open(box, using: key)).map { (id, $0) } }).first
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let message = try? decoder.decode(Message.self, from: plain),
              abs(now.timeIntervalSince(message.sentAt)) <= maxAge
        else { return nil }
        if case .move(_, let request) = message.kind, !request.move.isStructurallyValid { return nil }
        return (from, message)
    }

    /// Remembers when each (person, topic) last happened so repeats are dropped.
    struct RateLimiter {
        let interval: TimeInterval
        private var last: [String: Date] = [:]

        init(interval: TimeInterval) {
            self.interval = interval
        }

        func isAllowed(_ personId: String, _ topic: String, at now: Date, interval override: TimeInterval? = nil) -> Bool {
            guard let previous = last["\(personId)|\(topic)"] else { return true }
            return now.timeIntervalSince(previous) >= (override ?? interval)
        }

        mutating func record(_ personId: String, _ topic: String, at now: Date) {
            last["\(personId)|\(topic)"] = now
        }

        /// Clears everything recorded for a person (they came back, so new nudges are fresh).
        mutating func forget(_ personId: String) {
            last = last.filter { !$0.key.hasPrefix("\(personId)|") }
        }

        /// Checks and records in one step.
        mutating func allow(_ personId: String, _ topic: String, at now: Date) -> Bool {
            guard isAllowed(personId, topic, at: now) else { return false }
            record(personId, topic, at: now)
            return true
        }
    }

    /// Drops nudges this phone has already handled.
    struct ReplayGuard {
        private var seen: [UUID] = []
        private var seenSet: Set<UUID> = []

        mutating func isNew(_ id: UUID) -> Bool {
            guard seenSet.insert(id).inserted else { return false }
            seen.append(id)
            if seen.count > 500 { seenSet.remove(seen.removeFirst()) }
            return true
        }
    }
}
