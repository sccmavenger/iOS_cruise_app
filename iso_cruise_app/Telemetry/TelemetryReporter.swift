import Foundation
import os

/// Uploads aggregated telemetry to the collection endpoint, if the user turned sharing on.
///
/// **Opt-in.** Nothing is uploaded unless `TelemetryStore.isSharingEnabled` is true. The
/// store keeps recording locally either way, because the troubleshooting page runs off the
/// same numbers and that data never leaves the phone.
///
/// **No shipped credentials.** The app holds no API key. Anything compiled into an iOS
/// binary is extractable with `strings`, so a "secret" here would be a secret in name only.
/// The endpoint is instead protected on the server side: it accepts only this exact schema,
/// every label must match a known `TelemetryDimension`, bodies are size-capped, and
/// Cloudflare rate-limits by IP. The worst an attacker can do is add noise to aggregate
/// counters, which is why no decision should rest on a single install's numbers.
///
/// **Endpoint.** Read from the `CruiseLANTelemetryEndpoint` Info.plist key so it can differ
/// per build and the repo carries no hostname. Missing or non-HTTPS: uploads are skipped.
@MainActor
final class TelemetryReporter {
    /// Smallest gap between uploads. Aggregates are cheap and the window is long; there is
    /// no reason to talk to the network more often than this.
    static let minimumInterval: TimeInterval = 6 * 60 * 60
    /// Refuse to send anything larger than this. The schema is bounded, so exceeding it
    /// means something is wrong locally and shouldn't be pushed.
    static let maxBodyBytes = 64 * 1024
    private static let lastUploadKey = "telemetry.lastUpload"
    private static let logger = Logger(subsystem: "com.dannyguillory.cruiselan", category: "telemetry")

    /// What the endpoint receives. A flat, explicit shape so the server can validate it
    /// strictly and reject anything else.
    struct Payload: Codable, Sendable, Equatable {
        /// Bumped when the shape changes, so old builds' reports stay readable.
        var schema = 1
        var installId: String
        var appVersion: String
        var systemVersion: String
        var deviceClass: String
        var windowStart: Date
        var windowEnd: Date
        var measurements: [Measurement]

        struct Measurement: Codable, Sendable, Equatable {
            var signal: String
            var dimension: String?
            var count: Int
            var sum: Double
            var min: Double
            var max: Double
            var buckets: [Int]
        }
    }

    private let store: TelemetryStore
    private let session: URLSession
    private let endpoint: URL?
    private let now: () -> Date

    init(store: TelemetryStore, session: URLSession = .shared, now: @escaping () -> Date = { .now }) {
        self.store = store
        self.session = session
        self.now = now
        self.endpoint = Self.configuredEndpoint()
    }

    /// Whether a destination is configured at all. The insights page shows this so a build
    /// without an endpoint doesn't look like a build with a broken one.
    var isConfigured: Bool { endpoint != nil }

    var lastUpload: Date? {
        UserDefaults.standard.object(forKey: Self.lastUploadKey) as? Date
    }

    /// Uploads the current window if sharing is on, an endpoint exists, and enough time has
    /// passed. Clears the window on success so nothing is counted twice.
    func uploadIfDue() async {
        guard store.isSharingEnabled, let endpoint else { return }
        if let last = lastUpload, now().timeIntervalSince(last) < Self.minimumInterval { return }
        let snapshot = store.snapshot()
        guard !snapshot.aggregates.isEmpty else { return }

        do {
            let body = try JSONEncoder.telemetry.encode(payload(from: snapshot))
            guard body.count <= Self.maxBodyBytes else {
                Self.logger.error("Telemetry body too large (\(body.count, privacy: .public) bytes); dropping window")
                store.reset()
                return
            }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 20
            // Telemetry must never compete with the mesh for the radio or hold up a launch.
            request.networkServiceType = .background
            request.allowsExpensiveNetworkAccess = false
            request.allowsConstrainedNetworkAccess = false

            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Self.logger.notice("Telemetry upload rejected")
                return
            }
            UserDefaults.standard.set(now(), forKey: Self.lastUploadKey)
            store.reset()
        } catch {
            // Keep the window; it'll go with the next attempt. Shipboard Wi-Fi fails often.
            Self.logger.notice("Telemetry upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func payload(from snapshot: TelemetryStore.Snapshot) -> Payload {
        Payload(
            installId: snapshot.installId,
            appVersion: snapshot.appVersion,
            systemVersion: snapshot.systemVersion,
            deviceClass: snapshot.deviceClass,
            windowStart: snapshot.windowStart,
            windowEnd: now(),
            measurements: snapshot.aggregates
                .map { series, aggregate in
                    Payload.Measurement(
                        signal: series.signal.rawValue,
                        dimension: series.dimension?.rawValue,
                        count: aggregate.count,
                        sum: aggregate.sum,
                        min: aggregate.lowest,
                        max: aggregate.highest,
                        buckets: aggregate.buckets
                    )
                }
                .sorted { ($0.signal, $0.dimension ?? "") < ($1.signal, $1.dimension ?? "") }
        )
    }

    /// HTTPS only. A plaintext endpoint would put this data on the ship's network in the
    /// clear, which is exactly the network we're least willing to trust.
    private static func configuredEndpoint() -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CruiseLANTelemetryEndpoint") as? String,
              !raw.isEmpty, !raw.hasPrefix("$"),
              let url = URL(string: raw), url.scheme?.lowercased() == "https"
        else { return nil }
        return url
    }
}

extension JSONEncoder {
    /// Shared encoder for telemetry payloads: ISO-8601 dates so the server needs no
    /// knowledge of Apple's reference date.
    static var telemetry: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
