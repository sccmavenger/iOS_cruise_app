import SwiftUI

/// Full-screen container for the current lobby and its match.
struct MatchContainerView: View {
    @Environment(GameCoordinator.self) private var games
    @Environment(AppState.self) private var app
    @Environment(SessionManager.self) private var session
    @State private var confirmLeave = false

    var body: some View {
        @Bindable var games = games
        NavigationStack {
            Group {
                if let lobby = games.lobby {
                    switch lobby.phase {
                    case .lobby:
                        LobbyView(lobby: lobby)
                    case .playing:
                        MatchView(lobby: lobby)
                    case .ended(let reason):
                        MatchEndedView(reason: reason)
                    }
                }
            }
            .navigationTitle(games.lobby?.gameType.displayName ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // Tucks the game away so the player can chat while waiting for their turn.
                    Button {
                        app.selectedTab = .chat
                        app.isMatchMinimized = true
                    } label: {
                        Label(session.chat.totalUnread > 0 ? "Chat (\(session.chat.totalUnread))" : "Chat", systemImage: "bubble.left.and.bubble.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityHint("Shows the chat. The game keeps going and you can come back anytime.")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Leave", role: .destructive) {
                        if case .ended = games.lobby?.phase {
                            games.dismissEndedMatch()
                        } else {
                            confirmLeave = true
                        }
                    }
                }
            }
            .alert("Leave this game?", isPresented: $confirmLeave) {
                Button("Leave Game", role: .destructive) { games.leave() }
                Button("Stay", role: .cancel) {}
            } message: {
                Text(leaveMessage)
            }
            .alert(
                games.notice ?? "",
                isPresented: Binding(
                    get: { games.notice != nil },
                    set: { if !$0 { games.notice = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled()
        .onAppear { app.isMatchVisible = true }
        .onDisappear { app.isMatchVisible = false }
    }

    private var leaveMessage: String {
        guard let lobby = games.lobby else { return "" }
        if games.isHost { return "You're the host. Leaving ends the game for everyone." }
        return lobby.phase == .lobby ? "Your seat will open up for someone else." : "The game will end for the other players."
    }
}

// MARK: - Lobby

struct LobbyView: View {
    let lobby: GameCoordinator.Lobby
    @Environment(GameCoordinator.self) private var games
    @Environment(SessionManager.self) private var session

    private var me: LobbyPlayer? { lobby.player(games.localId) }

    /// Connected people, plus people who are away (they get a notification and the invite when they're back).
    private var invitable: [PeerIdentity] {
        session.reachableIdentities.filter { lobby.player($0.id) == nil }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    GameArtwork(game: lobby.gameType)
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(games.isHost ? "You're hosting" : "Hosted by \(games.name(for: lobby.hostId))")
                            .font(.headline)
                        Text("\(lobby.players.count) of \(lobby.maxSeats) seats filled")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Players") {
                ForEach(lobby.players) { player in
                    HStack {
                        Image(systemName: player.isHost ? "crown.fill" : "person.fill")
                            .foregroundStyle(player.isHost ? Theme.sunset : Theme.teal)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        Text(player.id == games.localId ? "\(player.nickname) (you)" : "\(player.nickname) #\(Nickname.tag(for: player.id))")
                        Spacer()
                        if games.awayIds.contains(player.id) {
                            Label("Away", systemImage: "moon.zzz.fill").foregroundStyle(.secondary)
                        } else if player.isHost {
                            Text("Host").foregroundStyle(.secondary)
                        } else {
                            Label(player.isReady ? "Ready" : "Not ready", systemImage: player.isReady ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(player.isReady ? .green : .secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(lobby.players.count..<lobby.maxSeats, id: \.self) { _ in
                    HStack {
                        Image(systemName: "chair")
                            .foregroundStyle(.tertiary)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        Text("Open seat").foregroundStyle(.secondary)
                    }
                }
            }

            if games.isHost {
                if !lobby.isFull {
                    Section {
                        if invitable.isEmpty {
                            Text("No other connected people to invite. Connect to people from the Chat tab.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(invitable, id: \.id) { identity in
                            Button {
                                games.invite(identity)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(identity.labeledName).foregroundStyle(.primary)
                                        if !session.isConnected(identity.id) {
                                            Text("Away · gets a notification")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(games.invitedIds.contains(identity.id) ? "Invited" : "Invite")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(games.invitedIds.contains(identity.id) ? Color.secondary : Theme.teal)
                                }
                            }
                            .disabled(games.invitedIds.contains(identity.id))
                        }
                    } header: {
                        Text("Invite")
                    } footer: {
                        Text("Your game is also visible to everyone you're connected with.")
                    }
                }

                Section {
                    Button {
                        games.startGame()
                    } label: {
                        Text("Start Game")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!games.canStart)
                    .listRowBackground(Color.clear)
                } footer: {
                    if !games.canStart {
                        Text(lobby.players.count < lobby.gameType.minPlayers
                             ? "Waiting for \(lobby.gameType.minPlayers - lobby.players.count) more player(s)."
                             : lobby.players.contains(where: { games.awayIds.contains($0.id) })
                                ? "Waiting for everyone to come back."
                                : "Waiting for everyone to be ready.")
                    }
                }
            } else if let me {
                Section {
                    Button {
                        games.setReady(!me.isReady)
                    } label: {
                        Text(me.isReady ? "I'm Not Ready" : "I'm Ready")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("The host starts the game once everyone is ready.")
                }
            }
        }
    }
}

// MARK: - Match

struct MatchView: View {
    let lobby: GameCoordinator.Lobby
    @Environment(GameCoordinator.self) private var games

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !games.awayIds.isEmpty {
                    AwayBanner(title: awayTitle, detail: awayDetail, isReconnecting: isReconnecting)
                }
                switch games.snapshot {
                case .ticTacToe(let state):
                    TicTacToeView(state: state)
                case .connectFour(let state):
                    ConnectFourView(state: state)
                case .colorMatch(let table):
                    ColorMatchView(table: table)
                case .checkers(let state):
                    CheckersView(state: state)
                case .chess(let state):
                    ChessView(state: state)
                case nil:
                    ProgressView("Waiting for the host…")
                        .padding(.top, 80)
                }
            }
            .padding()
        }
        .background(alignment: .bottom) {
            SeaView()
                .frame(height: 90)
                .opacity(0.35)
                .ignoresSafeArea()
        }
    }
}

/// Shown while someone's app is in the background: the match is paused, not over.
struct AwayBanner: View {
    let title: String
    let detail: String
    var isReconnecting = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: isReconnecting ? "arrow.triangle.2.circlepath" : "pause.circle.fill")
                .foregroundStyle(isReconnecting ? Theme.teal : Theme.sunset)
                .symbolEffect(.rotate, isActive: isReconnecting)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

extension MatchView {
    /// Everyone missing dropped because our own app was away: we're the one catching up.
    fileprivate var isReconnecting: Bool {
        !games.awayIds.isEmpty && games.awayIds.isSubset(of: games.reconnectingIds)
    }

    fileprivate var awayTitle: String {
        let names = games.awayIds.sorted().map(games.name(for:)).formatted(.list(type: .and))
        if isReconnecting { return "Reconnecting to \(names)…" }
        // Only say they stepped away if their app said so; otherwise we just can't reach them.
        let saidAway = games.awayIds.isSubset(of: games.session.steppedAwayIds)
        return saidAway ? "\(names) stepped away" : "Can't reach \(names) right now"
    }

    fileprivate var awayDetail: String {
        if isReconnecting { return "You were away for a moment. This usually takes a few seconds." }
        if games.relayedMoveDelivered {
            return "Your move reached their phone over Bluetooth. It shows here when they're back."
        }
        if games.isHostAway {
            return "You can still play: your move goes to their phone over Bluetooth, and they get a notification."
        }
        return "Their phone gets a notification when it's their turn. The game waits up to 10 minutes."
    }
}

struct MatchEndedView: View {
    let reason: String
    @Environment(GameCoordinator.self) private var games
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 20) {
            IllustratedMessage(title: "Game over", message: reason)
            Button {
                games.dismissEndedMatch()
                app.selectedTab = .games
            } label: {
                Text("Back to Games")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal)
            Spacer()
        }
        .padding(.top, 24)
    }
}

/// Shared footer for finished rounds: rematch voting.
struct RematchControls: View {
    var title = "Rematch"
    var waitingTitle = "Waiting for opponent…"
    @Environment(GameCoordinator.self) private var games

    var body: some View {
        let voted = games.rematchVotes.contains(games.localId)
        let othersWaiting = games.rematchVotes.subtracting([games.localId])
        VStack(spacing: 8) {
            Button {
                games.requestRematch()
            } label: {
                Label(voted ? waitingTitle : title, systemImage: "arrow.clockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(voted)
            if !othersWaiting.isEmpty, !voted {
                Text("\(othersWaiting.map(games.name(for:)).joined(separator: ", ")) \(othersWaiting.count == 1 ? "is" : "are") ready to go again!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
