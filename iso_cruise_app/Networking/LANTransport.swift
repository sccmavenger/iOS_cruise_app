import CryptoKit
import Foundation
import Network
import os

/// `PeerTransport` over the ship's own network, so people can reach each other from
/// opposite ends of the ship instead of only across a room.
///
/// **The problem this solves.** MultipeerConnectivity picks its own radios. On a cruise it
/// almost always ends up on Bluetooth or peer-to-peer Wi-Fi, because using the ship's
/// network needs three things guest Wi-Fi usually withholds: both phones on the same
/// subnet, multicast/mDNS forwarded between clients, and client-to-client traffic allowed
/// at all. So the app worked at arm's length and nowhere else. This transport talks plain
/// TCP over whatever network the phone is already on, which has no range limit beyond the
/// network's own coverage.
///
/// **Three tiers, tried in order.** No single discovery method survives every network, so
/// each tier gives up a little convenience for a lot of reach:
/// 1. `.lanBonjour` — the normal way. Costs nothing, works whenever mDNS is forwarded.
/// 2. `.lanBroadcast` — a small UDP beacon to the broadcast address. Many networks drop
///    multicast (which mDNS needs) but still pass broadcast, so this covers the gap.
/// 3. `.lanJoinCode` — someone reads out a code. The only tier that needs no discovery at
///    all, and so the only one that works when the network forwards nothing.
///
/// Every tier reports to `TelemetryStore`, including its failures, so which of these
/// actually carries traffic on real ships becomes a measured fact rather than a guess.
///
/// **Security.** Links are TLS 1.2 with a pre-shared key (TLS_PSK_WITH_AES_128_GCM_SHA256; Network.framework doesn't support external PSKs over 1.3), so nobody passively sniffing the
/// ship's network sees CruiseLAN traffic in the clear. The PSK is compiled into the app and
/// is therefore *not* a secret — any CruiseLAN user has it. It is not doing authentication,
/// and nothing here relies on it for that. Authentication is `MeshPacket`: every packet is
/// signed by a key its sender's id is derived from, and private content is sealed per
/// recipient, so a link is only ever a pipe. This is the same bargain `MultipeerTransport`
/// already makes (`encryptionPreference: .required` with `certificateHandler(true)`), and
/// it's recorded in docs/decisions/lan-transport.md.
@MainActor
final class LANTransport: PeerTransport {
    /// Bonjour type for the LAN tier. Distinct from Multipeer's `_cruiselan._tcp` so the two
    /// transports never try to adopt each other's advertisements.
    static let serviceType = "_cruiselan-lan._tcp"
    /// Fixed so a join code doesn't have to carry a port. Inside the dynamic/private range.
    static let defaultPort: UInt16 = 50711
    /// Must match `MultipeerTransport.protocolVersion`'s intent: phones on older builds are
    /// ignored rather than half-connected.
    static let protocolVersion = "2"
    /// How often the UDP beacon goes out. Frequent enough that a friend walking into
    /// coverage appears within a few seconds, rare enough to be invisible on battery.
    static let beaconInterval: Duration = .seconds(4)
    /// A beacon heard longer ago than this means they've gone.
    static let beaconLifetime: TimeInterval = 20
    /// Most LAN links at once, matching the radio transport's budget.
    static let maxLinks = 5
    /// Time a connection gets to finish TLS and say hello before it's abandoned.
    static let handshakeTimeout: Duration = .seconds(12)

    private static let logger = Logger(subsystem: "com.dannyguillory.cruiselan", category: "lan")

    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    /// One discovered-or-connected phone on the network.
    private struct Node {
        let key: PeerKey
        var host: NWEndpoint.Host
        var port: NWEndpoint.Port
        var displayName: String
        /// Which tier found it, for telemetry and the diagnostics page.
        var tier: TelemetryDimension
        var lastSeen: Date
        var connection: NWConnection?
        var state: PeerConnectionState = .notConnected
        /// Stable per-install id the peer announced, used only for blocking.
        var nodeId: String?
        var connectedAt: Date?
    }

    private var nodes: [PeerKey: Node] = [:]
    /// Maps "host:port" to a key so rediscovery reuses the same `PeerKey`.
    private var keysByAddress: [String: PeerKey] = [:]
    private var pendingInvitations: [UUID: PeerKey] = [:]

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var beaconListener: NWListener?
    private var beaconTask: Task<Void, Never>?
    private var sweepTask: Task<Void, Never>?
    private var displayName = ""
    private var isRunning = false

