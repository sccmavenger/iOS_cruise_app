import Foundation

/// One thing CruiseLAN measures about itself.
///
/// **Every signal must name the question it answers** (`question`). A number that answers
/// no question is noise: it costs battery, widens the privacy surface, and makes the
/// insights page harder to read. Some questions need several signals together, so each
/// case also declares which `TelemetryQuestion` it contributes to, and the insights page
/// groups them that way rather than listing raw counters.
///
/// **Privacy.** Signals carry a number and, at most, one label drawn from `Dimension` —
/// a closed enum. There is deliberately no case for a nickname, a message, a mesh id, an
/// IP address, a Wi-Fi network name, or a location, and because `Dimension` is closed,
/// a call site cannot smuggle one in later without editing this file. That makes this
/// file the single place a reviewer has to read to know everything the app can report.
/// See docs/decisions/telemetry.md.
nonisolated enum TelemetrySignal: String, CaseIterable, Sendable, Codable {
    // MARK: Reach — "can people reach each other across the ship?"

    /// Which transport tier a link was carried by when it connected.
    case linkConnectedByTier
    /// Hops a received announcement travelled (0 = direct radio neighbour).
    case announceHopCount
    /// Seconds from starting discovery to the first peer appearing.
    case timeToFirstPeer
    /// Contacts reachable, sampled periodically.
    case reachableContacts
    /// A tier was attempted and did not produce a usable link.
    case tierAttemptFailed

    // MARK: Conditions — "what is the radio and network environment?"

    /// Outcome of a network path probe (see `NetworkPathProbe`).
    case pathProbeOutcome
    /// Peers visible while Low Power Mode was in the sampled state.
    case peersVisibleByPowerMode
    /// A capability the app needs was unavailable at start.
    case capabilityUnavailable

    // MARK: Delivery — "do messages actually arrive?"

    /// A chat message was handed to the transport.
    case chatSendAttempt
    /// A chat message had no live path and went to the outbox instead.
    case chatHeldForAway
    /// An inbound packet was refused by validation, by reason.
    case packetRejected
    /// A packet was dropped because a rate limit was hit.
    case rateLimitHit

    // MARK: Stability — "does the app stay connected?"

    /// A link dropped, by reason.
    case linkDropped
    /// Seconds a link survived before dropping.
    case linkLifetime
    /// Seconds from a contact dropping to being reachable again.
    case reconnectLatency

    // MARK: Play — "are games actually playable?"

    /// A match reached the playing phase.
    case matchStarted
    /// A match ended, by how it ended.
    case matchEnded
    /// Seconds from submitting a move to the host's snapshot arriving.
    case moveRoundTrip
    /// The host had to resend state because a client was out of sync.
    case stateResync

    /// The question this signal helps answer. Several signals may share one question.
    var question: TelemetryQuestion {
        switch self {
        case .linkConnectedByTier, .announceHopCount, .timeToFirstPeer, .reachableContacts, .tierAttemptFailed:
            .whichTransportCarriesTraffic
        case .pathProbeOutcome, .capabilityUnavailable:
            .whatBlocksDiscovery
        case .peersVisibleByPowerMode:
            .doesBatterySaverHurtDiscovery
        case .chatSendAttempt, .chatHeldForAway, .packetRejected, .rateLimitHit:
            .doMessagesArrive
        case .linkDropped, .linkLifetime, .reconnectLatency:
            .doesTheAppStayConnected
        case .matchStarted, .matchEnded, .moveRoundTrip, .stateResync:
            .areGamesPlayable
        }
    }

    /// What the recorded value means.
    var unit: Unit {
        switch self {
        case .linkConnectedByTier, .tierAttemptFailed, .pathProbeOutcome, .capabilityUnavailable,
             .chatSendAttempt, .chatHeldForAway, .packetRejected, .rateLimitHit, .linkDropped,
             .matchStarted, .matchEnded, .stateResync:
            .occurrences
        case .timeToFirstPeer, .linkLifetime, .reconnectLatency, .moveRoundTrip:
            .seconds
        case .announceHopCount, .reachableContacts, .peersVisibleByPowerMode:
            .count
        }
    }

    /// Short human label for the insights page.
    var title: String {
        switch self {
        case .linkConnectedByTier: "Links by transport"
        case .announceHopCount: "Mesh hops"
        case .timeToFirstPeer: "Time to first peer"
        case .reachableContacts: "Reachable contacts"
        case .tierAttemptFailed: "Transport attempts failed"
        case .pathProbeOutcome: "Network path probe"
        case .peersVisibleByPowerMode: "Peers seen by power mode"
        case .capabilityUnavailable: "Missing capabilities"
        case .chatSendAttempt: "Chat sends"
        case .chatHeldForAway: "Chat held for away"
        case .packetRejected: "Packets rejected"
        case .rateLimitHit: "Rate limits hit"
        case .linkDropped: "Links dropped"
        case .linkLifetime: "Link lifetime"
        case .reconnectLatency: "Reconnect time"
        case .matchStarted: "Matches started"
        case .matchEnded: "Matches ended"
        case .moveRoundTrip: "Move round trip"
        case .stateResync: "State resyncs"
        }
    }

    nonisolated enum Unit: String, Sendable, Codable {
        /// A tally of events; `sum` is the only meaningful rollup.
        case occurrences
        /// A duration; percentiles are meaningful.
        case seconds
        /// A sampled quantity; the average and max are meaningful.
        case count

        var isDistribution: Bool { self != .occurrences }
    }
}

