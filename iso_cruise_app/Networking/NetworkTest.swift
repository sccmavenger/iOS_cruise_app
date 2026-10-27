import Darwin
import Foundation
import Network
import Observation

/// An active, thorough test of what the current network allows, for the diagnostics report.
///
/// Passive counters can't tell apart "nobody else is here", "the network hides phones from
/// each other", "the network drops traffic between them", and "something on this phone is
/// broken". So this probes each layer in turn and writes every result, with timings and exact
/// error codes, to the report and the event log:
///
/// 1. **Interfaces**: every network interface with its address, netmask, and flags.
/// 2. **Path**: what iOS reports (status, interfaces, gateway, DNS, IPv4/IPv6, constraints).
/// 3. **Self test**: a TLS connection to this phone's own CruiseLAN listener, over its Wi-Fi
///    address. If this fails, nothing else could have worked (this would have caught the
///    TLS 1.3 PSK bug in one run).
/// 4. **Router**: TCP to the gateway on common ports. A refusal or answer proves the phone
///    can reach the network itself.
/// 5. **Bonjour census**: how many advertisements of common device types (AirPlay, printers,
///    Chromecasts, other phones) are visible. Seeing none of anything, on a busy hotel network,
///    means discovery between guests is filtered.
/// 6. **Broadcast**: whether a UDP broadcast can even be sent from this phone.
/// 7. **Other phones**: TCP to each known peer address (join code target, beacons, links) on
///    CruiseLAN's port and on ports Apple devices commonly answer. "Refused" means packets
///    reach the device; "timed out" means the network drops them (client isolation) or the
///    device's firewall does.
///
/// Everything stays on the local network: no internet hosts are contacted.
@MainActor
@Observable
final class NetworkTest {
    /// One per app, so results survive leaving and reopening Troubleshooting.
    static let shared = NetworkTest()

    private(set) var isRunning = false
    private(set) var lines: [String] = []
    private(set) var finishedAt: Date?
    /// One-line conclusion for the screen.
    private(set) var verdict: String?

    /// Service types counted in the census. Each must be listed in `NSBonjourServices`.
    static let censusTypes = [
        "_cruiselan-lan._tcp", "_cruiselan._tcp", "_airplay._tcp", "_raop._tcp", "_companion-link._tcp",
        "_googlecast._tcp", "_spotify-connect._tcp", "_ipp._tcp", "_printer._tcp", "_http._tcp",
        "_smb._tcp", "_hap._tcp", "_device-info._tcp",
    ]
    /// CruiseLAN, iPhone/iPad sync service, AirPlay receiver (Mac/Apple TV), AirPlay control, SSH.
    static let peerPorts: [UInt16] = [LANTransport.defaultPort, 62078, 7000, 5000, 22]

