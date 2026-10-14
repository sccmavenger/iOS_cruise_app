import SwiftUI

/// Root of the app: onboarding until a nickname exists, then the Chat / Games tabs.
struct ContentView: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(SessionManager.self) private var session

    var body: some View {
        Group {
            if profile.nickname == nil {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .task(id: profile.nickname) {
            if profile.nickname != nil, session.status == .idle {
                session.start()
            }
        }
        .alert(
            invitationTitle,
            isPresented: Binding(
                get: { session.invitations.first != nil },
                set: { _ in }
            ),
            presenting: session.invitations.first
        ) { invitation in
            Button("Accept") { session.respond(to: invitation, accept: true) }
            Button("Decline", role: .cancel) { session.respond(to: invitation, accept: false) }
        } message: { _ in
            Text("Only accept people you recognize. Names aren't verified.")
        }
    }

    private var invitationTitle: String {
        guard let invitation = session.invitations.first else { return "" }
        return "\(invitation.displayName) wants to connect"
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Chat", systemImage: "bubble.left.and.bubble.right.fill") {
                ChatView()
            }
            Tab("Games", systemImage: "gamecontroller.fill") {
                GamesHomeView()
            }
        }
    }
}

#Preview {
    let profile = ProfileStore()
    ContentView()
        .environment(profile)
        .environment(SessionManager(transport: MultipeerTransport(), profile: profile))
}
