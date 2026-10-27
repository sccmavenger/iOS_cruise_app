import Foundation

/// Rolls the raw signals up into "how is the app doing", which is the question the
/// performance page exists to answer.
///
/// Each `Finding` scores one `TelemetryQuestion` from the signals that serve it. Scoring is
/// deliberately simple and explainable — a ratio against a stated target — because a health
/// number nobody can account for is worse than no number at all. Every finding carries the
/// `detail` string that explains how it was derived, and the page shows it.
struct PerformanceReport {
    enum Grade: Int, Comparable, Sendable {
        case unknown = 0
        case poor = 1
        case fair = 2
        case good = 3

        static func < (lhs: Grade, rhs: Grade) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .unknown: "No data"
            case .poor: "Needs work"
            case .fair: "Fair"
            case .good: "Good"
            }
        }
    }

    struct Finding: Identifiable, Sendable {
        let question: TelemetryQuestion
        let grade: Grade
        /// One line stating what the data shows.
        let summary: String
        /// How the grade was derived, so it can be argued with.
        let detail: String

        var id: TelemetryQuestion { question }
    }

    let findings: [Finding]

    /// The worst graded finding drives the overall read: a mesh that can't connect isn't
    /// "mostly fine" because chat delivery looks healthy.
    var overall: Grade {
        let graded = findings.map(\.grade).filter { $0 != .unknown }
        return graded.min() ?? .unknown
    }

    @MainActor
    init(store: TelemetryStore) {
        findings = TelemetryQuestion.allCases.map { question in
            switch question {
            case .whichTransportCarriesTraffic: Self.transportFinding(store)
            case .whatBlocksDiscovery: Self.blockerFinding(store)
            case .doesBatterySaverHurtDiscovery: Self.powerFinding(store)
            case .doMessagesArrive: Self.deliveryFinding(store)
            case .doesTheAppStayConnected: Self.stabilityFinding(store)
            case .areGamesPlayable: Self.playFinding(store)
            }
        }
    }

    // MARK: - Per-question scoring

    @MainActor
    private static func transportFinding(_ store: TelemetryStore) -> Finding {
        let byTier = store.breakdown(of: .linkConnectedByTier)
        let connected = byTier.reduce(0) { $0 + $1.aggregate.count }
        guard connected > 0 else {
            return Finding(question: .whichTransportCarriesTraffic, grade: .unknown,
                           summary: "No links recorded yet.",
                           detail: "Nothing has connected since the last window began.")
        }
        let lanTiers: Set<TelemetryDimension> = [.lanBonjour, .lanBroadcast, .lanJoinCode]
        let lan = byTier.filter { $0.dimension.map(lanTiers.contains) ?? false }
            .reduce(0) { $0 + $1.aggregate.count }
        let lanShare = Double(lan) / Double(connected)
        let top = byTier.first?.dimension?.label ?? "unknown"
        // LAN carrying a meaningful share is the whole point of the shipwide work: radio
        // alone means people have to be in the same room.
        let grade: Grade = lan == 0 ? .poor : (lanShare < 0.5 ? .fair : .good)
        let hops = store.aggregate(.announceHopCount)
        let reach = hops.map { " Announcements averaged \(String(format: "%.1f", $0.average)) hops." } ?? ""
        return Finding(
            question: .whichTransportCarriesTraffic,
            grade: grade,
            summary: "\(Int(lanShare * 100))% of \(connected) links used the ship LAN; most common path was \(top).",
            detail: "Graded on the share of links carried by a LAN tier rather than radio. 0% is Needs work, under half is Fair.\(reach)"
        )
    }

    @MainActor
    private static func blockerFinding(_ store: TelemetryStore) -> Finding {
        let probes = store.breakdown(of: .pathProbeOutcome)
        let total = probes.reduce(0) { $0 + $1.aggregate.count }
        guard total > 0 else {
            return Finding(question: .whatBlocksDiscovery, grade: .unknown,
                           summary: "No probes recorded yet.",
                           detail: "The network path probe hasn't run in this window.")
        }
        let healthy = probes.first { $0.dimension == .ok }?.aggregate.count ?? 0
        let share = Double(healthy) / Double(total)
        let worst = probes.filter { $0.dimension != .ok }.first?.dimension?.label
        let grade: Grade = share >= 0.8 ? .good : (share >= 0.4 ? .fair : .poor)
        return Finding(
            question: .whatBlocksDiscovery,
            grade: grade,
            summary: worst.map { "\(Int(share * 100))% of \(total) probes were clear; top blocker was \($0)." }
                ?? "All \(total) probes were clear.",
            detail: "Graded on the share of probes reporting no blocker. 80% or better is Good, 40% or better is Fair."
        )
    }

    @MainActor
    private static func powerFinding(_ store: TelemetryStore) -> Finding {
        let on = store.aggregate(.peersVisibleByPowerMode, .lowPowerOn)
        let off = store.aggregate(.peersVisibleByPowerMode, .lowPowerOff)
        guard let on, let off, !on.isEmpty, !off.isEmpty else {
            return Finding(question: .doesBatterySaverHurtDiscovery, grade: .unknown,
                           summary: "Need samples in both power modes to compare.",
                           detail: "Collects peers-visible samples separately with Low Power Mode on and off; a comparison needs at least one of each.")
        }
        // The owner suspects battery saver suppresses discovery. This is the test: same
        // metric, split by power mode, so the two averages can be compared directly.
        let ratio = off.average > 0 ? on.average / off.average : 1
        let drop = (1 - ratio) * 100
        let grade: Grade = drop >= 30 ? .poor : (drop >= 10 ? .fair : .good)
        return Finding(
            question: .doesBatterySaverHurtDiscovery,
            grade: grade,
            summary: String(format: "%.1f peers visible on Low Power vs %.1f off — a %.0f%% difference.",
                            on.average, off.average, drop),
            detail: "Compares the average peers-visible sample in each power mode. A 30% or worse drop is Needs work, 10% or worse is Fair. Positive numbers mean Low Power Mode is costing discovery."
        )
    }

    @MainActor
    private static func deliveryFinding(_ store: TelemetryStore) -> Finding {
        let attempts = store.total(.chatSendAttempt)
        let held = store.total(.chatHeldForAway)
        guard attempts > 0 else {
            return Finding(question: .doMessagesArrive, grade: .unknown,
                           summary: "No messages sent yet.",
                           detail: "Nothing to grade until a message is sent.")
        }
        let heldShare = Double(held) / Double(attempts)
        let rejected = store.total(.packetRejected)
        let grade: Grade = heldShare >= 0.4 ? .poor : (heldShare >= 0.15 ? .fair : .good)
        return Finding(
            question: .doMessagesArrive,
            grade: grade,
            summary: "\(attempts) sent, \(held) held for someone away (\(Int(heldShare * 100))%), \(rejected) packets rejected.",
            detail: "Graded on the share of messages with no live path at send time. 40% or more is Needs work, 15% or more is Fair. Held messages still arrive later, so this measures reach, not loss."
        )
    }

    @MainActor
    private static func stabilityFinding(_ store: TelemetryStore) -> Finding {
        let lifetime = store.aggregate(.linkLifetime)
        guard let lifetime, !lifetime.isEmpty else {
            return Finding(question: .doesTheAppStayConnected, grade: .unknown,
                           summary: "No completed links recorded yet.",
                           detail: "Link lifetime is recorded when a link drops; none have.")
        }
        let median = lifetime.percentile(0.5) ?? lifetime.average
        let reconnect = store.aggregate(.reconnectLatency)
        // Five minutes of median uptime is the bar: shorter than that and people notice
        // the app "losing" their friends mid-game.
        let grade: Grade = median >= 300 ? .good : (median >= 60 ? .fair : .poor)
        let reconnectText = reconnect.flatMap { $0.percentile(0.5) }
            .map { " Median reconnect took about \(Int($0))s." } ?? ""
        return Finding(
            question: .doesTheAppStayConnected,
            grade: grade,
            summary: "Median link lasted about \(Int(median))s across \(lifetime.count) links.\(reconnectText)",
            detail: "Graded on median link lifetime. Five minutes or more is Good, one minute or more is Fair."
        )
    }

    @MainActor
    private static func playFinding(_ store: TelemetryStore) -> Finding {
        let started = store.total(.matchStarted)
        guard started > 0 else {
            return Finding(question: .areGamesPlayable, grade: .unknown,
                           summary: "No matches started yet.",
                           detail: "Nothing to grade until a match begins.")
        }
        let completed = store.aggregate(.matchEnded, .completed)?.count ?? 0
        let share = Double(completed) / Double(started)
        let resyncs = store.total(.stateResync)
        let roundTrip = store.aggregate(.moveRoundTrip).flatMap { $0.percentile(0.95) }
        let latencyText = roundTrip.map { " 95% of moves confirmed within \(String(format: "%.2g", $0))s." } ?? ""
        let grade: Grade = share >= 0.7 ? .good : (share >= 0.4 ? .fair : .poor)
        return Finding(
            question: .areGamesPlayable,
            grade: grade,
            summary: "\(completed) of \(started) matches finished (\(Int(share * 100))%), \(resyncs) resyncs.\(latencyText)",
            detail: "Graded on the share of started matches that reached a result. 70% or more is Good, 40% or more is Fair. Abandoned matches usually mean someone went out of range."
        )
    }
}
