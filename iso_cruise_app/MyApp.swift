import SwiftUI

@main struct MyApp: App {
    @State private var profile: ProfileStore
    @State private var session: SessionManager

    init() {
        let profile = ProfileStore()
        _profile = State(initialValue: profile)
        _session = State(initialValue: SessionManager(transport: MultipeerTransport(), profile: profile))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(profile)
                .environment(session)
        }
    }
}
