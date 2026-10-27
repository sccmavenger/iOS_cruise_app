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
    @State private var telemetry: TelemetryStore
    @State private var probe: NetworkPathProbe
    @State private var reporter: TelemetryReporter
    /// The LAN side of the transport, kept so the troubleshooting page can offer a join
    /// code. Nil in demo builds, where the transport is faked.
    @State private var lan: LANTransport?
    @State private var connectionSettings: ConnectionSettings
    /// Whether games can be hosted online right now.
    @State private var online: OnlineStatus
    /// Open online games anyone can join.
    @State private var openGames: OpenGamesList
    #if DEBUG
    /// Scripted screenshot scene, when launched with `-CruiseLANDemo <scene>`.
    @State private var demo: DemoMode?
    #endif

    init() {
        var profile = ProfileStore()
        let telemetry = TelemetryStore()
        // Radio and ship-network transports run together: either can be the one that works,
        // and which one does is exactly what the telemetry is there to find out.
        // See docs/decisions/lan-transport.md.
        var lan: LANTransport? = LANTransport(telemetry: telemetry)
        let connectionSettings = ConnectionSettings()
        let composite = CompositeTransport(
            children: [
                // Radio links are labelled here because MultipeerConnectivity doesn't know
                // or expose which bearer it chose; the LAN transport reports its own tier
                // because only it knows whether Bonjour, a beacon, or a code found the peer.
                .init(MultipeerTransport(), tier: .multipeer),
                .init(lan!, tier: nil),
            ],
            telemetry: telemetry
        )
        // Before anything starts, so turning Nearby radio off holds across launches.
        composite.setEnabled(connectionSettings.nearbyRadioEnabled, for: .multipeer)
        var transport: any PeerTransport = composite
        #if DEBUG
        let demo = DemoMode.requestedScene.map(DemoMode.init(scene:))
        if let demo {
            profile = demo.profile
            transport = demo.transport
            lan = nil
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
        let session = SessionManager(transport: transport, profile: profile, safety: SafetyStore(),
                                     identity: identity, telemetry: telemetry)
        // Online games: hosted by the game service when the internet is reachable, on a phone
        // otherwise. Demo builds stay fully offline.
        let cloudService = LiveCloudGameService()
        let online = OnlineStatus(service: cloudService, settings: connectionSettings)
        var cloud: CloudGameService? = cloudService
        #if DEBUG
        if demo != nil { cloud = nil }
        #endif
        let games = GameCoordinator(
            session: session,
            cloud: cloud,
            cloudStore: CloudRoomStore(),
            onlineAvailable: { await online.currentlyOnline() }
        )
        connectionSettings.apply = { [weak session] enabled in
            composite.setEnabled(enabled, for: .multipeer)
            session?.restartTransport()
        }
        let notifications = NotificationManager()
        notifications.install()
        let nudges = NudgeRouter(session: session, games: games, notifications: notifications, nudges: NudgeService())
        // Start Bluetooth right away (not from a view), so a background relaunch by iOS for
        // an incoming nudge can receive it before any UI exists.
        if profile.nickname != nil, identity != nil { nudges.start() }
        let probe = NetworkPathProbe(telemetry: telemetry)
        // Read Bluetooth power from the manager NudgeService already owns, so the
        // troubleshooting page can tell "off" apart from "not permitted".
        let nudgeService = nudges.service
        probe.bluetoothStateProvider = { nudgeService.managerState }
        _profile = State(initialValue: profile)
        _session = State(initialValue: session)
        _games = State(initialValue: games)
        _notifications = State(initialValue: notifications)
        _nudges = State(initialValue: nudges)
        _telemetry = State(initialValue: telemetry)
        _probe = State(initialValue: probe)
        _reporter = State(initialValue: TelemetryReporter(store: telemetry))
        _lan = State(initialValue: lan)
        _connectionSettings = State(initialValue: connectionSettings)
        _online = State(initialValue: online)
        _openGames = State(initialValue: OpenGamesList(service: cloudService))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(profile)
                .environment(session)
                .environment(games)
                .environment(appState)
                .environment(notifications)
                .environment(telemetry)
                .environment(probe)
                .environment(\.lanTransport, lan)
                .environment(connectionSettings)
                .environment(online)
                .environment(openGames)
                .task(id: profile.nickname) {
                    #if DEBUG
                    if let demo {
                        await demo.run(session: session, games: games, app: appState)
                        return
                    }
                    #endif
                    // Ask for notifications and Bluetooth only after onboarding, when they make sense.
                    guard profile.nickname != nil else { return }
                    online.start()
                    // iOS may have quit the app mid-game; go back to the online game, if any.
                    games.restoreOnlineGame()
                    nudges.start()
                    probe.start()
                    await notifications.requestAuthorization()
                    await reporter.uploadIfDue()
                    #if DEBUG
                    // Scripted diagnostics: `-CruiseLANRunNetworkTest` runs the network test at launch.
                    if ProcessInfo.processInfo.arguments.contains("-CruiseLANRunNetworkTest") {
                        try? await Task.sleep(for: .seconds(6))
                        await NetworkTest.shared.run(lan: lan)
                    }
                    #endif
                }
        }
        .onChange(of: scenePhase) { old, phase in
            notifications.isAppActive = phase == .active
            switch phase {
            case .inactive where old == .background:
                // Back on screen but not yet active, for example behind a system alert.
                // Peer-to-peer works now, so reconnect without waiting for the alert.
                session.resume()
                online.refresh()
            case .active where old == .inactive && !session.isSuspended:
                // Already resumed on the way through `.inactive`.
                break
            case .background:
                // Keep what's been measured so far; a relaunch shouldn't lose the window.
                telemetry.persist()
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
                online.refresh()
            default:
                break
            }
        }
    }
}
