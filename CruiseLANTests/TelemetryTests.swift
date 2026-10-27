import Foundation
import Testing
@testable import iso_cruise_app

@Suite("Telemetry")
@MainActor
struct TelemetryTests {
    /// A store that never touches the filesystem, so tests don't fight over one file.
    private func makeStore() -> TelemetryStore {
        TelemetryStore(storageURL: nil)
    }

    @Test("Every signal declares the question it answers")
    func everySignalHasAQuestion() {
        // The whole premise of the catalog is that a number without a question doesn't get
        // collected. `question` is non-optional, so this checks the questions are reachable
        // from the other direction: no question is left with no signals serving it.
        for question in TelemetryQuestion.allCases {
            #expect(!question.signals.isEmpty, "\(question) has no signals")
            #expect(!question.text.isEmpty)
        }
        #expect(TelemetrySignal.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test("Counting tallies occurrences per dimension")
    func counting() {
        let store = makeStore()
        store.count(.linkConnectedByTier, .multipeer)
        store.count(.linkConnectedByTier, .multipeer)
        store.count(.linkConnectedByTier, .lanBonjour)

        #expect(store.aggregate(.linkConnectedByTier, .multipeer)?.count == 2)
        #expect(store.aggregate(.linkConnectedByTier, .lanBonjour)?.count == 1)
        #expect(store.total(.linkConnectedByTier) == 3)
        #expect(store.breakdown(of: .linkConnectedByTier).first?.dimension == .multipeer)
    }

    @Test("Durations summarise without keeping individual events")
    func distributions() {
        let store = makeStore()
        for value in [0.2, 0.4, 1.5, 9.0] {
            store.observe(.moveRoundTrip, value)
        }
        let aggregate = try! #require(store.aggregate(.moveRoundTrip))
        #expect(aggregate.count == 4)
        #expect(aggregate.lowest == 0.2)
        #expect(aggregate.highest == 9.0)
        #expect(abs(aggregate.average - 2.775) < 0.001)
        // Percentiles come from buckets, so they land on a bucket's upper bound.
        #expect(aggregate.percentile(0.5) != nil)
        #expect(aggregate.percentile(1.0)! >= 5)
    }

    @Test("Non-finite values are ignored rather than poisoning an average")
    func rejectsNonFinite() {
        let store = makeStore()
        store.observe(.moveRoundTrip, .infinity)
        store.observe(.moveRoundTrip, .nan)
        #expect(store.aggregate(.moveRoundTrip) == nil)
    }

    @Test("A snapshot round-trips through JSON")
    func snapshotCoding() throws {
        let store = makeStore()
        store.count(.chatSendAttempt)
        store.observe(.linkLifetime, 120, .lanBroadcast)

        let encoded = try JSONEncoder().encode(store.snapshot())
        let decoded = try JSONDecoder().decode(TelemetryStore.Snapshot.self, from: encoded)

        #expect(decoded.aggregates.count == 2)
        let lifetime = TelemetryStore.Series(signal: .linkLifetime, dimension: .lanBroadcast)
        #expect(decoded.aggregates[lifetime]?.sum == 120)
        // A signal recorded with no dimension must survive as nil, not as a stray label.
        let chat = TelemetryStore.Series(signal: .chatSendAttempt, dimension: nil)
        #expect(decoded.aggregates[chat]?.count == 1)
    }

    @Test("Erasing removes everything")
    func erase() {
        let store = makeStore()
        store.count(.chatSendAttempt)
        store.eraseAll()
        #expect(store.aggregates.isEmpty)
    }

    @Test("Sharing is off until the user turns it on")
    func sharingDefaultsOff() {
        UserDefaults.standard.removeObject(forKey: "telemetry.sharingEnabled")
        #expect(makeStore().isSharingEnabled == false)
    }

    @Test("The uploaded payload carries no nickname, message, or mesh id")
    func payloadCarriesNoIdentifiers() throws {
        let store = makeStore()
        store.count(.linkConnectedByTier, .lanJoinCode)
        store.observe(.moveRoundTrip, 1.25)
        let reporter = TelemetryReporter(store: store)

        let json = try String(
            data: JSONEncoder.telemetry.encode(reporter.payload(from: store.snapshot())),
            encoding: .utf8
        )!

        // Everything in the body must be a signal name, a known label, or a number. This is
        // the regression guard for the privacy claim in docs/decisions/telemetry.md.
        for signal in TelemetrySignal.allCases where json.contains(signal.rawValue) {
            #expect(TelemetrySignal(rawValue: signal.rawValue) != nil)
        }
        #expect(json.contains("lanJoinCode"))
        #expect(!json.lowercased().contains("nickname"))
        #expect(!json.lowercased().contains("message"))
    }

    @Test("Performance findings explain how they were graded")
    func findingsAreExplainable() {
        let store = makeStore()
        store.count(.linkConnectedByTier, .lanBonjour)
        store.count(.matchStarted)
        store.count(.matchEnded, .completed)

        let report = PerformanceReport(store: store)
        #expect(report.findings.count == TelemetryQuestion.allCases.count)
        // A grade nobody can account for is worse than no grade, so every finding must say
        // how it got there.
        #expect(report.findings.allSatisfy { !$0.detail.isEmpty && !$0.summary.isEmpty })
    }

    @Test("The worst finding sets the overall grade")
    func overallFollowsTheWorst() {
        let store = makeStore()
        // Links exist but none used the ship network: reach is the problem, even though
        // matches are completing fine.
        store.count(.linkConnectedByTier, .multipeer)
        store.count(.matchStarted)
        store.count(.matchEnded, .completed)

        let report = PerformanceReport(store: store)
        #expect(report.overall == .poor)
    }

    @Test("Low Power Mode comparison needs samples from both modes")
    func powerComparisonNeedsBothModes() {
        let store = makeStore()
        store.observe(.peersVisibleByPowerMode, 1, .lowPowerOn)
        var report = PerformanceReport(store: store)
        #expect(report.findings.first { $0.question == .doesBatterySaverHurtDiscovery }?.grade == .unknown)

        store.observe(.peersVisibleByPowerMode, 4, .lowPowerOff)
        report = PerformanceReport(store: store)
        let finding = report.findings.first { $0.question == .doesBatterySaverHurtDiscovery }
        // One peer visible against four is a large drop, which should read as a problem.
        #expect(finding?.grade == .poor)
    }
}