    func run(lan: LANTransport?) async {
        guard !isRunning else { return }
        isRunning = true
        lines = []
        verdict = nil
        defer {
            isRunning = false
            finishedAt = .now
        }
        let started = Date.now
        out("Network test started \(started.formatted(.iso8601))")

        // 1. Interfaces
        out("-- Interfaces --")
        let interfaces = Self.interfaces()
        for interface in interfaces { out("  \(interface)") }
        let wifi = interfaces.first { $0.name == "en0" && $0.ipv4 != nil }
        if wifi == nil { out("  No IPv4 address on en0 (Wi-Fi).") }

        // 2. Path
        out("-- Path --")
        let path = await Self.currentPath()
        out("  status \(path.status), unsatisfied reason \(path.unsatisfiedReason)")
        out("  interfaces \(path.availableInterfaces.map { "\($0.name)(\($0.type))" })")
        out("  gateways \(path.gateways.map { LANTransport.describe($0) })")
        out("  IPv4 \(path.supportsIPv4), IPv6 \(path.supportsIPv6), DNS \(path.supportsDNS), expensive \(path.isExpensive), constrained \(path.isConstrained)")
        if path.unsatisfiedReason == .localNetworkDenied {
            out("  Local Network permission is OFF for CruiseLAN: nothing on this network can work.")
        }

        // 3. Self test
        out("-- Self test (TLS to this phone's own CruiseLAN listener) --")
        var selfOK = false
        if let address = wifi?.ipv4 {
            let result = await Self.probe(host: address, port: LANTransport.defaultPort, parameters: LANTransport.linkParameters(), timeout: 5)
            out("  \(address):\(LANTransport.defaultPort) → \(result)")
            selfOK = result.reachedDevice && result.outcome == .open
        } else {
            out("  skipped: no Wi-Fi address")
        }

        // 4. Router
        out("-- Router --")
        var routerReached = false
        let gatewayHosts = path.gateways.compactMap { endpoint -> String? in
            if case .hostPort(.ipv4(let address), _) = endpoint { return "\(address)" }
            return nil
        }
        let routers = gatewayHosts.isEmpty ? (wifi.flatMap(Self.guessGateway).map { [$0] } ?? []) : gatewayHosts
        if routers.isEmpty { out("  no gateway known") }
        for router in routers {
            for port: UInt16 in [53, 80, 443] {
                let result = await Self.probe(host: router, port: port, parameters: .tcp, timeout: 3)
                out("  \(router):\(port) → \(result)")
                routerReached = routerReached || result.reachedDevice
            }
        }

        // 5. Bonjour census
        out("-- Bonjour census (8 s; counts only, and they can include this device's own services) --")
        let census = await Self.census(types: Self.censusTypes, seconds: 8)
        var othersSeen = 0
        for type in Self.censusTypes {
            let entry = census[type]
            out("  \(type): \(entry.map { "\($0.count) found" + ($0.error.map { ", error \($0)" } ?? "") } ?? "no answer")")
            if type != "_cruiselan-lan._tcp" && type != "_cruiselan._tcp" { othersSeen += entry?.count ?? 0 }
        }
        let cruiseLANSeen = max(0, (census["_cruiselan-lan._tcp"]?.count ?? 0) - 1) // minus ourselves

        // 6. Broadcast
        out("-- Broadcast --")
        let broadcastTarget = wifi?.broadcast ?? "255.255.255.255"
        let broadcast = await Self.sendUDP(host: broadcastTarget, port: LANTransport.defaultPort)
        out("  UDP to \(broadcastTarget) → \(broadcast)")
        if broadcast.contains("posix 13") || broadcast.contains("posix 50") {
            out("  (iOS blocks broadcasts from apps without Apple's multicast networking entitlement, so this is expected until Apple grants it.)")
        }

        // 7. Other phones
        out("-- Other devices --")
        var targets = Set(lan?.knownPeerAddresses ?? [])
        if let join = lan?.diagnostics.lastJoinTarget { targets.insert(join) }
        if let mine = wifi?.ipv4 { targets.remove(mine) }
        var anyPeerReached = false, anyPeerTimedOut = false
        if targets.isEmpty { out("  none known: scan or type a friend's join code, then run the test again") }
        for target in targets.sorted() {
            if let wifi, !Self.sameSubnet(target, wifi) { out("  \(target) is outside this phone's subnet \(wifi.ipv4 ?? "")/\(wifi.prefix ?? 0)") }
            for port in Self.peerPorts {
                let parameters: NWParameters = port == LANTransport.defaultPort ? LANTransport.linkParameters() : .tcp
                let result = await Self.probe(host: target, port: port, parameters: parameters, timeout: 4)
                out("  \(target):\(port) → \(result)")
                anyPeerReached = anyPeerReached || result.reachedDevice
                anyPeerTimedOut = anyPeerTimedOut || result.outcome == .timedOut
            }
        }

        // Conclusion
        out("-- Conclusion --")
        let conclusion: String
        if wifi == nil {
            conclusion = "Not on Wi-Fi: join a Wi-Fi network (or a friend's Personal Hotspot)."
        } else if path.unsatisfiedReason == .localNetworkDenied {
            conclusion = "Local Network permission is off for CruiseLAN. Turn it on in Settings › Privacy & Security › Local Network."
        } else if !selfOK {
            conclusion = "This phone couldn't connect to its own CruiseLAN listener. That's a problem on this phone, not the network; please send this report."
        } else if anyPeerReached {
            conclusion = "Packets reach the other device, so the network isn't isolating guests. If CruiseLAN still didn't connect, check that both phones have it open with the same build."
        } else if anyPeerTimedOut || (targets.isEmpty && lan?.diagnostics.lastDirectOutcome == .timedOut) {
            conclusion = "The other device never answered on any port: this network is very likely blocking traffic between guests (client isolation), or that device's firewall is. Use a Personal Hotspot or Nearby radio."
        } else if othersSeen == 0 && cruiseLANSeen == 0 {
            conclusion = routerReached
                ? "The router answers, but no other device's announcements are visible at all: this network hides guests from each other. Try a join code; if that times out too, use a Personal Hotspot or Nearby radio."
                : "Nothing on this network answered, not even the router's common ports. Discovery between guests is likely blocked."
        } else if cruiseLANSeen == 0 {
            // The counts can be this phone's own services (an iPhone advertises several), so
            // they don't prove other guests are visible. Only a join code settles it.
            conclusion = "No other CruiseLAN phone is visible. The \(othersSeen) other announcement(s) may be this phone's own, so this doesn't show whether the network passes discovery. Scan or type the other phone's code, then run the test again: that tests the path directly."
        } else {
            conclusion = "Another CruiseLAN phone is visible on this network. If it doesn't connect, run the test again after scanning its code."
        }
        verdict = conclusion
        out("  \(conclusion)")
        out("Finished in \(String(format: "%.1f", Date.now.timeIntervalSince(started))) s")
    }