/// A question the owner actually wants answered. Signals exist to serve these, and the
/// insights page is organised by them so a number without a purpose is obvious.
nonisolated enum TelemetryQuestion: String, CaseIterable, Sendable, Codable {
    case whichTransportCarriesTraffic
    case whatBlocksDiscovery
    case doesBatterySaverHurtDiscovery
    case doMessagesArrive
    case doesTheAppStayConnected
    case areGamesPlayable

    var text: String {
        switch self {
        case .whichTransportCarriesTraffic: "Which transport actually carries traffic, and how far does the mesh reach?"
        case .whatBlocksDiscovery: "When people can't find each other, what is blocking it?"
        case .doesBatterySaverHurtDiscovery: "Does Low Power Mode reduce how many friends are discovered?"
        case .doMessagesArrive: "Do messages reach their recipients, and where are they lost?"
        case .doesTheAppStayConnected: "Do connections hold, and how quickly do they come back?"
        case .areGamesPlayable: "Can a match start, stay in sync, and finish?"
        }
    }

    var signals: [TelemetrySignal] {
        TelemetrySignal.allCases.filter { $0.question == self }
    }
}

/// The complete, closed vocabulary of labels a signal may carry.
///
/// Closed on purpose: the only way to report a new label is to add a case here, which
/// forces the privacy question to be answered at review time rather than at a call site.
/// Keeping it small also keeps the number of distinct series bounded, so the free-tier
/// backend stays free.
nonisolated enum TelemetryDimension: String, Sendable, Codable, CaseIterable {
    // Transport tiers, in the order they're tried.
    case multipeer
    case lanBonjour
    case lanBroadcast
    case lanJoinCode

    // Probe and capability outcomes.
    case wifiUnavailable
    case bluetoothUnavailable
    case bluetoothUnauthorized
    case localNetworkDenied
    case multicastBlocked
    case clientIsolation
    case captivePortal
    case lowPowerMode
    case notificationsDenied
    case ok

    // Generic outcomes.
    case success
    case failure
    case timeout
    case noPeers
    case refused

    // Power mode samples.
    case lowPowerOn
    case lowPowerOff

    // Packet rejection and drop reasons.
    case badSignature
    case unknownSender
    case stale
    case duplicate
    case oversized
    case blockedSender
    case connectionLost
    case localSuspend

    // Match outcomes.
    case completed
    case abandoned

    var label: String {
        switch self {
        case .multipeer: "Multipeer (radio)"
        case .lanBonjour: "LAN — Bonjour"
        case .lanBroadcast: "LAN — broadcast"
        case .lanJoinCode: "LAN — join code"
        case .wifiUnavailable: "Wi-Fi unavailable"
        case .bluetoothUnavailable: "Bluetooth off"
        case .bluetoothUnauthorized: "Bluetooth not permitted"
        case .localNetworkDenied: "Local Network denied"
        case .multicastBlocked: "Multicast blocked"
        case .clientIsolation: "Client isolation"
        case .captivePortal: "Captive portal"
        case .lowPowerMode: "Low Power Mode"
        case .notificationsDenied: "Notifications denied"
        case .ok: "OK"
        case .success: "Success"
        case .failure: "Failure"
        case .timeout: "Timed out"
        case .noPeers: "No peers"
        case .refused: "Refused"
        case .lowPowerOn: "Low Power on"
        case .lowPowerOff: "Low Power off"
        case .badSignature: "Bad signature"
        case .unknownSender: "Unknown sender"
        case .stale: "Too old"
        case .duplicate: "Duplicate"
        case .oversized: "Oversized"
        case .blockedSender: "Blocked sender"
        case .connectionLost: "Connection lost"
        case .localSuspend: "App backgrounded"
        case .completed: "Completed"
        case .abandoned: "Abandoned"
        }
    }
}
