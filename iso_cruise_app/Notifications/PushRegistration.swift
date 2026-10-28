import UIKit
import UserNotifications

/// This phone's push address (an APNs device token). The online game service uses it to
/// notify a player whose app isn't open: someone joined their game, it started, it's their
/// turn, it ended. It's only ever given to the game the player is in, and the server forgets
/// it with the game. Phone-hosted games don't use it; nearby phones nudge over Bluetooth.
@Observable
final class PushRegistration {
    static let shared = PushRegistration()

    /// Hex device token, once iOS has handed one over. Nil without notification permission.
    private(set) var token: String?
    /// Debug builds are signed for Apple's test push service; TestFlight and App Store builds
    /// for the real one, and the token only works with the matching one.
    #if DEBUG
    let sandbox = true
    #else
    let sandbox = false
    #endif
    @ObservationIgnored var onChange: ((String?) -> Void)?

    /// Asks iOS for a token if the user allows notifications; forgets it if they've turned
    /// them off since. Cheap to call on every launch and return to the foreground.
    func refresh() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        DebugTrace.log("push: notification permission \(status.rawValue)")
        switch status {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            update(nil)
        }
    }

    func received(_ deviceToken: Data) {
        DebugTrace.log("push: got a device token (\(deviceToken.count) bytes)")
        update(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    private func update(_ newToken: String?) {
        guard newToken != token else { return }
        token = newToken
        onChange?(newToken)
    }
}

/// Receives the device token from iOS (SwiftUI apps have no other way to get it).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistration.shared.received(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No token (no network yet, or a simulator without push): online games still work,
        // just without notifications while the app is closed. iOS retries on the next launch.
        DiagnosticLog.shared.note("push", "registration failed: \(error.localizedDescription)")
        DebugTrace.log("push: registration failed: \(error.localizedDescription)")
    }
}
