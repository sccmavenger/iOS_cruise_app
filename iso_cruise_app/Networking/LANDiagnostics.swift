import Foundation
import Observation

/// Live state of the LAN transport's three discovery tiers, for the troubleshooting page.
///
/// **Why this exists.** The passive checks in `NetworkPathProbe` can't detect the thing that
/// actually breaks phone-to-phone apps on hotel and ship Wi-Fi. "Client isolation" is a
/// setting on the access point: both phones hold a perfectly good IP address, the Wi-Fi
/// check passes, Local Network permission is granted — and the network simply refuses to
/// carry a packet from one guest to another. Nothing about the local interface reveals that.
///
/// The only way to know is to *try*, and report what happened. So each tier records whether
/// it ever saw anything, and the page turns that into a verdict:
///
/// - Bonjour saw peers → mDNS is forwarded; the network is friendly.
/// - No Bonjour but beacons heard → multicast is filtered, broadcast isn't.
/// - Neither, but a join code connects → discovery is blocked, unicast works.
/// - Nothing at all → client isolation. No peer-to-peer app can work on this network.
@MainActor
@Observable
final class LANDiagnostics {
    /// Whether the TCP listener came up. False means the app can't accept LAN links at all.
    private(set) var isListening = false
    /// Why the listener or a tier failed, if it did.
    private(set) var listenerError: String?
    /// Distinct phones seen via Bonjour this run.
    private(set) var bonjourPeersSeen = 0
    /// UDP beacons heard this run.
    private(set) var beaconsHeard = 0
    /// LAN links that reached `connected`.
    private(set) var linksConnected = 0
    /// LAN connection attempts that failed or timed out.
    private(set) var attemptsFailed = 0
    /// Whether a join code has been tried this run, and whether it worked.
    private(set) var joinCodeAttempted = false
    /// How the last direct connection attempt ended. This is the only reliable way to tell
    /// client isolation from an ordinary "nothing there" — see `IsolationReading`.
    private(set) var lastDirectOutcome: DirectOutcome?

    /// What happened when we tried to open a TCP connection straight to another phone.
    ///
    /// The *manner* of failure is the diagnosis:
    /// - `refused` means our packet reached the other device and its network stack answered
    ///   "nothing is listening on that port". Traffic crossed the network, so **client
    ///   isolation is off** — the other phone just didn't have CruiseLAN listening.
    /// - `timedOut` means the packet vanished with no reply at all. On a network where the
    ///   other device is demonstrably online, silent discard is the signature of **client
    ///   isolation**.
    /// - `noRoute` means the network rejected it before it left, usually a different subnet.
    enum DirectOutcome: Equatable, Sendable {
        case connected
        case refused
        case timedOut
        case noRoute
        case other(String)
    }

    /// The verdict on client isolation, with how confident it is and why.
    struct IsolationReading: Equatable {
        enum Answer: Equatable {
            case notTested
            case off
            case likelyOn
            case inconclusive
        }

        let answer: Answer
        let reason: String
    }

