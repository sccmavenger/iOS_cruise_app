import SwiftUI

@main struct MyApp: App {
    @State private var profile: ProfileStore
    @State private var session: SessionManager
    @State private var games: GameCoordinator

    init() {
        let profile = ProfileStore()
        let session = SessionManager(transport: MultipeerTransport(), profile: profile, safety: SafetyStore())
        _profile = State(initialValue: profile)
        _session = State(initialValue: session)
        _games = State(initialValue: GameCoordinator(session: session))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(profile)
                .environment(session)
                .environment(games)
        }
    }
}
