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
    @Environment(GameCoordinator.self) private var games
    /// Driven from the lobby state with a short delay so any open sheet can finish
    /// dismissing first; UIKit drops a presentation that starts while another is closing.
    @State private var showMatch = false

    var body: some View {
        TabView {
            Tab("Chat", systemImage: "bubble.left.and.bubble.right.fill") {
                ChatView()
            }
            Tab("Games", systemImage: "gamecontroller.fill") {
                GamesHomeView()
            }
        }
        // Presented from the root so a match opens no matter which tab is showing.
        .fullScreenCover(isPresented: $showMatch) {
            MatchContainerView()
        }
        .onChange(of: games.lobby != nil) { _, active in
            if active {
                presentMatchSoon()
            } else {
                showMatch = false
            }
        }
        .onChange(of: showMatch) { _, showing in
            // If the system dropped the cover while a match is still active, bring it back.
            if !showing, games.lobby != nil { presentMatchSoon() }
        }
        .alert(
            gameInvitationTitle,
            isPresented: Binding(
                get: { games.invitation != nil },
                set: { _ in }
            ),
            presenting: games.invitation
        ) { _ in
            Button("Join") { games.respondToInvitation(accept: true) }
            Button("Decline", role: .cancel) { games.respondToInvitation(accept: false) }
        } message: { invitation in
            Text("\(invitation.payload.seatsTaken) of \(invitation.payload.maxSeats) seats taken.")
        }
    }

    private func presentMatchSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if games.lobby != nil { showMatch = true }
        }
    }

    private var gameInvitationTitle: String {
        guard let invitation = games.invitation else { return "" }
        return "\(invitation.host.labeledName) invited you to play \(invitation.payload.gameType.displayName)"
    }
}

#Preview {
    let profile = ProfileStore()
    let session = SessionManager(transport: MultipeerTransport(), profile: profile)
    ContentView()
        .environment(profile)
        .environment(session)
        .environment(GameCoordinator(session: session))
}
