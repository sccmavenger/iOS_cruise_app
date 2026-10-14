import Foundation
import Observation

/// The only thing CruiseLAN stores on disk: the user's chosen nickname.
@Observable
final class ProfileStore {
    private static let nicknameKey = "profile.nickname"
    private let defaults: UserDefaults

    private(set) var nickname: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        nickname = defaults.string(forKey: Self.nicknameKey).flatMap(Nickname.sanitize)
    }

    /// Saves a sanitized nickname. Returns `false` if nothing usable remains after sanitizing.
    @discardableResult
    func setNickname(_ raw: String) -> Bool {
        guard let clean = Nickname.sanitize(raw) else { return false }
        nickname = clean
        defaults.set(clean, forKey: Self.nicknameKey)
        return true
    }
}
