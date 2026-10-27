import CryptoKit
import Foundation
import UIKit

/// Builds the text file a user sends when something went wrong.
///
/// **Why not just export `DebugTrace`.** That trace is compiled out of release builds and
/// records nicknames, which is exactly what must not be in a file a user emails to a stranger.
/// This report is assembled from things already known to be safe to share: the telemetry
/// aggregates (counts and timings only, see docs/decisions/telemetry.md), the connectivity
/// checks, and a short ring of redacted events.
///
/// **One tap, no credentials.** The cruise notes floated auto-filing a GitHub issue or
/// dropping into a OneDrive share. Both need a credential in the app, and anything in an iOS
/// binary is extractable — a token shipped this way would let anyone file issues or write to
/// the share as the owner. So the report goes out through the system share sheet instead:
/// one tap, then the user picks Mail, Messages, or Files. A prefilled GitHub issue link is
/// offered alongside, which opens a browser with the body already written and lets the user
/// attach the file themselves. No secret, and the user always sees what they're sending.
@MainActor
struct DiagnosticReport {
    let text: String

    /// A filename with a timestamp, so several reports from one person don't collide.
    static var fileName: String {
        let stamp = Date.now.formatted(
            .iso8601.year().month().day().dateSeparator(.omitted)
                .time(includingFractionalSeconds: false).timeSeparator(.omitted)
        )
        return "CruiseLAN-diagnostics-\(stamp).txt"
    }

