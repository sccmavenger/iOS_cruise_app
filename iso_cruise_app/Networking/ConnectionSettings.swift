import Foundation
import Observation

/// User choices about which transports CruiseLAN uses.
///
/// **Nearby radio** (Apple's MultipeerConnectivity) is on by default: it's what lets two
/// phones connect with no shared network at all. Turning it off leaves only CruiseLAN's own
/// connection over the Wi-Fi network (`LANTransport`), so people can check that the Wi-Fi
/// path works on its own. That path is the one that reaches across a building rather than a
/// room, but only between phones joined to the same network.
///
/// Bluetooth nudges to locked phones (`NudgeService`) are separate and stay on either way:
/// iOS stops every peer-to-peer connection in the background, so they're the only thing
/// that can reach a locked phone.
@Observable
final class ConnectionSettings {
    private static let nearbyRadioKey = "transport.nearbyRadioEnabled"
    private static let onlineGamesKey = "games.onlineEnabled"

    var nearbyRadioEnabled: Bool {
        didSet {
            guard nearbyRadioEnabled != oldValue else { return }
            defaults.set(nearbyRadioEnabled, forKey: Self.nearbyRadioKey)
            apply?(nearbyRadioEnabled)
        }
    }

    /// Host games on the online service when the internet is reachable (on by default). Off means
    /// every game is hosted on a phone, as in version 1, which is handy for testing offline play.
    var onlineGamesEnabled: Bool {
        didSet { defaults.set(onlineGamesEnabled, forKey: Self.onlineGamesKey) }
    }

    /// Applies a change (switches the transport and restarts links). Installed by the app.
    @ObservationIgnored var apply: ((Bool) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `bool(forKey:)` also understands "NO"/"0" strings (launch arguments, MDM); unset means on.
        nearbyRadioEnabled = defaults.object(forKey: Self.nearbyRadioKey) == nil ? true : defaults.bool(forKey: Self.nearbyRadioKey)
        onlineGamesEnabled = defaults.object(forKey: Self.onlineGamesKey) == nil ? true : defaults.bool(forKey: Self.onlineGamesKey)
    }
}
