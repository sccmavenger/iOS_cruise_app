import Foundation
import Observation
import os

/// Collects `TelemetrySignal` measurements, aggregates them on the device, and keeps them
/// for the insights page.
///
/// **Aggregates, not events.** Nothing stores a timeline of individual events. Each
/// (signal, dimension) pair collapses into one `Aggregate` the moment it's recorded. That
/// keeps memory flat, makes the data cheap to upload, and — most importantly — removes the
/// ordering information that would let a reader reconstruct what one person did and when.
///
/// **Bounded by construction.** `TelemetrySignal` and `TelemetryDimension` are both closed
/// enums, so the number of series has a hard compile-time ceiling. There is no code path
/// that can grow this store without a source change.
///
/// Recording is always on because the troubleshooting page needs it and the data never
/// leaves the device by itself. *Sharing* it is opt-in; see `TelemetryReporter`.
@MainActor
@Observable
final class TelemetryStore {
    /// Identifies one measured series.
    struct Series: Hashable, Codable, Sendable {
        let signal: TelemetrySignal
        let dimension: TelemetryDimension?
    }

    /// A collapsed summary of every value recorded for one series.
    struct Aggregate: Codable, Sendable, Equatable {
        private(set) var count = 0
        private(set) var sum: Double = 0
        private(set) var minimum: Double = .greatestFiniteMagnitude
        private(set) var maximum: Double = -.greatestFiniteMagnitude
        /// Values per bucket of `Aggregate.bucketUpperBounds`, plus a final overflow bucket.
        private(set) var buckets = [Int](repeating: 0, count: Aggregate.bucketUpperBounds.count + 1)

        /// Upper bounds for the latency/size histogram, in the signal's own unit.
        /// Chosen to straddle what matters here: sub-second is "instant", 1–10s is
        /// "noticeable", and anything past 30s reads as "it didn't work".
        static let bucketUpperBounds: [Double] = [0.25, 0.5, 1, 2, 5, 10, 30, 60, 300]

        var average: Double { count > 0 ? sum / Double(count) : 0 }
        var isEmpty: Bool { count == 0 }
        var lowest: Double { count > 0 ? minimum : 0 }
        var highest: Double { count > 0 ? maximum : 0 }

        mutating func add(_ value: Double) {
            count += 1
            sum += value
            minimum = Swift.min(minimum, value)
            maximum = Swift.max(maximum, value)
            let index = Self.bucketUpperBounds.firstIndex { value <= $0 } ?? Self.bucketUpperBounds.count
            buckets[index] += 1
        }

        /// Approximate percentile from the histogram. Returns the upper bound of the bucket
        /// the percentile falls in, so it reads as "most moves landed under 2s" rather than
        /// implying a precision the buckets don't have.
        func percentile(_ fraction: Double) -> Double? {
            guard count > 0 else { return nil }
            let target = Int((Double(count) * fraction).rounded(.up))
            var seen = 0
            for (index, bucketCount) in buckets.enumerated() {
                seen += bucketCount
                if seen >= target {
                    return index < Self.bucketUpperBounds.count ? Self.bucketUpperBounds[index] : maximum
                }
            }
            return maximum
        }
    }

    /// Everything collected in the current window, ready to persist or upload.
    struct Snapshot: Codable, Sendable, Equatable {
        /// Rotating pseudonym; see `TelemetryInstallId`.
        var installId: String
        var appVersion: String
        var systemVersion: String
        /// Device *class* only ("iPhone"), never the exact model: on a small beta the exact
        /// model plus OS version is close to a fingerprint.
        var deviceClass: String
        var windowStart: Date
        var aggregates: [Series: Aggregate]

        enum CodingKeys: String, CodingKey {
            case installId, appVersion, systemVersion, deviceClass, windowStart, entries
        }

        /// `[Series: Aggregate]` can't round-trip through JSON with a struct key, so it's
        /// encoded as an array of pairs.
        private struct Entry: Codable {
            var signal: TelemetrySignal
            var dimension: TelemetryDimension?
            var aggregate: Aggregate
        }

        init(installId: String, appVersion: String, systemVersion: String, deviceClass: String,
             windowStart: Date, aggregates: [Series: Aggregate]) {
            self.installId = installId
            self.appVersion = appVersion
            self.systemVersion = systemVersion
            self.deviceClass = deviceClass
            self.windowStart = windowStart
            self.aggregates = aggregates
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            installId = try container.decode(String.self, forKey: .installId)
            appVersion = try container.decode(String.self, forKey: .appVersion)
            systemVersion = try container.decode(String.self, forKey: .systemVersion)
            deviceClass = try container.decode(String.self, forKey: .deviceClass)
            windowStart = try container.decode(Date.self, forKey: .windowStart)
            let entries = try container.decode([Entry].self, forKey: .entries)
            aggregates = Dictionary(
                entries.map { (Series(signal: $0.signal, dimension: $0.dimension), $0.aggregate) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(installId, forKey: .installId)
            try container.encode(appVersion, forKey: .appVersion)
            try container.encode(systemVersion, forKey: .systemVersion)
            try container.encode(deviceClass, forKey: .deviceClass)
            try container.encode(windowStart, forKey: .windowStart)
            try container.encode(
                aggregates.map { Entry(signal: $0.key.signal, dimension: $0.key.dimension, aggregate: $0.value) },
                forKey: .entries
            )
        }
    }

    private static let logger = Logger(subsystem: "com.dannyguillory.cruiselan", category: "telemetry")

    private(set) var aggregates: [Series: Aggregate] = [:]
    private(set) var windowStart: Date

    /// Whether the user agreed to share aggregates. Recording is local regardless.
    var isSharingEnabled: Bool {
        didSet {
            guard isSharingEnabled != oldValue else { return }
            UserDefaults.standard.set(isSharingEnabled, forKey: Self.sharingKey)
        }
    }

    private static let sharingKey = "telemetry.sharingEnabled"

    private let storageURL: URL?
    private let now: () -> Date
    private let installIdProvider: TelemetryInstallId

    init(
        storageURL: URL? = TelemetryStore.defaultStorageURL,
        installId: TelemetryInstallId = TelemetryInstallId(),
        now: @escaping () -> Date = { .now }
    ) {
        self.storageURL = storageURL
        self.installIdProvider = installId
        self.now = now
        self.isSharingEnabled = UserDefaults.standard.bool(forKey: Self.sharingKey)
        self.windowStart = now()
        if let restored = Self.read(from: storageURL) {
            aggregates = restored.aggregates
            windowStart = restored.windowStart
        }
    }

    static var defaultStorageURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("telemetry.json")
    }

