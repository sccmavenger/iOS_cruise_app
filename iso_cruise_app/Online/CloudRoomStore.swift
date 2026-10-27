import Foundation
import Security

/// Remembers the online game this phone is in, so a relaunch (iOS often quits apps in the
/// background) goes straight back to it. Holds the seat token, so it lives in the Keychain:
/// "after first unlock, this device only", never synced or backed up. Cleared when the game
/// ends or the player leaves.
final class CloudRoomStore {
    private let service: String
    private let account = "current"

    init(service: String = "com.dannyguillory.cruiselan.cloudroom") {
        self.service = service
    }

    func load() -> CloudSeat? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(CloudSeat.self, from: data)
    }

    func save(_ seat: CloudSeat) {
        guard let data = try? JSONEncoder().encode(seat) else { return }
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