    private let telemetry: TelemetryStore
    /// Live tier state for the troubleshooting page. See `LANDiagnostics`.
    let diagnostics: LANDiagnostics
    private let nodeId: String

    init(telemetry: TelemetryStore, diagnostics: LANDiagnostics = LANDiagnostics()) {
        self.telemetry = telemetry
        self.diagnostics = diagnostics
        self.nodeId = LANNodeId.current()
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .bufferingNewest(1024))
    }

    deinit {
        continuation.finish()
    }

    // MARK: - PeerTransport

    func start(displayName: String) {
        stop()
        self.displayName = displayName
        isRunning = true

        do {
            try startListener()
        } catch {
            Self.logger.error("LAN listener failed: \(error.localizedDescription, privacy: .public)")
            log("start: listener could not be created: \(error)")
            telemetry.count(.tierAttemptFailed, .lanBonjour)
            diagnostics.failedToListen(error.localizedDescription)
            continuation.yield(.startFailed(error.localizedDescription))
            return
        }
        diagnostics.started(address: LANAddress.currentIPv4())
        log("start: listening on port \(Self.defaultPort), Wi-Fi address \(LANAddress.currentIPv4() ?? "none"), hotspot \(LANAddress.hotspotRole())")
        startBrowser()
        startBeacon()
        startSweep()
        DebugTrace.log("lan start \(displayName)")
        continuation.yield(.started)
    }

    func stop() {
        if isRunning { diagnostics.stopped() }
        isRunning = false
        beaconTask?.cancel(); beaconTask = nil
        sweepTask?.cancel(); sweepTask = nil
        browser?.cancel(); browser = nil
        beaconListener?.cancel(); beaconListener = nil
        listener?.cancel(); listener = nil
        for node in nodes.values { node.connection?.cancel() }
        nodes.removeAll()
        keysByAddress.removeAll()
        pendingInvitations.removeAll()
    }

    @discardableResult
    func invite(_ peer: PeerKey) -> Bool {
        guard isRunning, var node = nodes[peer], node.state == .notConnected else { return false }
        guard connectedCount < Self.maxLinks else { return false }
        // A Bonjour peer has no usable host/port of its own (its "host" is only a display
        // name), so it must be dialed by the service endpoint Bonjour found; Network.framework
        // resolves that to an address. Dialing the name instead failed every time, which left
        // Bonjour-found phones unreachable and everyone on radio.
        let connection = if let endpoint = bonjourEndpoints[peer] {
            NWConnection(to: endpoint, using: Self.parameters())
        } else {
            NWConnection(host: node.host, port: node.port, using: Self.parameters())
        }
        node.connection = connection
        node.state = .connecting
        nodes[peer] = node
        continuation.yield(.peerStateChanged(peer, .connecting))
        DebugTrace.log("lan invite \(node.displayName) via \(node.tier.rawValue)")
        log("dialing \(label(peer)) at \(Self.describe(connection.endpoint))")
        open(connection, for: peer, isInbound: false)
        return true
    }

    func respond(toInvitation invitationId: UUID, accept: Bool) {
        guard let key = pendingInvitations.removeValue(forKey: invitationId) else { return }
        guard accept, connectedCount <= Self.maxLinks, var node = nodes[key] else {
            nodes[key]?.connection?.cancel()
            nodes[key] = nil
            return
        }
        node.state = .connected
        node.connectedAt = .now
        nodes[key] = node
        telemetry.count(.linkConnectedByTier, node.tier)
        continuation.yield(.peerStateChanged(key, .connected))
    }

    func send(_ data: Data, to peers: [PeerKey]) throws {
        guard isRunning else { throw TransportError.notRunning }
        let targets = peers.compactMap { key -> NWConnection? in
            guard let node = nodes[key], node.state == .connected else { return nil }
            return node.connection
        }
        guard !targets.isEmpty else { throw TransportError.noRecipients }
        let frame = Self.frame(.data, payload: data)
        for connection in targets {
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    Self.logger.notice("LAN send failed: \(error.localizedDescription, privacy: .public)")
                }
            })
        }
    }

    func disconnectAll() {
        for (key, node) in nodes {
            node.connection?.cancel()
            nodes[key]?.connection = nil
            nodes[key]?.state = .notConnected
        }
    }

    /// Stable only for as long as the peer's `LANNodeId` lasts, which is deliberately not
    /// forever — see that type. Used only to keep a blocked person's phone blocked.
    func fingerprint(for peer: PeerKey) -> String? {
        guard let nodeId = nodes[peer]?.nodeId else { return nil }
        return SHA256.hash(data: Data(nodeId.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Which interface a connected link actually runs over, read from its live path (so a
    /// phone that moves from Wi-Fi to a hotspot shows the change), and which tier found it.
    func medium(for peer: PeerKey) -> LinkMedium? {
        guard let node = nodes[peer], node.state == .connected else { return nil }
        let found: LinkMedium.LocalDiscovery = switch node.tier {
        case .lanBroadcast: .broadcast
        case .lanJoinCode: .joinCode
        default: .automatic
        }
        let interface: LinkMedium.LocalInterface
        if let path = node.connection?.currentPath {
            // Sharing a hotspot puts the link on the `bridge` interface; joining one is Wi-Fi
            // to iOS, so it's recognized by the hotspot's address range instead.
            if path.availableInterfaces.contains(where: { $0.name.hasPrefix("bridge") }) || LANAddress.hotspotRole() == .joined {
                interface = .hotspot
            } else if path.usesInterfaceType(.wifi) {
                interface = .wifi
            } else if path.usesInterfaceType(.wiredEthernet) {
                interface = .ethernet
            } else {
                interface = .other
            }
        } else {
            interface = .other
        }
        return .localNetwork(interface, found: found)
    }

    // MARK: - Join by code (tier 3)

    /// The code to read out so someone else can connect to this phone.
    var localJoinCode: LANJoinCode? {
        LANAddress.currentIPv4().flatMap { LANJoinCode(ipv4: $0) }
    }

    /// Connects straight to the address in a code the user typed. Returns false only if the
    /// code can't be used at all; an unreachable address fails later, asynchronously.
    @discardableResult
    func join(using code: LANJoinCode) -> Bool {
        guard isRunning else { return false }
        guard let port = NWEndpoint.Port(rawValue: Self.defaultPort) else { return false }
        // Refuse our own address: connecting to ourselves would look like a phantom friend.
        if let mine = LANAddress.currentIPv4(), mine == code.ipv4 { return false }
        diagnostics.noteJoinCodeAttempt(target: code.ipv4)
        log("join code: dialing \(code.ipv4):\(Self.defaultPort)")
        // Meanwhile, ask the same device on ports Apple devices normally answer, so the log
        // shows whether packets reach it at all ("refused" = they do; "timed out" = dropped).
        let target = code.ipv4
        Task { [weak self] in
            for port: UInt16 in [62078, 7000, 5000, 22] {
                let result = await NetworkTest.probe(host: target, port: port, parameters: .tcp, timeout: 4)
                self?.log("join code: \(target):\(port) → \(result)")
            }
        }
        let key = note(host: NWEndpoint.Host(code.ipv4), port: port, displayName: "Joining…", tier: .lanJoinCode)
        continuation.yield(.peerFound(key, displayName: "Joining…"))
        return invite(key)
    }

    // MARK: - Listener

    private func startListener() throws {
        let parameters = Self.parameters()
        parameters.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: Self.defaultPort)
        let listener = try NWListener(using: parameters, on: port ?? .any)
        // The nickname rides in the Bonjour record so tier 1 needs no extra round trip.
        // It's already the name the user chose to show other guests.
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            MainActor.assumeIsolated {
                switch change {
                case .add(let endpoint): self?.log("bonjour: our service registered \(Self.describe(endpoint))")
                case .remove(let endpoint): self?.log("bonjour: our service removed \(Self.describe(endpoint))")
                @unknown default: self?.log("bonjour: registration change")
                }
            }
        }
        listener.service = NWListener.Service(
            name: "\(displayName)-\(nodeId.prefix(6))",
            type: Self.serviceType,
            txtRecord: NWTXTRecord(["v": Self.protocolVersion, "n": displayName, "id": nodeId])
        )
        // Network.framework types its handlers as nonisolated, but every one of them is
        // scheduled on `.main` below, so assuming main-actor isolation is sound and keeps
        // all mutable state on one actor without a lock.
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.log("listener state: \(state)") }
            guard case .failed(let error) = state else { return }
            Self.logger.error("LAN listener state failed: \(error.localizedDescription, privacy: .public)")
            MainActor.assumeIsolated { self?.continuation.yield(.startFailed(error.localizedDescription)) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        // The network test's self check connects to our own address; accept the TLS so the
        // check is real, but don't turn it into a phantom peer.
        if case .hostPort(let host, _) = connection.endpoint, "\(host)" == LANAddress.currentIPv4() {
            log("inbound self-test connection from this phone")
            connection.stateUpdateHandler = { state in
                if case .ready = state { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { connection.cancel() } }
            }
            connection.start(queue: .main)
            return
        }
        guard isRunning, connectedCount < Self.maxLinks,
              let (host, port) = Self.address(of: connection.endpoint)
        else {
            log("inbound connection refused from \(Self.describe(connection.endpoint)): running \(isRunning), \(connectedCount)/\(Self.maxLinks) links")
            connection.cancel()
            return
        }
        let key = note(host: host, port: port, displayName: "Unknown", tier: .lanBonjour)
        log("inbound connection from \(host):\(port) (\(connectedCount) links busy)")
        nodes[key]?.connection?.cancel()
        nodes[key]?.connection = connection
        nodes[key]?.state = .connecting
        open(connection, for: key, isInbound: true)
    }

    // MARK: - Bonjour (tier 1)

    private func startBrowser() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            MainActor.assumeIsolated {
                self?.log("bonjour browse: \(results.count) result(s), \(changes.count) change(s)")
                self?.handle(bonjour: results)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.log("bonjour browser state: \(state)") }
            guard case .failed = state else { return }
            // mDNS blocked or unavailable: not fatal, the other tiers still apply.
            MainActor.assumeIsolated { self?.telemetry.count(.tierAttemptFailed, .lanBonjour) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func handle(bonjour results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            guard case .bonjour(let txt) = result.metadata else { continue }
            guard txt.getEntry(for: "v") == .string(Self.protocolVersion) else { continue }
            guard case .string(let peerNodeId)? = txt.getEntry(for: "id"), peerNodeId != nodeId else { continue }
            let advertised: String = if case .string(let value)? = txt.getEntry(for: "n") { value } else { name }
            // Bonjour gives a service endpoint, not an address. Resolve by connecting to the
            // endpoint itself; Network.framework resolves it for us.
            resolve(result.endpoint, nodeId: peerNodeId, displayName: advertised)
        }
    }

    /// Bonjour results carry a service name rather than an address. Rather than resolving by
    /// hand, record the service endpoint directly — `NWConnection` accepts it.
    private func resolve(_ endpoint: NWEndpoint, nodeId peerNodeId: String, displayName advertised: String) {
        let address = "service:\(peerNodeId)"
        let key = keysByAddress[address] ?? PeerKey()
        keysByAddress[address] = key
        if var existing = nodes[key] {
            existing.lastSeen = .now
            existing.displayName = advertised
            existing.nodeId = peerNodeId
            nodes[key] = existing
            return
        }
        nodes[key] = Node(
            key: key,
            host: .name(Self.host(of: endpoint) ?? advertised, nil),
            port: NWEndpoint.Port(rawValue: Self.defaultPort) ?? .any,
            displayName: advertised,
            tier: .lanBonjour,
            lastSeen: .now,
            nodeId: peerNodeId
        )
        // Keep the service endpoint so the connection resolves the way Bonjour intended.
        bonjourEndpoints[key] = endpoint
        diagnostics.noteBonjourPeer()
        log("bonjour found \(DiagnosticLog.shared.handle(peerNodeId)) at \(Self.describe(endpoint))")
        DebugTrace.log("lan bonjour found \(advertised)")
        continuation.yield(.peerFound(key, displayName: advertised))
    }

    private var bonjourEndpoints: [PeerKey: NWEndpoint] = [:]

    // MARK: - UDP beacon (tier 2)

    /// What a beacon carries. Deliberately tiny and free of anything personal beyond the
    /// nickname the user already shows to other guests.
    private struct Beacon: Codable {
        var v: String
        var n: String
        var id: String
    }

    private func startBeacon() {
        guard let port = NWEndpoint.Port(rawValue: Self.defaultPort) else { return }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                MainActor.assumeIsolated { self?.receiveBeacon(on: connection) }
            }
            listener.start(queue: .main)
            beaconListener = listener
        } catch {
            telemetry.count(.tierAttemptFailed, .lanBroadcast)
            log("beacon listener could not be created: \(error)")
            Self.logger.notice("LAN beacon listener failed: \(error.localizedDescription, privacy: .public)")
        }

        beaconTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sendBeacon()
                try? await Task.sleep(for: Self.beaconInterval)
            }
        }
    }

    private func sendBeacon() {
        guard isRunning, let port = NWEndpoint.Port(rawValue: Self.defaultPort),
              let payload = try? JSONEncoder().encode(Beacon(v: Self.protocolVersion, n: displayName, id: nodeId))
        else { return }
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = false
        let connection = NWConnection(host: "255.255.255.255", port: port, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                MainActor.assumeIsolated { self?.noteBeaconSendFailure(Self.describe(error)) }
            } else if case .waiting(let error) = state {
                MainActor.assumeIsolated { self?.noteBeaconSendFailure("waiting: \(Self.describe(error))") }
            }
        }
        connection.start(queue: .main)
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                if let error { self?.noteBeaconSendFailure(Self.describe(error)) } else { self?.beaconSendsOK += 1 }
            }
            connection.cancel()
        })
    }

    /// Beacon sends are logged once per distinct result, not every 4 seconds.
    private var beaconSendsOK = 0
    private var lastBeaconFailure: String?
    private func noteBeaconSendFailure(_ reason: String) {
        guard reason != lastBeaconFailure else { return }
        lastBeaconFailure = reason
        log("broadcast beacon send failed: \(reason) (sent OK so far: \(beaconSendsOK)). iOS needs the multicast networking entitlement to broadcast.")
    }

    private func receiveBeacon(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
            defer { connection.cancel() }
            guard let self, let data, data.count <= 512,
                  let beacon = try? JSONDecoder().decode(Beacon.self, from: data),
                  beacon.v == Self.protocolVersion, beacon.id != self.nodeId,
                  let (host, _) = Self.address(of: connection.endpoint),
                  let port = NWEndpoint.Port(rawValue: Self.defaultPort)
            else { return }
            let name = Nickname.sanitize(beacon.n) ?? "Unknown"
            self.diagnostics.noteBeacon()
            self.log("beacon heard from \(DiagnosticLog.shared.handle(beacon.id)) at \(host)")
            // Bonjour already found them: don't add a second entry for the same phone.
            guard !self.nodes.values.contains(where: { $0.nodeId == beacon.id }) else {
                self.touch(nodeId: beacon.id)
                return
            }
            let key = self.note(host: host, port: port, displayName: name, tier: .lanBroadcast)
            self.nodes[key]?.nodeId = beacon.id
            DebugTrace.log("lan beacon found \(name)")
            self.continuation.yield(.peerFound(key, displayName: name))
            }
        }
    }

    private func touch(nodeId peerNodeId: String) {
        for (key, node) in nodes where node.nodeId == peerNodeId {
            nodes[key]?.lastSeen = .now
        }
    }

    // MARK: - Connection handling

    private func open(_ connection: NWConnection, for key: PeerKey, isInbound: Bool) {
        let opened = Date.now
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ms = Int(Date.now.timeIntervalSince(opened) * 1000)
                switch state {
                case .ready:
                    let path = connection.currentPath
                    self.log("\(isInbound ? "inbound" : "outbound") \(self.label(key)) ready after \(ms) ms: local \(Self.describe(path?.localEndpoint)) remote \(Self.describe(path?.remoteEndpoint)) interfaces \(path?.availableInterfaces.map { "\($0.name)(\($0.type))" } ?? [])")
                case .failed(let error):
                    self.log("\(isInbound ? "inbound" : "outbound") \(self.label(key)) failed after \(ms) ms: \(Self.describe(error))")
                case .waiting(let error):
                    self.log("\(isInbound ? "inbound" : "outbound") \(self.label(key)) waiting after \(ms) ms: \(Self.describe(error))")
                case .cancelled:
                    self.log("\(isInbound ? "inbound" : "outbound") \(self.label(key)) closed after \(ms) ms")
                case .preparing:
                    self.log("\(isInbound ? "inbound" : "outbound") \(self.label(key)) preparing")
                default:
                    break
                }
                switch state {
                case .ready:
                    self.sendHello(on: connection)
                    self.receiveFrame(on: connection, for: key, isInbound: isInbound)
                case .failed(let error):
                    Self.logger.notice("LAN link failed: \(error.localizedDescription, privacy: .public)")
                    self.diagnostics.noteDirectOutcome(Self.outcome(for: error))
                    self.teardown(key, reason: .failure)
                case .cancelled:
                    self.teardown(key, reason: nil)
                case .waiting(let error):
                    // `waiting` means the connection can't proceed yet. For a peer on the
                    // same network that's effectively terminal, and *why* it's waiting is
                    // the diagnosis: a refusal means the packet arrived, silence means it
                    // didn't. Give up rather than waiting forever so the next tier can try.
                    Self.logger.notice("LAN link waiting: \(error.localizedDescription, privacy: .public)")
                    self.diagnostics.noteDirectOutcome(Self.outcome(for: error))
                    self.teardown(key, reason: .timeout)
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
        }
        connection.start(queue: .main)

        Task { [weak self] in
            try? await Task.sleep(for: Self.handshakeTimeout)
            guard let self, let node = self.nodes[key], node.state != .connected else { return }
            // Ran out of time without the network ever saying anything. That silence is
            // itself the evidence; don't overwrite a more specific error if one arrived.
            if self.diagnostics.lastDirectOutcome == nil {
                self.diagnostics.noteDirectOutcome(.timedOut)
            }
            self.log("\(self.label(key)) gave up: no TLS + hello within \(Self.handshakeTimeout)")
            self.teardown(key, reason: .timeout)
        }
    }

    /// Maps a Network.framework error onto what it says about the network.
    ///
    /// The distinction that matters: `ECONNREFUSED` means the other device's stack replied,
    /// so packets are crossing between guests. A timeout means they aren't. See
    /// `LANDiagnostics.DirectOutcome`.
    private static func outcome(for error: NWError) -> LANDiagnostics.DirectOutcome {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: .refused
            case .ETIMEDOUT, .EHOSTDOWN: .timedOut
            case .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN: .noRoute
            default: .other(error.localizedDescription)
            }
        default:
            .other(error.localizedDescription)
        }
    }

    private func sendHello(on connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(
            Beacon(v: Self.protocolVersion, n: displayName, id: nodeId)
        ) else { return }
        connection.send(content: Self.frame(.hello, payload: payload), completion: .contentProcessed { _ in })
    }

    /// Reads one length-prefixed frame and recurses. TCP is a stream, so without explicit
    /// framing two packets can arrive glued together or split in half.
    private func receiveFrame(on connection: NWConnection, for key: PeerKey, isInbound: Bool) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if error != nil || isComplete {
                    self.teardown(key, reason: nil)
                    return
                }
                guard let header, header.count == 4 else {
                    self.teardown(key, reason: .failure)
                    return
                }
                let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
                // One byte of frame type plus at most a full mesh packet. Anything larger is
                // a malformed or hostile peer and the link is dropped rather than trusted.
                guard length > 0, length <= MeshPacket.maxPacketBytes + 1 else {
                    Self.logger.notice("LAN frame oversized (\(length, privacy: .public)); dropping link")
                    self.teardown(key, reason: .failure)
                    return
                }
                connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, bodyComplete, bodyError in
                    MainActor.assumeIsolated {
                        guard let body, body.count == length, bodyError == nil, !bodyComplete else {
                            self.teardown(key, reason: nil)
                            return
                        }
                        self.handle(frame: body, from: key, on: connection, isInbound: isInbound)
                        self.receiveFrame(on: connection, for: key, isInbound: isInbound)
                    }
                }
            }
        }
    }

    private func handle(frame: Data, from key: PeerKey, on connection: NWConnection, isInbound: Bool) {
        guard let kind = FrameKind(rawValue: frame[frame.startIndex]) else { return }
        let payload = frame.dropFirst()
        switch kind {
        case .hello:
            guard let beacon = try? JSONDecoder().decode(Beacon.self, from: payload),
                  beacon.v == Self.protocolVersion, beacon.id != nodeId
            else {
                let decoded = try? JSONDecoder().decode(Beacon.self, from: payload)
                log("hello rejected from \(label(key)): \(decoded == nil ? "unreadable" : decoded!.id == nodeId ? "it's this phone" : "protocol \(decoded!.v), expected \(Self.protocolVersion)")")
                teardown(key, reason: .refused)
                return
            }
            let name = Nickname.sanitize(beacon.n) ?? "Unknown"
            nodes[key]?.displayName = name
            nodes[key]?.nodeId = beacon.id
            nodes[key]?.lastSeen = .now
            if isInbound {
                // Mirror the radio transport: the session layer decides whether to keep it.
                let invitationId = UUID()
                pendingInvitations[invitationId] = key
                continuation.yield(.invitationReceived(invitationId: invitationId, from: key, displayName: name))
            } else if nodes[key]?.state != .connected {
                nodes[key]?.state = .connected
                nodes[key]?.connectedAt = .now
                let tier = nodes[key]?.tier ?? .lanBonjour
                telemetry.count(.linkConnectedByTier, tier)
                diagnostics.noteLinkConnected()
                DebugTrace.log("lan connected \(name) via \(tier.rawValue)")
                log("linked \(label(key)) (hello exchanged)")
                continuation.yield(.peerStateChanged(key, .connected))
            }
        case .data:
            guard nodes[key]?.state == .connected, payload.count <= MeshPacket.maxPacketBytes else { return }
            continuation.yield(.received(Data(payload), from: key))
        }
    }

    private func teardown(_ key: PeerKey, reason: TelemetryDimension?) {
        guard let node = nodes[key] else { return }
        if node.state != .notConnected || reason != nil {
            log("teardown \(label(key)) was \(node.state), reason \(reason?.rawValue ?? "closed")")
        }
        node.connection?.cancel()
        if let connectedAt = node.connectedAt {
            telemetry.observe(.linkLifetime, Date.now.timeIntervalSince(connectedAt), node.tier)
        }
        if reason != nil, node.state != .connected {
            telemetry.count(.tierAttemptFailed, node.tier)
            diagnostics.noteAttemptFailed()
        }
        let wasActive = node.state != .notConnected
        nodes[key]?.connection = nil
        nodes[key]?.state = .notConnected
        nodes[key]?.connectedAt = nil
        pendingInvitations = pendingInvitations.filter { $0.value != key }
        if wasActive { continuation.yield(.peerStateChanged(key, .notConnected)) }
    }

    // MARK: - Diagnostics

    /// The exact connection settings links use, so the network test exercises the same TLS.
    static func linkParameters() -> NWParameters { parameters() }

    /// IPv4 addresses of phones seen on this network (by beacon, join code, an inbound
    /// connection, or a link's resolved address), for the network test to probe.
    var knownPeerAddresses: [String] {
        var addresses = Set<String>()
        for node in nodes.values {
            if case .ipv4(let address) = node.host { addresses.insert("\(address)") }
            if case .hostPort(.ipv4(let address), _)? = node.connection?.currentPath?.remoteEndpoint {
                addresses.insert("\(address)")
            }
        }
        return addresses.sorted()
    }

    private func log(_ message: String) { DiagnosticLog.shared.note("lan", message) }

    /// A node's label for the log: an anonymous handle plus how it was found.
    private func label(_ key: PeerKey) -> String {
        guard let node = nodes[key] else { return "unknown-node" }
        return "\(DiagnosticLog.shared.handle(node.nodeId ?? node.displayName)) via \(node.tier.rawValue)"
    }

    nonisolated static func describe(_ endpoint: NWEndpoint?) -> String {
        guard let endpoint else { return "none" }
        switch endpoint {
        case .hostPort(let host, let port): return "\(host):\(port)"
        case .service(_, let type, let domain, let interface): return "service \(type) \(domain) on \(interface?.name ?? "any")"
        default: return "\(endpoint)"
        }
    }

    nonisolated static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): "posix \(code.rawValue) (\(code))"
        case .dns(let code): "dns \(code)"
        case .tls(let status): "tls \(status)"
        case .wifiAware(let code): "wifiAware \(code)"
        @unknown default: "\(error)"
        }
    }

    // MARK: - Housekeeping

    /// Drops peers whose beacons stopped arriving, so a friend who left the network doesn't
    /// linger in the list forever.
    private func startSweep() {
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.sweep()
            }
        }
    }

    private func sweep() {
        let cutoff = Date.now.addingTimeInterval(-Self.beaconLifetime)
        for (key, node) in nodes where node.state == .notConnected && node.lastSeen < cutoff {
            nodes[key] = nil
            keysByAddress = keysByAddress.filter { $0.value != key }
            bonjourEndpoints[key] = nil
            continuation.yield(.peerLost(key))
        }
    }

    private var connectedCount: Int {
        nodes.values.filter { $0.state != .notConnected }.count
    }

    /// Records a peer at an address, reusing its key if we've seen it before.
    private func note(host: NWEndpoint.Host, port: NWEndpoint.Port, displayName: String, tier: TelemetryDimension) -> PeerKey {
        let address = "\(host):\(port)"
        if let existing = keysByAddress[address] {
            nodes[existing]?.lastSeen = .now
            nodes[existing]?.displayName = displayName
            return existing
        }
        let key = PeerKey()
        keysByAddress[address] = key
        nodes[key] = Node(key: key, host: host, port: port, displayName: displayName,
                          tier: tier, lastSeen: .now)
        return key
    }

    // MARK: - Framing and parameters

    private enum FrameKind: UInt8 {
        case hello = 1
        case data = 2
    }

    private static func frame(_ kind: FrameKind, payload: Data) -> Data {
        var out = Data(capacity: payload.count + 5)
        var length = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(kind.rawValue)
        out.append(payload)
        return out
    }

    /// TLS 1.2 with a pre-shared key. See the type's note on what this does and doesn't buy.
    private static func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        pskData.withUnsafeBytes { keyBytes in
            pskIdentityData.withUnsafeBytes { identityBytes in
                let key = DispatchData(bytes: keyBytes)
                let identity = DispatchData(bytes: identityBytes)
                sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, identity as __DispatchData)
            }
        }
        // TLS 1.2 PSK, as in Apple's peer-to-peer sample. Network.framework doesn't do external
        // PSKs over TLS 1.3: with a 1.3-only suite every handshake fails (-9858), which is why
        // no LAN link ever connected in builds up to 1.9 (20). Verified on macOS: 1.3 fails,
        // 1.2 with TLS_PSK_WITH_AES_128_GCM_SHA256 connects.
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveCount = 3
        tcp.keepaliveInterval = 5
        // Mesh packets are small and latency matters more than packing them together.
        tcp.noDelay = true
        tcp.connectionTimeout = 10

        let parameters = NWParameters(tls: tls, tcp: tcp)
        // The radio transport already covers peer-to-peer; this one is the network path.
        parameters.includePeerToPeer = false
        // Never run this over cellular: it would be someone's roaming bill at sea.
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    /// Derived from a fixed label so every build agrees without shipping a key blob. Not a
    /// secret: see the type's security note.
    private static let pskData: Data = Data(
        SHA256.hash(data: Data("CruiseLAN/LAN/v\(protocolVersion)".utf8))
    )
    private static let pskIdentityData = Data("cruiselan".utf8)

    private static func address(of endpoint: NWEndpoint) -> (NWEndpoint.Host, NWEndpoint.Port)? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        return (host, port)
    }

    private static func host(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        return "\(host)"
    }
}

