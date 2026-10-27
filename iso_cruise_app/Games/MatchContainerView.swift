import SwiftUI

/// Full-screen container for the current lobby and its match.
struct MatchContainerView: View {
    @Environment(GameCoordinator.self) private var games
    @Environment(AppState.self) private var app
    @Environment(SessionManager.self) private var session
    @State private var confirmLeave = false
    @State private var reportTarget: ReportTarget?

    /// The other people at the table, for reporting during a match.
    private var otherPlayers: [LobbyPlayer] {
        games.lobby?.players.filter { $0.id != games.localId } ?? []
    }

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
                if AppFeatures.chatEnabled { ToolbarItem(placement: .primaryAction) {
                    // Tucks the game away so the player can chat while waiting for their turn,
                    // landing straight in the chat with the people at this table rather than
                    // on the conversation list (where the default is "Everyone", which goes
                    // to every contact — tester feedback, 2026-10-19).
                    Button {
                        if let conversation = games.matchConversation() {
                            app.open(conversation: conversation.id)
                        } else {
                            app.selectedTab = .chat
                        }
                        app.isMatchMinimized = true
                    } label: {
                        Label(session.chat.totalUnread > 0 ? "Chat (\(session.chat.totalUnread))" : "Chat", systemImage: "bubble.left.and.bubble.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityHint("Opens the chat with the players in this game. The game keeps going and you can come back anytime.")
                } }
                if games.lobby?.phase != .lobby, !otherPlayers.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            ForEach(otherPlayers) { player in
                                Button("Report \(player.nickname)", systemImage: "exclamationmark.bubble") {
                                    reportTarget = ReportTarget(identityId: player.id, name: player.nickname, message: nil, onlineCode: games.lobby?.cloudCode)
                                }
                            }
                        } label: {
                            Label("Report a Player", systemImage: "exclamationmark.bubble")
                        }
                    }
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
            .sheet(item: $reportTarget) { ReportView(target: $0) }
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
        .modifier(InviteSwitchAlert(isOnTop: true))
        .onAppear { app.isMatchVisible = true }
        .onDisappear { app.isMatchVisible = false }
    }

    private var leaveMessage: String {
        guard let lobby = games.lobby else { return "" }
        if lobby.isOnline {
            if lobby.phase == .lobby {
                if games.isHost { return lobby.players.count > 1 ? "Another player will become the host." : "The game will close." }
                return "Your seat will open up for someone else."
            }
            return "The game will end for the other players."
        }
        if games.isHost { return "You're the host. Leaving ends the game for everyone." }
        return lobby.phase == .lobby ? "Your seat will open up for someone else." : "The game will end for the other players."
    }
}

// MARK: - Lobby

struct LobbyView: View {
    let lobby: GameCoordinator.Lobby
    @Environment(GameCoordinator.self) private var games
    @Environment(SessionManager.self) private var session
    @State private var reportTarget: ReportTarget?

    private var me: LobbyPlayer? { lobby.player(games.localId) }

