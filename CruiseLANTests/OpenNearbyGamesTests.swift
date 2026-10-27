import Foundation
import Testing
@testable import iso_cruise_app

/// Offline games with anyone nearby: no connection request, no contacts.
@MainActor
@Suite("Open games nearby")
struct OpenNearbyGamesTests {
    let network = FakeNetwork()
    let host: FakeNetwork.Node
    let guest: FakeNetwork.Node

    init() {
        host = network.addNode("Host")
        guest = network.addNode("Guest")
        // In range of each other, but nobody sent or accepted a connection request.
        network.connect(host, guest, befriend: false)
    }

    @Test("Strangers nearby are players, not contacts")
    func strangersArePlayers() {
        #expect(!host.session.isContact(guest.id))
        #expect(host.session.nearbyPlayers.map(\.id) == [guest.id])
        #expect(guest.session.nearbyPlayers.map(\.nickname) == ["Host"])
    }

    @Test("A stranger nearby sees the game, joins and plays it through")
    func playWithStranger() throws {
        host.games.hostLobby(.ticTacToe)
        let offer = try #require(guest.games.offers(for: .ticTacToe).first)
        #expect(offer.host.id == host.id)
        guest.games.join(offer)
        #expect(host.games.lobby?.players.count == 2)
        guest.games.setReady(true)
        host.games.startGame()
        #expect(guest.games.lobby?.phase == .playing)
        for cell in [0, 3, 1, 4, 2] {
            guard case .ticTacToe(let state) = host.games.snapshot else { Issue.record("no state"); return }
            let mover = state.playerId(for: state.turn) == host.id ? host : guest
            mover.games.play(.ticTacToe(cell: cell))
        }
        guard case .ticTacToe(let final) = guest.games.snapshot else { Issue.record("no state"); return }
        #expect(final.outcome == .win(.x, line: [0, 1, 2]))
        #expect(host.games.snapshot == guest.games.snapshot)
    }

    @Test("A stranger dropping mid-game pauses it, as with a contact")
    func strangerDropPauses() throws {
        host.games.hostLobby(.ticTacToe)
        guest.games.join(try #require(guest.games.offers(for: .ticTacToe).first))
        guest.games.setReady(true)
        host.games.startGame()
        network.disconnect(host, guest)
        #expect(host.games.awayIds.contains(guest.id))
        #expect(guest.games.isHostAway || guest.games.awayIds.contains(host.id))
        #expect(host.games.lobby?.phase == .playing, "paused, not over")
    }

    @Test("Chat still only goes to contacts, never to strangers")
    func chatStaysContactsOnly() {
        #expect(host.session.sendChat("hello?", in: ChatStore.everyoneId) == .noRecipients)
        #expect(!guest.session.chat.messages.contains { $0.text == "hello?" })
    }

    @Test("A blocked person's games don't show, and they can't join")
    func blockedStranger() throws {
        guest.session.block(identityId: host.id)
        guest.session.tick()
        host.games.hostLobby(.ticTacToe)
        #expect(guest.games.offers(for: .ticTacToe).isEmpty)
        #expect(!guest.session.nearbyPlayers.contains { $0.id == host.id })
    }

    @Test("A private game isn't shown to people nearby unless they're invited")
    func privateNearby() throws {
        host.games.hostLobby(.ticTacToe, open: false)
        #expect(guest.games.offers(for: .ticTacToe).isEmpty)
        host.games.invite(try #require(host.session.player(for: guest.id)))
        #expect(guest.games.invitation?.host.id == host.id)
    }

    @Test("The host removes a nearby player; they're told and can't rejoin")
    func removeNearby() throws {
        host.games.hostLobby(.ticTacToe)
        let offer = try #require(guest.games.offers(for: .ticTacToe).first)
        guest.games.join(offer)
        #expect(host.games.lobby?.players.count == 2)
        host.games.removePlayer(guest.id)
        #expect(host.games.lobby?.players.count == 1)
        #expect(guest.games.lobby == nil)
        #expect(guest.games.notice == "You were removed from the lobby.")
        guest.games.join(offer)
        #expect(host.games.lobby?.players.count == 1, "removed players can't come back")
    }

    @Test("Quick Play nearby joins an open game, or hosts one if there's none")
    func quickPlayNearby() {
        guest.games.quickPlay(.connectFour)
        #expect(guest.games.lobby?.hostId == guest.id, "nothing to join: hosts an open game")
        #expect(host.games.offers(for: .connectFour).count == 1)
        host.games.quickPlay(.connectFour)
        #expect(host.games.lobby?.hostId == guest.id, "joins the open one")
    }
}
