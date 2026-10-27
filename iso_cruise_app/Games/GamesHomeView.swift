import SwiftUI

/// The single Games tab listing every title, open games nearby, and the active match.
struct GamesHomeView: View {
    @Environment(GameCoordinator.self) private var games
    @Environment(SessionManager.self) private var session
    @Environment(AppState.self) private var app
    @Environment(OnlineStatus.self) private var online
    @Environment(OpenGamesList.self) private var openGames
    @State private var selectedGame: GameType?
    @State private var isJoiningByCode = false
    @State private var showProfile = false

    var body: some View {
        @Bindable var games = games
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HostingModeBanner(isEmpty: session.nearbyPlayers.isEmpty)
                    if online.canPlayOnline {
                        Button {
                            isJoiningByCode = true
                        } label: {
                            Label("Join a Game with a Code", systemImage: "number.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .disabled(games.lobby != nil || games.isConnectingOnline)
                    }

                    ForEach(GameType.allCases) { game in
                        Button {
                            selectedGame = game
                        } label: {
                            GameTile(game: game, isAvailable: game.isPlayable, openCount: openCount(for: game))
                        }
                        .buttonStyle(.plain)
                        .disabled(!game.isPlayable)
                    }
                }
                .padding()
            }
            .overlay {
                // Creating or joining an online game takes a moment; say so.
                if games.isConnectingOnline {
                    ProgressView(games.connectingMessage)
                        .padding(24)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
            }
            .navigationTitle("Games")
            .onAppear { openGames.startWatching() }
            .onDisappear { openGames.stopWatching() }
            // A game just started or ended here: the list changed, so don't wait for the next refresh.
            .onChange(of: games.lobby?.id) { Task { await openGames.refresh() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Profile", systemImage: "person.crop.circle") { showProfile = true }
                }
            }
            .sheet(isPresented: $showProfile) { ProfileView() }
            .sheet(item: $selectedGame) { game in
                GameDetailSheet(game: game)
            }
            .sheet(isPresented: $isJoiningByCode) {
                JoinOnlineSheet()
            }
            .onChange(of: app.sheetDismissals) {
                selectedGame = nil
                isJoiningByCode = false
                showProfile = false
            }
            .alert(
                games.notice ?? "",
                isPresented: Binding(
                    // While a match is on screen, the match shows its own notices; while one of this
                    // screen's sheets is up, the sheet does (two alerts for one notice would make
                    // iOS close the sheet and lose the message, as joining with a wrong code did).
                    get: { games.notice != nil && !app.isMatchVisible && !isJoiningByCode && selectedGame == nil && !showProfile },
                    set: { if !$0 { games.notice = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            }
        }
    }
}

/// Play a title: Quick Play, host (open to anyone, or private), or pick an open game.
struct GameDetailSheet: View {
    let game: GameType
    @Environment(GameCoordinator.self) private var games
    @Environment(SessionManager.self) private var session
    @Environment(AppState.self) private var app
    @Environment(OnlineStatus.self) private var online
    @Environment(OpenGamesList.self) private var openGames
    @Environment(\.dismiss) private var dismiss
    /// Open (anyone can join) is the default; private is the option.
    @State private var hostOpen = true

    private var isBusy: Bool { games.lobby != nil || games.joiningLobbyId != nil || games.isConnectingOnline }

    /// Online open games for this title, plus games hosted on phones nearby. A nearby friend's
    /// online game shows once, as an online game.
    private var onlineGames: [OpenGame] {
        guard online.canPlayOnline else { return [] }
        return openGames.games(for: game, excluding: games.removedFromCodes.union(games.lobby?.cloudCode.map { [$0] } ?? []))
    }

    private var nearbyOffers: [GameCoordinator.Offer] {
        let listed = Set(onlineGames.map(\.code))
        return games.offers(for: game).filter { $0.payload.cloudCode.map { !listed.contains($0) } ?? true }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        GameArtwork(game: game)
                            .frame(width: 72, height: 72)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(game.tagline)
                            Text(game.playerCountText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let current = games.lobby {
                    Section {
                        Button {
                            dismiss()
                            app.isMatchMinimized = false
                        } label: {
                            Label("Back to your \(current.gameType.displayName) game", systemImage: "arrow.uturn.backward.circle.fill")
                        }
                    } footer: {
                        Text("You're already in a game. Finish or leave it to host or join another one.")
                    }
                }

                Section {
                    Button {
                        games.quickPlay(game)
                        dismiss()
                    } label: {
                        Label("Quick Play", systemImage: "bolt.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(isBusy)
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(online.canPlayOnline
                         ? "Joins an open game that's waiting for players, or starts one that anyone can join."
                         : "Joins an open game nearby, or starts one that anyone nearby can join.")
                }

                Section {
                    Picker("Who can join", selection: $hostOpen) {
                        Text("Anyone").tag(true)
                        Text("Private").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Button {
                        games.hostLobby(game, open: hostOpen)
                        dismiss()
                    } label: {
                        // Grey the whole row (icon included) when it can't be used, so it doesn't look tappable.
                        Label("Host a New Game", systemImage: "plus.circle.fill")
                            .foregroundStyle(isBusy ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    }
                    .disabled(isBusy)
                } header: {
                    Text("Host")
                } footer: {
                    Text(hostFooter)
                }

                Section("Open games") {
                    if onlineGames.isEmpty, nearbyOffers.isEmpty {
                        Text(online.canPlayOnline || !session.nearbyPlayers.isEmpty
                             ? "No open games right now. Host one, or use Quick Play."
                             : "Nobody nearby has CruiseLAN open right now.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(onlineGames) { entry in
                        Button {
                            games.joinOnline(code: entry.code)
                            dismiss()
                        } label: {
                            OpenGameRow(host: entry.host, seats: entry.seats, maxSeats: entry.maxSeats, place: "Online", isJoining: false)
                        }
                        .disabled(isBusy)
                        .accessibilityHint("Joins this game")
                    }
                    ForEach(nearbyOffers) { offer in
                        Button {
                            games.join(offer)
                            // Close right away so the game screen can appear when the host accepts.
                            dismiss()
                        } label: {
                            OpenGameRow(host: offer.host.labeledName, seats: offer.payload.seatsTaken, maxSeats: offer.payload.maxSeats,
                                        place: offer.payload.cloudCode == nil ? "Nearby" : "Online", isJoining: games.joiningLobbyId == offer.id)
                        }
                        .disabled(offer.isFull || isBusy)
                        .accessibilityHint("Asks the host for a seat")
                    }
                }
            }
            .navigationTitle(game.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: games.lobby?.id) { _, id in
                if id != nil { dismiss() }
            }
            .onAppear { openGames.startWatching() }
            .onDisappear { openGames.stopWatching() }
        }
    }

    private var hostFooter: String {
        switch (online.canPlayOnline, hostOpen) {
        case (true, true): "Anyone using CruiseLAN can find it and join, from anywhere. You also get a code to share."
        case (true, false): "Only people you give the code to can join."
        case (false, true): "Hosted on your phone. Anyone nearby with CruiseLAN open sees it and can join."
        case (false, false): "Hosted on your phone. Only people you invite from the lobby can join."
        }
    }
}

/// One open game in the list: whose it is, how full, and where it's hosted.
struct OpenGameRow: View {
    let host: String
    let seats: Int
    let maxSeats: Int
    let place: String
    let isJoining: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("\(host)'s game")
                    .foregroundStyle(.primary)
                Text("\(seats) of \(maxSeats) seats taken · \(place)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isJoining {
                ProgressView()
            } else {
                Text(seats >= maxSeats ? "Full" : "Join")
                    .fontWeight(.semibold)
                    .foregroundStyle(seats >= maxSeats ? Color.secondary : Theme.teal)
            }
        }
    }
}

/// Says who will host a new game right now, since that decides who can join.
struct HostingModeBanner: View {
    /// Nobody nearby has CruiseLAN open.
    let isEmpty: Bool
    @Environment(OnlineStatus.self) private var online

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .accessibilityElement(children: .combine)
    }

    private var text: String {
        if online.canPlayOnline {
            return "Online: games are hosted on the internet. Play with anyone, anywhere, with a code."
        }
        if online.isEnabled, online.state == .checking {
            return "Checking your internet connection…"
        }
        let nearby = isEmpty ? " Nobody nearby has CruiseLAN open yet." : ""
        return online.isEnabled
            ? "No internet: games are hosted on a phone. Anyone nearby with CruiseLAN can join.\(nearby)"
            : "Online games are off in Profile: games are hosted on a phone nearby.\(nearby)"
    }

    private var symbol: String {
        if online.canPlayOnline { return "globe" }
        return online.state == .checking && online.isEnabled ? "globe.badge.chevron.backward" : "person.2.wave.2"
    }
}

/// Enter a friend's invite code to join their online game from anywhere.
struct JoinOnlineSheet: View {
    @Environment(GameCoordinator.self) private var games
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @FocusState private var focused: Bool

    /// The code typed, or the one inside a pasted invite link.
    private var cleaned: String { InviteLink.code(fromText: code) ?? "" }

    var body: some View {
        @Bindable var games = games
        NavigationStack {
            Form {
                Section {
                    TextField("ABCD-1234", text: $code)
                        .font(.title2.monospaced().weight(.semibold))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.join)
                        .onSubmit(join)
                        .accessibilityLabel("Invite code")
                } footer: {
                    Text("The host sees the code in their game's lobby. It's 8 letters and numbers. You can also paste an invite link here.")
                }
                Section {
                    Button(action: join) {
                        HStack {
                            Text("Join Game").font(.headline)
                            if games.isConnectingOnline {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(cleaned.isEmpty || games.isConnectingOnline)
                }
            }
            .navigationTitle("Join with a Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
            .onChange(of: games.lobby?.id) { _, id in
                if id != nil { dismiss() }
            }
            .alert(
                games.notice ?? "",
                isPresented: Binding(get: { games.notice != nil }, set: { if !$0 { games.notice = nil } })
            ) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func join() {
        guard !cleaned.isEmpty else { return }
        games.joinOnline(code: cleaned)
    }
}

extension GamesHomeView {
    /// Open games for a title: online ones plus phone-hosted ones nearby.
    fileprivate func openCount(for game: GameType) -> Int {
        let online = self.online.canPlayOnline ? openGames.games(for: game, excluding: games.removedFromCodes) : []
        let listed = Set(online.map(\.code))
        let nearby = games.offers(for: game).filter { $0.payload.cloudCode.map { !listed.contains($0) } ?? true }
        return online.count + nearby.count
    }
}

struct GameTile: View {
    let game: GameType
    let isAvailable: Bool
    var openCount: Int = 0

    var body: some View {
        HStack(spacing: 16) {
            GameArtwork(game: game)
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.displayName)
                    .font(.headline)
                Text(game.tagline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(game.playerCountText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.teal)
                if !isAvailable {
                    pill("Coming soon", tint: nil)
                } else if openCount > 0 {
                    pill(openCount == 1 ? "1 open game" : "\(openCount) open games", tint: Theme.teal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isAvailable {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding()
        .contentShape(.rect)
        .glassEffect(.regular.interactive(isAvailable), in: .rect(cornerRadius: 24))
        .opacity(isAvailable ? 1 : 0.75)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isAvailable ? .isButton : [])
    }

    private func pill(_ text: String, tint: Color?) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint == nil ? Color.primary : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.fill.tertiary), in: Capsule())
            .padding(.top, 2)
    }
}

extension GameType {
    var tagline: String {
        switch self {
        case .ticTacToe: "Three in a row wins."
        case .connectFour: "Drop discs, connect four."
        case .colorMatch: "Match colors and numbers, empty your hand."
        case .checkers: "Jump your way across the board."
        case .chess: "Checkmate the king to win."
        case .spades: "Partners, bids, and trump. Four players."
        case .tonk: "Fast rummy. Spread, hit, or drop."
        }
    }

    var playerCountText: String {
        minPlayers == maxPlayers ? "\(minPlayers) players" : "\(minPlayers)–\(maxPlayers) players"
    }
}

/// Small illustrated thumbnails drawn with SwiftUI shapes (no external art).
struct GameArtwork: View {
    let game: GameType

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(background)
                .accessibilityHidden(true)
            switch game {
            case .ticTacToe: ticTacToe
            case .connectFour: connectFour
            case .colorMatch: colorMatch
            case .checkers: checkers
            case .chess: chess
            case .spades: spades
            case .tonk: tonk
            }
        }
        .accessibilityHidden(true)
    }

    private var background: LinearGradient {
        switch game {
        case .ticTacToe: LinearGradient(colors: [Theme.teal, Theme.deep], startPoint: .top, endPoint: .bottom)
        case .connectFour: LinearGradient(colors: [Theme.deep, Theme.night], startPoint: .top, endPoint: .bottom)
        case .colorMatch: LinearGradient(colors: [Theme.sunset, Theme.coral], startPoint: .top, endPoint: .bottom)
        case .checkers: LinearGradient(colors: [Theme.coral, Theme.night], startPoint: .top, endPoint: .bottom)
        case .chess: LinearGradient(colors: [Theme.foam, Theme.teal], startPoint: .top, endPoint: .bottom)
        case .spades: LinearGradient(colors: [Theme.night, Theme.deep], startPoint: .top, endPoint: .bottom)
        case .tonk: LinearGradient(colors: [Theme.teal, Theme.coral], startPoint: .top, endPoint: .bottom)
        }
    }

    /// A fanned hand with the spade pip on top.
    private var spades: some View {
        ZStack {
            ForEach(Array([-18.0, 0.0, 18.0].enumerated()), id: \.offset) { index, angle in
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(index == 1 ? 0.95 : 0.6))
                    .frame(width: 26, height: 38)
                    .rotationEffect(.degrees(angle))
                    .offset(x: CGFloat(angle) * 0.7)
            }
            Image(systemName: "suit.spade.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.night)
        }
    }

    /// A stack of cards with one card lifted off, suggesting draw-and-discard.
    private var tonk: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.white.opacity(0.55))
                .frame(width: 26, height: 38)
                .offset(x: -10, y: 4)
            RoundedRectangle(cornerRadius: 4)
                .fill(.white.opacity(0.95))
                .frame(width: 26, height: 38)
                .offset(x: 10, y: -4)
                .overlay {
                    Image(systemName: "suit.heart.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.coral)
                        .offset(x: 10, y: -4)
                }
        }
    }

    private var ticTacToe: some View {
        let marks = ["xmark", "", "circle", "", "xmark", "", "circle", "", "xmark"]
        return Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let symbol = marks[row * 3 + column]
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white.opacity(0.18))
                            .frame(width: 20, height: 20)
                            .overlay {
                                if !symbol.isEmpty {
                                    Image(systemName: symbol)
                                        .font(.system(size: 11, weight: .heavy))
                                        .foregroundStyle(symbol == "xmark" ? Theme.foam : Theme.sunset)
                                }
                            }
                    }
                }
            }
        }
    }

