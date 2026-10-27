import CryptoKit
import Foundation

/// Every message exchanged between peers is wrapped in a versioned envelope.
///
/// The envelope carries routing/replay metadata (`id`, `senderId`, `sequence`) and a
/// typed payload. The `kind` field is redundant with the payload case but is required by
/// the protocol contract; the decoder rejects envelopes where they disagree.
nonisolated struct Envelope: Equatable, Sendable {
    /// 2: mesh. Envelopes travel inside signed `MeshPacket`s; older builds can't talk to this one.
    static let currentVersion = 2

    var version: Int
    var id: UUID
    var sessionId: UUID?
    var senderId: String
    var sequence: Int
    var payload: Payload

    var kind: Kind { payload.kind }

    init(
        version: Int = Envelope.currentVersion,
        id: UUID = UUID(),
        sessionId: UUID? = nil,
        senderId: String,
        sequence: Int,
        payload: Payload
    ) {
        self.version = version
        self.id = id
        self.sessionId = sessionId
        self.senderId = senderId
        self.sequence = sequence
        self.payload = payload
    }

    enum Kind: String, Codable, Sendable, CaseIterable {
        /// Identity handshake sent immediately after a peer connects (CruiseLAN addition to the v0.2 kind list).
        case hello
        case chat
        case lobbyOffer
        case joinRequest
        case joinAccept
        case joinReject
        case ready
        case startGame
        case moveRequest
        case stateSnapshot
        case gameEvent
        case rematchRequest
        case leave
        case error
        case heartbeat
        /// "I'm stepping away" (app going to the background) so peers show "away", not "disconnected".
        case presence
        /// Mesh: "I'm here", flooded every few seconds so everyone can find everyone (public).
        case announce
        /// Mesh: asks to become contacts. Only contacts can chat or play together.
        case contactRequest
        /// Mesh: accepts a contact request.
        case contactAccept
        /// A fresh key for Bluetooth nudges between two contacts (see `KeysPayload`).
        case keys
        /// The sender stopped being contacts ("Disconnect from Everyone").
        case contactEnd
    }

    enum Payload: Equatable, Sendable {
        case hello(HelloPayload)
        case chat(ChatPayload)
        case lobbyOffer(LobbyOfferPayload)
        case joinRequest(LobbyRefPayload)
        case joinAccept(LobbyRosterPayload)
        case joinReject(JoinRejectPayload)
        case ready(ReadyPayload)
        case startGame(StartGamePayload)
        case moveRequest(MoveRequestPayload)
        case stateSnapshot(StateSnapshotPayload)
        case gameEvent(GameEventPayload)
        case rematchRequest(LobbyRefPayload)
        case leave(LeavePayload)
        case error(ErrorPayload)
        case heartbeat(EmptyPayload)
        case presence(PresencePayload)
        case announce(AnnouncePayload)
        case contactRequest(ContactPayload)
        case contactAccept(ContactPayload)
        case keys(KeysPayload)
        case contactEnd(EmptyPayload)

        var kind: Kind {
            switch self {
            case .hello: .hello
            case .chat: .chat
            case .lobbyOffer: .lobbyOffer
            case .joinRequest: .joinRequest
            case .joinAccept: .joinAccept
            case .joinReject: .joinReject
            case .ready: .ready
            case .startGame: .startGame
            case .moveRequest: .moveRequest
            case .stateSnapshot: .stateSnapshot
            case .gameEvent: .gameEvent
            case .rematchRequest: .rematchRequest
            case .leave: .leave
            case .error: .error
            case .heartbeat: .heartbeat
            case .presence: .presence
            case .announce: .announce
            case .contactRequest: .contactRequest
            case .contactAccept: .contactAccept
            case .keys: .keys
            case .contactEnd: .contactEnd
            }
        }
    }
}

// MARK: - Payloads

nonisolated struct EmptyPayload: Codable, Equatable, Sendable {}

/// First packet on a new link between two phones (not relayed): who's on the other end.
/// The packet around it carries the sender's keys and signature (see `MeshPacket`).
nonisolated struct HelloPayload: Codable, Equatable, Sendable {
    /// Sanitized nickname the peer wants to be shown as.
    var nickname: String
    /// Protocol version the peer speaks, so incompatible builds can be told apart.
    var protocolVersion: Int
}

/// Flooded through the mesh so people further away can be found and sent a request.
nonisolated struct AnnouncePayload: Codable, Equatable, Sendable {
    var nickname: String
}

/// A contact request or acceptance. Sealed, so only the two phones see it.
nonisolated struct ContactPayload: Codable, Equatable, Sendable {
    var nickname: String
}

/// A fresh random key (base64, 32 bytes) made for one contact. They use it to encrypt
/// Bluetooth nudges to the sender while either app is in the background, so only the
/// two of them can make or read those nudges. Sent sealed through the mesh.
nonisolated struct KeysPayload: Codable, Equatable, Sendable {
    var nudgeKey: String
}

