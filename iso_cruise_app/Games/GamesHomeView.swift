import SwiftUI

/// The single Games tab listing all three titles, open games nearby, and the active match.
struct GamesHomeView: View {
    @Environment(GameCoordinator.self) private var games
    @Environment(SessionManager.self) private var session
    @State private var selectedGame: GameType?

    var body: some View {
        @Bindable var games = games
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if session.connectedIdentities.isEmpty {
                        Label("Connect to someone in the Chat tab's People list to play together.", systemImage: "person.2.wave.2")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
            .onChange(of: games.lobby?.id) { _, id in
                if id != nil { selectedGame = nil }
            }
            .alert(
                games.notice ?? "",
                isPresented: Binding(
                    get: { games.notice != nil && games.lobby == nil },
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

                Section {
                    Button {
                        games.hostLobby(game)
                        dismiss()
                    } label: {
                        Label("Host a New Game", systemImage: "plus.circle.fill")
                    }
                } footer: {
                    Text("Nearby connected players will see your game and can join. You can also invite someone directly from the lobby.")
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
                                    Text("\(offer.payload.seatsTaken) of \(offer.payload.maxSeats) seats taken")
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
                        .disabled(offer.isFull || games.joiningLobbyId != nil)
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
            }
        }
        .accessibilityHidden(true)
    }

    private var background: LinearGradient {
        switch game {
        case .ticTacToe: LinearGradient(colors: [Theme.teal, Theme.deep], startPoint: .top, endPoint: .bottom)
        case .connectFour: LinearGradient(colors: [Theme.deep, Theme.night], startPoint: .top, endPoint: .bottom)
        case .colorMatch: LinearGradient(colors: [Theme.sunset, Theme.coral], startPoint: .top, endPoint: .bottom)
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

    private func card(color: Color, label: String, foreground: Color = .white) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color)
            .frame(width: 30, height: 44)
            .overlay(Text(label).font(.system(size: 16, weight: .black)).foregroundStyle(foreground))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}
