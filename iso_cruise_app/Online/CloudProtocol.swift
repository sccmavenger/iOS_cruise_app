import Foundation

/// Where the online game service lives, and which protocol version this build speaks.
/// The server is `server/game-worker` (Cloudflare Workers + Durable Objects).
enum CloudConfig {
    static let protocolVersion = 1
    static let productionURL = URL(string: "https://cruiselan-games.dguilloryjr.workers.dev")!

    static var baseURL: URL {
        #if DEBUG
        // `-CruiseLANCloudURL http://localhost:8787` points a debug build at `wrangler dev`.
        if let override = UserDefaults.standard.string(forKey: "CruiseLANCloudURL"), let url = URL(string: override) {
            return url
        }
        #endif
        return productionURL
    }

    /// "ABCD1234" → "ABCD-1234", the way codes are shown and read aloud.
    static func displayCode(_ code: String) -> String {
        guard code.count == 8 else { return code }
        return "\(code.prefix(4))-\(code.suffix(4))"
    }
}

/// A seat in an online room: the room's invite code, which seat is ours, and the secret that
/// proves it. The token is kept in the Keychain (`CloudRoomStore`) and never shown.
nonisolated struct CloudSeat: Codable, Equatable, Sendable {
    var code: String
    var seat: String
    var token: String
    var game: GameType
    var maxSeats: Int
}

/// An open online game waiting for players, from the service's list.
nonisolated struct OpenGame: Codable, Equatable, Sendable, Identifiable {
    var code: String
    var game: GameType
    var host: String
    var seats: Int
    var maxSeats: Int

    var id: String { code }
}

/// The server's view of the table, sent whenever someone joins, connects, leaves or votes.
nonisolated struct CloudRoster: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case lobby, playing, ended
    }

    struct Player: Codable, Equatable, Sendable {
        var seat: String
        var nickname: String
        var connected: Bool
    }

    var code: String
    var game: GameType
    var phase: Phase
    var minSeats: Int
    var maxSeats: Int
    var organizer: String
    var endedMessage: String?
    var you: String
    /// Listed for everyone (rather than code-only). Absent from older servers.
    var open: Bool?
    var players: [Player]
    var rematchVotes: [String]
}

nonisolated struct CloudMoveResult: Codable, Equatable, Sendable {
    var moveId: String
    var ok: Bool
    var revision: Int?
    var error: String?
    var message: String?
    var duplicate: Bool?
}

/// Messages from the server. Unknown types are ignored, so the server can add new ones.
nonisolated enum CloudServerMessage: Decodable, Equatable, Sendable {
    case roster(CloudRoster)
    case snapshot(revision: Int, view: GameStateSnapshot)
    case result(CloudMoveResult)
    case error(String)
    case other

    private enum Keys: String, CodingKey { case type, revision, view, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "roster": self = .roster(try CloudRoster(from: decoder))
        case "snapshot":
            self = .snapshot(revision: try container.decode(Int.self, forKey: .revision), view: try container.decode(GameStateSnapshot.self, forKey: .view))
        case "result": self = .result(try CloudMoveResult(from: decoder))
        case "error": self = .error(try container.decode(String.self, forKey: .error))
        default: self = .other
        }
    }
}

/// Messages to the server.
nonisolated enum CloudClientMessage: Encodable, Equatable, Sendable {
    case resume
    case start
    case move(MoveRequestPayload)
    case rematch
    case leave
    /// The host removes a player from the lobby.
    case kick(seat: String)
    /// This phone's push address, so the seat is notified while the app isn't open. Empty clears it.
    case push(token: String, sandbox: Bool)
    /// The app left the screen: the server treats the seat as not looking (and notifies it)
    /// until `here` or any other message.
    case away
    case here

    private enum Keys: String, CodingKey { case type, moveId, baseRevision, move, seat, token, sandbox }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .resume: try container.encode("resume", forKey: .type)
        case .start: try container.encode("start", forKey: .type)
        case .rematch: try container.encode("rematch", forKey: .type)
        case .leave: try container.encode("leave", forKey: .type)
        case .kick(let seat):
            try container.encode("kick", forKey: .type)
            try container.encode(seat, forKey: .seat)
        case .push(let token, let sandbox):
            try container.encode("push", forKey: .type)
            try container.encode(token, forKey: .token)
            try container.encode(sandbox, forKey: .sandbox)
        case .away: try container.encode("away", forKey: .type)
        case .here: try container.encode("here", forKey: .type)
        case .move(let request):
            try container.encode("move", forKey: .type)
            try container.encode(request.moveId.uuidString, forKey: .moveId)
            try container.encode(request.baseRevision, forKey: .baseRevision)
            try container.encode(request.move, forKey: .move)
        }
    }
}

/// Why an online request failed, in words a player understands.
nonisolated enum CloudError: Error, Equatable, Sendable {
    case notFound
    case alreadyStarted
    case full
    case rateLimited
    case unreachable
    case server

    var message: String {
        switch self {
        case .notFound: "There's no game with that code. Check it and try again."
        case .alreadyStarted: "That game has already started."
        case .full: "That game is full."
        case .rateLimited: "Too many tries. Wait a minute and try again."
        case .unreachable: "Couldn't reach the online game service. Check your internet connection."
        case .server: "The online game service had a problem. Try again."
        }
    }
}
