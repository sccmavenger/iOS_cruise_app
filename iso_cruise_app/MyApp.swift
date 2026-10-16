import SwiftUI
import UIKit

@main struct MyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var profile: ProfileStore
    @State private var session: SessionManager
    @State private var games: GameCoordinator
    @State private var appState = AppState()
    @State private var notifications: NotificationManager
    @State private var nudges: NudgeRouter
    #if DEBUG
    /// Scripted screenshot scene, when launched with `-CruiseLANDemo <scene>`.
    @State private var demo: DemoMode?
    #endif

    init() {
        var profile = ProfileStore()
        var transport: any PeerTransport = MultipeerTransport()
        #if DEBUG
        let demo = DemoMode.requestedScene.map(DemoMode.init(scene:))
        if let demo {
            profile = demo.profile
            transport = demo.transport
        }
        _demo = State(initialValue: demo)
        #endif
        // Keychain items survive deleting the app; a fresh install starts with a fresh identity.
        let installMarker = "identity.installMarker"
        if !UserDefaults.standard.bool(forKey: installMarker) {
            IdentityStore().clear()
            UserDefaults.standard.set(true, forKey: installMarker)
        }
        var identity: IdentityStore? = IdentityStore()
        #if DEBUG
        if demo != nil { identity = nil }
        #endif
        let session = SessionManager(transport: transport, profile: profile, safety: SafetyStore(), identity: identity)
        let games = GameCoordinator(session: session)
        let notifications = NotificationManager()
        notifications.install()
        let nudges = NudgeRouter(session: session, games: games, notifications: notifications, nudges: NudgeService())
        // Start Bluetooth right away (not from a view), so a background relaunch by iOS for
        // an incoming nudge can receive it before any UI exists.
        if profile.nickname != nil, identity != nil { nudges.start() }
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
                    #if DEBUG
                    if let demo {
                        await demo.run(session: session, games: games, app: appState)
                        return
                    }
                    #endif
                    // Ask for notifications and Bluetooth only after onboarding, when they make sense.
                    guard profile.nickname != nil else { return }
                    nudges.start()
                    await notifications.requestAuthorization()
                }
        }
        .onChange(of: scenePhase) { old, phase in
            notifications.isAppActive = phase == .active
            switch phase {
            case .inactive where old == .background:
                // Back on screen but not yet active, for example behind a system alert.
                // Peer-to-peer works now, so reconnect without waiting for the alert.
                session.resume()
            case .active where old == .inactive && !session.isSuspended:
                // Already resumed on the way through `.inactive`.
                break
            case .background:
                // iOS drops peer-to-peer sessions now anyway. Tell peers we're stepping away
                // first, so they show "away", keep the game paused, and nudge us over Bluetooth.
                nudges.appWillBackground()
                var task = UIBackgroundTaskIdentifier.invalid
                task = UIApplication.shared.beginBackgroundTask(withName: "Step away") {
                    // Out of time: suspend now rather than being terminated.
                    session.suspend()
                    UIApplication.shared.endBackgroundTask(task)
                    task = .invalid
                }
                Task {
                    await session.stepAway()
                    if task != .invalid {
                        UIApplication.shared.endBackgroundTask(task)
                        task = .invalid
                    }
                }
            case .active:
                session.resume()
            default:
                break
            }
        }
    }
}
