import Foundation

/// Errors produced while decoding or validating untrusted envelopes.
nonisolated enum EnvelopeCodecError: Error, Equatable, Sendable {
    case tooLarge(Int)
    case malformed
    case unsupportedVersion(Int)
    case invalidField(String)
}

/// Encodes and decodes `Envelope` values and enforces protocol bounds.
///
/// All data arriving from the network is untrusted: decoding never traps, every
/// size is bounded, and semantic validation runs after structural decoding.
nonisolated enum EnvelopeCodec {
    /// Hard ceiling for a single encoded envelope. Snapshots for the card game are
    /// the largest legitimate message and stay well below this.
    static let maxEnvelopeBytes = 32 * 1024
    static let maxChatCharacters = 1_000
    static let maxSenderIdLength = 64
    static let maxMessageLength = 200
    /// About the year 2286 in milliseconds; far above any honest sequence number.
    static let maxSequence = 10_000_000_000_000

    static func encode(_ envelope: Envelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= maxEnvelopeBytes else {
            throw EnvelopeCodecError.tooLarge(data.count)
        }
        return data
    }

    static func decode(_ data: Data) throws(EnvelopeCodecError) -> Envelope {
        guard data.count <= maxEnvelopeBytes else {
            throw .tooLarge(data.count)
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch let error as EnvelopeCodecError {
            throw error
        } catch {
            throw .malformed
        }
        try validate(envelope)
        return envelope
    }

    /// Semantic checks that structural decoding cannot express.
    static func validate(_ envelope: Envelope) throws(EnvelopeCodecError) {
        guard envelope.version == Envelope.currentVersion else {
            throw .unsupportedVersion(envelope.version)
        }
        guard !envelope.senderId.isEmpty, envelope.senderId.count <= maxSenderIdLength else {
            throw .invalidField("senderId")
        }
        // Sequences start at the sender's clock in milliseconds; anything wildly larger is bogus.
        guard envelope.sequence >= 0, envelope.sequence < Self.maxSequence else {
            throw .invalidField("sequence")
        }

        switch envelope.payload {
        case .hello(let hello):
            guard Nickname.sanitize(hello.nickname) != nil else { throw .invalidField("nickname") }
            if let key = hello.nudgeKey {
                guard key.count <= 64, Data(base64Encoded: key)?.count == 32 else { throw .invalidField("nudgeKey") }
            }
            if let nonce = hello.nonce {
                guard nonce.count <= 32, Data(base64Encoded: nonce)?.count == 16 else { throw .invalidField("nonce") }
            }
        case .proof(let proof):
            guard proof.mac.count <= 64, Data(base64Encoded: proof.mac)?.count == 32 else { throw .invalidField("proof") }
        case .chat(let chat):
            let trimmed = chat.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, chat.text.count <= maxChatCharacters else {
                throw .invalidField("text")
            }
            if let conversation = chat.conversation, !conversation.isStructurallyValid {
                throw .invalidField("conversation")
            }
        case .lobbyOffer(let offer):
            guard (offer.gameType.minPlayers...offer.gameType.maxPlayers).contains(offer.maxSeats),
                  (0...offer.maxSeats).contains(offer.seatsTaken),
                  Nickname.sanitize(offer.hostNickname) != nil
            else { throw .invalidField("lobbyOffer") }
        case .joinAccept(let roster):
            guard (roster.gameType.minPlayers...roster.gameType.maxPlayers).contains(roster.maxSeats),
                  roster.players.count <= roster.maxSeats,
                  roster.players.allSatisfy({ !$0.id.isEmpty && $0.id.count <= maxSenderIdLength && Nickname.sanitize($0.nickname) != nil })
            else { throw .invalidField("roster") }
        case .startGame(let start):
            guard (start.gameType.minPlayers...start.gameType.maxPlayers).contains(start.seats.count),
                  Set(start.seats).count == start.seats.count
            else { throw .invalidField("seats") }
        case .moveRequest(let request):
            guard request.baseRevision >= 0, request.move.isStructurallyValid else {
                throw .invalidField("move")
            }
        case .stateSnapshot(let snapshot):
            guard snapshot.revision >= 0, snapshot.state.isStructurallyValid else {
                throw .invalidField("state")
            }
        case .gameEvent(let event):
            guard event.message.count <= maxMessageLength else { throw .invalidField("message") }
        case .error(let error):
            guard error.code.count <= 64, error.message.count <= maxMessageLength else {
                throw .invalidField("error")
            }
        case .joinRequest, .joinReject, .ready, .rematchRequest, .leave, .heartbeat, .presence:
            break
        }
    }
}

// MARK: - Codable

extension Envelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, id, kind, sessionId, senderId, sequence, payload
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(UUID.self, forKey: .id)
        sessionId = try container.decodeIfPresent(UUID.self, forKey: .sessionId)
        senderId = try container.decode(String.self, forKey: .senderId)
        sequence = try container.decode(Int.self, forKey: .sequence)

        // Unknown kinds fail here (raw value lookup), which the codec maps to `.malformed`.
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .hello: payload = .hello(try container.decode(HelloPayload.self, forKey: .payload))
        case .chat: payload = .chat(try container.decode(ChatPayload.self, forKey: .payload))
        case .lobbyOffer: payload = .lobbyOffer(try container.decode(LobbyOfferPayload.self, forKey: .payload))
        case .joinRequest: payload = .joinRequest(try container.decode(LobbyRefPayload.self, forKey: .payload))
        case .joinAccept: payload = .joinAccept(try container.decode(LobbyRosterPayload.self, forKey: .payload))
        case .joinReject: payload = .joinReject(try container.decode(JoinRejectPayload.self, forKey: .payload))
        case .ready: payload = .ready(try container.decode(ReadyPayload.self, forKey: .payload))
        case .startGame: payload = .startGame(try container.decode(StartGamePayload.self, forKey: .payload))
        case .moveRequest: payload = .moveRequest(try container.decode(MoveRequestPayload.self, forKey: .payload))
        case .stateSnapshot: payload = .stateSnapshot(try container.decode(StateSnapshotPayload.self, forKey: .payload))
        case .gameEvent: payload = .gameEvent(try container.decode(GameEventPayload.self, forKey: .payload))
        case .rematchRequest: payload = .rematchRequest(try container.decode(LobbyRefPayload.self, forKey: .payload))
        case .leave: payload = .leave(try container.decode(LeavePayload.self, forKey: .payload))
        case .error: payload = .error(try container.decode(ErrorPayload.self, forKey: .payload))
        case .heartbeat: payload = .heartbeat(try container.decode(EmptyPayload.self, forKey: .payload))
        case .presence: payload = .presence(try container.decode(PresencePayload.self, forKey: .payload))
        case .proof: payload = .proof(try container.decode(ProofPayload.self, forKey: .payload))
        }
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(senderId, forKey: .senderId)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(kind, forKey: .kind)
        switch payload {
        case .hello(let value): try container.encode(value, forKey: .payload)
        case .chat(let value): try container.encode(value, forKey: .payload)
        case .lobbyOffer(let value): try container.encode(value, forKey: .payload)
        case .joinRequest(let value): try container.encode(value, forKey: .payload)
        case .joinAccept(let value): try container.encode(value, forKey: .payload)
        case .joinReject(let value): try container.encode(value, forKey: .payload)
        case .ready(let value): try container.encode(value, forKey: .payload)
        case .startGame(let value): try container.encode(value, forKey: .payload)
        case .moveRequest(let value): try container.encode(value, forKey: .payload)
        case .stateSnapshot(let value): try container.encode(value, forKey: .payload)
        case .gameEvent(let value): try container.encode(value, forKey: .payload)
        case .rematchRequest(let value): try container.encode(value, forKey: .payload)
        case .leave(let value): try container.encode(value, forKey: .payload)
        case .error(let value): try container.encode(value, forKey: .payload)
        case .heartbeat(let value): try container.encode(value, forKey: .payload)
        case .presence(let value): try container.encode(value, forKey: .payload)
        case .proof(let value): try container.encode(value, forKey: .payload)
        }
    }
}
