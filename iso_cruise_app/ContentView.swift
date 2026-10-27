import SwiftUI

/// Root of the app: onboarding until a nickname exists, then Games (plus Chat when enabled).
struct ContentView: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(SessionManager.self) private var session
    @Environment(AppState.self) private var app

    /// Shown once after onboarding. Presented *after* the permission prompts rather than
    /// before, so the live peer list on it can actually find people — an explanation of
    /// discovery is worth much less than watching it happen.
    @State private var showConnectGuide = false

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
        .sheet(isPresented: $showConnectGuide) {
            GetConnectedView()
        }
        // Invite links: the custom scheme, and Universal Links (which SwiftUI also delivers here).
        .onOpenURL { url in
            if let code = InviteLink.code(from: url) { app.pendingInviteCode = code }
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL, let code = InviteLink.code(from: url) { app.pendingInviteCode = code }
        }
        .onChange(of: profile.nickname, initial: true) { _, nickname in
            // The connect guide is about connecting to people for chat; games don't need it.
            guard AppFeatures.chatEnabled, nickname != nil, !profile.hasSeen(.connectGuide) else { return }
            // A beat after the permission prompts, so it doesn't fight them for the screen.
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard !profile.hasSeen(.connectGuide) else { return }
                showConnectGuide = true
            }
        }
        // Connection requests don't pop up: they wait in People › Requests, and the Chats
        // banner says how many are waiting. (See docs/decisions/connection-requests.md.)
    }
}

struct MainTabView: View {
    @Environment(GameCoordinator.self) private var games
    @Environment(AppState.self) private var app
    @Environment(NotificationManager.self) private var notifications
    @Environment(SessionManager.self) private var session
    /// Driven from the lobby state with a short delay so any open sheet can finish
    /// dismissing first; UIKit drops a presentation that starts while another is closing.
    @State private var showMatch = false

    var body: some View {
        @Bindable var app = app
        Group {
            if AppFeatures.chatEnabled {
                TabView(selection: $app.selectedTab) {
                    Tab("Games", systemImage: "gamecontroller.fill", value: AppState.Tab.games) {
                        GamesHomeView()
                    }
                    Tab("Chat", systemImage: "bubble.left.and.bubble.right.fill", value: AppState.Tab.chat) {
                        ChatView()
                    }
                    .badge(session.chat.totalUnread)
                }
                // While the match is tucked away, a bar above the tabs leads back to it.
                .tabViewBottomAccessory(isEnabled: games.lobby != nil && app.isMatchMinimized) {
                    MatchAccessoryView()
                }
            } else {
                // Games is the whole app while chat is off.
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
                app.isMatchMinimized = false
            }
        }
        .onChange(of: app.isMatchMinimized) { _, minimized in
            if minimized {
                showMatch = false
            } else {
                presentMatchSoon()
            }
        }
        .onChange(of: app.isMatchVisible) { _, visible in
            // If the cover went away while a match is still active and not minimized (for
            // example the system dismissed it), bring it back.
            if !visible, games.lobby != nil, !app.isMatchMinimized {
                showMatch = false
                presentMatchSoon()
            }
        }
        // The conversation on screen (if any) isn't counted unread and gets no banners.
        .onChange(of: visibleConversation, initial: true) { _, id in
            session.chat.visibleConversationId = id
            if let id { notifications.clearDelivered(for: id) }
        }
        .onChange(of: isChatListOnScreen, initial: true) { _, onScreen in
            notifications.isChatListOnScreen = onScreen
        }
        .onChange(of: session.chat.totalUnread, initial: true) { _, count in
            notifications.setBadge(AppFeatures.chatEnabled ? count : 0)
        }
        .onChange(of: app.isMatchVisible, initial: true) { _, visible in
            notifications.isMatchOnScreen = visible
        }
        // An invite link: straight into that game. `initial`: it may have opened the app.
        .onChange(of: app.pendingInviteCode, initial: true) { _, code in
            guard let code else { return }
            app.pendingInviteCode = nil
            openInvite(code)
        }
        .modifier(InviteSwitchAlert(isOnTop: !app.isMatchVisible))
        // `initial`: a notification tapped while the app was closed sets the route before this view exists.
        .onChange(of: notifications.pendingRoute, initial: true) { _, route in
            guard let route else { return }
            notifications.pendingRoute = nil
            open(route)
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

    private var isChatListOnScreen: Bool {
        app.selectedTab == .chat && !app.isMatchVisible && app.chatPath.isEmpty
    }

    private var visibleConversation: UUID? {
        guard notifications.isAppActive, app.selectedTab == .chat, !app.isMatchVisible else { return nil }
        return app.openConversation
    }

    /// Navigates for a tapped notification.
    private func open(_ route: NotificationManager.Route) {
        switch route {
        case .chat where !AppFeatures.chatEnabled, .chats where !AppFeatures.chatEnabled:
            app.selectedTab = .games
        case .chat(let id):
            if session.chat.conversation(id) != nil { app.open(conversation: id) } else { app.selectedTab = .chat }
            if games.lobby != nil { app.isMatchMinimized = true }
        case .chats:
            app.selectedTab = .chat
            app.chatPath = []
            if games.lobby != nil { app.isMatchMinimized = true }
        case .games:
            app.selectedTab = .games
            if games.lobby != nil { app.isMatchMinimized = true }
        case .game:
            if games.lobby != nil { app.isMatchMinimized = false }
        }
    }

    /// Joins the game an invite link points to, or shows it if the player is already in it.
    private func openInvite(_ code: String) {
        if let lobby = games.lobby {
            if lobby.cloudCode == code {
                app.isMatchMinimized = false
                presentMatchSoon()
                return
            }
            if case .ended = lobby.phase {
                games.dismissEndedMatch()
            } else {
                app.switchToInviteCode = code
                return
            }
        }
        app.selectedTab = .games
        app.sheetDismissals += 1
        games.joinOnline(code: code)
    }

    /// Closes any open sheet, then shows the match. If UIKit drops the presentation (it does
    /// when another one is still closing), it's noticed and retried a few times.
    private func presentMatchSoon(attempt: Int = 0) {
        app.sheetDismissals += 1
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard games.lobby != nil, !app.isMatchMinimized else { return }
            showMatch = true
            try? await Task.sleep(for: .milliseconds(1_200))
            if games.lobby != nil, !app.isMatchMinimized, !app.isMatchVisible, attempt < 4 {
                showMatch = false
                presentMatchSoon(attempt: attempt + 1)
            }
        }
    }

    private var gameInvitationTitle: String {
        guard let invitation = games.invitation else { return "" }
        return "\(invitation.host.labeledName) invited you to play \(invitation.payload.gameType.displayName)"
    }
}

/// "Join another game?" for an invite that arrives mid-game. Attached both to the main screen and
/// to the match (whichever is on top shows it).
struct InviteSwitchAlert: ViewModifier {
    let isOnTop: Bool
    @Environment(GameCoordinator.self) private var games
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        content.alert(
            "Join another game?",
            isPresented: Binding(
                get: { isOnTop && app.switchToInviteCode != nil },
                set: { if !$0 { app.switchToInviteCode = nil } }
            )
        ) {
            Button("Leave and Join") {
                guard let code = app.switchToInviteCode else { return }
                app.switchToInviteCode = nil
                games.leave()
                games.joinOnline(code: code)
            }
            Button("Stay", role: .cancel) { app.switchToInviteCode = nil }
        } message: {
            Text("You're in a \(games.lobby?.gameType.displayName ?? "") game. Leaving it ends it for the other players if it's started.")
        }
    }
}

