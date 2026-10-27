import Foundation

/// Runs several `PeerTransport`s at once and presents them as one.
///
/// `SessionManager` owns exactly one transport and shouldn't have to care how a packet
/// reached it — the mesh logic is identical whether a neighbour is one deck away over the
/// ship's Wi-Fi or across the table over Bluetooth. So instead of teaching the session layer
/// about transports, this fans out to all of them and merges their events behind the same
/// protocol. Adding a future transport means adding it to this array and nothing else.
///
/// **Duplicate people are fine.** The same friend may be reachable over radio *and* over the
/// LAN, which produces two links and two copies of each packet. That isn't corrected here,
/// on purpose: `SessionManager` already drops duplicate packets by id, so the second copy
/// costs a little radio time and buys real redundancy — if one path dies mid-game the other
/// carries on with no reconnect at all. Collapsing them here would mean guessing which path
/// is better before we have any evidence, and the telemetry exists precisely because we
/// don't yet know.
@MainActor
final class CompositeTransport: PeerTransport {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    /// Composite key → which child owns it and under what key there.
    private struct Origin {
        let child: Int
        let key: PeerKey
    }

    /// One child transport and how its links should be labelled in telemetry.
    struct Child {
        let transport: any PeerTransport
        /// Tier recorded when a link through this transport connects, or nil when the
        /// transport reports its own finer-grained tier. `LANTransport` does the latter,
        /// because only it knows whether a link came from Bonjour, a beacon, or a code.
        let telemetryTier: TelemetryDimension?

        init(_ transport: any PeerTransport, tier: TelemetryDimension?) {
            self.transport = transport
            self.telemetryTier = tier
        }
    }

    private let children: [any PeerTransport]
    private let tiers: [TelemetryDimension?]
    private var origins: [PeerKey: Origin] = [:]
    /// Reverse lookup per child, so a child's repeated events map to one stable key.
    private var mapped: [[PeerKey: PeerKey]]
    private var invitationOwners: [UUID: Int] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var startedChildren = 0
    private var failures: [String] = []
    /// When each link connected, so its lifetime can be recorded when it drops.
    private var connectedAt: [PeerKey: Date] = [:]
    private let telemetry: TelemetryStore?
    /// Children turned off by the user (see `setEnabled(_:for:)`). Not started, and anything
    /// they still report is ignored.
    private var disabled: Set<Int> = []

    init(children: [Child], telemetry: TelemetryStore? = nil) {
        self.children = children.map(\.transport)
        self.tiers = children.map(\.telemetryTier)
        self.telemetry = telemetry
        self.mapped = Array(repeating: [:], count: children.count)
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .bufferingNewest(2048))

