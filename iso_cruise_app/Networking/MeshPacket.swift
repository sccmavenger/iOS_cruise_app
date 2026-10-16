import CryptoKit
import Foundation

/// What travels between phones in the mesh: a signed frame around an `Envelope`.
///
/// - **Signed by the sender.** Relays and recipients check the signature, and that the
///   signing key hashes to `origin` (see `MeshIdentity`). Nobody can forge, alter, or
///   impersonate. Everything except `ttl` is signed; relays only decrement `ttl`.
/// - **Sealed for its recipients.** Unless it's a public broadcast (only `announce` and the
///   link `hello` are), the envelope is encrypted with a fresh key, and that key is
///   wrapped once per recipient with the key the sender shares with them. Relays can't
///   read it, and the wrapped keys don't name anyone, so relays can't see who it's for.
///   Recipients find theirs by trying each one.
/// - **Bounded.** Hop limit, size limits, a freshness window, and duplicate ids keep a
///   flood from circling or growing (see `MeshRouter` limits in `SessionManager`).
nonisolated struct MeshPacket: Codable, Equatable, Sendable {
    static let version = 2
    /// Most phones a packet passes through.
    static let maxTTL = 6
    /// The envelope limit plus base64 and up to `maxRecipients` wrapped keys.
    static let maxPacketBytes = 64 * 1024
    static let maxRecipients = 64
    /// Packets older (or further in the future) than this are dropped, so they can't be replayed later.
    static let freshness: TimeInterval = 10 * 60

    var v: Int
    var id: UUID
    /// Sender's id, `MeshIdentity.id(for: originKey)`.
    var origin: String
    /// Sender's Ed25519 signing public key (32 bytes).
    var originKey: Data
    /// Sender's X25519 key-agreement public key (32 bytes), so any recipient can derive the shared key.
    var originAgreementKey: Data
    /// Sender's clock, milliseconds since 1970.
    var sentAt: Int64
    /// Remaining hops. 0 means "only for the phone it's sent to" (link hello).
    var ttl: Int
    /// Wrapped content keys, one per recipient (unlabelled). Empty for a public broadcast.
    var keys: [Data]
    /// The encoded `Envelope`: sealed (ChaChaPoly combined) unless `keys` is empty.
    var body: Data
    /// Ed25519 signature over `signedBytes`.
    var signature: Data

    var isBroadcast: Bool { keys.isEmpty }

    /// Everything but `ttl`, length-prefixed so fields can't be shifted between each other.
    var signedBytes: Data {
        var data = Data("cruiselan.packet.v2".utf8)
        func append(_ field: Data) {
            var length = UInt32(field.count).bigEndian
            data.append(Data(bytes: &length, count: 4))
            data.append(field)
        }
        append(Data(String(v).utf8))
        append(Data(id.uuidString.utf8))
        append(Data(origin.utf8))
        append(originKey)
        append(originAgreementKey)
        append(Data(String(sentAt).utf8))
        for key in keys { append(key) }
        append(Data(String(keys.count).utf8))
        append(body)
        return data
    }

    // MARK: - Making packets

    /// A public packet anyone can read (announcements and link hellos only).
    static func broadcast(_ envelope: Envelope, from identity: MeshIdentity, ttl: Int, now: Date = .now) throws -> MeshPacket {
        let body = try EnvelopeCodec.encode(envelope)
        return try make(id: UUID(), body: body, keys: [], from: identity, ttl: ttl, now: now)
    }

    /// A packet only `recipients` can read. Each recipient is (id, X25519 public key).
    static func sealed(_ envelope: Envelope, to recipients: [(id: String, agreementKey: Data)],
                       from identity: MeshIdentity, ttl: Int, now: Date = .now) throws -> MeshPacket {
        guard (1...maxRecipients).contains(recipients.count) else { throw MeshPacketError.invalid("recipients") }
        let contentKey = SymmetricKey(size: .bits256)
        // Each packet has its own id (for duplicate suppression), separate from the message id
        // inside: a message resent later (for someone who was away) must not look like a
        // duplicate to the relays that carried the first copy.
        let packetId = UUID()
        let plain = try EnvelopeCodec.encode(envelope)
        let body = try ChaChaPoly.seal(plain, using: contentKey, authenticating: Data(packetId.uuidString.utf8)).combined
        let rawContentKey = contentKey.withUnsafeBytes { Data($0) }
        var wrapped: [Data] = []
        for recipient in recipients {
            guard let pairKey = identity.pairKey(with: recipient.id, agreementPublicKey: recipient.agreementKey) else {
                throw MeshPacketError.invalid("recipient key")
            }
            wrapped.append(try ChaChaPoly.seal(rawContentKey, using: pairKey, authenticating: Data(packetId.uuidString.utf8)).combined)
        }
        wrapped.shuffle()
        return try make(id: packetId, body: body, keys: wrapped, from: identity, ttl: ttl, now: now)
    }

    private static func make(id: UUID, body: Data, keys: [Data], from identity: MeshIdentity, ttl: Int, now: Date) throws -> MeshPacket {
        var packet = MeshPacket(v: version, id: id, origin: identity.id, originKey: identity.signingPublicKey,
                                originAgreementKey: identity.agreementPublicKey,
                                sentAt: Int64(now.timeIntervalSince1970 * 1000), ttl: min(max(ttl, 0), maxTTL),
                                keys: keys, body: body, signature: Data())
        guard let signature = identity.sign(packet.signedBytes) else { throw MeshPacketError.invalid("sign") }
        packet.signature = signature
        return packet
    }

    // MARK: - Reading packets

    /// Structure, sender key, signature, and freshness. Run before relaying or reading anything.
    func verify(now: Date = .now) throws(MeshPacketError) {
        guard v == Self.version else { throw .invalid("version") }
        guard MeshIdentity.isValidId(origin), originKey.count == 32, originAgreementKey.count == 32,
              MeshIdentity.id(for: originKey) == origin
        else { throw .invalid("origin") }
        guard (0...Self.maxTTL).contains(ttl), keys.count <= Self.maxRecipients,
              keys.allSatisfy({ $0.count == 32 + 12 + 16 }),
              signature.count == 64
        else { throw .invalid("fields") }
        let age = now.timeIntervalSince1970 - Double(sentAt) / 1000
        guard abs(age) <= Self.freshness else { throw .stale }
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: originKey),
              publicKey.isValidSignature(signature, for: signedBytes)
        else { throw .invalid("signature") }
    }

    /// The envelope inside, if this phone may read it. Broadcasts are readable by all;
    /// sealed packets only by a recipient. The envelope must name the packet's sender.
    func open(as identity: MeshIdentity) throws(MeshPacketError) -> Envelope {
        let plain: Data
        if isBroadcast {
            plain = body
        } else {
            guard let pairKey = identity.pairKey(with: origin, agreementPublicKey: originAgreementKey) else { throw .notForMe }
            let aad = Data(id.uuidString.utf8)
            var contentKey: SymmetricKey?
            for wrapped in keys {
                if let box = try? ChaChaPoly.SealedBox(combined: wrapped),
                   let raw = try? ChaChaPoly.open(box, using: pairKey, authenticating: aad) {
                    contentKey = SymmetricKey(data: raw)
                    break
                }
            }
            guard let contentKey,
                  let box = try? ChaChaPoly.SealedBox(combined: body),
                  let opened = try? ChaChaPoly.open(box, using: contentKey, authenticating: aad)
            else { throw .notForMe }
            plain = opened
        }
        let envelope: Envelope
        do {
            envelope = try EnvelopeCodec.decode(plain)
        } catch {
            throw .invalid("envelope")
        }
        guard envelope.senderId == origin else { throw .invalid("sender") }
        return envelope
    }

    // MARK: - Wire format

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maxPacketBytes else { throw MeshPacketError.invalid("size") }
        return data
    }

    static func decode(_ data: Data) throws(MeshPacketError) -> MeshPacket {
        guard data.count <= maxPacketBytes else { throw .invalid("size") }
        guard let packet = try? JSONDecoder().decode(MeshPacket.self, from: data) else { throw .invalid("malformed") }
        return packet
    }
}

nonisolated enum MeshPacketError: Error, Equatable, Sendable {
    case invalid(String)
    case stale
    /// Sealed for someone else (normal for packets this phone only relays).
    case notForMe
}