    init(telemetry: TelemetryStore, conditions: NetworkPathProbe.Conditions, linkedCount: Int, contactCount: Int,
         lan: LANDiagnostics? = nil, nearbyRadioEnabled: Bool? = nil, linkMedia: [LinkMedium] = [],
         networkTest: NetworkTest? = nil, wifiName: String? = nil) {
        var lines: [String] = []

        lines.append("CruiseLAN diagnostics")
        lines.append("Generated: \(Date.now.formatted(.iso8601))")
        lines.append("")
        lines.append("This file contains no messages and no names of people — people appear only")
        lines.append("as anonymous handles like peer-3fa2. It does contain technical network details:")
        lines.append("local (not internet) addresses, timings, error codes, and the Wi-Fi name if you")
        lines.append("chose to show it in Troubleshooting. You can read it before sending.")
        lines.append("")

        lines.append("== App ==")
        lines.append("Version: \(TelemetryStore.appVersion)")
        lines.append("System: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        // Class, not model: the exact model plus OS version narrows a small beta group far
        // more than a bug report needs.
        lines.append("Device class: \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")")
        lines.append("Low Power Mode: \(conditions.isLowPowerMode ? "on" : "off")")
        lines.append("")

        lines.append("== Connectivity ==")
        let diagnosis = ConnectivityDiagnosis(conditions: conditions, reach: lan?.verdict)
        lines.append("Summary: \(diagnosis.headline)")
        for check in diagnosis.checks {
            lines.append("- \(check.title): \(check.state.label) — \(check.detail)")
        }
        lines.append("Phones linked: \(linkedCount)")
        lines.append("Contacts known: \(contactCount)")
        if let nearbyRadioEnabled {
            lines.append("Nearby radio: \(nearbyRadioEnabled ? "on" : "off (Wi-Fi network only)")")
        }
        if !linkMedia.isEmpty {
            let counts = Dictionary(grouping: linkMedia, by: \.label).map { "\($0.key) \($0.value.count)" }.sorted()
            lines.append("Links by path: \(counts.joined(separator: ", "))")
        }
        lines.append("")

        // What the Wi-Fi path managed on this network since CruiseLAN last started looking.
        // This is what tells "the phones never saw each other" (discovery blocked) apart from
        // "they saw each other but couldn't connect" (traffic between guests blocked).
        if let lan {
            lines.append("== Wi-Fi network (since the app last started looking) ==")
            if let wifiName { lines.append("Wi-Fi name: \(wifiName)") }
            lines.append("Listening for connections: \(lan.isListening ? "yes" : "no\(lan.listenerError.map { " (\($0))" } ?? "")")")
            // Only the network part of the address: enough to tell whether two phones share
            // a network, not enough to identify this phone.
            lines.append("Network range: \(lan.localAddress.map(Self.networkRange) ?? "no Wi-Fi address")")
            lines.append("Phones found by Bonjour: \(lan.bonjourPeersSeen)")
            lines.append("Broadcast signals heard: \(lan.beaconsHeard)")
            lines.append("Connections made: \(lan.linksConnected)")
            lines.append("Connection attempts that failed: \(lan.attemptsFailed)")
            lines.append("Last direct connection: \(lan.lastDirectOutcome.map(Self.describe) ?? "none tried")")
            lines.append("Join code tried: \(lan.joinCodeAttempted ? "yes" : "no")")
            let reading = lan.isolationReading
            lines.append("Client isolation: \(reading.answer) — \(reading.reason)")
            lines.append("")
        }

        lines.append("== Performance ==")
        let report = PerformanceReport(store: telemetry)
        lines.append("Overall: \(report.overall.label)")
        for finding in report.findings {
            lines.append("- [\(finding.grade.label)] \(finding.question.text)")
            lines.append("    \(finding.summary)")
        }
        lines.append("")

        lines.append("== Measurements ==")
        lines.append("Window started: \(telemetry.windowStart.formatted(.iso8601))")
        if telemetry.aggregates.isEmpty {
            lines.append("(nothing recorded yet)")
        } else {
            for signal in TelemetrySignal.allCases {
                let breakdown = telemetry.breakdown(of: signal)
                guard !breakdown.isEmpty else { continue }
                lines.append("\(signal.rawValue):")
                for entry in breakdown {
                    let label = entry.dimension?.rawValue ?? "all"
                    let aggregate = entry.aggregate
                    switch signal.unit {
                    case .occurrences:
                        lines.append("    \(label) = \(aggregate.count)")
                    case .seconds, .count:
                        lines.append(String(
                            format: "    %@ n=%d avg=%.3f min=%.3f max=%.3f",
                            label, aggregate.count, aggregate.average, aggregate.lowest, aggregate.highest
                        ))
                    }
                }
            }
        }
        lines.append("")

        lines.append("== Network test ==")
        if let networkTest, !networkTest.lines.isEmpty {
            lines.append(contentsOf: networkTest.lines)
        } else {
            lines.append("(not run: tap Run network test in Troubleshooting for a much more detailed report)")
        }
        lines.append("")

        lines.append("== Recent events (oldest first) ==")
        let events = DiagnosticLog.shared.snapshot()
        if events.isEmpty {
            lines.append("(none)")
        } else {
            lines.append(contentsOf: events)
        }

        text = lines.joined(separator: "\n")
    }

    /// "192.168.4.23" → "192.168.4.x".
    static func networkRange(_ address: String) -> String {
        var parts = address.split(separator: ".").map(String.init)
        guard parts.count == 4 else { return "unknown" }
        parts[3] = "x"
        return parts.joined(separator: ".")
    }

    private static func describe(_ outcome: LANDiagnostics.DirectOutcome) -> String {
        switch outcome {
        case .connected: "connected"
        case .refused: "refused (the other phone answered, so the network passes traffic)"
        case .timedOut: "timed out (no answer: typical of a network that blocks guests from each other)"
        case .noRoute: "no route (probably different parts of the network)"
        case .other(let message): "failed: \(message)"
        }
    }

    /// Writes the report to a temporary file for `ShareLink`. Returns nil if it can't be
    /// written, in which case the UI offers the text inline instead.
    func writeToTemporaryFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(Self.fileName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// A GitHub issue URL with the body prefilled. The report itself is *not* in the URL —
    /// it would blow past the length limit and bury the description — so the body asks the
    /// user to attach the file they just saved.
    static func githubIssueURL(repository: String) -> URL? {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        let body = """
        **What happened?**


        **What did you expect?**


        ---
        Diagnostics attached (use the paperclip below after saving the file from CruiseLAN).
        App version: \(TelemetryStore.appVersion)
        System: \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        components?.queryItems = [
            URLQueryItem(name: "title", value: "CruiseLAN report"),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "from-app"),
        ]
        return components?.url
    }
}

/// A small ring of recent, already-redacted events, available in release builds.
///
/// Deliberately separate from `DebugTrace`: that one is for the developer and records
/// nicknames, and it's compiled out of release. This one exists so a user's report has some
/// recent history in it, so it only ever records a short fixed phrase plus numbers. There is
/// no call that can put a name or a message in here.
nonisolated final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()

    /// Large enough to hold a whole test session in detail (the owner asked for logs that
    /// answer questions without a back-and-forth), and still only kept in memory.
    private static let capacity = 3_000

    private let lock = NSLock()
    private var entries: [String] = []

    private init() {}

    /// Records one event. `detail` must be a fixed phrase or a number — never user content.
    func record(_ event: Event, detail: String = "") {
        append("\(event.rawValue)\(detail.isEmpty ? "" : " \(detail)")")
    }

    /// Records a technical fact about networking: states, error codes, timings, local
    /// addresses, counts. Never a nickname or message: people appear only as `handle(_:)`.
    func note(_ area: String, _ message: String) {
        append("[\(area)] \(message)")
    }

    /// A short anonymous label for a person or phone, the same within one install so a
    /// log can follow one peer, but salted per install so it can't be matched across reports.
    func handle(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data((salt + "|" + raw).utf8))
        return "peer-" + digest.prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    private let salt = UUID().uuidString

    private static let timeFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true).time(includingFractionalSeconds: true)

    private func append(_ message: String) {
        let line = "\(Date.now.formatted(Self.timeFormat)) \(message)"
        lock.lock()
        defer { lock.unlock() }
        entries.append(line)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    /// The closed set of things that can be logged. Closed for the same reason
    /// `TelemetryDimension` is: it makes the privacy claim checkable by reading one list.
    nonisolated enum Event: String, Sendable {
        case transportStarted = "transport.started"
        case transportFailed = "transport.failed"
        case peerFound = "peer.found"
        case peerLost = "peer.lost"
        case linkConnected = "link.connected"
        case linkDropped = "link.dropped"
        case packetRejected = "packet.rejected"
        case chatSent = "chat.sent"
        case chatHeld = "chat.held"
        case matchStarted = "match.started"
        case matchEnded = "match.ended"
        case suspended = "app.suspended"
        case resumed = "app.resumed"
    }
}