nonisolated struct PresencePayload: Codable, Equatable, Sendable {
    /// The sender's app is going to the background; it will come back and reconnect.
    var away: Bool
}

nonisolated struct ChatPayload: Codable, Equatable, Sendable {
    var text: String
    /// Which conversation the message belongs to. `nil` means "Everyone" (and is what
    /// older builds send).
    var conversation: ConversationRef? = nil
}

nonisolated struct ConversationMember: Codable, Equatable, Hashable, Sendable {
    var id: String
    var nickname: String
}

/// Describes a one-on-one chat or group so every member files the message in the same place.
nonisolated struct ConversationRef: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case direct, group
    }

    static let maxMembers = 8
    static let maxNameLength = 30

    var id: UUID
    var kind: Kind
    var name: String?
    /// Everyone in the conversation, including the sender.
    var members: [ConversationMember]

    /// Both phones derive the same id for a one-on-one chat, so it never needs negotiating.
    static func directId(_ a: String, _ b: String) -> UUID {
        let pair = [a, b].sorted().joined(separator: "|")
        let digest = Array(SHA256.hash(data: Data("cruiselan.dm.v1|\(pair)".utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    var isStructurallyValid: Bool {
        let ids = members.map(\.id)
        guard (2...Self.maxMembers).contains(members.count),
              Set(ids).count == ids.count,
              ids.allSatisfy({ !$0.isEmpty && $0.count <= EnvelopeCodec.maxSenderIdLength }),
              members.allSatisfy({ Nickname.sanitize($0.nickname) != nil })
        else { return false }
        switch kind {
        case .direct:
            return members.count == 2 && name == nil && id == Self.directId(ids[0], ids[1])
        case .group:
            return name.map { !$0.isEmpty && $0.count <= Self.maxNameLength } ?? true
        }
    }
}

nonisolated enum GameType: String, Codable, Sendable, CaseIterable, Identifiable {
    case ticTacToe
    case connectFour
    case colorMatch
    case checkers
    case chess
    case spades
    case tonk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ticTacToe: "Tic-Tac-Toe"
        case .connectFour: "Connect Four"
        case .colorMatch: "Color Match"
        case .checkers: "Checkers"
        case .chess: "Chess"
        case .spades: "Spades"
        case .tonk: "Tonk"
        }
    }

    var minPlayers: Int {
        switch self {
        case .ticTacToe, .connectFour, .checkers, .chess: 2
        case .colorMatch, .tonk: 2
        // Spades is partnerships, so it needs exactly four.
        case .spades: SpadesRules.playerCount
        }
    }

    var maxPlayers: Int {
        switch self {
        case .ticTacToe, .connectFour, .checkers, .chess: 2
        case .colorMatch, .tonk: 4
        case .spades: SpadesRules.playerCount
        }
    }
}

nonisolated struct LobbyOfferPayload: Codable, Equatable, Sendable {
    var lobbyId: UUID
    var gameType: GameType
    var hostNickname: String
    var maxSeats: Int
    var seatsTaken: Int
    /// When set, this offer is a direct invitation to one player rather than a public advertisement.
    var invitedPlayerId: String? = nil
}

nonisolated struct LobbyRefPayload: Codable, Equatable, Sendable {
    var lobbyId: UUID
}

nonisolated struct LobbyPlayer: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var nickname: String
    var isReady: Bool
    var isHost: Bool
}

nonisolated struct LobbyRosterPayload: Codable, Equatable, Sendable {
    var lobbyId: UUID
    var gameType: GameType
    var maxSeats: Int
    var players: [LobbyPlayer]
}

nonisolated struct JoinRejectPayload: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        case lobbyFull
        case declined
        case notFound
        case alreadyStarted
        /// The invited person is already in another game.
        case busy
    }

    var lobbyId: UUID
    var reason: Reason
}

nonisolated struct ReadyPayload: Codable, Equatable, Sendable {
    var lobbyId: UUID
    var isReady: Bool
}

nonisolated struct StartGamePayload: Codable, Equatable, Sendable {
    var lobbyId: UUID
    var gameType: GameType
    /// Player ids in seat order.
    var seats: [String]
}

nonisolated struct MoveRequestPayload: Codable, Equatable, Sendable {
    /// Unique id for the requested action so the host can drop replays.
    var moveId: UUID
    /// Revision the client was looking at when it requested the move.
    var baseRevision: Int
    var move: GameMove
}

nonisolated struct StateSnapshotPayload: Codable, Equatable, Sendable {
    var revision: Int
    var state: GameStateSnapshot
}

nonisolated struct GameEventPayload: Codable, Equatable, Sendable {
    enum Event: String, Codable, Sendable {
        case moveRejected
        case matchEnded
        case hostEnded
    }

    var event: Event
    var message: String
}

nonisolated struct LeavePayload: Codable, Equatable, Sendable {
    var lobbyId: UUID?
}

nonisolated struct ErrorPayload: Codable, Equatable, Sendable {
    var code: String
    var message: String
}
