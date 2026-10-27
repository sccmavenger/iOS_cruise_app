import CoreLocation
import NetworkExtension
import Observation

/// Reads the name (SSID) of the Wi-Fi network this phone is on, for Troubleshooting, so
/// people can check they and their friends really are on the same network.
///
/// iOS only gives an app the Wi-Fi name if it has the "Access Wi-Fi Information" entitlement
/// *and* Location permission (Apple treats network names as location data). A family chat app
/// shouldn't ask for location up front, so this asks only when the user taps "Show Wi-Fi
/// name", and the name is only shown on screen: it never goes into diagnostics or telemetry.
@MainActor
@Observable
final class WiFiNameReader: NSObject, CLLocationManagerDelegate {
    enum State: Equatable {
        /// Location hasn't been asked for yet.
        case notAsked
        case checking
        case name(String)
        /// Allowed, but not on Wi-Fi right now (or iOS didn't say).
        case notOnWiFi
        /// The user declined Location, so iOS won't share the name.
        case denied
    }

    private(set) var state: State = .notAsked
    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: refresh()
        case .denied, .restricted: state = .denied
        default: break
        }
    }

    /// Asks for Location the first time; after that, just reads the name again.
    func request() {
        switch manager.authorizationStatus {
        case .notDetermined:
            state = .checking
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            refresh()
        default:
            state = .denied
        }
    }

    func refresh() {
        state = .checking
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            Task { @MainActor in
                guard let self else { return }
                if let ssid = network?.ssid, !ssid.isEmpty {
                    self.state = .name(ssid)
                } else {
                    self.state = .notOnWiFi
                }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.refresh()
            case .denied, .restricted: self.state = .denied
            default: break
            }
        }
    }
}