    // MARK: - Recording

    /// Tallies one occurrence of `signal`.
    func count(_ signal: TelemetrySignal, _ dimension: TelemetryDimension? = nil) {
        observe(signal, 1, dimension)
    }

    /// Records a measured `value` for `signal`, in the signal's own unit.
    func observe(_ signal: TelemetrySignal, _ value: Double, _ dimension: TelemetryDimension? = nil) {
        guard value.isFinite else { return }
        aggregates[Series(signal: signal, dimension: dimension), default: Aggregate()].add(value)
    }

    /// Records how long something took, from a start instant.
    func observe(_ signal: TelemetrySignal, since start: Date, _ dimension: TelemetryDimension? = nil) {
        observe(signal, now().timeIntervalSince(start), dimension)
    }

    // MARK: - Reading

    func aggregate(_ signal: TelemetrySignal, _ dimension: TelemetryDimension? = nil) -> Aggregate? {
        aggregates[Series(signal: signal, dimension: dimension)]
    }

    /// Every dimension recorded for `signal`, with its aggregate, most frequent first.
    func breakdown(of signal: TelemetrySignal) -> [(dimension: TelemetryDimension?, aggregate: Aggregate)] {
        aggregates
            .filter { $0.key.signal == signal }
            .map { (dimension: $0.key.dimension, aggregate: $0.value) }
            .sorted { $0.aggregate.count > $1.aggregate.count }
    }

    /// Total occurrences recorded for `signal` across all dimensions.
    func total(_ signal: TelemetrySignal) -> Int {
        aggregates.reduce(into: 0) { result, entry in
            if entry.key.signal == signal { result += entry.value.count }
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            installId: installIdProvider.current(),
            appVersion: Self.appVersion,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceClass: Self.deviceClass,
            windowStart: windowStart,
            aggregates: aggregates
        )
    }

    // MARK: - Lifecycle

    /// Writes the current aggregates so a relaunch doesn't lose them. Called when the app
    /// backgrounds; cheap enough to call more often.
    func persist() {
        guard let storageURL else { return }
        do {
            let data = try JSONEncoder().encode(snapshot())
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: storageURL, options: .atomic)
        } catch {
            Self.logger.error("Telemetry persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Clears everything after a successful upload, starting a new window.
    func reset() {
        aggregates.removeAll()
        windowStart = now()
        persist()
    }

    /// Deletes all collected data, on the device too. Offered in the UI so the answer to
    /// "what do you have about me" is always "nothing, if you say so".
    func eraseAll() {
        aggregates.removeAll()
        windowStart = now()
        installIdProvider.rotate()
        if let storageURL { try? FileManager.default.removeItem(at: storageURL) }
    }

    private static func read(from url: URL?) -> Snapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Device class only. `utsname` would give the exact model, which on a small TestFlight
    /// group narrows an install down much further than this needs to.
    private static var deviceClass: String {
        #if os(iOS)
        ProcessInfo.processInfo.isiOSAppOnMac ? "Mac" : "iPhone"
        #else
        "Unknown"
        #endif
    }
}

/// A rotating pseudonym used to group one device's aggregates together.
///
/// Rotates every `lifetime` so reports can't be chained into a long-term history of one
/// person, and lives in `UserDefaults` rather than the Keychain *on purpose*: Keychain
/// items can outlive a delete-and-reinstall, which would make "remove the app" stop
/// meaning "start over".
nonisolated struct TelemetryInstallId: Sendable {
    static let lifetime: TimeInterval = 14 * 24 * 60 * 60

    private let idKey = "telemetry.installId"
    private let issuedKey = "telemetry.installIdIssued"
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { .now }) {
        self.now = now
    }

    func current() -> String {
        let defaults = UserDefaults.standard
        let issued = defaults.object(forKey: issuedKey) as? Date
        if let existing = defaults.string(forKey: idKey), let issued,
           now().timeIntervalSince(issued) < Self.lifetime {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: idKey)
        defaults.set(now(), forKey: issuedKey)
        return fresh
    }

    func rotate() {
        UserDefaults.standard.removeObject(forKey: idKey)
        UserDefaults.standard.removeObject(forKey: issuedKey)
    }
}