    /// Anyone nearby with CruiseLAN open who isn't already at this table.
    private var invitable: [PeerIdentity] {
        session.nearbyPlayers.filter { lobby.player($0.id) == nil }
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

            if let code = lobby.cloudCode {
                OnlineCodeSection(code: code, game: lobby.gameType, isConnected: games.isCloudConnected)
            }

            Section {
                ForEach(lobby.players) { player in
                    HStack {
                        Image(systemName: player.isHost ? "crown.fill" : "person.fill")
                            .foregroundStyle(player.isHost ? Theme.sunset : Theme.teal)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        // Online seats aren't mesh ids, so they have no tag to show.
                        Text(player.id == games.localId ? "\(player.nickname) (you)" : lobby.isOnline ? player.nickname : "\(player.nickname) #\(Nickname.tag(for: player.id))")
                        Spacer()
                        if games.awayIds.contains(player.id) {
                            Label("Away", systemImage: "moon.zzz.fill").foregroundStyle(.secondary)
                        } else if player.isHost {
                            Text("Host").foregroundStyle(.secondary)
                        } else if lobby.isOnline {
                            Label("Here", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label(player.isReady ? "Ready" : "Not ready", systemImage: player.isReady ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(player.isReady ? .green : .secondary)
                        }
                        if player.id != games.localId {
                            Menu {
                                if games.isHost {
                                    Button("Remove from Game", systemImage: "person.fill.xmark", role: .destructive) {
                                        games.removePlayer(player.id)
                                    }
                                }
                                Button("Report \(player.nickname)", systemImage: "exclamationmark.bubble") {
                                    reportTarget = ReportTarget(identityId: player.id, name: player.nickname, message: nil, onlineCode: lobby.cloudCode)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .imageScale(.large)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(.rect)
                                    .accessibilityLabel("Options for \(player.nickname)")
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
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
            } header: {
                Text("Players")
            } footer: {
                Label(lobby.isOpen
                      ? (lobby.isOnline ? "Open game: anyone using CruiseLAN can find and join it." : "Open game: anyone nearby with CruiseLAN can join.")
                      : (lobby.isOnline ? "Private game: only people with the code can join." : "Private game: only people you invite can join."),
                      systemImage: lobby.isOpen ? "person.3.fill" : "lock.fill")
            }

            if games.isHost {
                if !lobby.isFull {
                    Section {
                        if invitable.isEmpty {
                            Text("Nobody else nearby has CruiseLAN open right now.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(invitable, id: \.id) { identity in
                            Button {
                                games.invite(identity)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(identity.labeledName).foregroundStyle(.primary)
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
                        Text(lobby.isOnline ? "Invite people nearby" : "Invite")
                    } footer: {
                        Text(lobby.isOnline
                             ? "People nearby also see your game in their list and can join it."
                             : "Anyone nearby with CruiseLAN open sees your game and can join it.")
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
                    if !games.canStart, lobby.isOnline, !games.isCloudConnected {
                        Text("Connecting to the online game service…")
                    } else if !games.canStart {
                        Text(lobby.players.count < lobby.gameType.minPlayers
                             ? (lobby.gameType.minPlayers - lobby.players.count == 1 ? "Waiting for 1 more player." : "Waiting for \(lobby.gameType.minPlayers - lobby.players.count) more players.")
                             : lobby.players.contains(where: { games.awayIds.contains($0.id) })
                                ? (lobby.isOnline ? "Waiting for everyone to connect." : "Waiting for everyone to come back.")
                                : "Waiting for everyone to be ready.")
                    }
                }
            } else if lobby.isOnline {
                Section {
                    Label(games.isCloudConnected ? "You're in. The host starts the game when everyone's here." : "Connecting to the online game service…",
                          systemImage: games.isCloudConnected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
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
        .sheet(item: $reportTarget) { ReportView(target: $0) }
    }
}

// MARK: - Match

struct MatchView: View {
    let lobby: GameCoordinator.Lobby
    @Environment(GameCoordinator.self) private var games

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if games.lobby?.isOnline == true, !games.isCloudConnected {
                    AwayBanner(
                        title: "Reconnecting to the game…",
                        detail: "Your game is saved online. A move you make now is sent as soon as you're back.",
                        isReconnecting: true
                    )
                } else if !games.awayIds.isEmpty {
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
                case .spades(let table):
                    SpadesView(table: table)
                case .tonk(let table):
                    TonkView(table: table)
                case nil:
                    ProgressView(lobby.isOnline ? "Connecting to the game…" : "Waiting for the host…")
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

/// An online game's invite code, to read out or share.
struct OnlineCodeSection: View {
    let code: String
    let game: GameType
    let isConnected: Bool

    var body: some View {
        let shown = CloudConfig.displayCode(code)
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invite code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(shown)
                        .font(.title.monospaced().weight(.bold))
                        .textSelection(.enabled)
                        .accessibilityLabel("Invite code \(shown.map(String.init).joined(separator: " "))")
                }
                Spacer()
                ShareLink(
                    item: InviteLink.url(for: code),
                    subject: Text("Play \(game.displayName) with me"),
                    message: Text("Join my \(game.displayName) game on CruiseLAN. Tap the link to jump in, or enter code \(shown).")
                ) {
                    Label("Share Invite", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glass)
            }
        } header: {
            Label("Online game", systemImage: isConnected ? "globe" : "arrow.triangle.2.circlepath")
        } footer: {
            Text("Share the invite: one tap on the link opens CruiseLAN and joins this game, from any network or city. Without the app, the link shows how to get it. The game is saved online, so it keeps going even if someone's phone drops out.")
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
        if lobby.isOnline { return "\(names) \(games.awayIds.count == 1 ? "is" : "are") away" }
        if isReconnecting { return "Reconnecting to \(names)…" }
        // Only say they stepped away if their app said so; otherwise we just can't reach them.
        let saidAway = games.awayIds.isSubset(of: games.session.steppedAwayIds)
        return saidAway ? "\(names) stepped away" : "Can't reach \(names) right now"
    }

    fileprivate var awayDetail: String {
        if lobby.isOnline { return "The game is saved online and carries on when they're back." }
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