    private func out(_ line: String) {
        lines.append(line)
        DiagnosticLog.shared.note("test", line.trimmingCharacters(in: .whitespaces))
        DebugTrace.log("test \(line)")
    }

    /// A fresh path from a started monitor (an unstarted one reports nothing useful).
    static func currentPath() async -> NWPath {
        let monitor = NWPathMonitor()
        monitor.start(queue: .main)
        defer { monitor.cancel() }
        for await path in monitor { return path }
        return monitor.currentPath
    }

    // MARK: - Interfaces

    struct Interface: CustomStringConvertible {
        let name: String
        var ipv4: String?
        var netmask: String?
        var broadcast: String?
        var prefix: Int?
        var hasIPv6LinkLocal = false
        var flags: [String] = []

        var description: String {
            var parts = [name]
            if let ipv4 { parts.append("\(ipv4)/\(prefix ?? 0)") }
            if let broadcast { parts.append("broadcast \(broadcast)") }
            if hasIPv6LinkLocal { parts.append("IPv6 link-local") }
            parts.append(flags.joined(separator: ","))
            return parts.joined(separator: " ")
        }
    }

    /// Every interface that's up, from `getifaddrs`.
    static func interfaces() -> [Interface] {
        var result: [String: Interface] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            let name = String(cString: ifa.ifa_name)
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0 else { continue }
            var interface = result[name] ?? Interface(name: name)
            interface.flags = [
                flags & IFF_RUNNING != 0 ? "running" : nil,
                flags & IFF_BROADCAST != 0 ? "broadcast" : nil,
                flags & IFF_MULTICAST != 0 ? "multicast" : nil,
                flags & IFF_LOOPBACK != 0 ? "loopback" : nil,
                flags & IFF_POINTOPOINT != 0 ? "point-to-point" : nil,
            ].compactMap { $0 }
            if let addr = ifa.ifa_addr {
                switch Int32(addr.pointee.sa_family) {
                case AF_INET:
                    interface.ipv4 = address(addr)
                    if let mask = ifa.ifa_netmask {
                        interface.netmask = address(mask)
                        interface.prefix = interface.netmask.map(prefixLength)
                    }
                    if flags & IFF_BROADCAST != 0, let dst = ifa.ifa_dstaddr { interface.broadcast = address(dst) }
                case AF_INET6:
                    if address(addr)?.hasPrefix("fe80") == true { interface.hasIPv6LinkLocal = true }
                default:
                    break
                }
            }
            result[name] = interface
        }
        return result.values.filter { $0.ipv4 != nil || $0.hasIPv6LinkLocal }.sorted { $0.name < $1.name }
    }

    private static func address(_ sockaddr: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(sockaddr.pointee.sa_family == AF_INET6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
        guard getnameinfo(sockaddr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }

    private static func prefixLength(_ netmask: String) -> Int {
        netmask.split(separator: ".").compactMap { UInt8($0) }.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    private static func ipv4Value(_ address: String) -> UInt32? {
        let parts = address.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        return parts.reduce(0) { $0 << 8 | $1 }
    }

    static func sameSubnet(_ address: String, _ interface: Interface) -> Bool {
        guard let mine = interface.ipv4.flatMap(ipv4Value), let other = ipv4Value(address), let prefix = interface.prefix else { return true }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        return mine & mask == other & mask
    }

    /// The first address of the subnet, the usual router address, when iOS doesn't report one.
    private static func guessGateway(_ interface: Interface) -> String? {
        guard let mine = interface.ipv4.flatMap(ipv4Value), let prefix = interface.prefix, prefix < 31 else { return nil }
        let mask: UInt32 = ~UInt32(0) << (32 - prefix)
        let first = (mine & mask) + 1
        return [24, 16, 8, 0].map { String((first >> $0) & 0xff) }.joined(separator: ".")
    }

    // MARK: - Probes

    struct ProbeResult: CustomStringConvertible {
        enum Outcome: String { case open, refused, timedOut = "timed out", noRoute = "no route", failed }
        let outcome: Outcome
        let milliseconds: Int
        let detail: String?

        /// A reply of any kind (open or refused) proves packets reached the device.
        var reachedDevice: Bool { outcome == .open || outcome == .refused }

        var description: String {
            "\(outcome.rawValue) in \(milliseconds) ms" + (detail.map { " (\($0))" } ?? "")
        }
    }

    /// Opens a connection and reports how it ended. TLS probes count as open only after the
    /// handshake completes.
    static func probe(host: String, port: UInt16, parameters: NWParameters, timeout: TimeInterval) async -> ProbeResult {
        guard let port = NWEndpoint.Port(rawValue: port) else { return ProbeResult(outcome: .failed, milliseconds: 0, detail: "bad port") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let started = Date.now
        let elapsed = { Int(Date.now.timeIntervalSince(started) * 1000) }
        return await withCheckedContinuation { continuation in
            let once = Once()
            let finish: (ProbeResult) -> Void = { result in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(ProbeResult(outcome: .open, milliseconds: elapsed(), detail: nil))
                case .failed(let error), .waiting(let error):
                    finish(classify(error, ms: elapsed()))
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                finish(ProbeResult(outcome: .timedOut, milliseconds: elapsed(), detail: nil))
            }
        }
    }

    nonisolated private static func classify(_ error: NWError, ms: Int) -> ProbeResult {
        if case .posix(let code) = error {
            switch code {
            case .ECONNREFUSED: return ProbeResult(outcome: .refused, milliseconds: ms, detail: "the device answered: nothing listening")
            case .ETIMEDOUT: return ProbeResult(outcome: .timedOut, milliseconds: ms, detail: nil)
            case .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN, .EHOSTDOWN: return ProbeResult(outcome: .noRoute, milliseconds: ms, detail: "\(code)")
            case .ECONNRESET: return ProbeResult(outcome: .refused, milliseconds: ms, detail: "reset by the device")
            default: break
            }
        }
        if case .tls = error {
            // The TCP connection reached the device; only the TLS layer disagreed.
            return ProbeResult(outcome: .refused, milliseconds: ms, detail: "reached the device, TLS failed: \(LANTransport.describe(error))")
        }
        return ProbeResult(outcome: .failed, milliseconds: ms, detail: LANTransport.describe(error))
    }

    /// Sends one UDP datagram and reports whether iOS let it out.
    static func sendUDP(host: String, port: UInt16) async -> String {
        guard let port = NWEndpoint.Port(rawValue: port) else { return "bad port" }
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = false
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        return await withCheckedContinuation { continuation in
            let once = Once()
            let finish: (String) -> Void = { result in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data("cruiselan-test".utf8), completion: .contentProcessed { error in
                        finish(error.map { "send failed: \(LANTransport.describe($0))" } ?? "sent")
                    })
                case .failed(let error), .waiting(let error):
                    finish("blocked: \(LANTransport.describe(error))")
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish("no result in 3 s") }
        }
    }

    /// Browses each service type for `seconds` and counts distinct results (no names kept).
    static func census(types: [String], seconds: TimeInterval) async -> [String: (count: Int, error: String?)] {
        final class Tally: @unchecked Sendable {
            var found: [String: Set<String>] = [:]
            var errors: [String: String] = [:]
        }
        let tally = Tally()
        var browsers: [String: NWBrowser] = [:]
        for type in types {
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: parameters)
            browser.browseResultsChangedHandler = { results, _ in
                MainActor.assumeIsolated {
                    tally.found[type, default: []].formUnion(results.map { "\($0.endpoint)" })
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    MainActor.assumeIsolated { tally.errors[type] = LANTransport.describe(error) }
                } else if case .waiting(let error) = state {
                    MainActor.assumeIsolated { tally.errors[type] = "waiting: \(LANTransport.describe(error))" }
                }
            }
            browser.start(queue: .main)
            browsers[type] = browser
        }
        try? await Task.sleep(for: .seconds(seconds))
        browsers.values.forEach { $0.cancel() }
        var result: [String: (count: Int, error: String?)] = [:]
        for type in types { result[type] = (tally.found[type]?.count ?? 0, tally.errors[type]) }
        return result
    }
}

/// Lets a continuation be resumed exactly once from several callbacks.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
