import Foundation

/// Talks to the online game service. A protocol so tests can stand in a fake.
protocol CloudGameService: AnyObject {
    /// Whether the service answers right now: the real test for "online", since a network can
    /// look connected (captive portals, guest Wi-Fi before sign-in) and still not reach it.
    func checkHealth() async -> Bool
    /// `open`: listed for everyone; otherwise only people with the code can join.
    func createRoom(_ game: GameType, nickname: String, open: Bool) async throws(CloudError) -> CloudSeat
    func joinRoom(code: String, nickname: String) async throws(CloudError) -> CloudSeat
    /// Open games waiting for players, newest first. Nil if the service can't be reached.
    func openGames() async -> [OpenGame]?
    /// A seat in the open game that's waited longest, or a new open game if there's none.
    /// `avoid`: codes of games not to join (ones this player was removed from).
    func quickPlay(_ game: GameType, nickname: String, avoid: [String]) async throws(CloudError) -> CloudSeat
    /// Gives up the seat over HTTPS (works while the socket is down). Best effort.
    func leaveRoom(_ seat: CloudSeat) async
    /// Opens the room's live connection. It reconnects by itself until closed.
    func openRoom(_ seat: CloudSeat, onEvent: @escaping (CloudRoomEvent) -> Void) -> any CloudRoomConnection
}

protocol CloudRoomConnection: AnyObject {
    var isConnected: Bool { get }
    func send(_ message: CloudClientMessage)
    /// Try again now instead of waiting out the backoff (network came back, app came forward).
    func reconnectNow()
    func close()
}

enum CloudRoomEvent: Equatable {
    /// Connected, and `resume` was sent: a roster and the current state follow.
    case connected
    case disconnected
    case message(CloudServerMessage)
    /// The room expired, or our seat is no longer in it. Reconnecting won't help.
    case roomGone
    /// The host removed this player from the lobby.
    case removed
}

/// The real service, over HTTPS and a WebSocket.
final class LiveCloudGameService: CloudGameService {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = CloudConfig.baseURL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func checkHealth() async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "v1/health"))
        request.timeoutInterval = 5
        struct Health: Decodable { var ok: Bool; var `protocol`: Int }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try? JSONDecoder().decode(Health.self, from: data)
        else { return false }
        return health.ok && health.protocol >= CloudConfig.protocolVersion
    }

    func createRoom(_ game: GameType, nickname: String, open: Bool) async throws(CloudError) -> CloudSeat {
        try await post("v1/rooms", body: ["game": game.rawValue, "nickname": nickname, "open": open])
    }

    func openGames() async -> [OpenGame]? {
        var request = URLRequest(url: baseURL.appending(path: "v1/lobbies"))
        request.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        // Skip entries for games this build doesn't know, rather than failing the whole list.
        struct Lenient: Decodable {
            var lobbies: [Entry]
            struct Entry: Decodable {
                var value: OpenGame?
                init(from decoder: Decoder) throws { value = try? OpenGame(from: decoder) }
            }
        }
        return (try? JSONDecoder().decode(Lenient.self, from: data))?.lobbies.compactMap(\.value)
    }

    func quickPlay(_ game: GameType, nickname: String, avoid: [String]) async throws(CloudError) -> CloudSeat {
        try await post("v1/quickplay", body: ["game": game.rawValue, "nickname": nickname, "avoid": avoid])
    }

    func joinRoom(code: String, nickname: String) async throws(CloudError) -> CloudSeat {
        let cleaned = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard cleaned.count == 8 else { throw .notFound }
        return try await post("v1/rooms/\(cleaned)/join", body: ["nickname": nickname])
    }

    func leaveRoom(_ seat: CloudSeat) async {
        var request = URLRequest(url: baseURL.appending(path: "v1/rooms/\(seat.code)/leave"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(seat.token)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    func openRoom(_ seat: CloudSeat, onEvent: @escaping (CloudRoomEvent) -> Void) -> any CloudRoomConnection {
        WebSocketRoomConnection(seat: seat, baseURL: baseURL, session: session, onEvent: onEvent)
    }

    private func post(_ path: String, body: [String: any Sendable]) async throws(CloudError) -> CloudSeat {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw .unreachable }
        struct Failure: Decodable { var error: String }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            guard let seat = try? JSONDecoder().decode(CloudSeat.self, from: data) else { throw .server }
            return seat
        case 404: throw .notFound
        case 409: throw (try? JSONDecoder().decode(Failure.self, from: data))?.error == "full" ? .full : .alreadyStarted
        case 429: throw .rateLimited
        default: throw .server
        }
    }
}

