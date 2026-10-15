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

/// Where safety reports are sent. Reports open the Mail app with a pre-filled message;
/// nothing is sent automatically, and there is no CruiseLAN server.
enum SafetyConfig {
    /// TODO: Set the published support/safety contact address before external TestFlight or App Store release.
    static let reportEmail: String? = nil
    /// Filtered messages from one person in a session before they're blocked automatically.
    static let autoBlockThreshold = 3
}
