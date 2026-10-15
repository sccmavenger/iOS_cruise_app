import Foundation
import Observation
import UserNotifications

/// UI-level navigation state shared by the tab bar, the match screen, and notifications.
@Observable
final class AppState {
    enum Tab: Hashable {
        case chat, games
    }

    var selectedTab: Tab = .chat
    /// The match is tucked into the "Back to game" bar so the player can chat meanwhile.
    var isMatchMinimized = false
}

/// Local notifications for new messages and "your turn", plus the unread chat count.
///
/// Everything is local to the device: CruiseLAN has no server, so notifications are
/// posted by the app itself, either while it's running or when a friend's phone wakes
/// it with a Bluetooth nudge (see `Nudge`). Banners are skipped for whatever is
/// already on screen.
@Observable
final class NotificationManager: NSObject {
    enum Route: String {
        case chat, game
    }

    private(set) var unreadChatCount = 0
    /// Set when the user taps a notification; the tab view navigates and clears it.
    var pendingRoute: Route?

    /// Kept current by the UI so banners aren't shown for what the user is looking at.
    var isAppActive = true
    var isChatOnScreen = false
    var isMatchOnScreen = false

    private var center: UNUserNotificationCenter { .current() }

    func install() {
        center.delegate = self
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: - Events

    func chatReceived(from identity: PeerIdentity, text: String) {
        guard !(isAppActive && isChatOnScreen) else { return }
        unreadChatCount += 1
        updateBadge()
        // The text already passed the safety filter on this device before it was shown in chat.
        post(title: identity.nickname, body: text, thread: "chat", route: .chat)
    }

    func chatViewed() {
        guard unreadChatCount > 0 else { return }
        unreadChatCount = 0
        updateBadge()
        center.removeAllDeliveredNotifications()
    }

    func turnStarted(in game: GameType) {
        guard !(isAppActive && isMatchOnScreen) else { return }
        post(title: "Your turn in \(game.displayName)", body: "Tap to jump back into the game.", thread: "game", route: .game, id: "turn")
    }

    /// A friend's phone sent a message preview over Bluetooth while we were away. `sender` is
    /// the name this phone already knows for them; the full message arrives when they reconnect.
    func chatNudgeReceived(from sender: PeerIdentity, preview: String?) {
        unreadChatCount += 1
        updateBadge()
        post(title: sender.nickname, body: preview ?? "Sent you a message. Open CruiseLAN to read it.", thread: "chat", route: .chat)
    }

    /// A friend's phone says it's our turn.
    func turnNudgeReceived(in game: GameType, from sender: PeerIdentity) {
        post(title: "Your turn in \(game.displayName)", body: "\(sender.nickname) is waiting for you.", thread: "game", route: .game, id: "turn")
    }

    // MARK: - Posting

    private func post(title: String, body: String, thread: String, route: Route, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = thread
        content.userInfo = ["route": route.rawValue]
        // Reusing the "turn" id replaces an older turn reminder instead of stacking them.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func updateBadge() {
        center.setBadgeCount(unreadChatCount)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Banners are filtered when posted, so anything posted while the app is open should show.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["route"] as? String
        await MainActor.run {
            self.pendingRoute = raw.flatMap(Route.init(rawValue:))
        }
    }
}