/// A per-install id used to recognise the same phone across the LAN tiers (so Bonjour and
/// the beacon don't show one friend twice) and to keep a blocked phone blocked.
///
/// Rotates on the same schedule as the telemetry pseudonym, and for the same reason: a
/// permanent broadcast identifier would let anyone on the ship's network log which cabins a
/// phone passed through all week. It lives in `UserDefaults`, not the Keychain, so deleting
/// the app actually clears it.
nonisolated enum LANNodeId {
    static let lifetime: TimeInterval = 14 * 24 * 60 * 60
    private static let idKey = "lan.nodeId"
    private static let issuedKey = "lan.nodeIdIssued"

    static func current() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: idKey),
           let issued = defaults.object(forKey: issuedKey) as? Date,
           Date.now.timeIntervalSince(issued) < lifetime {
            return existing
        }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(fresh, forKey: idKey)
        defaults.set(Date.now, forKey: issuedKey)
        return fresh
    }
}

/// Finds this phone's IPv4 address on the current Wi-Fi network, for the join code.
nonisolated enum LANAddress {
    /// Whether this phone is on a Personal Hotspot, and which end of it.
    ///
    /// **Why this matters.** A hotspot is a private network with no client isolation, so
    /// CruiseLAN always works across one. When a hotel or ship blocks guest devices from
    /// reaching each other, "one of you share a hotspot and everyone join it" is the only
    /// reliable workaround — and the app can tell the user they're already on one rather
    /// than leaving them to wonder.
    enum HotspotRole: Equatable, Sendable {
        /// This phone is sharing its connection; others have joined it.
        case sharing
        /// This phone has joined someone else's iPhone hotspot.
        case joined
        case none
    }

    /// iOS names the hotspot bridge interface `bridge100` when sharing.
    private static let hotspotBridgeInterface = "bridge100"
    /// Apple hands hotspot clients addresses in 172.20.10.0/28, with the host at .1. This is
    /// stable across iOS versions but is a convention rather than a documented guarantee, so
    /// it's only ever used to *add* reassurance, never to rule anything out.
    private static let hotspotClientPrefix = "172.20.10."

    static func hotspotRole() -> HotspotRole {
        let addresses = interfaceAddresses()
        if addresses[hotspotBridgeInterface] != nil { return .sharing }
        if let wifi = addresses["en0"], wifi.hasPrefix(hotspotClientPrefix) { return .joined }
        return .none
    }

    /// The address on `en0` (Wi-Fi). Nil when not on Wi-Fi, which is also when a join code
    /// would be useless anyway.
    static func currentIPv4() -> String? {
        interfaceAddresses()["en0"]
    }

    /// Every IPv4 interface with an address, by interface name. One pass over `getifaddrs`
    /// serves both the join code and hotspot detection.
    private static func interfaceAddresses() -> [String: String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var result: [String: String] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let name = String(cString: interface.ifa_name)
            // Keep the first address per interface; aliases aren't useful here.
            if result[name] == nil { result[name] = String(cString: buffer) }
        }
        return result
    }
}

