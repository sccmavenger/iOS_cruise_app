import Foundation

/// Opaque, device-local handle for a remote peer as seen by the transport.
///
/// It is *not* an identity claim: the session layer binds a `PeerKey` to a peer's
/// announced id via the `hello` handshake and rejects any envelope whose sender
/// doesn't match the key it arrived on.
nonisolated struct PeerKey: Hashable, Sendable {
    let raw: UUID

    init(raw: UUID = UUID()) {
        self.raw = raw
    }
}

nonisolated enum PeerConnectionState: Sendable, Equatable {
    case notConnected
    case connecting
    case connected
}

nonisolated enum TransportEvent: Sendable, Equatable {
    case started
    case startFailed(String)
    case peerFound(PeerKey, displayName: String)
    case peerLost(PeerKey)
    case invitationReceived(invitationId: UUID, from: PeerKey, displayName: String)
    case invitationExpired(invitationId: UUID)
    case peerStateChanged(PeerKey, PeerConnectionState)
    case received(Data, from: PeerKey)
}

/// How one link reaches the other phone, for showing people what's actually working.
nonisolated enum LinkMedium: Sendable, Hashable {
    /// Apple's MultipeerConnectivity. iOS picks Bluetooth, peer-to-peer Wi-Fi ("AWDL"), or the
    /// Wi-Fi network for each link and doesn't say which, so this can't be narrowed down.
    case nearbyRadio
    /// CruiseLAN's own connection over the local network (`LANTransport`), on this interface,
    /// found this way.
    case localNetwork(LocalInterface, found: LocalDiscovery)

    nonisolated enum LocalInterface: Sendable, Hashable {
        case wifi, ethernet, hotspot, other
    }

    nonisolated enum LocalDiscovery: Sendable, Hashable {
        /// Found automatically with Bonjour (mDNS).
        case automatic
        /// Found by the UDP broadcast beacon, when the network blocks Bonjour.
        case broadcast
        /// Joined by entering someone's join code.
        case joinCode
    }
}

nonisolated enum TransportError: Error, Equatable, Sendable {
    case notRunning
    case noRecipients
    case sendFailed(String)
}

/// Abstraction over the local peer transport so coordinators can be tested with a fake.
@MainActor
protocol PeerTransport: AnyObject {
    /// Single-consumer stream of transport events, delivered in order.
    var events: AsyncStream<TransportEvent> { get }
    func start(displayName: String)
    func stop()
    /// Returns `false` if the invitation couldn't be sent (unknown peer, session full, not running).
    @discardableResult
    func invite(_ peer: PeerKey) -> Bool
    func respond(toInvitation invitationId: UUID, accept: Bool)
    func send(_ data: Data, to peers: [PeerKey]) throws
    /// Leaves the current session (all peers) while continuing to advertise and browse.
    func disconnectAll()
    /// A stable, opaque identifier for a remote device that survives app relaunches
    /// (used only to remember blocked people on this device).
    func fingerprint(for peer: PeerKey) -> String?
    /// How a connected link reaches the other phone, if this transport knows.
    func medium(for peer: PeerKey) -> LinkMedium?
}

extension PeerTransport {
    /// Test fakes and transports without a notion of medium.
    func medium(for peer: PeerKey) -> LinkMedium? { nil }
}

extension LinkMedium {
    /// Short label for a person's row, like "Wi-Fi network" or "Nearby radio".
    var label: String {
        switch self {
        case .nearbyRadio: "Nearby radio"
        case .localNetwork(.wifi, _): "Wi-Fi network"
        case .localNetwork(.ethernet, _): "Ethernet"
        case .localNetwork(.hotspot, _): "Personal Hotspot"
        case .localNetwork(.other, _): "Local network"
        }
    }

    /// One-line explanation for the details screen.
    var detail: String {
        switch self {
        case .nearbyRadio:
            return "Apple's direct phone-to-phone link. iOS picks Bluetooth, peer-to-peer Wi-Fi, or the Wi-Fi network you're both on, and doesn't tell apps which."
        case .localNetwork(let interface, let found):
            let path = switch interface {
            case .wifi: "Over the Wi-Fi network you're both joined to"
            case .ethernet: "Over a wired network (Ethernet)"
            case .hotspot: "Over a Personal Hotspot"
            case .other: "Over the local network"
            }
            let how = switch found {
            case .automatic: "found automatically"
            case .broadcast: "found by broadcast, because this network blocks automatic discovery"
            case .joinCode: "joined with a code"
            }
            return "\(path), \(how)."
        }
    }

    var symbol: String {
        switch self {
        case .nearbyRadio: "dot.radiowaves.left.and.right"
        case .localNetwork(.wifi, _): "wifi"
        case .localNetwork(.ethernet, _): "cable.connector"
        case .localNetwork(.hotspot, _): "personalhotspot"
        case .localNetwork(.other, _): "network"
        }
    }

    /// Network paths first, then radio, so rows read the same way every time.
    var sortOrder: Int {
        switch self {
        case .localNetwork(.wifi, _): 0
        case .localNetwork(.ethernet, _): 1
        case .localNetwork(.hotspot, _): 2
        case .localNetwork(.other, _): 3
        case .nearbyRadio: 4
        }
    }
}