/// One room's WebSocket. Every (re)connect sends `resume`, so the server replies with the roster
/// and the current state; nothing is assumed to survive a dropped connection.
final class WebSocketRoomConnection: CloudRoomConnection {
    private let seat: CloudSeat
    private let url: URL
    private let session: URLSession
    private let onEvent: (CloudRoomEvent) -> Void
    private var task: URLSessionWebSocketTask?
    /// Bumped on every new attempt, so callbacks from an abandoned socket are ignored.
    private var generation = 0
    private var isClosed = false
    private(set) var isConnected = false
    private var retryDelay: Duration = .seconds(1)
    private var retryTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    /// A text "ping" this often keeps the seat marked as connected (the room shows a phone as
    /// away after 75 s of silence) and keeps proxies and carrier NATs from closing an idle
    /// connection. Cloudflare answers "pong" itself, so it doesn't wake the room.
    static let pingInterval: Duration = .seconds(25)
    static let maxRetryDelay: Duration = .seconds(30)

    init(seat: CloudSeat, baseURL: URL, session: URLSession, onEvent: @escaping (CloudRoomEvent) -> Void) {
        self.seat = seat
        self.session = session
        self.onEvent = onEvent
        var components = URLComponents(url: baseURL.appending(path: "v1/rooms/\(seat.code)/socket"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        url = components.url!
        connect()
    }

    func send(_ message: CloudClientMessage) {
        guard isConnected, let task, let data = try? JSONEncoder().encode(message) else { return }
        let attempt = generation
        Task {
            do { try await task.send(.string(String(decoding: data, as: UTF8.self))) } catch { dropped(attempt) }
        }
    }

    func reconnectNow() {
        guard !isClosed else { return }
        retryDelay = .seconds(1)
        if isConnected, let task {
            // After a trip to the background the socket may be dead without anyone knowing yet.
            let attempt = generation
            task.sendPing { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in self?.dropped(attempt) }
            }
        } else {
            retryTask?.cancel()
            connect()
        }
    }

    func close() {
        isClosed = true
        generation += 1
        retryTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
    }

    private func connect() {
        guard !isClosed else { return }
        generation += 1
        let attempt = generation
        task?.cancel(with: .goingAway, reason: nil)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(seat.token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        Task {
            // The first send completes only once the upgrade succeeded.
            guard let resume = try? JSONEncoder().encode(CloudClientMessage.resume) else { return }
            do {
                try await task.send(.string(String(decoding: resume, as: UTF8.self)))
            } catch {
                return dropped(attempt)
            }
            guard attempt == generation else { return }
            isConnected = true
            retryDelay = .seconds(1)
            startPinging(task, attempt: attempt)
            onEvent(.connected)
            await receive(task, attempt: attempt)
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, attempt: Int) async {
        while attempt == generation {
            do {
                let message = try await task.receive()
                guard attempt == generation else { return }
                let data: Data? = switch message {
                case .string(let text): Data(text.utf8)
                case .data(let data): data
                @unknown default: nil
                }
                if let data, let decoded = try? JSONDecoder().decode(CloudServerMessage.self, from: data) {
                    onEvent(.message(decoded))
                }
            } catch {
                return dropped(attempt)
            }
        }
    }

    private func startPinging(_ task: URLSessionWebSocketTask, attempt: Int) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard !Task.isCancelled, let self, attempt == self.generation else { return }
                do { try await task.send(.string("ping")) } catch { self.dropped(attempt) }
            }
        }
    }

    private func dropped(_ attempt: Int) {
        guard attempt == generation, !isClosed else { return }
        generation += 1
        pingTask?.cancel()
        let wasConnected = isConnected
        isConnected = false
        // The server refused the seat (401/404/410) or closed the room (4404) or our seat (4000).
        let status = (task?.response as? HTTPURLResponse)?.statusCode
        let closeCode = task?.closeCode.rawValue ?? 0
        // The server answers a removed seat's reconnect with 403; iOS can't read custom close
        // codes, so the close code is only a bonus.
        if closeCode == 4001 || status == 403 {
            close()
            onEvent(.removed)
            return
        }
        if [401, 404, 410].contains(status) || closeCode == 4404 || closeCode == 4000 {
            close()
            onEvent(.roomGone)
            return
        }
        if wasConnected { onEvent(.disconnected) }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }
}