/// The "Back to game" bar shown above the tabs while a match is minimized.
///
/// iOS places this above the tab bar at normal size and *inline with it* once the tab bar
/// collapses, so the content has to work at two very different widths — two stacked lines of
/// text don't fit inline. `tabViewBottomAccessoryPlacement` says which one we're in.
struct MatchAccessoryView: View {
    @Environment(GameCoordinator.self) private var games
    @Environment(AppState.self) private var app
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { placement == .inline }

    var body: some View {
        Button {
            app.isMatchMinimized = false
        } label: {
            HStack(spacing: isInline ? 8 : 12) {
                Image(systemName: games.isAwaitingMe ? "hand.point.right.fill" : "gamecontroller.fill")
                    .foregroundStyle(games.isAwaitingMe ? Theme.sunset : Theme.teal)
                    .symbolEffect(.bounce, value: games.isAwaitingMe)
                if isInline {
                    // One line only: the title would push "Return" off the edge.
                    Text(status)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(games.isAwaitingMe ? Theme.sunset : .secondary)
                        .lineLimit(1)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(games.lobby?.gameType.displayName ?? "Game")
                            .font(.subheadline.weight(.semibold))
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(games.isAwaitingMe ? Theme.sunset : .secondary)
                    }
                }
                Spacer(minLength: 0)
                Text("Return")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.teal)
            }
            .padding(.horizontal, isInline ? 12 : 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Return to \(games.lobby?.gameType.displayName ?? "game"), \(status)")
    }

    private var status: String {
        guard let lobby = games.lobby else { return "" }
        switch lobby.phase {
        case .ended: return "Game over"
        case .lobby: return "In the lobby"
        case .playing: break
        }
        if let away = games.awayIds.first {
            return games.reconnectingIds.contains(away) ? "Reconnecting…" : "Waiting for \(games.name(for: away)) to come back"
        }
        if games.isAwaitingMe { return "Your turn!" }
        if games.snapshot?.isFinished == true { return "Round over" }
        if let next = games.snapshot?.awaitingPlayerIds.first { return "\(games.name(for: next))'s turn" }
        return "In progress"
    }
}

#Preview {
    let profile = ProfileStore()
    let session = SessionManager(transport: MultipeerTransport(), profile: profile)
    let settings = ConnectionSettings()
    ContentView()
        .environment(settings)
        .environment(OnlineStatus(service: LiveCloudGameService(), settings: settings))
        .environment(profile)
        .environment(session)
        .environment(GameCoordinator(session: session))
        .environment(AppState())
        .environment(NotificationManager())
}