    private var connectFour: some View {
        let pattern: [[Color?]] = [
            [nil, nil, nil, nil],
            [nil, nil, Theme.sunset, nil],
            [nil, Theme.sunset, Theme.foam, nil],
            [Theme.sunset, Theme.foam, Theme.foam, Theme.sunset],
        ]
        return VStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { column in
                        Circle()
                            .fill(pattern[row][column] ?? .white.opacity(0.15))
                            .frame(width: 13, height: 13)
                    }
                }
            }
        }
        .padding(6)
        .background(Theme.teal.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private var colorMatch: some View {
        ZStack {
            card(color: Theme.deep, label: "7").rotationEffect(.degrees(-16)).offset(x: -12)
            card(color: Theme.teal, label: "⟲").rotationEffect(.degrees(2))
            card(color: .white, label: "★", foreground: Theme.coral).rotationEffect(.degrees(18)).offset(x: 12)
        }
    }

    private var checkers: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { column in
                        let dark = (row + column) % 2 == 1
                        Rectangle()
                            .fill(dark ? Theme.night.opacity(0.6) : Color.white.opacity(0.25))
                            .frame(width: 13, height: 13)
                            .overlay {
                                if dark, row == 0 || row == 3 {
                                    Circle()
                                        .fill(row < 2 ? Theme.coral : Theme.foam)
                                        .padding(1.5)
                                }
                            }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var chess: some View {
        HStack(alignment: .bottom, spacing: -6) {
            ChessGlyph(piece: ChessPiece(.white, .knight))
                .frame(width: 34, height: 34)
            ChessGlyph(piece: ChessPiece(.black, .king))
                .frame(width: 44, height: 44)
        }
    }

    private func card(color: Color, label: String, foreground: Color = .white) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color)
            .frame(width: 30, height: 44)
            .overlay(Text(label).font(.system(size: 16, weight: .black)).foregroundStyle(foreground))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}
