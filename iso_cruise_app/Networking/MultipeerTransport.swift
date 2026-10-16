import CryptoKit
import Foundation
import MultipeerConnectivity
import os

/// `PeerTransport` backed by MultipeerConnectivity.
///
/// MultipeerConnectivity calls its delegates on private background queues, so this class
/// is `nonisolated`; all mutable state lives behind a `Mutex`, and events are forwarded
/// in order through an `AsyncStream` for the main-actor session layer to consume.
nonisolated final class MultipeerTransport: NSObject, PeerTransport, @unchecked Sendable {
    /// Bonjour service type. Must match `NSBonjourServices` (`_cruiselan._tcp` / `_udp`).
    static let serviceType = "cruiselan"
    static let protocolVersion = "1"
    /// How long a connection request waits for an answer. Requests sit quietly in People
    /// rather than popping up, so they get a minute to be noticed.
    static let invitationTimeout: TimeInterval = 60
    static let maxPendingInvitations = 5
    /// MultipeerConnectivity sessions support at most 8 peers including the local one.
    static let maxSessionPeers = kMCSessionMaximumNumberOfPeers - 1

    private static let logger = Logger(subsystem: "com.dannyguillory.cruiselan", category: "transport")

    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    nonisolated private struct PendingInvitation {
        let peerID: MCPeerID
        let handler: (Bool, MCSession?) -> Void
    }

    nonisolated private struct State {
        var localPeer: MCPeerID?
        var session: MCSession?
        var advertiser: MCNearbyServiceAdvertiser?
        var browser: MCNearbyServiceBrowser?
        var keysByPeer: [MCPeerID: PeerKey] = [:]
        var peersByKey: [PeerKey: MCPeerID] = [:]
        var pendingInvitations: [UUID: PendingInvitation] = [:]
        /// Peers the current session reports as connecting.
        var connectingPeers: Set<MCPeerID> = []
        /// Invitations this phone sent on the current session, by when they expire.
        var outgoingInvites: [MCPeerID: Date] = [:]
    }

    private let state = LockedState(State())
    private let peerIDStore: PeerIDStore

    init(peerIDStore: PeerIDStore = PeerIDStore()) {
        self.peerIDStore = peerIDStore
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .bufferingNewest(512))
        super.init()
    }

    deinit {
        continuation.finish()
    }

    // MARK: - PeerTransport

    func start(displayName: String) {
        stop()

        let peerID = peerIDStore.peerID(for: displayName)
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self

        let advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["v": Self.protocolVersion],
            serviceType: Self.serviceType
        )
        advertiser.delegate = self

        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        browser.delegate = self

        state.withLock {
            $0.localPeer = peerID
            $0.session = session
            $0.advertiser = advertiser
            $0.browser = browser
        }

        DebugTrace.log("transport start \(displayName)")
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        continuation.yield(.started)
    }

    func stop() {
        let (session, advertiser, browser, pending) = state.withLock { state in
            let result = (state.session, state.advertiser, state.browser, state.pendingInvitations)
            state = State()
            return result
        }
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        for invitation in pending.values {
            invitation.handler(false, nil)
        }
    }

    @discardableResult
    func invite(_ peer: PeerKey) -> Bool {
        let target: (MCNearbyServiceBrowser, MCPeerID, MCSession, MCSession?)? = state.withLock { state in
            guard let browser = state.browser,
                  let peerID = state.peersByKey[peer]
            else { return nil }
            let replaced = freshSessionIfIdle(&state, ignoringInviteTo: peerID)
            guard let session = state.session, session.connectedPeers.count < Self.maxSessionPeers else { return nil }
            state.outgoingInvites[peerID] = Date.now.addingTimeInterval(Self.invitationTimeout)
            return (browser, peerID, session, replaced)
        }
        guard let (browser, peerID, session, replaced) = target else { return false }
        replaced?.disconnect()
        DebugTrace.log("transport invite \(peerID.displayName) freshSession=\(replaced != nil)")
        let context = try? JSONEncoder().encode(InvitationContext(v: Self.protocolVersion))
        browser.invitePeer(peerID, to: session, withContext: context, timeout: Self.invitationTimeout)
        return true
    }

    func respond(toInvitation invitationId: UUID, accept: Bool) {
        let resolved: (PendingInvitation, MCSession?, MCSession?)? = state.withLock { state in
            guard let pending = state.pendingInvitations.removeValue(forKey: invitationId) else { return nil }
            let replaced = accept ? freshSessionIfIdle(&state, ignoringInviteTo: nil) : nil
            return (pending, state.session, replaced)
        }
        guard let (pending, session, replaced) = resolved else { return }
        replaced?.disconnect()
        DebugTrace.log("transport respond \(pending.peerID.displayName) accept=\(accept) freshSession=\(replaced != nil) sessionPeers=\(session?.connectedPeers.count ?? -1)")
        if accept, let session, session.connectedPeers.count < Self.maxSessionPeers {
            pending.handler(true, session)
        } else {
            pending.handler(false, nil)
        }
    }

    func send(_ data: Data, to peers: [PeerKey]) throws {
        let (session, recipients) = state.withLock { state in
            (state.session, peers.compactMap { state.peersByKey[$0] })
        }
        guard let session else { throw TransportError.notRunning }
        let connected = recipients.filter { session.connectedPeers.contains($0) }
        guard !connected.isEmpty else { throw TransportError.noRecipients }
        do {
            try session.send(data, toPeers: connected, with: .reliable)
        } catch {
            throw TransportError.sendFailed(error.localizedDescription)
        }
    }

    func disconnectAll() {
        let session = state.withLock { $0.session }
        session?.disconnect()
    }

    /// SHA-256 of the remote `MCPeerID`'s archived form. Peers reuse their archived
    /// `MCPeerID` across launches (see `PeerIDStore`), so this stays stable for a device
    /// until it changes its nickname, and two devices with the same nickname differ.
    func fingerprint(for peer: PeerKey) -> String? {
        guard let peerID = state.withLock({ $0.peersByKey[peer] }),
              let data = try? NSKeyedArchiver.archivedData(withRootObject: peerID, requiringSecureCoding: true)
        else { return nil }
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    /// Most distinct peers remembered per run; beyond this, ones not in the session are dropped.
    /// (Browsers report peers as lost and found constantly, so keys must stay stable for any
    /// normal number of peers; this only matters if a device cycles through many peer ids.)
    private static let maxRememberedPeers = 256

    /// Returns the stable local key for a remote `MCPeerID`, creating one on first sight.
    private func key(for peerID: MCPeerID) -> PeerKey {
        state.withLock { state in
            if let existing = state.keysByPeer[peerID] { return existing }
            if state.keysByPeer.count >= Self.maxRememberedPeers {
                let connected = Set(state.session?.connectedPeers ?? [])
                for stale in state.keysByPeer.keys where !connected.contains(stale) {
                    if let staleKey = state.keysByPeer.removeValue(forKey: stale) { state.peersByKey[staleKey] = nil }
                }
            }
            let key = PeerKey()
            state.keysByPeer[peerID] = key
            state.peersByKey[key] = peerID
            return key
        }
    }

    /// Swaps in a new, empty `MCSession` when the current one has nobody connected and
    /// nothing in progress, and returns the old one for the caller to disconnect.
    ///
    /// A session that a peer dropped out of (for example, when their app went to the
    /// background) often can't take that same peer back: invitations sit unanswered or fail
    /// even though both phones see each other. A fresh session per reconnection avoids that.
    /// `ignoringInviteTo` is the peer about to be invited; an earlier invite to it is superseded.
    private func freshSessionIfIdle(_ state: inout State, ignoringInviteTo peerID: MCPeerID?) -> MCSession? {
        guard let old = state.session, let localPeer = state.localPeer,
              old.connectedPeers.isEmpty, state.connectingPeers.isEmpty
        else { return nil }
        let now = Date.now
        let othersInvited = state.outgoingInvites.contains { $0.key != peerID && $0.value > now }
        guard !othersInvited else { return nil }
        let session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        old.delegate = nil
        state.session = session
        state.outgoingInvites.removeAll()
        return old
    }

    private func isCurrent(session: MCSession) -> Bool {
        state.withLock { $0.session === session }
    }

    private func expireInvitation(_ invitationId: UUID) {
        let pending = state.withLock { $0.pendingInvitations.removeValue(forKey: invitationId) }
        guard let pending else { return }
        pending.handler(false, nil)
        continuation.yield(.invitationExpired(invitationId: invitationId))
    }
}

