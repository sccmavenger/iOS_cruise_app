import CryptoKit
import Foundation

/// A tiny Bluetooth "doorbell" that wakes a nearby friend's phone while CruiseLAN is in
/// the background, so it can show a local notification. iOS ends peer-to-peer Wi-Fi
/// sessions in the background, but a Bluetooth peripheral app is woken for writes.
///
/// Privacy and safety:
/// - A nudge carries only who it's from and what kind it is, never message text.
/// - Each phone advertises a service UUID derived from its per-launch CruiseLAN id,
///   which is only ever shared with people it has connected with. It changes every launch.
/// - The receiver ignores nudges from anyone it hasn't connected with since launch, anyone
///   blocked, and repeats within `receiveInterval`, and it shows the name it already knows
///   rather than anything in the payload.
nonisolated enum Nudge {
    enum Kind: Codable, Equatable, Hashable, Sendable {
        case chat
        case turn(GameType)
    }

    struct Payload: Codable, Equatable, Sendable {
        /// Format version.
        var v: Int
        /// Sender's CruiseLAN id.
        var from: String
        var kind: Kind
    }

    static let version = 1
    /// Fits in a single default-MTU Bluetooth write.
    static let maxPayloadBytes = 180
    /// Fixed characteristic that receives nudges inside each phone's service.
    static let characteristicUUIDString = "6E1D5A2C-3F4B-4C8E-9A7D-2B1F0C9E8D71"
    /// Minimum time between two nudges of the same kind to the same person.
    static let sendInterval: TimeInterval = 45
    /// Minimum time between two notifications of the same kind from the same person.
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

    static func encode(_ payload: Payload) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload), data.count <= maxPayloadBytes else { return nil }
        return data
    }

    /// Decodes untrusted bytes from the air; anything unexpected is dropped.
    static func decode(_ data: Data) -> Payload? {
        guard data.count <= maxPayloadBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.v == version,
              !payload.from.isEmpty, payload.from.count <= EnvelopeCodec.maxSenderIdLength
        else { return nil }
        return payload
    }

    /// Remembers when each (person, kind) was last nudged so repeats are dropped.
    struct RateLimiter {
        let interval: TimeInterval
        private var last: [String: Date] = [:]

        init(interval: TimeInterval) {
            self.interval = interval
        }

        /// Returns `true` and records the time if the event is allowed now.
        mutating func allow(_ personId: String, _ kind: Kind, at now: Date) -> Bool {
            let key = "\(personId)|\(kind)"
            if let previous = last[key], now.timeIntervalSince(previous) < interval { return false }
            last[key] = now
            return true
        }
    }
}
