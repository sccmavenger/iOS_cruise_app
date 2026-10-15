#if DEBUG
import Foundation

/// Debug-only scripted scenes for App Store screenshots and quick UI checks on a single
/// simulator. Launch with `-CruiseLANDemo <scene>`; scenes are listed in `Scene`.
///
/// The app's own `SessionManager` and `GameCoordinator` run unchanged. They're wired to
/// a loopback network of in-process "friends" with their own sessions, so every message
/// and move goes through the real envelope codec, validation, and host logic.
@MainActor
final class DemoMode {
    enum Scene: String {
        case chat, games, chess, checkers, colorMatch, connectFour, chatWhilePlaying
    }

    static var requestedScene: Scene? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CruiseLANDemo"), arguments.indices.contains(index + 1) else { return nil }
        return Scene(rawValue: arguments[index + 1])
    }

    let scene: Scene
    let transport = LoopTransport()
    let profile: ProfileStore
    private var friends: [Friend] = []
    private var keys: [ObjectIdentifier: [ObjectIdentifier: PeerKey]] = [:]

    init(scene: Scene) {
        self.scene = scene
        let defaults = UserDefaults(suiteName: "demo-\(UUID().uuidString)")!
        profile = ProfileStore(defaults: defaults)
        _ = profile.setNickname("Sam")
    }

    /// Plays the scene against the app's real session and coordinator.
    func run(session: SessionManager, games: GameCoordinator, app: AppState) async {
        transport.network = self
        transport.owner = session
        session.start()
        session.handle(.started)

        let mia = addFriend("Mia"), leo = addFriend("Leo"), ava = addFriend("Ava")
        for friend in [mia, leo, ava] { connect(session, friend.session) }
        connect(mia.session, leo.session)
        connect(mia.session, ava.session)
        connect(leo.session, ava.session)
        await pause()

        switch scene {
        case .chat, .games:
            mia.session.sendChat("Anyone up for chess after lunch? ♟️")
            await pause()
            leo.session.sendChat("Yes! Meet by the pool deck?")
            await pause()
            session.sendChat("I'm in! Color Match first?")
            await pause()
            ava.session.sendChat("Me too 🙌 I'll host")
            if scene == .games {
                mia.games.hostLobby(.chess)
                ava.games.hostLobby(.colorMatch)
                app.selectedTab = .games
            }
        case .chess, .chatWhilePlaying:
            try? start(.chess, host: games, guests: [mia.games])
            // An Italian Game opening; Sam plays White.
            let moves = [(12, 28), (52, 36), (6, 21), (57, 42), (5, 26), (61, 34)]
            for (index, move) in moves.enumerated() {
                let mover = index.isMultiple(of: 2) ? games : mia.games
                mover.play(.chess(.move(from: move.0, to: move.1, promotion: nil)))
            }
            if scene == .chatWhilePlaying {
                mia.session.sendChat("Your move! 😄")
                leo.session.sendChat("Who's winning?")
                await pause()
                app.selectedTab = .chat
                app.isMatchMinimized = true
            }
        case .checkers:
            try? start(.checkers, host: games, guests: [mia.games])
            for (from, to) in [(18, 27), (45, 36), (27, 45)] {
                let player = games.snapshot.flatMap { snapshot -> GameCoordinator? in
                    guard case .checkers(let state) = snapshot else { return nil }
                    return state.playerId(for: state.turn) == session.localId ? games : mia.games
                }
                player?.play(.checkers(.move(from: from, to: to)))
            }
        case .colorMatch:
            try? start(.colorMatch, host: games, guests: [mia.games, leo.games])
        case .connectFour:
            try? start(.connectFour, host: games, guests: [mia.games])
            for (index, column) in [3, 3, 4, 2, 5].enumerated() {
                (index.isMultiple(of: 2) ? games : mia.games).play(.connectFour(column: column))
            }
        }
    }

    // MARK: - Network

    struct Friend {
        let session: SessionManager
        let games: GameCoordinator
    }

    private func addFriend(_ name: String) -> Friend {
        let defaults = UserDefaults(suiteName: "demo-\(name)-\(UUID().uuidString)")!
        let profile = ProfileStore(defaults: defaults)
        _ = profile.setNickname(name)
        let transport = LoopTransport()
        let session = SessionManager(transport: transport, profile: profile, safety: SafetyStore(defaults: defaults), trusted: TrustedPeersStore(defaults: defaults))
        transport.network = self
        transport.owner = session
        let friend = Friend(session: session, games: GameCoordinator(session: session))
        friends.append(friend)
        return friend
    }

    private func connect(_ a: SessionManager, _ b: SessionManager) {
        let keyForB = PeerKey(), keyForA = PeerKey()
        keys[ObjectIdentifier(a), default: [:]][ObjectIdentifier(b)] = keyForB
        keys[ObjectIdentifier(b), default: [:]][ObjectIdentifier(a)] = keyForA
        a.handle(.peerFound(keyForB, displayName: b.profile.nickname ?? ""))
        b.handle(.peerFound(keyForA, displayName: a.profile.nickname ?? ""))
        a.handle(.peerStateChanged(keyForB, .connected))
        b.handle(.peerStateChanged(keyForA, .connected))
    }

    fileprivate func deliver(_ data: Data, from sender: SessionManager, to key: PeerKey) {
        let all = [transport.owner].compactMap { $0 } + friends.map(\.session)
        guard let receiver = all.first(where: { keys[ObjectIdentifier(sender)]?[ObjectIdentifier($0)] == key }),
              let senderKey = keys[ObjectIdentifier(receiver)]?[ObjectIdentifier(sender)]
        else { return }
        receiver.handle(.received(data, from: senderKey))
    }

    private func start(_ game: GameType, host: GameCoordinator, guests: [GameCoordinator]) throws {
        host.hostLobby(game)
        for guest in guests {
            guard let offer = guest.offers(for: game).first else { continue }
            guest.join(offer)
            guest.setReady(true)
        }
        host.startGame()
    }

    private func pause() async {
        try? await Task.sleep(for: .milliseconds(350))
    }

    /// Synchronous in-process transport between demo sessions.
    final class LoopTransport: PeerTransport {
        let events = AsyncStream<TransportEvent> { _ in }
        weak var network: DemoMode?
        weak var owner: SessionManager?

        func start(displayName: String) {}
        func stop() {}
        func invite(_ peer: PeerKey) {}
        func respond(toInvitation invitationId: UUID, accept: Bool) {}
        func disconnectAll() {}
        func fingerprint(for peer: PeerKey) -> String? { peer.raw.uuidString }
        func send(_ data: Data, to peers: [PeerKey]) throws {
            guard let network, let owner else { return }
            for key in peers { network.deliver(data, from: owner, to: key) }
        }
    }
}
#endif
