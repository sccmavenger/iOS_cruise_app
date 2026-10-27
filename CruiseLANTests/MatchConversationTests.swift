import Foundation
import Testing
@testable import iso_cruise_app

/// Covers the fix for two pieces of tester feedback from 2026-10-19:
/// "Top right when I hit chat I should be dropped in a chat with the person or persons that
/// I am in the game with", and "once he accepted, everybody got added to the chat. I only
/// wanna be able to invite certain people".
@Suite("Match conversation")
@MainActor
struct MatchConversationTests {
    private func makeStore() -> ChatStore { ChatStore() }

    private func member(_ id: String) -> ConversationMember {
        ConversationMember(id: id, nickname: "P\(id)")
    }

    @Test("A match conversation is keyed by the lobby id, so every player derives the same one")
    func keyedByLobby() {
        let lobbyId = UUID()
        let members = ["a", "b", "c"].map(member)

        // Two different phones building it independently must land on the same conversation.
        let onPhoneOne = makeStore().matchConversation(id: lobbyId, name: "Spades", members: members)
        let onPhoneTwo = makeStore().matchConversation(id: lobbyId, name: "Spades", members: members)
        #expect(onPhoneOne.id == onPhoneTwo.id)
        #expect(onPhoneOne.id == lobbyId)
    }

    @Test("Asking twice returns the same conversation rather than piling up groups")
    func idempotent() {
        let store = makeStore()
        let lobbyId = UUID()
        let members = ["a", "b", "c"].map(member)

        let first = store.matchConversation(id: lobbyId, name: "Tonk", members: members)
        let second = store.matchConversation(id: lobbyId, name: "Tonk", members: members)
        #expect(first.id == second.id)
        // "Everyone" plus exactly one match group.
        #expect(store.conversations.count == 2)
    }

    /// The crux of the feedback: a match chat must not reach people who aren't playing.
    @Test("A match conversation contains only the players")
    func onlyPlayers() {
        let store = makeStore()
        let players = ["me", "rival"].map(member)
        let conversation = store.matchConversation(id: UUID(), name: "Chess", members: players)

        #expect(conversation.memberIds == ["me", "rival"])
        #expect(!conversation.memberIds.contains("bystander"))
        #expect(conversation.kind == .group)
    }

    @Test("A match conversation is a real group, distinct from Everyone")
    func notEveryone() {
        let store = makeStore()
        let conversation = store.matchConversation(id: UUID(), name: "Chess", members: ["a", "b", "c"].map(member))
        #expect(conversation.id != ChatStore.everyoneId)
        #expect(store.conversation(ChatStore.everyoneId)?.kind == .everyone)
    }

    @Test("Two players get their existing one-to-one chat, not a new group")
    func twoPlayersUseDirectChat() {
        let profile = ProfileStore(defaults: UserDefaults(suiteName: "match.tests.\(UUID())")!)
        profile.setNickname("Me")
        let session = SessionManager(transport: FakeTransport(), profile: profile)

        let rival = PeerIdentity(id: String(repeating: "b", count: 64), nickname: "Rival")
        let direct = session.directConversation(with: rival)

        let match = session.matchConversation(
            lobbyId: UUID(),
            named: "Chess",
            players: [PeerIdentity(id: session.localId, nickname: "Me"), rival]
        )
        // Reusing the one-to-one chat keeps a two-player game's history in one place rather
        // than splitting it across a group that means the same thing.
        #expect(match?.id == direct.id)
        #expect(match?.kind == .direct)
    }

    @Test("Three or more players get a group named after the game")
    func threePlayersUseGroup() {
        let profile = ProfileStore(defaults: UserDefaults(suiteName: "match.tests.\(UUID())")!)
        profile.setNickname("Me")
        let session = SessionManager(transport: FakeTransport(), profile: profile)

        let lobbyId = UUID()
        let others = (0..<3).map { PeerIdentity(id: String(repeating: "\($0)", count: 64), nickname: "P\($0)") }
        let match = session.matchConversation(
            lobbyId: lobbyId,
            named: "Spades",
            players: [PeerIdentity(id: session.localId, nickname: "Me")] + others
        )

        #expect(match?.id == lobbyId)
        #expect(match?.kind == .group)
        #expect(match?.name == "Spades")
        // Everyone at the table, including the local player.
        #expect(match?.memberIds.count == 4)
        #expect(match?.memberIds.contains(session.localId) == true)
    }

    @Test("A lobby with nobody else in it has no conversation yet")
    func soloLobbyHasNoConversation() {
        let profile = ProfileStore(defaults: UserDefaults(suiteName: "match.tests.\(UUID())")!)
        profile.setNickname("Me")
        let session = SessionManager(transport: FakeTransport(), profile: profile)

        let alone = session.matchConversation(
            lobbyId: UUID(),
            named: "Chess",
            players: [PeerIdentity(id: session.localId, nickname: "Me")]
        )
        // The caller falls back to the conversation list rather than opening an empty room.
        #expect(alone == nil)
    }
}
