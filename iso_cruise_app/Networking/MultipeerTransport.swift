import CryptoKit
import Foundation
import MultipeerConnectivity
import os

/// `PeerTransport` backed by MultipeerConnectivity, with one `MCSession` per link.
///
/// A single `MCSession` connects everyone in it to everyone else and holds at most 8
/// phones, so a group of friends could never grow past 8, and anyone one person linked
/// to was linked to all of them. Here every link between two phones is its own two-phone
/// session, so this phone picks its own neighbors (up to `maxLinks`), and the mesh
/// layer (`SessionManager`) relays messages further than radio range.
///
/// MultipeerConnectivity calls its delegates on private background queues, so this class
/// is `nonisolated`; all mutable state lives behind a lock, and events are forwarded in
/// order through an `AsyncStream` for the main-actor session layer to consume.
nonisolated final class MultipeerTransport: NSObject, PeerTransport, @unchecked Sendable {
    /// Bonjour service type. Must match `NSBonjourServices` (`_cruiselan._tcp` / `_udp`).
    static let serviceType = "cruiselan"
    /// "2": the mesh protocol. Phones on older builds aren't found or linked.
    static let protocolVersion = "2"
    /// How long a link invitation waits for an answer. Links are accepted automatically,
    /// so this only bounds a stalled attempt.
    static let invitationTimeout: TimeInterval = 15
    static let maxPendingInvitations = 5
    /// Most links this phone keeps at once. More links make the mesh sturdier but use more
    /// radio time and battery; testing other MultipeerConnectivity meshes found several
    /// concurrent sessions reliable, and relays reach everyone else.
    static let maxLinks = 5

    private static let logger = Logger(subsystem: "com.dannyguillory.cruiselan", category: "transport")

    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    nonisolated private struct PendingInvitation {
        let peerID: MCPeerID
        let handler: (Bool, MCSession?) -> Void
    }

    nonisolated private struct State {
        var localPeer: MCPeerID?
        var advertiser: MCNearbyServiceAdvertiser?
        var browser: MCNearbyServiceBrowser?
        var keysByPeer: [MCPeerID: PeerKey] = [:]
        var peersByKey: [PeerKey: MCPeerID] = [:]
        var pendingInvitations: [UUID: PendingInvitation] = [:]
        /// The two-phone session for each link, connecting or connected.
        var links: [MCPeerID: MCSession] = [:]
    }

    private let state = LockedState(State())
    private let peerIDStore: PeerIDStore

    init(peerIDStore: PeerIDStore = PeerIDStore()) {
        self.peerIDStore = peerIDStore
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .bufferingNewest(1024))
        super.init()
    }

    deinit {
        continuation.finish()
    }

    // MARK: - PeerTransport

    func start(displayName: String) {
        stop()

        let peerID = peerIDStore.peerID(for: displayName)
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
            $0.advertiser = advertiser
            $0.browser = browser
        }

        DebugTrace.log("transport start \(displayName)")
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        continuation.yield(.started)
    }

    func stop() {
        let (links, advertiser, browser, pending) = state.withLock { state in
            let result = (Array(state.links.values), state.advertiser, state.browser, state.pendingInvitations)
            state = State()
            return result
        }
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        for session in links {
            session.delegate = nil
            session.disconnect()
        }
        for invitation in pending.values {
            invitation.handler(false, nil)
        }
    }

    @discardableResult
    func invite(_ peer: PeerKey) -> Bool {
        let target: (MCNearbyServiceBrowser, MCPeerID, MCSession, MCSession?)? = state.withLock { state in
            guard let browser = state.browser, let localPeer = state.localPeer,
                  let peerID = state.peersByKey[peer]
            else { return nil }
            // A stalled attempt to the same phone is replaced; otherwise respect the link limit.
            let previous = state.links[peerID]
            if let previous, previous.connectedPeers.contains(peerID) { return nil }
            guard previous != nil || state.links.count < Self.maxLinks else { return nil }
            let session = self.makeSession(localPeer)
            state.links[peerID] = session
            return (browser, peerID, session, previous)
        }
        guard let (browser, peerID, session, previous) = target else { return false }
        previous?.delegate = nil
        previous?.disconnect()
        DebugTrace.log("transport invite \(peerID.displayName)")
        let context = try? JSONEncoder().encode(InvitationContext(v: Self.protocolVersion))
        browser.invitePeer(peerID, to: session, withContext: context, timeout: Self.invitationTimeout)
        return true
    }

    func respond(toInvitation invitationId: UUID, accept: Bool) {
        let resolved: (PendingInvitation, MCSession?, MCSession?)? = state.withLock { state in
            guard let pending = state.pendingInvitations.removeValue(forKey: invitationId) else { return nil }
            guard accept, let localPeer = state.localPeer else { return (pending, nil, nil) }
            let previous = state.links[pending.peerID]
            if let previous, previous.connectedPeers.contains(pending.peerID) { return (pending, nil, nil) }
            guard previous != nil || state.links.count < Self.maxLinks else { return (pending, nil, nil) }
            let session = self.makeSession(localPeer)
            state.links[pending.peerID] = session
            return (pending, session, previous)
        }
        guard let (pending, session, previous) = resolved else { return }
        previous?.delegate = nil
        previous?.disconnect()
        DebugTrace.log("transport respond \(pending.peerID.displayName) accept=\(session != nil)")
        pending.handler(session != nil, session)
    }

    func send(_ data: Data, to peers: [PeerKey]) throws {
        let targets: [(MCSession, MCPeerID)] = state.withLock { state in
            peers.compactMap { key in
                guard let peerID = state.peersByKey[key], let session = state.links[peerID],
                      session.connectedPeers.contains(peerID)
                else { return nil }
                return (session, peerID)
            }
        }
        guard !targets.isEmpty else { throw TransportError.noRecipients }
        var failure: String?
        for (session, peerID) in targets {
            do {
                try session.send(data, toPeers: [peerID], with: .reliable)
            } catch {
                failure = error.localizedDescription
            }
        }
        if let failure, targets.count == 1 { throw TransportError.sendFailed(failure) }
    }

    func disconnectAll() {
        let links = state.withLock { state -> [MCSession] in
            defer { state.links.removeAll() }
            return Array(state.links.values)
        }
        for session in links { session.disconnect() }
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

    /// Most distinct peers remembered per run; beyond this, ones without a link are dropped.
    /// (Browsers report peers as lost and found constantly, so keys must stay stable for any
    /// normal number of peers; this only matters if a device cycles through many peer ids.)
    private static let maxRememberedPeers = 512

    /// Returns the stable local key for a remote `MCPeerID`, creating one on first sight.
    private func key(for peerID: MCPeerID) -> PeerKey {
        state.withLock { state in
            if let existing = state.keysByPeer[peerID] { return existing }
            if state.keysByPeer.count >= Self.maxRememberedPeers {
                for stale in state.keysByPeer.keys where state.links[stale] == nil {
                    if let staleKey = state.keysByPeer.removeValue(forKey: stale) { state.peersByKey[staleKey] = nil }
                }
            }
            let key = PeerKey()
            state.keysByPeer[peerID] = key
            state.peersByKey[key] = peerID
            return key
        }
    }

    private func makeSession(_ localPeer: MCPeerID) -> MCSession {
        let session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }

    /// Whether `session` is the current link to `peerID` (not a replaced or stray one).
    private func isLink(_ session: MCSession, to peerID: MCPeerID) -> Bool {
        state.withLock { $0.links[peerID] === session }
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
        // Each link session holds exactly one other phone; anything else is stray.
        let current = self.state.withLock { locked -> Bool in
            guard locked.links[peerID] === session else { return false }
            if state == .notConnected { locked.links[peerID] = nil }
            return true
        }
        DebugTrace.log("transport state \(peerID.displayName) -> \(state.rawValue) current=\(current)")
        guard current else {
            // A session someone else's phone pulled us into, or one we replaced: don't keep it.
            if state == .connected, !isLink(session, to: peerID) { session.disconnect() }
            return
        }
        if state == .notConnected { session.disconnect() }
        let mapped: PeerConnectionState = switch state {
        case .connected: .connected
        case .connecting: .connecting
        case .notConnected: .notConnected
        @unknown default: .notConnected
        }
        continuation.yield(.peerStateChanged(key(for: peerID), mapped))
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard isLink(session, to: peerID) else { return }
        // Drop oversized frames before they reach the decoder.
        guard data.count <= MeshPacket.maxPacketBytes else {
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
        // No transport certificates: the link is still encrypted (`.required`), and every
        // packet on it is signed end to end by its sender (see `MeshPacket`).
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
