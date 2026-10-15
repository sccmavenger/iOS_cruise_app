import SwiftUI

/// Full-screen container for the current lobby and its match.
struct MatchContainerView: View {
    @Environment(GameCoordinator.self) private var games
    @Environment(AppState.self) private var app
    @Environment(NotificationManager.self) private var notifications
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
                        Label(notifications.unreadChatCount > 0 ? "Chat (\(notifications.unreadChatCount))" : "Chat", systemImage: "bubble.left.and.bubble.right")
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
                Text(games.isHost ? "You're the host. Leaving ends the game for everyone." : "The game will end for the other players.")
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
    }
}

// MARK: - Lobby

struct LobbyView: View {
    let lobby: GameCoordinator.Lobby
    @Environment(GameCoordinator.self) private var games
    @Environment(SessionManager.self) private var session

    private var me: LobbyPlayer? { lobby.player(games.localId) }

    private var invitable: [PeerIdentity] {
        session.connectedIdentities.filter { lobby.player($0.id) == nil }
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
                        if player.isHost {
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
                                    Text(identity.labeledName).foregroundStyle(.primary)
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
                    AwayBanner(names: games.awayIds.sorted().map(games.name(for:)))
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
    let names: [String]

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(names.formatted(.list(type: .and))) stepped away")
                    .font(.subheadline.weight(.semibold))
                Text("The game is paused. Their phone gets a nudge when it's their turn.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(Theme.sunset)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

struct MatchEndedView: View {
    let reason: String
    @Environment(GameCoordinator.self) private var games

    var body: some View {
        VStack(spacing: 20) {
            IllustratedMessage(title: "Game over", message: reason)
            Button {
                games.dismissEndedMatch()
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
