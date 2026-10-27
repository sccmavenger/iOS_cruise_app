import Foundation
import Observation
import UserNotifications

/// UI-level navigation state shared by the tab bar, the match screen, and notifications.
@Observable
final class AppState {
    enum Tab: Hashable {
        case chat, games
    }

    var selectedTab: Tab = .games
    /// The match is tucked into the "Back to game" bar so the player can chat meanwhile.
    var isMatchMinimized = false
    /// Navigation inside the Chat tab: the open conversation, if any.
    var chatPath: [UUID] = []
    /// The match screen is actually showing (set by the screen itself, not by the request to show it).
    var isMatchVisible = false
    /// Bumped to ask every open sheet to close, so the match screen can be presented.
    var sheetDismissals = 0
    /// An invite link was opened; joined as soon as the app is ready (after onboarding).
    var pendingInviteCode: String?
    /// An invite arrived while the player is in a different game: the screen on top asks
    /// before switching (an alert under the full-screen match would never show).
    var switchToInviteCode: String?

    var openConversation: UUID? { chatPath.last }

    func open(conversation id: UUID) {
        selectedTab = .chat
        chatPath = [id]
    }
}

/// Local notifications for new messages and "your turn", plus the unread chat count.
///
/// Everything is local to the device: CruiseLAN has no server, so notifications are
/// posted by the app itself, either while it's running or when a friend's phone wakes
/// it with a Bluetooth nudge (see `Nudge`). Banners are skipped for whatever is
/// already on screen.
@Observable
final class NotificationManager: NSObject {
    enum Route: Equatable {
        case chat(UUID)
        /// The chat list (for a conversation this phone doesn't know yet).
        case chats
        case games
        case game
    }

    /// Set when the user taps a notification; the tab view navigates and clears it.
    var pendingRoute: Route?

    /// Kept current by the UI so banners aren't shown for what the user is looking at.
    var isAppActive = true
    var isMatchOnScreen = false
    /// The chat list is on screen, already showing new messages and unread counts.
    var isChatListOnScreen = false

    private var center: UNUserNotificationCenter { .current() }

    func install() {
        center.delegate = self
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: - Events

    /// A message arrived over the session. The text already passed this phone's safety filter.
    func chatReceived(title: String, text: String, conversationId: UUID) {
        post(title: title, body: text, thread: conversationId.uuidString, route: .chat(conversationId))
    }

    func turnStarted(in game: GameType) {
        guard !(isAppActive && isMatchOnScreen) else { return }
        post(title: "Your turn in \(game.displayName)", body: "Tap to jump back into the game.", thread: "game", route: .game, id: "turn")
    }

    /// A friend's phone sent a message preview over Bluetooth while we were away. The full
    /// message arrives when they reconnect.
    func chatNudgeReceived(title: String, preview: String?, conversationId: UUID?) {
        post(title: title, body: preview ?? "Sent you a message. Open CruiseLAN to read it.",
             thread: conversationId?.uuidString ?? "chats", route: conversationId.map { .chat($0) } ?? .chats)
    }

    /// A friend's phone says it's our turn.
    func turnNudgeReceived(in game: GameType, from sender: PeerIdentity) {
        post(title: "Your turn in \(game.displayName)", body: "\(sender.nickname) is waiting for you.", thread: "game", route: .game, id: "turn")
    }

    /// A friend invited us to a game while we were away. Opening the app reconnects, and the
    /// host sends the invitation again.
    func inviteNudgeReceived(to game: GameType, from sender: PeerIdentity) {
        post(title: "\(sender.nickname) invited you to play \(game.displayName)", body: "Open CruiseLAN to join.",
             thread: "invites", route: .games, id: "invite-\(sender.id)-\(game.rawValue)")
    }

    func setBadge(_ count: Int) {
        center.setBadgeCount(count)
    }

    /// Clears delivered notifications for a conversation once it's read.
    func clearDelivered(for conversationId: UUID) {
        let thread = conversationId.uuidString
        Task {
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { $0.request.content.threadIdentifier == thread }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: - Posting

    private func post(title: String, body: String, thread: String, route: Route, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = thread
        switch route {
        case .chat(let conversationId): content.userInfo = ["route": "chat", "conversation": conversationId.uuidString]
        case .chats: content.userInfo = ["route": "chats"]
        case .games: content.userInfo = ["route": "games"]
        case .game: content.userInfo = ["route": "game"]
        }
        // Reusing an id (like "turn") replaces the older notification instead of stacking them.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Banners are filtered when posted, so anything posted while the app is open should show.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let route = info["route"] as? String
        let conversation = (info["conversation"] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            switch route {
            case "chat": self.pendingRoute = .chat(conversation ?? ChatStore.everyoneId)
            case "chats": self.pendingRoute = .chats
            case "games": self.pendingRoute = .games
            case "game": self.pendingRoute = .game
            default: break
            }
        }
    }
}
