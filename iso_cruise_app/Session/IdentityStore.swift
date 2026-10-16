import Foundation
import Security

/// Keeps this phone's CruiseLAN session identity for a while, in the Keychain.
///
/// iOS may quit CruiseLAN while it's in the background (for example, during a long movie).
/// With Bluetooth state restoration, iOS relaunches it in the background when a friend's
/// phone sends a nudge, but that only helps if the relaunched app still has the same
/// id (it decides the Bluetooth service friends look for), the same nudge keys, and
/// knows who its friends are. So those are saved here and reused for `lifetime` after
/// the app was last used, then a fresh identity starts.
///
/// Stored with "after first unlock, this device only": readable while the phone is
/// locked (needed when woken in the background), never synced or backed up.
final class IdentityStore {
    struct Snapshot: Codable, Equatable {
        var localId: String
        var lastActive: Date
        /// When this id was first made. Ids are retired after `maxAge` even if used daily,
        /// so the Bluetooth beacon derived from them can't track a phone for long.
        var createdAt: Date? = nil
        /// Mesh keys (raw private keys). `localId` is derived from the signing key.
        var signingKey: Data? = nil
        var agreementKey: Data? = nil
        /// Contacts: id → nickname.
        var known: [String: String]
        /// Raw nudge keys by person id.
        var inboundKeys: [String: Data]
        var outboundKeys: [String: Data]
    }

    static let lifetime: TimeInterval = 12 * 60 * 60
    static let maxAge: TimeInterval = 24 * 60 * 60

    private let service: String
    private let account = "session"
    private let now: () -> Date

    init(service: String = "com.dannyguillory.cruiselan.identity", now: @escaping () -> Date = { .now }) {
        self.service = service
        self.now = now
    }

    /// The saved identity, if it was used recently enough to reuse.
    func load() -> Snapshot? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return nil }
        guard now().timeIntervalSince(snapshot.lastActive) < Self.lifetime,
              now().timeIntervalSince(snapshot.createdAt ?? snapshot.lastActive) < Self.maxAge
        else {
            // Expired: remove it rather than leaving old keys and names behind.
            clear()
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(baseQuery.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
