import CoreBluetooth
import Foundation
import Network
import Observation

/// Watches the conditions CruiseLAN needs in order to find people, and records them.
///
/// This reports *facts only* — what the radios and permissions currently allow. It makes no
/// judgement about what the user should do; that's `ConnectivityDiagnosis`, which reads
/// these facts and the transport's own results.
///
/// **Why this exists.** Before this, a phone that couldn't see anyone looked identical to a
/// phone with nobody nearby. Low Power Mode, a denied Local Network prompt, and Wi-Fi being
/// off all produce the same empty screen, and the owner had no way to tell them apart mid-
/// cruise. Each of those is now a distinct, reportable condition.
///
/// **Passive by design.** No permission is requested here and no manager is created: reading
/// `CBManager.authorization` is a static lookup, and instantiating a second
/// `CBCentralManager` purely to read power state would prompt the user again and waste radio
/// time. Bluetooth *power* comes from `NudgeService`, which already owns a manager.
@MainActor
@Observable
final class NetworkPathProbe {
    /// What the system currently permits. Equatable so a sample is only recorded on change.
    struct Conditions: Equatable, Sendable {
        /// A Wi-Fi interface is carrying the usable path. Required for any LAN tier, and for
        /// Multipeer's peer-to-peer Wi-Fi.
        var hasWiFi = false
        var hasCellular = false
        var hasWiredOrOther = false
        /// iOS refused the app access to the local network. Fatal for LAN discovery, and the
        /// single most likely cause of "I can't see anyone" after a reinstall.
        var isLocalNetworkDenied = false
        /// The path exists but the system wants traffic minimised (Low Data Mode).
        var isConstrained = false
        var isExpensive = false
        /// Low Power Mode throttles background work and peer-to-peer Wi-Fi scanning.
        var isLowPowerMode = false
        var bluetooth: BluetoothAvailability = .unknown
        /// No usable path at all.
        var isOffline = true

        /// Whether any LAN tier could possibly work right now.
        var canUseLAN: Bool { hasWiFi && !isLocalNetworkDenied }

        /// Whether short-range radio discovery could work.
        var canUseRadio: Bool { bluetooth == .ready || hasWiFi }
    }

    enum BluetoothAvailability: Equatable, Sendable {
        case unknown
        case ready
        case poweredOff
        case unauthorized
        case unsupported

        var isUsable: Bool { self == .ready }
    }

    private(set) var conditions = Conditions()
    /// When the conditions last changed, for the troubleshooting page.
    private(set) var lastChange = Date.now

    private let telemetry: TelemetryStore
    private let monitor = NWPathMonitor()
    private var monitorTask: Task<Void, Never>?
    private var powerModeTask: Task<Void, Never>?
    /// Set by `NudgeService` so Bluetooth power is read from the manager that already exists.
    @ObservationIgnored var bluetoothStateProvider: (() -> CBManagerState?)?

    init(telemetry: TelemetryStore) {
        self.telemetry = telemetry
    }

    deinit {
        monitor.cancel()
    }

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self, monitor] in
            for await path in monitor {
                guard let self else { return }
                self.apply(path)
            }
        }
        monitor.start(queue: .main)

        // Low Power Mode has no path event; it posts its own notification.
        powerModeTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: .NSProcessInfoPowerStateDidChange
            )
            for await _ in notifications {
                guard let self else { return }
                self.refresh()
            }
        }
        refresh()
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        powerModeTask?.cancel()
        powerModeTask = nil
        monitor.cancel()
    }

    /// Re-reads everything that isn't delivered by a path update.
    func refresh() {
        apply(monitor.currentPath)
    }

    private var lastLoggedPath = ""

    private func apply(_ path: NWPath) {
        // Every distinct path, in full, so a report shows exactly when Wi-Fi came and went,
        // which router was in use, and what iOS said about local network access.
        let summary = "status \(path.status), reason \(path.unsatisfiedReason), interfaces \(path.availableInterfaces.map { "\($0.name)(\($0.type))" }), gateways \(path.gateways.map { LANTransport.describe($0) }), IPv4 \(path.supportsIPv4), IPv6 \(path.supportsIPv6), DNS \(path.supportsDNS), expensive \(path.isExpensive), constrained \(path.isConstrained), low power \(ProcessInfo.processInfo.isLowPowerModeEnabled)"
        if summary != lastLoggedPath {
            lastLoggedPath = summary
            DiagnosticLog.shared.note("path", summary)
        }
        var updated = Conditions()
        updated.hasWiFi = path.usesInterfaceType(.wifi)
        updated.hasCellular = path.usesInterfaceType(.cellular)
        updated.hasWiredOrOther = path.usesInterfaceType(.wiredEthernet) || path.usesInterfaceType(.other)
        updated.isConstrained = path.isConstrained
        updated.isExpensive = path.isExpensive
        updated.isOffline = path.status != .satisfied
        updated.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        updated.isLocalNetworkDenied = path.unsatisfiedReason == .localNetworkDenied
        updated.bluetooth = resolveBluetooth()

        guard updated != conditions else { return }
        conditions = updated
        lastChange = .now
        record(updated)
    }

    private func resolveBluetooth() -> BluetoothAvailability {
        switch CBManager.authorization {
        case .denied, .restricted: return .unauthorized
        case .notDetermined: return .unknown
        case .allowedAlways: break
        @unknown default: return .unknown
        }
        switch bluetoothStateProvider?() {
        case .poweredOn: return .ready
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .resetting, .unknown, nil: return .unknown
        @unknown default: return .unknown
        }
    }

    /// Records one probe outcome. Only the most significant blocker is reported, so the
    /// insights page shows "what stopped this" rather than every co-occurring condition —
    /// a phone with Wi-Fi off usually has several flags set and only one real cause.
    private func record(_ conditions: Conditions) {
        telemetry.count(.pathProbeOutcome, Self.primaryBlocker(conditions) ?? .ok)
        if conditions.isLowPowerMode {
            telemetry.count(.capabilityUnavailable, .lowPowerMode)
        }
    }

    /// The one condition most worth acting on, in the order a user should fix them.
    static func primaryBlocker(_ conditions: Conditions) -> TelemetryDimension? {
        if conditions.isLocalNetworkDenied { return .localNetworkDenied }
        if !conditions.hasWiFi && !conditions.bluetooth.isUsable {
            return conditions.bluetooth == .unauthorized ? .bluetoothUnauthorized : .wifiUnavailable
        }
        if !conditions.hasWiFi { return .wifiUnavailable }
        switch conditions.bluetooth {
        case .poweredOff: return .bluetoothUnavailable
        case .unauthorized: return .bluetoothUnauthorized
        case .ready, .unknown, .unsupported: break
        }
        if conditions.isLowPowerMode { return .lowPowerMode }
        return nil
    }

    /// Samples how many peers are visible, split by power mode, so the owner's hunch that
    /// battery saver hurts discovery can be checked against data instead of argued about.
    func samplePeerVisibility(peerCount: Int) {
        telemetry.observe(
            .peersVisibleByPowerMode,
            Double(peerCount),
            conditions.isLowPowerMode ? .lowPowerOn : .lowPowerOff
        )
    }
}
