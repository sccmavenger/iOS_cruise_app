import Foundation

/// Devices this user has already accepted a connection with. Lets CruiseLAN reconnect
/// automatically after the app was in the background (iOS drops every peer-to-peer
/// session then) without asking the user to approve the same person again.
///
/// Stores only opaque transport fingerprints. Entries expire after a day, and are
/// cleared by blocking someone or by "Disconnect from Everyone".
final class TrustedPeersStore {
    static let lifetime: TimeInterval = 24 * 60 * 60
    private static let key = "session.trustedPeers"

    private let defaults: UserDefaults
    private let now: () -> Date
    private var expiry: [String: Date]

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { .now }) {
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: Date].self, from: data) {
            expiry = stored.filter { $0.value > now() }
        } else {
            expiry = [:]
        }
    }

    func isTrusted(_ fingerprint: String?) -> Bool {
        guard let fingerprint, let until = expiry[fingerprint] else { return false }
        return until > now()
    }

    func trust(_ fingerprint: String?) {
        guard let fingerprint else { return }
        expiry[fingerprint] = now().addingTimeInterval(Self.lifetime)
        save()
    }

    func forget(_ fingerprint: String?) {
        guard let fingerprint, expiry.removeValue(forKey: fingerprint) != nil else { return }
        save()
    }

    func forgetAll() {
        expiry = [:]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(expiry) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
