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
}
