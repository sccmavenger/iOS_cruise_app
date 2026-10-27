import SwiftUI

/// The single Games tab listing every title, open games nearby, and the active match.
struct GamesHomeView: View {
    @Environment(GameCoordinator.self) private var games
    @Environment(SessionManager.self) private var session
    @Environment(AppState.self) private var app
    @Environment(OnlineStatus.self) private var online
    @State private var selectedGame: GameType?
    @State private var isJoiningByCode = false

    var body: some View {
        @Bindable var games = games
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HostingModeBanner(isEmpty: session.connectedIdentities.isEmpty)
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
                            GameTile(game: game, isAvailable: game.isPlayable, openCount: games.offers(for: game).count)
                        }
                        .buttonStyle(.plain)
                        .disabled(!game.isPlayable)
                    }
                }
                .padding()
            }
            .navigationTitle("Games")
            .sheet(item: $selectedGame) { game in
                GameDetailSheet(game: game)
            }
            .sheet(isPresented: $isJoiningByCode) {
                JoinOnlineSheet()
            }
            .onChange(of: app.sheetDismissals) {
                selectedGame = nil
                isJoiningByCode = false
            }
            .alert(
                games.notice ?? "",
                isPresented: Binding(
                    // While a match is on screen, the match shows its own notices.
                    get: { games.notice != nil && !app.isMatchVisible },
                    set: { if !$0 { games.notice = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            }
        }
    }
}

/// Host a new game or join an open one for a single title.
struct GameDetailSheet: View {
    let game: GameType
    @Environment(GameCoordinator.self) private var games
    @Environment(SessionManager.self) private var session
    @Environment(OnlineStatus.self) private var online
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

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
                    let canHost = games.lobby == nil && games.joiningLobbyId == nil && !games.isConnectingOnline
                    Button {
                        games.hostLobby(game)
                        dismiss()
                    } label: {
                        // Grey the whole row (icon included) when it can't be used, so it doesn't look tappable.
                        Label(online.canPlayOnline ? "Host a New Online Game" : "Host a New Game", systemImage: "plus.circle.fill")
                            .foregroundStyle(canHost ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    }
                    .disabled(!canHost)
                } footer: {
                    Text(online.canPlayOnline
                         ? "Hosted online, so it keeps going even if your phone drops out. You get a code to share with anyone, anywhere, and nearby friends see it too."
                         : "Hosted on your phone. Nearby connected players will see your game and can join. You can also invite someone directly from the lobby.")
                }

                Section("Open games nearby") {
                    let offers = games.offers(for: game)
                    if offers.isEmpty {
                        Text(session.connectedIdentities.isEmpty ? "Connect to people first to see their games." : "No open games right now.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(offers) { offer in
                        Button {
                            games.join(offer)
                            // Close right away so the game screen can appear when the host accepts.
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(offer.host.labeledName)'s game")
                                        .foregroundStyle(.primary)
                                    Text("\(offer.payload.seatsTaken) of \(offer.payload.maxSeats) seats taken\(offer.payload.cloudCode == nil ? "" : " · online")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if games.joiningLobbyId == offer.id {
                                    ProgressView()
                                } else {
                                    Text(offer.isFull ? "Full" : "Join")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(offer.isFull ? Color.secondary : Theme.teal)
                                }
                            }
                        }
                        .disabled(offer.isFull || games.joiningLobbyId != nil || games.lobby != nil)
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
        }
    }
}

/// Says who will host a new game right now, since that decides who can join.
struct HostingModeBanner: View {
    /// Nobody is connected nearby.
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
        let nearby = isEmpty ? " Connect to someone in the Chat tab's People list to play together." : ""
        return online.isEnabled
            ? "No internet: games are hosted on a phone, so players need to be connected nearby.\(nearby)"
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

    private var cleaned: String { code.uppercased().filter { $0.isLetter || $0.isNumber } }

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
                    Text("The host sees the code in their game's lobby. It's 8 letters and numbers.")
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
                    .disabled(cleaned.count != 8 || games.isConnectingOnline)
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
        guard cleaned.count == 8 else { return }
        games.joinOnline(code: cleaned)
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
                    pill(openCount == 1 ? "1 open game nearby" : "\(openCount) open games nearby", tint: Theme.teal)
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
