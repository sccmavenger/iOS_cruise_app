import SwiftUI

@main struct MyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var profile: ProfileStore
    @State private var session: SessionManager
    @State private var games: GameCoordinator
    @State private var appState = AppState()
    @State private var notifications: NotificationManager
    @State private var nudges: NudgeService

    init() {
        let profile = ProfileStore()
        let session = SessionManager(transport: MultipeerTransport(), profile: profile, safety: SafetyStore())
        let games = GameCoordinator(session: session)
        let notifications = NotificationManager()
        let nudges = NudgeService()
        Self.connect(session: session, games: games, notifications: notifications, nudges: nudges)
        _profile = State(initialValue: profile)
        _session = State(initialValue: session)
        _games = State(initialValue: games)
        _notifications = State(initialValue: notifications)
        _nudges = State(initialValue: nudges)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(profile)
                .environment(session)
                .environment(games)
                .environment(appState)
                .environment(notifications)
                .task(id: profile.nickname) {
                    // Ask for notifications and Bluetooth only after onboarding, when they make sense.
                    guard profile.nickname != nil else { return }
                    nudges.start(localId: session.localId)
                    await notifications.requestAuthorization()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            notifications.isAppActive = phase == .active
            switch phase {
            case .background:
                // iOS drops peer-to-peer sessions now anyway; going first lets the game pause cleanly.
                session.suspend()
            case .active:
                session.resume()
            default:
                break
            }
        }
    }

    /// Routes session and game events to notifications and Bluetooth nudges.
    private static func connect(session: SessionManager, games: GameCoordinator, notifications: NotificationManager, nudges: NudgeService) {
        notifications.install()
        session.onChatReceived = { identity, text in
            notifications.chatReceived(from: identity, text: text)
        }
        session.onChatQueuedForAway = { ids in
            for id in ids { nudges.nudge(id, kind: .chat) }
        }
        games.onTurnStarted = { game in
            notifications.turnStarted(in: game)
        }
        games.onNudgeNeeded = { playerId, game in
            nudges.nudge(playerId, kind: .turn(game))
        }
        nudges.onNudge = { [weak session] payload in
            // Only people this phone has connected with since launch, who aren't blocked
            // (blocking forgets them), and who aren't connected right now can nudge.
            guard let session, let sender = session.knownIdentities[payload.from], !session.isConnected(sender.id) else { return }
            notifications.nudgeReceived(payload.kind, from: sender)
        }
    }
}
