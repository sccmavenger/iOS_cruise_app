import Foundation
import Observation

/// Remembers blocked devices on this phone. Stores only opaque fingerprints plus the
/// name shown at the time of blocking (so the user can find them to unblock).
@Observable
final class SafetyStore {
    struct BlockedPerson: Codable, Equatable, Identifiable {
        let fingerprint: String
        let name: String
        let date: Date

        var id: String { fingerprint }
    }

    private static let key = "safety.blocked"
    private let defaults: UserDefaults

    private(set) var blocked: [BlockedPerson] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([BlockedPerson].self, from: data) {
            blocked = stored
        }
    }

    func isBlocked(_ fingerprint: String?) -> Bool {
        guard let fingerprint else { return false }
        return blocked.contains { $0.fingerprint == fingerprint }
    }

    func block(fingerprint: String, name: String) {
        guard !isBlocked(fingerprint) else { return }
        blocked.append(BlockedPerson(fingerprint: fingerprint, name: name, date: .now))
        save()
    }

    func unblock(_ person: BlockedPerson) {
        blocked.removeAll { $0.fingerprint == person.fingerprint }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(blocked) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// Where safety reports and support requests go. Reports open the Mail app with a
/// pre-filled message; nothing is sent automatically, and there is no CruiseLAN server.
/// Mail queues the message until the phone is back online (for example, after the cruise).
///
/// App Review Guideline 1.2 requires published contact information for apps with chat;
/// these must match the Support URL and contact email entered in App Store Connect.
enum SafetyConfig {
    /// Published safety and support contact. Rows that use it are hidden while it's `nil`.
    static let reportEmail: String? = nil
    static let supportURL: URL? = nil
    static let privacyPolicyURL: URL? = nil
    /// Filtered messages from one person in a session before they're blocked automatically.
    static let autoBlockThreshold = 3
}