        for (index, child) in children.enumerated() {
            let task = Task { [weak self, stream = child.transport.events] in
                for await event in stream {
                    guard let self else { return }
                    self.forward(event, from: index)
                }
            }
            tasks.append(task)
        }
    }

    deinit {
        continuation.finish()
    }

    // MARK: - PeerTransport

    func start(displayName: String) {
        startedChildren = 0
        failures = []
        for (index, child) in children.enumerated() where !disabled.contains(index) {
            child.start(displayName: displayName)
        }
    }

    /// Turns the children labelled `tier` on or off, for example Nearby radio, so only the
    /// Wi-Fi network is used. Takes effect on the next `start()`; the caller restarts.
    func setEnabled(_ enabled: Bool, for tier: TelemetryDimension) {
        for index in tiers.indices where tiers[index] == tier {
            if enabled {
                disabled.remove(index)
            } else {
                disabled.insert(index)
                children[index].stop()
            }
        }
    }

    func isEnabled(_ tier: TelemetryDimension) -> Bool {
        !tiers.indices.contains { tiers[$0] == tier && disabled.contains($0) }
    }

    func stop() {
        for child in children { child.stop() }
        origins.removeAll()
        mapped = Array(repeating: [:], count: children.count)
        invitationOwners.removeAll()
        connectedAt.removeAll()
        startedChildren = 0
    }

    @discardableResult
    func invite(_ peer: PeerKey) -> Bool {
        guard let origin = origins[peer] else { return false }
        return children[origin.child].invite(origin.key)
    }

    func respond(toInvitation invitationId: UUID, accept: Bool) {
        guard let child = invitationOwners.removeValue(forKey: invitationId) else { return }
        children[child].respond(toInvitation: invitationId, accept: accept)
    }

    /// Sends to each peer through whichever transport found it. A failure on one transport
    /// doesn't stop the others; the call only throws if nothing could be sent anywhere.
    func send(_ data: Data, to peers: [PeerKey]) throws {
        var grouped: [Int: [PeerKey]] = [:]
        for peer in peers {
            guard let origin = origins[peer] else { continue }
            grouped[origin.child, default: []].append(origin.key)
        }
        guard !grouped.isEmpty else { throw TransportError.noRecipients }

        var delivered = false
        var lastError: TransportError?
        for (child, keys) in grouped {
            do {
                try children[child].send(data, to: keys)
                delivered = true
            } catch let error as TransportError {
                lastError = error
            } catch {
                lastError = .sendFailed(error.localizedDescription)
            }
        }
        if !delivered, let lastError { throw lastError }
    }

    func disconnectAll() {
        for child in children { child.disconnectAll() }
    }

    func fingerprint(for peer: PeerKey) -> String? {
        guard let origin = origins[peer] else { return nil }
        // Namespaced per transport: the same phone fingerprints differently over radio and
        // over the LAN, and conflating them would let one transport's identifier authorise
        // the other's. Blocking a person on one path still blocks the other, because the
        // session layer also blocks by mesh id, which is the same on both.
        return children[origin.child].fingerprint(for: origin.key).map { "\(origin.child):\($0)" }
    }

    func medium(for peer: PeerKey) -> LinkMedium? {
        guard let origin = origins[peer] else { return nil }
        return children[origin.child].medium(for: origin.key)
    }

    // MARK: - Event merging

    private func forward(_ event: TransportEvent, from child: Int) {
        // A child the user turned off may still flush events from before it stopped.
        guard !disabled.contains(child) else { return }
        switch event {
        case .started:
            startedChildren += 1
            // Report running as soon as any transport is up; a phone with Wi-Fi off should
            // still work over radio rather than showing as failed.
            if startedChildren == 1 { continuation.yield(.started) }

        case .startFailed(let message):
            failures.append(message)
            // Only a real failure if nothing came up at all.
            if startedChildren == 0, failures.count == children.count - disabled.count {
                continuation.yield(.startFailed(message))
            }

        case .peerFound(let key, let displayName):
            continuation.yield(.peerFound(compositeKey(for: key, child: child), displayName: displayName))

        case .peerLost(let key):
            guard let composite = mapped[child][key] else { return }
            continuation.yield(.peerLost(composite))

        case .invitationReceived(let invitationId, let key, let displayName):
            invitationOwners[invitationId] = child
            continuation.yield(.invitationReceived(
                invitationId: invitationId,
                from: compositeKey(for: key, child: child),
                displayName: displayName
            ))

        case .invitationExpired(let invitationId):
            invitationOwners[invitationId] = nil
            continuation.yield(.invitationExpired(invitationId: invitationId))

        case .peerStateChanged(let key, let state):
            let composite = compositeKey(for: key, child: child)
            // Record which transport carried the link. Children that know their own tier
            // report it themselves; this covers the ones that don't, which is how radio
            // links get counted at all.
            if let tier = tiers[child] {
                switch state {
                case .connected:
                    connectedAt[composite] = .now
                    telemetry?.count(.linkConnectedByTier, tier)
                case .notConnected:
                    if let since = connectedAt.removeValue(forKey: composite) {
                        telemetry?.observe(.linkLifetime, Date.now.timeIntervalSince(since), tier)
                        telemetry?.count(.linkDropped, tier)
                    }
                case .connecting:
                    break
                }
            }
            continuation.yield(.peerStateChanged(composite, state))

        case .received(let data, let key):
            continuation.yield(.received(data, from: compositeKey(for: key, child: child)))
        }
    }

    /// Stable composite key for a child's key, created on first sight.
    private func compositeKey(for key: PeerKey, child: Int) -> PeerKey {
        if let existing = mapped[child][key] { return existing }
        let composite = PeerKey()
        mapped[child][key] = composite
        origins[composite] = Origin(child: child, key: key)
        return composite
    }
}