    /// Answers "is client isolation turned on?" as far as an app on iOS can.
    ///
    /// iOS gives apps no way to inspect the access point, so there is no setting to read.
    /// What there is: evidence. Anything that crossed between two phones proves isolation is
    /// off; a direct connection that was *refused* proves it too. Only silence is damning.
    var isolationReading: IsolationReading {
        if linksConnected > 0 {
            return .init(answer: .off, reason: "A phone connected through this network, so it is passing traffic between devices.")
        }
        if bonjourPeersSeen > 0 || beaconsHeard > 0 {
            return .init(
                answer: .likelyOn,
                reason: "Another phone was found on this network, but no connection to it could be opened. Discovery is getting through and data isn't, which is how isolation usually behaves."
            )
        }
        switch lastDirectOutcome {
        case .refused:
            return .init(
                answer: .off,
                reason: "The other phone's network stack answered and refused the connection. The packet reached it, so the network is not isolating devices — CruiseLAN just wasn't listening on that phone. Check it's open and on the same Wi-Fi."
            )
        case .timedOut:
            return .init(
                answer: .likelyOn,
                reason: "A direct connection to a phone that is online got no reply at all. Silently dropping traffic between guests is what client isolation does."
            )
        case .noRoute:
            return .init(
                answer: .inconclusive,
                reason: "The network refused to route to that address. The two phones are probably on different parts of the network rather than being isolated."
            )
        case .other(let message):
            return .init(answer: .inconclusive, reason: "The connection failed: \(message)")
        case .connected:
            return .init(answer: .off, reason: "A direct connection succeeded.")
        case nil:
            guard hasSettled else {
                return .init(answer: .notTested, reason: "Still checking this network.")
            }
            return .init(
                answer: .inconclusive,
                reason: "Nothing has been found on this network yet, but nothing has been tried directly either. Scan a friend's QR code to test it properly."
            )
        }
    }
    /// This phone's address, so the page can show a code even before anything connects.
    private(set) var localAddress: String?
    /// When discovery started, so "nothing yet" can be distinguished from "nothing, and
    /// it's been a while" — a verdict after two seconds would be meaningless.
    private(set) var startedAt: Date?

    /// How long the tiers get before "nothing found" is treated as a real answer rather
    /// than as "still looking". Bonjour and the beacon both act well inside this.
    static let verdictDelay: TimeInterval = 20

    var hasSettled: Bool {
        guard let startedAt else { return false }
        return Date.now.timeIntervalSince(startedAt) >= Self.verdictDelay
    }

    /// What the network appears to allow, based on what the tiers actually managed.
    enum Verdict: Equatable {
        case notStarted
        case looking
        /// Normal: discovery works.
        case discoveryWorks
        /// mDNS filtered, broadcast passes.
        case broadcastOnly
        /// Found nobody automatically, but a typed code connected.
        case codeOnly
        /// Found and reached nobody. The network is blocking phone-to-phone traffic.
        case blocked
        /// Couldn't even listen, so nothing was ever possible.
        case cannotListen
    }

    var verdict: Verdict {
        if startedAt == nil { return .notStarted }
        if !isListening { return .cannotListen }
        if linksConnected > 0 {
            if bonjourPeersSeen > 0 { return .discoveryWorks }
            if beaconsHeard > 0 { return .broadcastOnly }
            return .codeOnly
        }
        if bonjourPeersSeen > 0 || beaconsHeard > 0 {
            // Found someone but couldn't connect: discovery passes, data doesn't.
            return hasSettled ? .blocked : .looking
        }
        return hasSettled ? .blocked : .looking
    }

    // MARK: - Recording, called by LANTransport

    func started(address: String?) {
        isListening = true
        listenerError = nil
        bonjourPeersSeen = 0
        beaconsHeard = 0
        linksConnected = 0
        attemptsFailed = 0
        joinCodeAttempted = false
        localAddress = address
        startedAt = .now
    }

    func stopped() {
        isListening = false
        startedAt = nil
    }

    func failedToListen(_ message: String) {
        isListening = false
        listenerError = message
    }

    func noteBonjourPeer() { bonjourPeersSeen += 1 }
    func noteBeacon() { beaconsHeard += 1 }

    func noteLinkConnected() {
        linksConnected += 1
        lastDirectOutcome = .connected
    }

    func noteAttemptFailed() { attemptsFailed += 1 }

    /// The address the last join code pointed at, so the network test can probe it.
    private(set) var lastJoinTarget: String?

    func noteJoinCodeAttempt(target: String? = nil) {
        joinCodeAttempted = true
        if let target { lastJoinTarget = target }
        lastDirectOutcome = nil
    }

    /// Records how a direct attempt ended, which drives `isolationReading`.
    func noteDirectOutcome(_ outcome: DirectOutcome) {
        // Never downgrade a success: one working connection settles the question.
        if lastDirectOutcome == .connected, outcome != .connected { return }
        lastDirectOutcome = outcome
    }
}