/// Minimal lock-protected box. Unlike `Mutex`, it doesn't require the protected value
/// to be `Sendable`, which MultipeerConnectivity's Objective-C types are not.
nonisolated final class LockedState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// Small context blob attached to invitations so incompatible builds can decline early.
nonisolated private struct InvitationContext: Codable {
    var v: String
}

// MARK: - MCSessionDelegate

extension MultipeerTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let current = self.state.withLock { locked -> Bool in
            guard locked.session === session else { return false }
            if state == .connecting {
                locked.connectingPeers.insert(peerID)
            } else {
                locked.connectingPeers.remove(peerID)
                locked.outgoingInvites[peerID] = nil
            }
            return true
        }
        DebugTrace.log("transport state \(peerID.displayName) -> \(state.rawValue) current=\(current)")
        guard current else { return }
        let mapped: PeerConnectionState = switch state {
        case .connected: .connected
        case .connecting: .connecting
        case .notConnected: .notConnected
        @unknown default: .notConnected
        }
        continuation.yield(.peerStateChanged(key(for: peerID), mapped))
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard isCurrent(session: session) else { return }
        // Drop oversized frames before they reach the decoder.
        guard data.count <= EnvelopeCodec.maxEnvelopeBytes else {
            Self.logger.notice("Dropped oversized frame (\(data.count, privacy: .public) bytes)")
            return
        }
        continuation.yield(.received(data, from: key(for: peerID)))
    }

    // CruiseLAN never uses streams or resources; refuse them so peers can't push files.
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {
        if let localURL {
            try? FileManager.default.removeItem(at: localURL)
        }
    }

    func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        // No identity certificates are used; the link is still encrypted (`.required`).
        // Peer identity is unauthenticated by design (see 02-TECHNICAL-SPEC "Security and privacy").
        certificateHandler(true)
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Reject incompatible or malformed contexts without bothering the user.
        guard let context, context.count <= 256,
              let decoded = try? JSONDecoder().decode(InvitationContext.self, from: context),
              decoded.v == Self.protocolVersion
        else {
            invitationHandler(false, nil)
            return
        }

        let invitationId = UUID()
        let accepted: Bool = state.withLock { state in
            guard state.advertiser === advertiser,
                  state.pendingInvitations.count < Self.maxPendingInvitations,
                  !state.pendingInvitations.values.contains(where: { $0.peerID == peerID })
            else { return false }
            state.pendingInvitations[invitationId] = PendingInvitation(peerID: peerID, handler: invitationHandler)
            return true
        }
        guard accepted else {
            invitationHandler(false, nil)
            return
        }

        DebugTrace.log("transport invitation from \(peerID.displayName)")
        let name = Nickname.sanitize(peerID.displayName) ?? "Unknown"
        continuation.yield(.invitationReceived(invitationId: invitationId, from: key(for: peerID), displayName: name))

        DispatchQueue.global().asyncAfter(deadline: .now() + Self.invitationTimeout) { [weak self] in
            self?.expireInvitation(invitationId)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        Self.logger.error("Advertising failed: \(error.localizedDescription, privacy: .public)")
        continuation.yield(.startFailed(error.localizedDescription))
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard info?["v"] == Self.protocolVersion else { return }
        let isLocal = state.withLock { $0.localPeer == peerID }
        guard !isLocal else { return }
        DebugTrace.log("transport found \(peerID.displayName)")
        let name = Nickname.sanitize(peerID.displayName) ?? "Unknown"
        continuation.yield(.peerFound(key(for: peerID), displayName: name))
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DebugTrace.log("transport lost \(peerID.displayName)")
        continuation.yield(.peerLost(key(for: peerID)))
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        Self.logger.error("Browsing failed: \(error.localizedDescription, privacy: .public)")
        continuation.yield(.startFailed(error.localizedDescription))
    }
}

// MARK: - Peer ID persistence

/// Reuses the same `MCPeerID` for a given display name across launches, as Apple
/// recommends, so nearby devices don't see stale duplicate peers.
nonisolated struct PeerIDStore: Sendable {
    private let defaultsKey = "transport.peerID"
    private let nameKey = "transport.peerIDName"

    func peerID(for displayName: String) -> MCPeerID {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: nameKey) == displayName,
           let data = defaults.data(forKey: defaultsKey),
           let stored = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data) {
            return stored
        }
        let peerID = MCPeerID(displayName: displayName)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: peerID, requiringSecureCoding: true) {
            defaults.set(data, forKey: defaultsKey)
            defaults.set(displayName, forKey: nameKey)
        }
        return peerID
    }
}
