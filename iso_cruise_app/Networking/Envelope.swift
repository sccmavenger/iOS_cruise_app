import Foundation

/// Every message exchanged between peers is wrapped in a versioned envelope.
///
/// The envelope carries routing/replay metadata (`id`, `senderId`, `sequence`) and a
/// typed payload. The `kind` field is redundant with the payload case but is required by
/// the protocol contract; the decoder rejects envelopes where they disagree.
nonisolated struct Envelope: Equatable, Sendable {
    static let currentVersion = 1

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
            }
        }
    }
}

// MARK: - Payloads

nonisolated struct EmptyPayload: Codable, Equatable, Sendable {}

nonisolated struct HelloPayload: Codable, Equatable, Sendable {
    /// Sanitized nickname the peer wants to be shown as.
    var nickname: String
    /// Protocol version the peer speaks, so incompatible builds can be told apart.
    var protocolVersion: Int
    /// A fresh random key (base64, 32 bytes) made for this one recipient. The recipient
    /// uses it to encrypt Bluetooth nudges to the sender while either app is in the
    /// background, so only the two of them can make or read those nudges. It travels
    /// only over the encrypted peer-to-peer link. Optional for older builds.
    var nudgeKey: String? = nil
}

nonisolated struct PresencePayload: Codable, Equatable, Sendable {
    /// The sender's app is going to the background; it will come back and reconnect.
    var away: Bool
}

nonisolated struct ChatPayload: Codable, Equatable, Sendable {
    var text: String
}

nonisolated enum GameType: String, Codable, Sendable, CaseIterable, Identifiable {
    case ticTacToe
    case connectFour
    case colorMatch
    case checkers
    case chess

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ticTacToe: "Tic-Tac-Toe"
        case .connectFour: "Connect Four"
        case .colorMatch: "Color Match"
        case .checkers: "Checkers"
        case .chess: "Chess"
        }
    }

    var minPlayers: Int {
        switch self {
        case .ticTacToe, .connectFour, .checkers, .chess: 2
        case .colorMatch: 2
        }
    }

    var maxPlayers: Int {
        switch self {
        case .ticTacToe, .connectFour, .checkers, .chess: 2
        case .colorMatch: 4
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
